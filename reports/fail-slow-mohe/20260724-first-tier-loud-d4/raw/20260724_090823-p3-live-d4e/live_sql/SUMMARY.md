# P3 live SQL SUMMARY — d4e (corrected)

- RID: `20260724_090823-p3-live-d4e`
- LIVE: `/Users/yinjinrun/Codespace/myportal/results/muxi-mohe/20260724_090823-p3-live-d4e/live_sql`
- attach_ok (any tick with successful SHOW TABLES): **False** (ok_ticks=0, refused_ticks≈36)
- cpu.tasks 出现 stress（仅 SQL 段）: **False**
- 说明：先前 SUMMARY 里 stress=yes 含 pgrep 行误报；实时 probing 全程 Connection refused
- case.log: C0 COMPLETE, C1 COMPLETE (C1/C0=2.97), C2 SQL dump attempted 后 FAIL marker，EXIT:1；acceptance Loud **PASS**
