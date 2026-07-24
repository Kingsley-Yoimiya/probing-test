#!/usr/bin/env bash
# Ascend C3–C5 detect_env 片段。pipeline 中：
#   PLATFORM=ascend source .../config_denv_ascend.sh
#   denv+=$(ascend_config_denv "$cfg")
#
# 在 SYMBOL_MAP / 真 .so 就绪前，C3/C4 仅打印路径，避免误 LD_PRELOAD 空文件。

ascend_config_denv() {
  local cfg="$1"
  local gh="${FS_GREYHOUND_SO:-/workspace/probe-bundle/greyhound/libhcclprobe.so}"
  local xt="${FS_XPUTIMER_SO:-/workspace/probe-bundle/xputimer/libxpu_timer_ascend.so}"
  case "$cfg" in
    C0_baseline|C1_inject_none)
      echo "unset PROBING PROBING_TORCH_PROFILING PROBING_GPU; export PROBING=0;"
      ;;
    C2_probing)
      if [ -n "${PROBING_SPEC:-}" ]; then
        echo "export PROBING=2; export PROBING_TORCH_PROFILING='$PROBING_SPEC'; export PROBING_GPU=on; export PROBING_GPU_SAMPLE_MS=1000;"
      else
        echo "export PROBING=2; unset PROBING_TORCH_PROFILING; export PROBING_GPU=on; export PROBING_GPU_SAMPLE_MS=1000;"
      fi
      ;;
    C3_greyhound)
      echo "if [ -f '$gh' ]; then export LD_PRELOAD='$gh'; else echo 'WARN: missing $gh' >&2; fi;"
      ;;
    C4_xputimer)
      echo "if [ -f '$xt' ]; then export LD_PRELOAD='$xt'; else echo 'WARN: missing $xt' >&2; fi;"
      ;;
    C5_flight_recorder)
      # 优先 TORCH_HCCL_*（若进程识别）；同时保留 NCCL 名作兼容探测
      echo "unset PROBING PROBING_TORCH_PROFILING; export PROBING=0; export TORCH_NCCL_TRACE_BUFFER_SIZE=\${TORCH_NCCL_TRACE_BUFFER_SIZE:-1048576}; export TORCH_NCCL_DUMP_ON_TIMEOUT=1; export TORCH_HCCL_TRACE_BUFFER_SIZE=\${TORCH_HCCL_TRACE_BUFFER_SIZE:-\${TORCH_NCCL_TRACE_BUFFER_SIZE:-1048576}};"
      ;;
    *)
      echo ""
      ;;
  esac
}
