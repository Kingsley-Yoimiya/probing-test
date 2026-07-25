/* Ascend Greyhound S2 collect-min: LD_PRELOAD HCCL interposer.
 *
 * Hooks HcclAllReduce / Broadcast / AllGather / ReduceScatter / Send / Recv,
 * forwards via dlsym(RTLD_NEXT) or libhccl.so, appends JSONL events.
 *
 * Env:
 *   GREYHOUND_DUMP=/path/to/events.jsonl   (required for collect; default /tmp/hcclprobe.collect.jsonl)
 *   GREYHOUND_DEBUG=1                      stderr banner
 *   GREYHOUND_STUB_MARKER=/path            load marker (S1)
 *   GREYHOUND_HCCL_SO=/path/to/libhccl.so  optional explicit lib
 *
 * Does NOT change Greyhound detection thresholds — timing/metadata only.
 */
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <dlfcn.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

#define FS_GH_COLLECT_VERSION "ascend-collect-min-0.2"

#ifdef __cplusplus
extern "C" {
#endif

typedef void *HcclComm;
typedef void *aclrtStream;
typedef int32_t HcclResult;
typedef int32_t HcclDataType;
typedef int32_t HcclReduceOp;

typedef HcclResult (*fn_allreduce_t)(void *, void *, uint64_t, HcclDataType, HcclReduceOp,
                                     HcclComm, aclrtStream);
typedef HcclResult (*fn_bcast_t)(void *, uint64_t, HcclDataType, uint32_t, HcclComm, aclrtStream);
typedef HcclResult (*fn_allgather_t)(void *, void *, uint64_t, HcclDataType, HcclComm, aclrtStream);
typedef HcclResult (*fn_reducescatter_t)(void *, void *, uint64_t, HcclDataType, HcclReduceOp,
                                         HcclComm, aclrtStream);
typedef HcclResult (*fn_send_t)(void *, uint64_t, HcclDataType, uint32_t, HcclComm, aclrtStream);
typedef HcclResult (*fn_recv_t)(void *, uint64_t, HcclDataType, uint32_t, HcclComm, aclrtStream);

static pthread_mutex_t g_mu = PTHREAD_MUTEX_INITIALIZER;
static FILE *g_dump = NULL;
static int g_inited = 0;
static uint64_t g_seq = 0;

static fn_allreduce_t real_AllReduce;
static fn_bcast_t real_Broadcast;
static fn_allgather_t real_AllGather;
static fn_reducescatter_t real_ReduceScatter;
static fn_send_t real_Send;
static fn_recv_t real_Recv;

static double now_unix(void) {
  struct timeval tv;
  gettimeofday(&tv, NULL);
  return (double)tv.tv_sec + (double)tv.tv_usec * 1e-6;
}

static void resolve_log(const char *msg) {
  if (getenv("GREYHOUND_DEBUG") && *getenv("GREYHOUND_DEBUG") &&
      strcmp(getenv("GREYHOUND_DEBUG"), "0") != 0) {
    fprintf(stderr, "[hcclprobe-collect] %s dlerr=%s\n", msg, dlerror());
    fflush(stderr);
  }
}

/* Prefer explicit libhccl handle — RTLD_NEXT alone is flaky under torch_npu. */
static void *resolve_sym(const char *name) {
  static const char *k_cands[] = {
      NULL, /* filled from GREYHOUND_HCCL_SO */
      "/usr/local/Ascend/cann-8.5.0/aarch64-linux/lib64/libhccl.so",
      "/usr/local/Ascend/ascend-toolkit/latest/lib64/libhccl.so",
      "libhccl.so",
      NULL,
  };
  const char *env = getenv("GREYHOUND_HCCL_SO");
  k_cands[0] = (env && *env) ? env : k_cands[1];

  for (int i = 0; k_cands[i]; ++i) {
    const char *so = k_cands[i];
    if (!so || !*so)
      continue;
    void *h = dlopen(so, RTLD_NOW | RTLD_NOLOAD);
    if (!h)
      h = dlopen(so, RTLD_NOW | RTLD_LOCAL);
    if (!h)
      continue;
    void *p = dlsym(h, name);
    if (p) {
      /* Guard: must not resolve to our own interposer. */
      Dl_info self, got;
      if (dladdr((void *)resolve_sym, &self) && dladdr(p, &got) && self.dli_fbase &&
          got.dli_fbase == self.dli_fbase) {
        resolve_log("skip self-symbol");
        continue;
      }
      return p;
    }
  }
  void *p = dlsym(RTLD_NEXT, name);
  if (p) {
    Dl_info self, got;
    if (!(dladdr((void *)resolve_sym, &self) && dladdr(p, &got) &&
          self.dli_fbase && got.dli_fbase == self.dli_fbase))
      return p;
  }
  resolve_log(name);
  return NULL;
}

static void open_dump_locked(void) {
  if (g_dump)
    return;
  const char *path = getenv("GREYHOUND_DUMP");
  if (!path || !*path)
    path = "/tmp/hcclprobe.collect.jsonl";
  g_dump = fopen(path, "a");
  if (!g_dump && getenv("GREYHOUND_DEBUG")) {
    fprintf(stderr, "[hcclprobe-collect] WARN cannot open dump=%s\n", path);
  }
}

static void ensure_init(void) {
  if (g_inited)
    return;
  pthread_mutex_lock(&g_mu);
  if (!g_inited) {
    real_AllReduce = (fn_allreduce_t)resolve_sym("HcclAllReduce");
    real_Broadcast = (fn_bcast_t)resolve_sym("HcclBroadcast");
    real_AllGather = (fn_allgather_t)resolve_sym("HcclAllGather");
    real_ReduceScatter = (fn_reducescatter_t)resolve_sym("HcclReduceScatter");
    real_Send = (fn_send_t)resolve_sym("HcclSend");
    real_Recv = (fn_recv_t)resolve_sym("HcclRecv");
    open_dump_locked();
    g_inited = 1;
  }
  pthread_mutex_unlock(&g_mu);
}

static void emit(const char *op, uint64_t count, int32_t dtype, int32_t aux,
                 double t0, double t1, int32_t rc) {
  ensure_init();
  pthread_mutex_lock(&g_mu);
  open_dump_locked();
  if (g_dump) {
    uint64_t seq = ++g_seq;
    fprintf(g_dump,
            "{\"tool\":\"greyhound\",\"phase\":\"S2_collect_min\",\"version\":\"%s\","
            "\"seq\":%llu,\"pid\":%d,\"op\":\"%s\",\"count\":%llu,\"dtype\":%d,"
            "\"aux\":%d,\"t0\":%.6f,\"t1\":%.6f,\"dur_us\":%.3f,\"rc\":%d}\n",
            FS_GH_COLLECT_VERSION, (unsigned long long)seq, (int)getpid(), op,
            (unsigned long long)count, (int)dtype, (int)aux, t0, t1,
            (t1 - t0) * 1e6, (int)rc);
    fflush(g_dump);
  }
  pthread_mutex_unlock(&g_mu);
}

__attribute__((constructor)) static void fs_gh_collect_init(void) {
  const char *dbg = getenv("GREYHOUND_DEBUG");
  const char *marker = getenv("GREYHOUND_STUB_MARKER");
  if (dbg && *dbg && strcmp(dbg, "0") != 0) {
    fprintf(stderr,
            "[hcclprobe-collect] loaded version=%s pid=%d "
            "(Hccl* interpose → GREYHOUND_DUMP)\n",
            FS_GH_COLLECT_VERSION, (int)getpid());
  }
  if (marker && *marker) {
    FILE *fp = fopen(marker, "w");
    if (fp) {
      fprintf(fp, "tool=greyhound\nphase=S2_collect_min\nversion=%s\npid=%d\n",
              FS_GH_COLLECT_VERSION, (int)getpid());
      fclose(fp);
    }
  }
  ensure_init();
}

HcclResult HcclAllReduce(void *sendBuf, void *recvBuf, uint64_t count, HcclDataType dataType,
                         HcclReduceOp op, HcclComm comm, aclrtStream stream) {
  ensure_init();
  if (!real_AllReduce) {
    fprintf(stderr, "[hcclprobe-collect] FATAL unresolved HcclAllReduce\n");
    fflush(stderr);
    return (HcclResult)1;
  }
  double t0 = now_unix();
  HcclResult rc = real_AllReduce(sendBuf, recvBuf, count, dataType, op, comm, stream);
  double t1 = now_unix();
  emit("AllReduce", count, dataType, (int32_t)op, t0, t1, rc);
  return rc;
}

HcclResult HcclBroadcast(void *buf, uint64_t count, HcclDataType dataType, uint32_t root,
                         HcclComm comm, aclrtStream stream) {
  ensure_init();
  if (!real_Broadcast)
    return (HcclResult)1;
  double t0 = now_unix();
  HcclResult rc = real_Broadcast(buf, count, dataType, root, comm, stream);
  double t1 = now_unix();
  emit("Broadcast", count, dataType, (int32_t)root, t0, t1, rc);
  return rc;
}

HcclResult HcclAllGather(void *sendBuf, void *recvBuf, uint64_t sendCount, HcclDataType dataType,
                         HcclComm comm, aclrtStream stream) {
  ensure_init();
  if (!real_AllGather)
    return (HcclResult)1;
  double t0 = now_unix();
  HcclResult rc = real_AllGather(sendBuf, recvBuf, sendCount, dataType, comm, stream);
  double t1 = now_unix();
  emit("AllGather", sendCount, dataType, 0, t0, t1, rc);
  return rc;
}

HcclResult HcclReduceScatter(void *sendBuf, void *recvBuf, uint64_t recvCount,
                             HcclDataType dataType, HcclReduceOp op, HcclComm comm,
                             aclrtStream stream) {
  ensure_init();
  if (!real_ReduceScatter)
    return (HcclResult)1;
  double t0 = now_unix();
  HcclResult rc =
      real_ReduceScatter(sendBuf, recvBuf, recvCount, dataType, op, comm, stream);
  double t1 = now_unix();
  emit("ReduceScatter", recvCount, dataType, (int32_t)op, t0, t1, rc);
  return rc;
}

HcclResult HcclSend(void *sendBuf, uint64_t count, HcclDataType dataType, uint32_t destRank,
                    HcclComm comm, aclrtStream stream) {
  ensure_init();
  if (!real_Send)
    return (HcclResult)1;
  double t0 = now_unix();
  HcclResult rc = real_Send(sendBuf, count, dataType, destRank, comm, stream);
  double t1 = now_unix();
  emit("Send", count, dataType, (int32_t)destRank, t0, t1, rc);
  return rc;
}

HcclResult HcclRecv(void *recvBuf, uint64_t count, HcclDataType dataType, uint32_t srcRank,
                    HcclComm comm, aclrtStream stream) {
  ensure_init();
  if (!real_Recv)
    return (HcclResult)1;
  double t0 = now_unix();
  HcclResult rc = real_Recv(recvBuf, count, dataType, srcRank, comm, stream);
  double t1 = now_unix();
  emit("Recv", count, dataType, (int32_t)srcRank, t0, t1, rc);
  return rc;
}

const char *fs_gh_collect_version(void) { return FS_GH_COLLECT_VERSION; }

#ifdef __cplusplus
} /* extern "C" */
#endif
