#!/usr/bin/env bash
# deploy_to_pods.sh — 把实验环境部署到指定 pod 列表
#
# 从跳板运行:
#   export KUBECONFIG=/tmp/config-vc-c550-h3c-test-weibozhen.yaml
#   bash /tmp/deploy_to_pods.sh
#
# 做什么:
#   1. pip install probing (从 PyPI)
#   2. 编译 Greyhound libmcclprobe.so (in-place)
#   3. 编译 XPUTimer libxpu_timer_metax.so (in-place)
#   4. 解压 bundle 到 /workspace/baseline-exp/
set -euo pipefail

VCCTL="${VCCTL:-/usr/local/bin/vcctl}"
BUNDLE="/workspace/baseline-exp"
PARALLEL="${PARALLEL:-8}"

# 后 64 台（跳过不可用的）
PODS=(
  muxi-test-1-worker-63 muxi-test-1-worker-64 muxi-test-1-worker-65
  muxi-test-1-worker-66 muxi-test-1-worker-67 muxi-test-1-worker-68
  muxi-test-1-worker-69 muxi-test-1-worker-70 muxi-test-1-worker-71
  muxi-test-1-worker-72 muxi-test-1-worker-73 muxi-test-1-worker-74
  muxi-test-1-worker-75 muxi-test-1-worker-76 muxi-test-1-worker-77
  muxi-test-1-worker-79 muxi-test-1-worker-80 muxi-test-1-worker-81
  muxi-test-1-worker-82 muxi-test-1-worker-83 muxi-test-1-worker-84
  muxi-test-1-worker-85 muxi-test-1-worker-86 muxi-test-1-worker-87
  muxi-test-1-worker-88 muxi-test-1-worker-89 muxi-test-1-worker-90
  muxi-test-1-worker-91 muxi-test-1-worker-92 muxi-test-1-worker-93
  muxi-test-1-worker-94 muxi-test-1-worker-95 muxi-test-1-worker-96
  muxi-test-1-worker-97 muxi-test-1-worker-98 muxi-test-1-worker-99
  muxi-test-1-worker-100 muxi-test-1-worker-101 muxi-test-1-worker-102
  muxi-test-1-worker-103 muxi-test-1-worker-104 muxi-test-1-worker-105
  muxi-test-1-worker-106 muxi-test-1-worker-107 muxi-test-1-worker-108
  muxi-test-1-worker-109 muxi-test-1-worker-110 muxi-test-1-worker-111
  muxi-test-1-worker-112 muxi-test-1-worker-113 muxi-test-1-worker-114
  muxi-test-1-worker-115 muxi-test-1-worker-116 muxi-test-1-worker-117
  muxi-test-1-worker-118 muxi-test-1-worker-119 muxi-test-1-worker-120
  muxi-test-1-worker-121 muxi-test-1-worker-122 muxi-test-1-worker-123
  muxi-test-1-worker-124 muxi-test-1-worker-125 muxi-test-1-worker-126
)

deploy_one() {
  local pod="$1"
  echo "[deploy] $pod starting..."

  # Step 1: Install probing + stress-ng
  $VCCTL pod exec "$pod" -- bash -c '
    /opt/conda/bin/pip install probing -q 2>/dev/null
    apt-get update -qq && apt-get install -y -qq stress-ng 2>/dev/null || true
  ' > /dev/null 2>&1

  # Step 2: Compile Greyhound libmcclprobe.so
  $VCCTL pod exec "$pod" -- bash -c '
    mkdir -p /workspace/baseline-exp/greyhound
    if [[ ! -f /workspace/baseline-exp/greyhound/libmcclprobe.so ]]; then
      cat > /workspace/baseline-exp/greyhound/mcclprobe.cpp << '\''CPPEOF'\''
// Minimal MCCL probe: intercepts mcclAllReduce and logs timing to shared memory ring buffer
#include <dlfcn.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <chrono>
#include <atomic>
#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>

// Minimal MCCL types
typedef struct mcclComm* mcclComm_t;
typedef int mcclResult_t;
typedef int mcclDataType_t;
typedef int mcclRedOp_t;
typedef struct MCstream_st* mcStream_t;

#define NUM_FIELDS 14
#define BUFFER_SIZE 65536
#define METADATA_FIELDS 4
#define SHM_NAME "ncclRecord"

static int64_t* shm_buf = nullptr;
static std::atomic<int64_t>* shm_head = nullptr;
static std::atomic<int64_t>* shm_count = nullptr;
static int shm_fd = -1;

typedef mcclResult_t (*mcclAllReduce_fn)(const void*, void*, size_t, mcclDataType_t, mcclRedOp_t, mcclComm_t, mcStream_t);
static mcclAllReduce_fn real_allreduce = nullptr;

static void init_shm() {
    size_t total = (NUM_FIELDS * BUFFER_SIZE + METADATA_FIELDS) * sizeof(int64_t);
    shm_fd = shm_open(SHM_NAME, O_CREAT | O_RDWR, 0666);
    if (shm_fd < 0) return;
    ftruncate(shm_fd, total);
    void* p = mmap(NULL, total, PROT_READ|PROT_WRITE, MAP_SHARED, shm_fd, 0);
    if (p == MAP_FAILED) { close(shm_fd); return; }
    int64_t* base = (int64_t*)p;
    base[0] = NUM_FIELDS;
    base[1] = BUFFER_SIZE;
    base[2] = 0;  // num_records
    base[3] = 0;  // head
    shm_count = (std::atomic<int64_t>*)&base[2];
    shm_head = (std::atomic<int64_t>*)&base[3];
    shm_buf = base + METADATA_FIELDS;
}

static void record_op(size_t count, int64_t duration_ns, int rank) {
    if (!shm_buf) return;
    int64_t idx = shm_count->fetch_add(1) % BUFFER_SIZE;
    int64_t* rec = shm_buf + idx * NUM_FIELDS;
    auto now = std::chrono::steady_clock::now().time_since_epoch();
    rec[0] = 0;  // comm_addr placeholder
    rec[1] = shm_count->load();  // call_number
    rec[2] = (int64_t)count;
    rec[3] = 0; rec[4] = 0;  // buff placeholders
    rec[5] = 0;  // datatype
    rec[6] = getpid();
    rec[7] = std::chrono::duration_cast<std::chrono::nanoseconds>(now).count();
    rec[8] = 0;  // device
    rec[9] = rank;  // global_rank
    rec[10] = 0;  // aux
    rec[11] = duration_ns;
    rec[12] = 0;  // num_devices
    rec[13] = 0;  // event_id
}

extern "C" mcclResult_t mcclAllReduce(const void* sendbuff, void* recvbuff, size_t count,
                                       mcclDataType_t datatype, mcclRedOp_t op,
                                       mcclComm_t comm, mcStream_t stream) {
    if (!real_allreduce) {
        void* h = dlopen("libmccl.so", RTLD_NOW | RTLD_GLOBAL);
        if (h) real_allreduce = (mcclAllReduce_fn)dlsym(h, "mcclAllReduce");
        if (!real_allreduce) real_allreduce = (mcclAllReduce_fn)dlsym(RTLD_NEXT, "mcclAllReduce");
    }
    if (!shm_buf) init_shm();

    auto t0 = std::chrono::steady_clock::now();
    mcclResult_t ret = real_allreduce ? real_allreduce(sendbuff, recvbuff, count, datatype, op, comm, stream) : 1;
    auto t1 = std::chrono::steady_clock::now();
    int64_t dur = std::chrono::duration_cast<std::chrono::nanoseconds>(t1 - t0).count();
    int rank = 0;
    char* rank_env = getenv("RANK");
    if (rank_env) rank = atoi(rank_env);
    record_op(count, dur, rank);
    return ret;
}

__attribute__((constructor))
static void init() {
    init_shm();
    fprintf(stderr, "[mcclprobe] Greyhound probe loaded for pid=%d\n", getpid());
}
CPPEOF
      cd /workspace/baseline-exp/greyhound
      g++ -shared -fPIC -O2 -o libmcclprobe.so mcclprobe.cpp -ldl -lrt -lpthread 2>&1
    fi
    ls -la /workspace/baseline-exp/greyhound/libmcclprobe.so
  ' 2>&1 | tail -3

  # Step 3: Compile XPUTimer hook
  $VCCTL pod exec "$pod" -- bash -c '
    mkdir -p /workspace/baseline-exp/xputimer
    if [[ ! -f /workspace/baseline-exp/xputimer/libxpu_timer_metax.so ]]; then
      cat > /workspace/baseline-exp/xputimer/hook.cpp << '\''CPPEOF'\''
// Minimal XPUTimer-style hook: intercepts mcLaunchKernel, measures duration
#include <dlfcn.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <chrono>
#include <atomic>
#include <fstream>
#include <mutex>
#include <string>
#include <unordered_map>

struct dim3 { unsigned int x, y, z; };
typedef struct MCstream_st* mcStream_t;
typedef int mcError_t;

typedef mcError_t (*mcLaunchKernel_fn)(const void*, dim3, dim3, void**, size_t, mcStream_t);
static mcLaunchKernel_fn real_launch = nullptr;

static std::atomic<uint64_t> total_kernels{0};
static std::atomic<uint64_t> slow_kernels{0};  // > 10ms
static std::atomic<uint64_t> total_ns{0};
static const uint64_t SLOW_THRESHOLD_NS = 10000000;  // 10ms

static std::string dump_dir;

extern "C" mcError_t mcLaunchKernel(const void* func, dim3 gridDim, dim3 blockDim,
                                     void** args, size_t sharedMem, mcStream_t stream) {
    if (!real_launch) {
        real_launch = (mcLaunchKernel_fn)dlsym(RTLD_NEXT, "mcLaunchKernel");
    }
    auto t0 = std::chrono::steady_clock::now();
    mcError_t ret = real_launch ? real_launch(func, gridDim, blockDim, args, sharedMem, stream) : 0;
    auto t1 = std::chrono::steady_clock::now();
    uint64_t dur = std::chrono::duration_cast<std::chrono::nanoseconds>(t1 - t0).count();
    total_kernels++;
    total_ns += dur;
    if (dur > SLOW_THRESHOLD_NS) slow_kernels++;
    return ret;
}

__attribute__((constructor))
static void init() {
    char* d = getenv("XPU_TIMER_DUMP_DIR");
    if (d) dump_dir = d;
    fprintf(stderr, "[xpu_timer_metax] hook loaded pid=%d\n", getpid());
}

__attribute__((destructor))
static void fini() {
    fprintf(stderr, "[xpu_timer_metax] kernels=%lu slow=%lu total_ms=%.1f\n",
            total_kernels.load(), slow_kernels.load(), total_ns.load() / 1e6);
    if (!dump_dir.empty()) {
        std::string path = dump_dir + "/metrics.txt";
        FILE* f = fopen(path.c_str(), "w");
        if (f) {
            fprintf(f, "xpu_timer_common_kernel_total %lu\n", total_kernels.load());
            fprintf(f, "xpu_timer_common_kernel_slow %lu\n", slow_kernels.load());
            fprintf(f, "xpu_timer_common_kernel_total_ms %.1f\n", total_ns.load() / 1e6);
            fclose(f);
        }
    }
}
CPPEOF
      cd /workspace/baseline-exp/xputimer
      g++ -shared -fPIC -O2 -o libxpu_timer_metax.so hook.cpp -ldl -lpthread 2>&1
    fi
    ls -la /workspace/baseline-exp/xputimer/libxpu_timer_metax.so
  ' 2>&1 | tail -3

  echo "[deploy] $pod DONE"
}

echo "Deploying to ${#PODS[@]} pods (parallel=$PARALLEL)..."
running=0
for pod in "${PODS[@]}"; do
  deploy_one "$pod" &
  running=$((running + 1))
  if [[ $running -ge $PARALLEL ]]; then
    wait -n
    running=$((running - 1))
  fi
done
wait
echo "ALL PODS DEPLOYED"
