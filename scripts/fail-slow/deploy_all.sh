#!/usr/bin/env bash
# deploy_all.sh — 把实验环境批量部署到所有需要的 pod
#
# 从本机（Mac）运行。先通过跳板上传 tarball 到每个 pod，
# 然后在每个 pod 上 pip install probing + 编译 .so
#
# 用法: bash deploy_all.sh
set -euo pipefail

KUBECONFIG_PATH="/tmp/config-vc-c550-h3c-test-weibozhen.yaml"
JOB="muxi-test-1"
BUNDLE_TAR="/tmp/bc-bundle.tar.gz"
BUNDLE_DIR="/workspace/baseline-exp"
JUMP="ais-cf3e61a5"

# All pods we need (back-64 range, skip non-Running ones)
# worker-63..126, skip 78
PODS=()
for i in $(seq 63 77) $(seq 79 126); do
  PODS+=("${JOB}-worker-${i}")
done

echo "Deploying to ${#PODS[@]} pods..."

# Phase 1: Upload tarball to all pods (parallel, via jump host)
upload_one() {
  local pod="$1"
  cat "$BUNDLE_TAR" | ssh "$JUMP" "export KUBECONFIG=$KUBECONFIG_PATH; vcctl pod exec -i $pod -- bash -c 'mkdir -p $BUNDLE_DIR && cat > /tmp/bc-bundle.tar.gz && tar -xzf /tmp/bc-bundle.tar.gz -C $BUNDLE_DIR && rm /tmp/bc-bundle.tar.gz'" 2>/dev/null
  if [[ $? -eq 0 ]]; then
    echo "  [upload] $pod OK"
  else
    echo "  [upload] $pod FAIL"
  fi
}

PARALLEL=8
running=0
for pod in "${PODS[@]}"; do
  upload_one "$pod" &
  running=$((running + 1))
  if [[ $running -ge $PARALLEL ]]; then
    wait -n 2>/dev/null || true
    running=$((running - 1))
  fi
done
wait
echo "Phase 1 (upload) complete."

# Phase 2: pip install + compile .so (parallel via jump)
setup_one() {
  local pod="$1"
  ssh "$JUMP" "export KUBECONFIG=$KUBECONFIG_PATH; vcctl pod exec $pod -- bash -c '
    # pip install probing
    /opt/conda/bin/pip install probing -q 2>/dev/null
    # install stress-ng
    apt-get install -y -qq stress-ng 2>/dev/null || true
    # compile greyhound
    mkdir -p $BUNDLE_DIR/greyhound $BUNDLE_DIR/xputimer
    if [[ ! -f $BUNDLE_DIR/greyhound/libmcclprobe.so ]]; then
      cat > $BUNDLE_DIR/greyhound/p.cpp << \"CEOF\"
#include <dlfcn.h>
#include <cstdio>
#include <cstdlib>
#include <chrono>
#include <atomic>
#include <sys/mman.h>
#include <fcntl.h>
#include <unistd.h>
typedef struct mcclComm* mcclComm_t;
typedef int mcclResult_t,mcclDataType_t,mcclRedOp_t;
typedef struct MCstream_st* mcStream_t;
static int64_t* shm_buf=nullptr;
static std::atomic<int64_t>* shm_count=nullptr;
typedef mcclResult_t(*ar_fn)(const void*,void*,size_t,mcclDataType_t,mcclRedOp_t,mcclComm_t,mcStream_t);
static ar_fn real_ar=nullptr;
static void init_shm(){int fd=shm_open(\"ncclRecord\",O_CREAT|O_RDWR,0666);if(fd<0)return;size_t sz=(14*65536+4)*8;ftruncate(fd,sz);int64_t*b=(int64_t*)mmap(NULL,sz,PROT_READ|PROT_WRITE,MAP_SHARED,fd,0);if(b==MAP_FAILED){close(fd);return;}b[0]=14;b[1]=65536;b[2]=0;b[3]=0;shm_count=(std::atomic<int64_t>*)&b[2];shm_buf=b+4;}
extern \"C\" mcclResult_t mcclAllReduce(const void*s,void*r,size_t cnt,mcclDataType_t dt,mcclRedOp_t op,mcclComm_t comm,mcStream_t stream){if(!real_ar){void*h=dlopen(\"libmccl.so\",RTLD_NOW|RTLD_GLOBAL);if(h)real_ar=(ar_fn)dlsym(h,\"mcclAllReduce\");if(!real_ar)real_ar=(ar_fn)dlsym(RTLD_NEXT,\"mcclAllReduce\");}if(!shm_buf)init_shm();auto t0=std::chrono::steady_clock::now();mcclResult_t ret=real_ar?real_ar(s,r,cnt,dt,op,comm,stream):1;auto t1=std::chrono::steady_clock::now();int64_t dur=std::chrono::duration_cast<std::chrono::nanoseconds>(t1-t0).count();if(shm_buf){int64_t idx=shm_count->fetch_add(1)%65536;int64_t*rec=shm_buf+idx*14;rec[2]=(int64_t)cnt;rec[6]=getpid();rec[11]=dur;char*re=getenv(\"RANK\");rec[9]=re?atoi(re):0;}return ret;}
__attribute__((constructor))static void init(){init_shm();}
CEOF
      g++ -shared -fPIC -O2 -o $BUNDLE_DIR/greyhound/libmcclprobe.so $BUNDLE_DIR/greyhound/p.cpp -ldl -lrt -lpthread 2>/dev/null
    fi
    # compile xputimer
    if [[ ! -f $BUNDLE_DIR/xputimer/libxpu_timer_metax.so ]]; then
      cat > $BUNDLE_DIR/xputimer/h.cpp << \"CEOF\"
#include <dlfcn.h>
#include <cstdio>
#include <cstdlib>
#include <chrono>
#include <atomic>
#include <string>
struct dim3{unsigned x,y,z;};
typedef struct MCstream_st* mcStream_t;
typedef int mcError_t;
typedef mcError_t(*lf)(const void*,dim3,dim3,void**,size_t,mcStream_t);
static lf real_l=nullptr;
static std::atomic<uint64_t> tk{0},sk{0},tn{0};
extern \"C\" mcError_t mcLaunchKernel(const void*f,dim3 g,dim3 b,void**a,size_t sm,mcStream_t s){if(!real_l)real_l=(lf)dlsym(RTLD_NEXT,\"mcLaunchKernel\");auto t0=std::chrono::steady_clock::now();mcError_t r=real_l?real_l(f,g,b,a,sm,s):0;auto t1=std::chrono::steady_clock::now();uint64_t d=std::chrono::duration_cast<std::chrono::nanoseconds>(t1-t0).count();tk++;tn+=d;if(d>10000000)sk++;return r;}
__attribute__((constructor))static void init(){fprintf(stderr,\"[xpu_timer] pid=%d\\n\",getpid());}
__attribute__((destructor))static void fini(){fprintf(stderr,\"[xpu_timer] k=%lu s=%lu ms=%.1f\\n\",tk.load(),sk.load(),tn.load()/1e6);char*d=getenv(\"XPU_TIMER_DUMP_DIR\");if(d){std::string p=std::string(d)+\"/m.txt\";FILE*f=fopen(p.c_str(),\"w\");if(f){fprintf(f,\"tk %lu\\nsk %lu\\nms %.1f\\n\",tk.load(),sk.load(),tn.load()/1e6);fclose(f);}}}
CEOF
      g++ -shared -fPIC -O2 -o $BUNDLE_DIR/xputimer/libxpu_timer_metax.so $BUNDLE_DIR/xputimer/h.cpp -ldl -lpthread 2>/dev/null
    fi
    echo SETUP_OK
  '" 2>/dev/null
  if [[ $? -eq 0 ]]; then
    echo "  [setup] $pod OK"
  else
    echo "  [setup] $pod FAIL"
  fi
}

running=0
for pod in "${PODS[@]}"; do
  setup_one "$pod" &
  running=$((running + 1))
  if [[ $running -ge $PARALLEL ]]; then
    wait -n 2>/dev/null || true
    running=$((running - 1))
  fi
done
wait
echo "Phase 2 (setup) complete."
echo "ALL DEPLOYED."
