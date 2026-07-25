/* Ascend Greyhound S0 stub — constructor-only, no HCCL interpose.
 *
 * Purpose: prove LD_PRELOAD of libhcclprobe.so does not break process
 * startup. Real Hccl* hooks belong in a later probe build after nm -D.
 *
 * Env:
 *   GREYHOUND_DEBUG=1           → stderr banner
 *   GREYHOUND_STUB_MARKER=<path> → write one-line marker on load
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define FS_GH_STUB_VERSION "ascend-stub-0.1"

static void fs_gh_write_marker(const char *path) {
  FILE *fp;
  time_t now;
  if (!path || !*path)
    return;
  fp = fopen(path, "w");
  if (!fp)
    return;
  now = time(NULL);
  fprintf(fp,
          "tool=greyhound\n"
          "phase=S0_stub\n"
          "version=%s\n"
          "pid=%d\n"
          "loaded_unix=%ld\n",
          FS_GH_STUB_VERSION, (int)getpid(), (long)now);
  fclose(fp);
}

__attribute__((constructor)) static void fs_gh_stub_init(void) {
  const char *dbg = getenv("GREYHOUND_DEBUG");
  const char *marker = getenv("GREYHOUND_STUB_MARKER");

  if (dbg && *dbg && strcmp(dbg, "0") != 0) {
    fprintf(stderr,
            "[greyhound-ascend-stub] loaded version=%s pid=%d "
            "(constructor-only; no Hccl* interpose yet)\n",
            FS_GH_STUB_VERSION, (int)getpid());
  }
  if (marker && *marker)
    fs_gh_write_marker(marker);
}

/* Exported for nm / selftest; not an HCCL symbol. */
const char *fs_gh_stub_version(void) { return FS_GH_STUB_VERSION; }
