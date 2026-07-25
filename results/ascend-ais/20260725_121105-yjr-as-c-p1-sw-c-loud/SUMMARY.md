# SUMMARY · P1-SW-C Loud

- run_id: `20260725_121105-yjr-as-c-p1-sw-c-loud`
- dose: `n=1024,every=1,fallback_s=0.25`（INLINE_INJECT=2c）
- tip max C1/C0 = **4.63**（median 盲 1.02）；spike accept **BITE_OK**
- D-level: **D3**（offline + SQL）；SQL_NO_EXT_EVIDENCE 不升 D4
- evidence: tip max/p99 闸门；D3=`min_compute_at_tip_step`→rank_7
- torch.compile: Ascend 上 `INLINE_2C_SPIKE_OK`×200（C1/C2）
- tools: C0/C1/C2；jsonl=48
