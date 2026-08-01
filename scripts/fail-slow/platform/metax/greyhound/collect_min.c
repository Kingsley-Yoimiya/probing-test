/* MetaX Greyhound collect-min: LD_PRELOAD MCCL interposer.
 *
 * Hooks mcclAllReduce / Broadcast / AllGather / ReduceScatter / Send / Recv,
 * forwards via dlsym to libmccl.so, appends JSONL events.
 *
 * Env:
 *   GREYHOUND_DUMP=/path/to/events.jsonl
 *   GREYHOUND_DEBUG=1
 *   GREYHOUND_STUB_MARKER=/path
 *   GREYHOUND_MCCL_SO=/path/to/libmccl.so
 *
 * Stock Greyhound libncclprobe.so hooks nccl* — MetaX torch binds mccl* only.
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

#define FS_GH_COLLECT_VERSION "metax-collect-min-0.1"

#ifdef __cplusplus
extern "C" {
#endif

typedef void *mcclComm_t;
typedef void *mcStream_t;
typedef int mcclResult_t;
typedef int mcclDataType_t;
typedef int mcclRedOp_t;

typedef mcclResult_t (*fn_allreduce_t)(const void *, void *, size_t, mcclDataType_t, mcclRedOp_t,
                                       mcclComm_t, mcStream_t);
typedef mcclResult_t (*fn_bcast_t)(const void *, void *, size_t, mcclDataType_t, int, mcclComm_t,
                                   mcStream_t);
typedef mcclResult_t (*fn_allgather_t)(const void *, void *, size_t, mcclDataType_t, mcclComm_t,
                                       mcStream_t);
typedef mcclResult_t (*fn_reducescatter_t)(const void *, void *, size_t, mcclDataType_t,
                                           mcclRedOp_t, mcclComm_t, mcStream_t);
typedef mcclResult_t (*fn_send_t)(const void *, size_t, mcclDataType_t, int, mcclComm_t,
                                  mcStream_t);
typedef mcclResult_t (*fn_recv_t)(void *, size_t, mcclDataType_t, int, mcclComm_t, mcStream_t);

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
    fprintf(stderr, "[mcclprobe-collect] %s dlerr=%s\n", msg, dlerror());
    fflush(stderr);
  }
}

static void *resolve_sym(const char *name) {
  static const char *k_cands[] = {
      NULL,
      "/opt/maca/lib/libmccl.so",
      "/opt/maca-3.3.0/lib/libmccl.so",
      "libmccl.so",
      NULL,
  };
  const char *env = getenv("GREYHOUND_MCCL_SO");
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
    if (!(dladdr((void *)resolve_sym, &self) && dladdr(p, &got) && self.dli_fbase &&
          got.dli_fbase == self.dli_fbase))
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
    path = "/tmp/mcclprobe.collect.jsonl";
  g_dump = fopen(path, "a");
  if (!g_dump && getenv("GREYHOUND_DEBUG")) {
    fprintf(stderr, "[mcclprobe-collect] WARN cannot open dump=%s\n", path);
  }
}

static void ensure_init(void) {
  if (g_inited)
    return;
  pthread_mutex_lock(&g_mu);
  if (!g_inited) {
    real_AllReduce = (fn_allreduce_t)resolve_sym("mcclAllReduce");
    real_Broadcast = (fn_bcast_t)resolve_sym("mcclBroadcast");
    real_AllGather = (fn_allgather_t)resolve_sym("mcclAllGather");
    real_ReduceScatter = (fn_reducescatter_t)resolve_sym("mcclReduceScatter");
    real_Send = (fn_send_t)resolve_sym("mcclSend");
    real_Recv = (fn_recv_t)resolve_sym("mcclRecv");
    open_dump_locked();
    g_inited = 1;
  }
  pthread_mutex_unlock(&g_mu);
}

static void emit(const char *op, size_t count, int dtype, int aux, double t0, double t1, int rc) {
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
            (unsigned long long)count, dtype, aux, t0, t1, (t1 - t0) * 1e6, rc);
    fflush(g_dump);
  }
  pthread_mutex_unlock(&g_mu);
}

__attribute__((constructor)) static void fs_gh_collect_init(void) {
  const char *dbg = getenv("GREYHOUND_DEBUG");
  const char *marker = getenv("GREYHOUND_STUB_MARKER");
  if (dbg && *dbg && strcmp(dbg, "0") != 0) {
    fprintf(stderr,
            "[mcclprobe-collect] loaded version=%s pid=%d "
            "(mccl* interpose → GREYHOUND_DUMP)\n",
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

mcclResult_t mcclAllReduce(const void *sendbuff, void *recvbuff, size_t count,
                           mcclDataType_t datatype, mcclRedOp_t op, mcclComm_t comm,
                           mcStream_t stream) {
  ensure_init();
  if (!real_AllReduce) {
    fprintf(stderr, "[mcclprobe-collect] FATAL unresolved mcclAllReduce\n");
    fflush(stderr);
    return 1;
  }
  double t0 = now_unix();
  mcclResult_t rc = real_AllReduce(sendbuff, recvbuff, count, datatype, op, comm, stream);
  double t1 = now_unix();
  emit("AllReduce", count, (int)datatype, (int)op, t0, t1, (int)rc);
  return rc;
}

mcclResult_t mcclBroadcast(const void *sendbuff, void *recvbuff, size_t count,
                           mcclDataType_t datatype, int root, mcclComm_t comm, mcStream_t stream) {
  ensure_init();
  if (!real_Broadcast)
    return 1;
  double t0 = now_unix();
  mcclResult_t rc = real_Broadcast(sendbuff, recvbuff, count, datatype, root, comm, stream);
  double t1 = now_unix();
  emit("Broadcast", count, (int)datatype, root, t0, t1, (int)rc);
  return rc;
}

mcclResult_t mcclAllGather(const void *sendbuff, void *recvbuff, size_t sendcount,
                           mcclDataType_t datatype, mcclComm_t comm, mcStream_t stream) {
  ensure_init();
  if (!real_AllGather)
    return 1;
  double t0 = now_unix();
  mcclResult_t rc = real_AllGather(sendbuff, recvbuff, sendcount, datatype, comm, stream);
  double t1 = now_unix();
  emit("AllGather", sendcount, (int)datatype, 0, t0, t1, (int)rc);
  return rc;
}

mcclResult_t mcclReduceScatter(const void *sendbuff, void *recvbuff, size_t recvcount,
                               mcclDataType_t datatype, mcclRedOp_t op, mcclComm_t comm,
                               mcStream_t stream) {
  ensure_init();
  if (!real_ReduceScatter)
    return 1;
  double t0 = now_unix();
  mcclResult_t rc =
      real_ReduceScatter(sendbuff, recvbuff, recvcount, datatype, op, comm, stream);
  double t1 = now_unix();
  emit("ReduceScatter", recvcount, (int)datatype, (int)op, t0, t1, (int)rc);
  return rc;
}

mcclResult_t mcclSend(const void *sendbuff, size_t count, mcclDataType_t datatype, int peer,
                      mcclComm_t comm, mcStream_t stream) {
  ensure_init();
  if (!real_Send)
    return 1;
  double t0 = now_unix();
  mcclResult_t rc = real_Send(sendbuff, count, datatype, peer, comm, stream);
  double t1 = now_unix();
  emit("Send", count, (int)datatype, peer, t0, t1, (int)rc);
  return rc;
}

mcclResult_t mcclRecv(void *recvbuff, size_t count, mcclDataType_t datatype, int peer,
                      mcclComm_t comm, mcStream_t stream) {
  ensure_init();
  if (!real_Recv)
    return 1;
  double t0 = now_unix();
  mcclResult_t rc = real_Recv(recvbuff, count, datatype, peer, comm, stream);
  double t1 = now_unix();
  emit("Recv", count, (int)datatype, peer, t0, t1, (int)rc);
  return rc;
}

const char *fs_gh_collect_version(void) { return FS_GH_COLLECT_VERSION; }

#ifdef __cplusplus
}
#endif
