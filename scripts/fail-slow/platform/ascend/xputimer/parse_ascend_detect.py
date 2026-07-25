#!/usr/bin/env python3
"""Minimal S3 parser: assert HANG and/or SLOW from Ascend XPUTimer dumps.

Usage:
  python3 parse_ascend_detect.py /path/to/dump_dir [--require hang] [--require slow]
Exit 0 iff required verdicts found in *.flag / *.prom.
"""
from __future__ import annotations

import argparse
import glob
import os
import re
import sys


def load_text(paths):
    chunks = []
    for p in paths:
        try:
            with open(p, "r", encoding="utf-8", errors="replace") as f:
                chunks.append(f.read())
        except OSError:
            pass
    return "\n".join(chunks)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dump_dir")
    ap.add_argument("--require", action="append", choices=("hang", "slow"),
                    default=[], help="repeatable; default=hang if omitted")
    args = ap.parse_args()
    req = args.require or ["hang"]

    flags = sorted(glob.glob(os.path.join(args.dump_dir, "ascend_detect.*.flag")))
    proms = sorted(glob.glob(os.path.join(args.dump_dir, "ascend_metrics.*.prom")))
    logs = sorted(glob.glob(os.path.join(args.dump_dir, "..", "*s3*.log")))
    # also sibling run.log if any
    text = load_text(flags + proms)
    # stderr tee may live next to dump
    for pat in ("*.log", os.path.join("..", "*.log")):
        text += "\n" + load_text(glob.glob(os.path.join(args.dump_dir, pat)))

    hang_flag = bool(re.search(r"(?m)^HANG\b", text)) or bool(
        re.search(r"xpu_timer_ascend_hang_flags_total [1-9]", text)
    ) or bool(re.search(r'kernel_hang\{[^}]*\} [1-9]', text))
    slow_flag = bool(re.search(r"(?m)^SLOW\b", text)) or bool(
        re.search(r"xpu_timer_ascend_slow_flags_total [1-9]", text)
    ) or bool(re.search(r'kernel_slow\{[^}]*\} [1-9]', text))

    print(f"[parse] dump={args.dump_dir}")
    print(f"[parse] flags={len(flags)} proms={len(proms)}")
    print(f"[parse] hang={hang_flag} slow={slow_flag} require={req}")
    if flags:
        for p in flags:
            print(f"[parse] --- {os.path.basename(p)} ---")
            print(open(p).read().strip() or "(empty)")

    ok = True
    if "hang" in req and not hang_flag:
        print("[parse] FAIL: hang not found", file=sys.stderr)
        ok = False
    if "slow" in req and not slow_flag:
        print("[parse] FAIL: slow not found", file=sys.stderr)
        ok = False
    if ok:
        print("[parse] OK detect_ok")
        return 0
    return 2


if __name__ == "__main__":
    sys.exit(main())
