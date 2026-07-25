// xpu_timer_ascend_hook.cc
// Ascend (昇腾) backend for XPUTimer fail-slow detection — MetaX metax_probe mirror.
//
// S1/S2: Hccl* metadata + host-wall → prom/jsonl
// S3: background poller flags HANG on outstanding Hccl* (host-wall, no aclrtEvent);
//     completed ops with host_us >= XPU_TIMER_SLOW_REPORT_US → SLOW.
//
// Do NOT assume nccl*/cuda* symbol names. Build: build_ascend_hook.sh (plain g++).

#include <dlfcn.h>
#include <pthread.h>
#include <unistd.h>

#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <fstream>
#include <mutex>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>

extern "C" {
typedef void* aclrtStream;
typedef void* HcclComm;
typedef int HcclResult;  // HCCL_SUCCESS == 0
typedef int HcclDataType;
typedef int HcclReduceOp;
}

namespace {

struct Config {
  bool enable = true;
  long hang_timeout_ms = 2000;
  long slow_report_us = 0;  // 0 = off
  int dump_interval_s = 1;
  int poller_sleep_us = 200;
  std::string dump_dir = "/tmp/xpu_timer_ascend";
};

Config& cfg() {
  static Config c = [] {
    Config x;
    if (const char* e = getenv("XPU_TIMER_ENABLE")) x.enable = atoi(e) != 0;
    if (const char* e = getenv("XPU_TIMER_HANG_TIMEOUT_MS"))
      x.hang_timeout_ms = atol(e);
    if (const char* e = getenv("XPU_TIMER_SLOW_REPORT_US"))
      x.slow_report_us = atol(e);
    if (const char* e = getenv("XPU_TIMER_DUMP_DIR")) x.dump_dir = e;
    if (const char* e = getenv("XPU_TIMER_DUMP_INTERVAL_S"))
      x.dump_interval_s = atoi(e);
    if (const char* e = getenv("XPU_TIMER_POLLER_SLEEP_US"))
      x.poller_sleep_us = atoi(e);
    return x;
  }();
  return c;
}

inline uint64_t now_us() {
  return std::chrono::duration_cast<std::chrono::microseconds>(
             std::chrono::steady_clock::now().time_since_epoch())
      .count();
}

void* resolve_hccl(const char* sym) {
  static void* handle = [] {
    const char* p = getenv("XPU_TIMER_HCCL_LIB");
    const char* name = p ? p : "libhccl.so";
    void* h = dlopen(name, RTLD_LAZY | RTLD_GLOBAL | RTLD_NOLOAD);
    if (!h) h = dlopen(name, RTLD_LAZY | RTLD_GLOBAL);
    if (!h)
      h = dlopen("/usr/local/Ascend/ascend-toolkit/latest/lib64/libhccl.so",
                 RTLD_LAZY | RTLD_GLOBAL);
    if (!h)
      fprintf(stderr, "[xpu_timer.ascend] cannot dlopen libhccl.so: %s\n",
              dlerror());
    return h;
  }();
  if (!handle) return nullptr;
  void* fn = dlsym(handle, sym);
  if (!fn) fn = dlsym(RTLD_NEXT, sym);
  return fn;
}

struct KernelStat {
  uint64_t count = 0;
  double sum_us = 0;
  double max_us = 0;
  uint64_t hang_count = 0;
  uint64_t slow_count = 0;
  std::string type;  // "coll"
};

// Outstanding Hccl* call observed by hang poller (MetaX TimedOp analogue).
struct Outstanding {
  std::string name;
  uint64_t bytes = 0;
  uint64_t start_us = 0;
  bool hang_reported = false;
};

class Manager {
 public:
  static Manager& get() {
    static Manager m;
    return m;
  }

  bool enabled() const { return cfg().enable && running_.load(); }

  void ensure_started() {
    std::call_once(start_once_, [this] { start(); });
  }

  // Enter Hccl* — register outstanding so poller can fire HANG while blocked.
  Outstanding* begin_coll(const char* name, uint64_t bytes) {
    auto* op = new Outstanding();
    op->name = name;
    op->bytes = bytes;
    op->start_us = now_us();
    op->hang_reported = false;
    {
      std::lock_guard<std::mutex> lk(q_mu_);
      work_.push_back(op);
    }
    return op;
  }

  // Leave timed region — fold host-wall; SLOW / post-facto HANG thresholds.
  void end_coll(Outstanding* op, double host_us) {
    if (!op) return;
    bool already_hang = false;
    std::string name;
    uint64_t bytes = 0;
    {
      std::lock_guard<std::mutex> lk(q_mu_);
      for (auto it = work_.begin(); it != work_.end(); ++it) {
        if (*it == op) {
          work_.erase(it);
          break;
        }
      }
      already_hang = op->hang_reported;
      name = op->name;
      bytes = op->bytes;
      delete op;
    }

    const bool post_hang =
        !already_hang &&
        host_us >= (double)cfg().hang_timeout_ms * 1000.0;
    const bool is_slow =
        !already_hang && !post_hang && cfg().slow_report_us > 0 &&
        host_us >= (double)cfg().slow_report_us;

    {
      std::lock_guard<std::mutex> lk(stat_mu_);
      KernelStat& s = stats_[std::string("coll:") + name];
      s.type = "coll";
      s.count++;
      s.sum_us += host_us;
      if (host_us > s.max_us) s.max_us = host_us;
      coll_bytes_[name] += bytes;
      coll_events_++;
      if (post_hang) {
        s.hang_count++;
        fprintf(stderr,
                "[xpu_timer.ascend][HANG] op=%s host_us=%.1fms >= %ldms "
                "(post-facto / blocked call)\n",
                name.c_str(), host_us / 1000.0, cfg().hang_timeout_ms);
      } else if (is_slow) {
        s.slow_count++;
        fprintf(stderr,
                "[xpu_timer.ascend][SLOW] op=%s host_us=%.1f >= %ldus\n",
                name.c_str(), host_us, cfg().slow_report_us);
      }
      if (trace_.is_open()) {
        trace_ << "{\"ts_us\":" << now_us() << ",\"name\":\"" << name
               << "\",\"type\":\"coll\",\"dur_us\":" << host_us
               << ",\"psize\":" << bytes << ",\"hang\":"
               << ((already_hang || post_hang) ? "true" : "false") << "}\n";
      }
    }
    if (post_hang) write_detect_flag("HANG", name, host_us);
    else if (is_slow) write_detect_flag("SLOW", name, host_us);
  }

  void stop() {
    if (!running_.exchange(false)) return;
    if (poller_.joinable()) poller_.join();
    if (dumper_.joinable()) dumper_.join();
    dump_metrics(/*final=*/true);
    fprintf(stderr,
            "[xpu_timer.ascend] stopped. events=%llu hang_flags=%llu "
            "slow_flags=%llu metrics -> %s\n",
            (unsigned long long)coll_events_.load(),
            (unsigned long long)hang_flags_.load(),
            (unsigned long long)slow_flags_.load(), dump_prom_.c_str());
  }

 private:
  Manager() = default;
  ~Manager() { stop(); }

  void start() {
    ensure_dump_dir();
    running_.store(true);
    poller_ = std::thread([this] { hang_loop(); });
    dumper_ = std::thread([this] { dump_loop(); });
    fprintf(stderr,
            "[xpu_timer.ascend] started. pid=%d hang_timeout=%ldms "
            "slow_us=%ld dump=%s\n",
            getpid(), cfg().hang_timeout_ms, cfg().slow_report_us,
            cfg().dump_dir.c_str());
  }

  void ensure_dump_dir() {
    std::string d = cfg().dump_dir;
    std::string cmd = "mkdir -p '" + d + "'";
    (void)system(cmd.c_str());
    const char* rank = getenv("RANK");
    char suffix[64];
    snprintf(suffix, sizeof(suffix), "rank%s.pid%d", rank ? rank : "NA",
             getpid());
    dump_prom_ = d + "/ascend_metrics." + suffix + ".prom";
    dump_trace_ = d + "/ascend_trace." + suffix + ".jsonl";
    dump_flag_ = d + "/ascend_detect." + suffix + ".flag";
    suffix_ = suffix;
    trace_.open(dump_trace_, std::ios::out | std::ios::trunc);
  }

  void write_detect_flag(const char* kind, const std::string& name, double us) {
    if (kind[0] == 'H') hang_flags_++;
    else slow_flags_++;
    std::ofstream f(dump_flag_, std::ios::out | std::ios::app);
    if (!f.is_open()) return;
    f << kind << " name=" << name << " us=" << us
      << " hang_timeout_ms=" << cfg().hang_timeout_ms << "\n";
  }

  void hang_loop() {
    while (running_.load()) {
      drain_hang_once();
      std::this_thread::sleep_for(
          std::chrono::microseconds(cfg().poller_sleep_us));
    }
  }

  void drain_hang_once() {
    // Touch Outstanding* only under q_mu_ (end_coll deletes after erase).
    struct Hit {
      std::string name;
      double us;
    };
    std::vector<Hit> hits;
    {
      std::lock_guard<std::mutex> lk(q_mu_);
      for (Outstanding* op : work_) {
        if (!op || op->hang_reported) continue;
        uint64_t outstanding = now_us() - op->start_us;
        if (outstanding > (uint64_t)cfg().hang_timeout_ms * 1000ULL) {
          op->hang_reported = true;
          hits.push_back({op->name, (double)outstanding});
        }
      }
    }
    for (const Hit& h : hits) {
      {
        std::lock_guard<std::mutex> lk(stat_mu_);
        KernelStat& s = stats_[std::string("coll:") + h.name];
        s.type = "coll";
        s.hang_count++;
      }
      fprintf(stderr,
              "[xpu_timer.ascend][HANG] op=%s outstanding=%.1fms >= %ldms "
              "(fail-slow candidate)\n",
              h.name.c_str(), h.us / 1000.0, cfg().hang_timeout_ms);
      write_detect_flag("HANG", h.name, h.us);
      dump_metrics(false);
    }
  }

  void dump_loop() {
    while (running_.load()) {
      dump_metrics(false);
      for (int i = 0; i < cfg().dump_interval_s * 10 && running_.load(); ++i)
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
    }
  }

  void dump_metrics(bool final) {
    std::lock_guard<std::mutex> lk(stat_mu_);
    std::ofstream f(dump_prom_, std::ios::out | std::ios::trunc);
    if (!f.is_open()) return;
    f << "# XPUTimer Ascend backend metrics (Prometheus text exposition)\n";
    f << "# device=Ascend910 pid=" << getpid()
      << " events=" << coll_events_.load()
      << " hang_flags=" << hang_flags_.load()
      << " slow_flags=" << slow_flags_.load() << "\n";
    for (auto& kv : stats_) {
      const std::string& name = kv.first;
      const KernelStat& s = kv.second;
      double avg = s.count ? s.sum_us / s.count : 0.0;
      f << "xpu_timer_common_kernel_count{name=\"" << name << "\",type=\""
        << s.type << "\"} " << s.count << "\n";
      f << "xpu_timer_common_kernel_avg_us{name=\"" << name << "\",type=\""
        << s.type << "\"} " << avg << "\n";
      f << "xpu_timer_common_kernel_max_us{name=\"" << name << "\",type=\""
        << s.type << "\"} " << s.max_us << "\n";
      f << "xpu_timer_common_kernel_hang{name=\"" << name << "\",type=\""
        << s.type << "\"} " << s.hang_count << "\n";
      f << "xpu_timer_common_kernel_slow{name=\"" << name << "\",type=\""
        << s.type << "\"} " << s.slow_count << "\n";
    }
    for (auto& kv : coll_bytes_) {
      f << "xpu_timer_common_coll_bytes_total{name=\"" << kv.first << "\"} "
        << kv.second << "\n";
    }
    f << "xpu_timer_ascend_coll_events_total " << coll_events_.load() << "\n";
    f << "xpu_timer_ascend_hang_flags_total " << hang_flags_.load() << "\n";
    f << "xpu_timer_ascend_slow_flags_total " << slow_flags_.load() << "\n";
    if (trace_.is_open()) trace_.flush();
    if (final && trace_.is_open()) trace_.close();
  }

  std::atomic<bool> running_{false};
  std::once_flag start_once_;
  std::thread poller_;
  std::thread dumper_;
  std::string dump_prom_, dump_trace_, dump_flag_, suffix_;
  std::ofstream trace_;

  std::mutex q_mu_;
  std::deque<Outstanding*> work_;

  std::mutex stat_mu_;
  std::unordered_map<std::string, KernelStat> stats_;
  std::unordered_map<std::string, uint64_t> coll_bytes_;
  std::atomic<uint64_t> coll_events_{0};
  std::atomic<uint64_t> hang_flags_{0};
  std::atomic<uint64_t> slow_flags_{0};
};

__attribute__((destructor)) void xpu_ascend_dtor() { Manager::get().stop(); }

static inline uint64_t dtype_bytes(HcclDataType dt) {
  switch (dt) {
    case 0: return 1;
    case 1: return 2;
    case 2: return 4;
    case 3: return 2;
    case 4: return 4;
    case 5: return 8;
    case 6: return 8;
    case 7: return 1;
    case 8: return 2;
    case 9: return 4;
    case 10: return 8;
    case 11: return 2;
    default: return 4;
  }
}

}  // namespace

#define EXPOSE_API __attribute__((visibility("default")))

extern "C" {

#define COLL_HOST(NAME, BYTES, EXPR)                                       \
  do {                                                                     \
    Manager& _m = Manager::get();                                          \
    _m.ensure_started();                                                   \
    Outstanding* _op = nullptr;                                            \
    if (_m.enabled()) _op = _m.begin_coll(NAME, (BYTES));                  \
    /* Oracle inject: stall after begin so hang poller can observe. */     \
    if (const char* _inj = getenv("XPU_TIMER_INJECT_STALL_MS")) {          \
      int _ms = atoi(_inj);                                                \
      if (_ms > 0)                                                         \
        std::this_thread::sleep_for(std::chrono::milliseconds(_ms));       \
    }                                                                      \
    uint64_t _t0 = now_us();                                               \
    HcclResult _rc = (EXPR);                                               \
    uint64_t _dt = now_us() - _t0;                                         \
    if (_op) _m.end_coll(_op, (double)_dt);                                \
    return _rc;                                                            \
  } while (0)

EXPOSE_API HcclResult HcclAllReduce(void* s, void* r, uint64_t count,
                                    HcclDataType dt, HcclReduceOp op,
                                    HcclComm comm, aclrtStream stream) {
  using Fn = HcclResult (*)(void*, void*, uint64_t, HcclDataType, HcclReduceOp,
                            HcclComm, aclrtStream);
  static Fn orig = (Fn)resolve_hccl("HcclAllReduce");
  if (!orig) return -1;
  COLL_HOST("HcclAllReduce", count * dtype_bytes(dt),
            orig(s, r, count, dt, op, comm, stream));
}

EXPOSE_API HcclResult HcclAllGather(void* s, void* r, uint64_t sendCount,
                                    HcclDataType dt, HcclComm comm,
                                    aclrtStream stream) {
  using Fn = HcclResult (*)(void*, void*, uint64_t, HcclDataType, HcclComm,
                            aclrtStream);
  static Fn orig = (Fn)resolve_hccl("HcclAllGather");
  if (!orig) return -1;
  COLL_HOST("HcclAllGather", sendCount * dtype_bytes(dt),
            orig(s, r, sendCount, dt, comm, stream));
}

EXPOSE_API HcclResult HcclReduceScatter(void* s, void* r, uint64_t recvCount,
                                        HcclDataType dt, HcclReduceOp op,
                                        HcclComm comm, aclrtStream stream) {
  using Fn = HcclResult (*)(void*, void*, uint64_t, HcclDataType, HcclReduceOp,
                            HcclComm, aclrtStream);
  static Fn orig = (Fn)resolve_hccl("HcclReduceScatter");
  if (!orig) return -1;
  COLL_HOST("HcclReduceScatter", recvCount * dtype_bytes(dt),
            orig(s, r, recvCount, dt, op, comm, stream));
}

EXPOSE_API HcclResult HcclBroadcast(void* buf, uint64_t count, HcclDataType dt,
                                    uint32_t root, HcclComm comm,
                                    aclrtStream stream) {
  using Fn = HcclResult (*)(void*, uint64_t, HcclDataType, uint32_t, HcclComm,
                            aclrtStream);
  static Fn orig = (Fn)resolve_hccl("HcclBroadcast");
  if (!orig) return -1;
  COLL_HOST("HcclBroadcast", count * dtype_bytes(dt),
            orig(buf, count, dt, root, comm, stream));
}

EXPOSE_API HcclResult HcclReduce(void* s, void* r, uint64_t count,
                                 HcclDataType dt, HcclReduceOp op,
                                 uint32_t root, HcclComm comm,
                                 aclrtStream stream) {
  using Fn = HcclResult (*)(void*, void*, uint64_t, HcclDataType, HcclReduceOp,
                            uint32_t, HcclComm, aclrtStream);
  static Fn orig = (Fn)resolve_hccl("HcclReduce");
  if (!orig) return -1;
  COLL_HOST("HcclReduce", count * dtype_bytes(dt),
            orig(s, r, count, dt, op, root, comm, stream));
}

EXPOSE_API HcclResult HcclSend(void* s, uint64_t count, HcclDataType dt,
                               uint32_t destRank, HcclComm comm,
                               aclrtStream stream) {
  using Fn = HcclResult (*)(void*, uint64_t, HcclDataType, uint32_t, HcclComm,
                            aclrtStream);
  static Fn orig = (Fn)resolve_hccl("HcclSend");
  if (!orig) return -1;
  COLL_HOST("HcclSend", count * dtype_bytes(dt),
            orig(s, count, dt, destRank, comm, stream));
}

EXPOSE_API HcclResult HcclRecv(void* r, uint64_t count, HcclDataType dt,
                               uint32_t srcRank, HcclComm comm,
                               aclrtStream stream) {
  using Fn = HcclResult (*)(void*, uint64_t, HcclDataType, uint32_t, HcclComm,
                            aclrtStream);
  static Fn orig = (Fn)resolve_hccl("HcclRecv");
  if (!orig) return -1;
  COLL_HOST("HcclRecv", count * dtype_bytes(dt),
            orig(r, count, dt, srcRank, comm, stream));
}

// HCCL collectives are often async; torch waits on stream sync. torch_npu has
// U aclrtSynchronizeStream — hang poller must watch that path for desync.
typedef int (*aclrtSynchronizeStream_t)(aclrtStream);
EXPOSE_API int aclrtSynchronizeStream(aclrtStream stream) {
  static aclrtSynchronizeStream_t orig = []() -> aclrtSynchronizeStream_t {
    const char* p = getenv("XPU_TIMER_ACL_LIB");
    const char* name = p ? p : "libascendcl.so";
    void* h = dlopen(name, RTLD_LAZY | RTLD_GLOBAL | RTLD_NOLOAD);
    if (!h) h = dlopen(name, RTLD_LAZY | RTLD_GLOBAL);
    if (!h)
      h = dlopen("/usr/local/Ascend/ascend-toolkit/latest/lib64/libascendcl.so",
                 RTLD_LAZY | RTLD_GLOBAL);
    void* fn = h ? dlsym(h, "aclrtSynchronizeStream") : nullptr;
    if (!fn) fn = dlsym(RTLD_NEXT, "aclrtSynchronizeStream");
    return (aclrtSynchronizeStream_t)fn;
  }();
  if (!orig) return -1;
  Manager& m = Manager::get();
  m.ensure_started();
  Outstanding* op = nullptr;
  if (m.enabled()) op = m.begin_coll("aclrtSynchronizeStream", 0);
  uint64_t t0 = now_us();
  int rc = orig(stream);
  uint64_t dt = now_us() - t0;
  if (op) m.end_coll(op, (double)dt);
  return rc;
}

}  // extern "C"
