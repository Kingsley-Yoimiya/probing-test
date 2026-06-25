# Megatron-LM 真实参数 Preset
# 参考: examples/inference/run_text_generation_server_345M.sh
#       tests/functional_tests/gpt3_mr_te_tp2_pp2_dgx_a100_1N8G

MEGATRON_ROOT="/home/yjr/work/Megatron-LM"
VENV="/home/yjr/probing-test/probing/.venv"
CLI="/home/yjr/probing-test/probing/target/release/probing-cli"

# local impl 在无 TE/APEX 环境下必需
MEGATRON_COMMON=(
  --transformer-impl local
  --use-mcore-models
  --no-persist-layer-norm
  --no-gradient-accumulation-fusion
  --no-masked-softmax-fusion
  --attention-backend unfused
  --mock-data
  --tokenizer-type NullTokenizer
  --vocab-size 32000
  --bf16
  --lr 1.5e-4
  --min-lr 1e-5
  --lr-decay-style constant
  --weight-decay 0.1
  --clip-grad 1.0
  --distributed-backend nccl
  --no-load-optim --no-load-rng
  --no-save-optim --no-save-rng
  --log-interval 1
  --log-params-norm
  --log-num-zeros-in-grad
)

# preset 名 -> (描述, model/parallel args...)
declare -A PRESET_DESC=(
  [gpt126m]="GPT-126M: 12L/768H/12H seq1024 (Megatron CI 规模)"
  [gpt345m]="GPT-345M: 24L/1024H/16H seq1024 (Megatron 官方 345M)"
  [gpt345m_long]="GPT-345M long: seq2048 mbs1"
  [gpt345m_gbs]="GPT-345M 梯度累积: mbs1 gbs16"
  [gpt345m_tp2]="GPT-345M + TP=2"
  [gpt126m_pp2]="GPT-126M + PP=2 (12L/512H/8H)"
  [gpt126m_2dp]="GPT-126M 2-GPU DP (TP1 PP1 world=2)"
)

preset_args() {
  local name=$1
  case "$name" in
    gpt126m)
      echo --num-layers 12 --hidden-size 768 --num-attention-heads 12 \
        --seq-length 1024 --max-position-embeddings 1024 \
        --micro-batch-size 2 --global-batch-size 8 \
        --train-iters 25 --exit-interval 25 \
        --tensor-model-parallel-size 1 --pipeline-model-parallel-size 1
      ;;
    gpt345m)
      echo --num-layers 24 --hidden-size 1024 --num-attention-heads 16 \
        --seq-length 1024 --max-position-embeddings 1024 \
        --micro-batch-size 2 --global-batch-size 8 \
        --train-iters 20 --exit-interval 20 \
        --tensor-model-parallel-size 1 --pipeline-model-parallel-size 1
      ;;
    gpt345m_long)
      echo --num-layers 24 --hidden-size 1024 --num-attention-heads 16 \
        --seq-length 2048 --max-position-embeddings 2048 \
        --micro-batch-size 1 --global-batch-size 4 \
        --train-iters 15 --exit-interval 15 \
        --tensor-model-parallel-size 1 --pipeline-model-parallel-size 1
      ;;
    gpt345m_gbs)
      echo --num-layers 24 --hidden-size 1024 --num-attention-heads 16 \
        --seq-length 1024 --max-position-embeddings 1024 \
        --micro-batch-size 1 --global-batch-size 16 \
        --train-iters 20 --exit-interval 20 \
        --tensor-model-parallel-size 1 --pipeline-model-parallel-size 1
      ;;
    gpt345m_tp2)
      echo --num-layers 24 --hidden-size 1024 --num-attention-heads 16 \
        --seq-length 1024 --max-position-embeddings 1024 \
        --micro-batch-size 2 --global-batch-size 8 \
        --train-iters 20 --exit-interval 20 \
        --tensor-model-parallel-size 2 --pipeline-model-parallel-size 1
      ;;
    gpt126m_pp2)
      echo --num-layers 12 --hidden-size 512 --num-attention-heads 8 \
        --seq-length 1024 --max-position-embeddings 1024 \
        --micro-batch-size 2 --global-batch-size 8 \
        --train-iters 25 --exit-interval 25 \
        --tensor-model-parallel-size 1 --pipeline-model-parallel-size 2
      ;;
    gpt126m_2dp)
      echo --num-layers 12 --hidden-size 768 --num-attention-heads 12 \
        --seq-length 1024 --max-position-embeddings 1024 \
        --micro-batch-size 2 --global-batch-size 8 \
        --train-iters 25 --exit-interval 25 \
        --tensor-model-parallel-size 1 --pipeline-model-parallel-size 1
      ;;
    *)
      echo "unknown preset $name" >&2; return 1
      ;;
  esac
}

nproc_for_preset() {
  local name=$1
  case "$name" in
    gpt345m_tp2|gpt126m_pp2|gpt126m_2dp) echo 2 ;;
    *) echo 1 ;;
  esac
}

gpu_for_preset() {
  local name=$1
  case "$name" in
    gpt345m_tp2) echo "0,1" ;;
    gpt126m_pp2|gpt126m_2dp) echo "1,3" ;;
    *) echo "1" ;;
  esac
}
