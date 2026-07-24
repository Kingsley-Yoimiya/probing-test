# Fail-slow / Probing SQL 统一实验镜像（MetaX C550）
# 底包与 provision_priv_pods.sh 默认一致；上层固化 Probing_plus(gpu+mx-smi) + probe-bundle。
ARG BASE_IMAGE=registry2.d.pjlab.org.cn/ccr-deeplink/megatron-lm:0.12.0-maca.ai3.3.0.11-torch2.6-py312-ubuntu22.04-amd64-driver
FROM ${BASE_IMAGE}

LABEL org.opencontainers.image.title="probing-failslow-metax"
LABEL org.opencontainers.image.description="MetaX C550 fail-slow bench + Probing_plus (gpu/mx-smi)"

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    PROBE_BUNDLE=/workspace/probe-bundle \
    PYTHONPATH=/workspace/probe-bundle/pydeps \
    PATH=/workspace/probe-bundle/pydeps/bin:/opt/conda/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    PROBING_GPU=on \
    PROBING_GPU_SAMPLE_MS=1000 \
    SIDECAR_WARMUP=8 \
    LOCAL_CODE=/workspace/probe-bundle \
    LOCAL_OUT=/workspace/probe-bundle/out

# host 注入工具（P3-EXT）；忽略已装失败
RUN (apt-get update -qq \
    && apt-get install -y -qq --no-install-recommends stress-ng fio curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*) || true

WORKDIR /workspace/probe-bundle

# Probing_plus wheel（构建上下文必须提供 probing.whl）
COPY probing.whl /tmp/probing.whl
RUN mkdir -p /workspace/probe-bundle/pydeps \
    && /opt/conda/bin/python3.12 -m pip install --no-cache-dir --target=/workspace/probe-bundle/pydeps --no-deps /tmp/probing.whl \
    && rm -f /tmp/probing.whl \
    && SP=/opt/conda/lib/python3.12/site-packages \
    && ln -sfn /workspace/probe-bundle/pydeps/probing $SP/probing \
    && ln -sfn /workspace/probe-bundle/pydeps/probing-0.2.5.dist-info $SP/probing-0.2.5.dist-info \
    && ln -sfn /workspace/probe-bundle/pydeps/probing_hook.py $SP/probing_hook.py \
    && cp -f /workspace/probe-bundle/pydeps/probing.pth $SP/probing.pth \
    && /opt/conda/bin/python3.12 -c "import probing; print('probing_ok', probing.__file__)"

# 编排 / 训练 / 注入 / SQL dump（镜像内自洽，起 pod 即可跑）
COPY bundle/ /workspace/probe-bundle/
RUN chmod +x /workspace/probe-bundle/*.sh 2>/dev/null || true \
    && mkdir -p /workspace/probe-bundle/out /workspace/probe-bundle/ckpt /workspace/probe-bundle/io_stress

# 冒烟：确认 .so 含 mx-smi / gpu.utilization 字符串
RUN strings /workspace/probe-bundle/pydeps/probing/_core.abi3.so | grep -q mx-smi \
    && strings /workspace/probe-bundle/pydeps/probing/_core.abi3.so | grep -q 'gpu.utilization' \
    && echo "probing_gpu_feature_ok"

WORKDIR /workspace
CMD ["sleep", "infinity"]
