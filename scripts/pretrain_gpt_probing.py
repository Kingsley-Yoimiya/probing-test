#!/usr/bin/env python3
"""Megatron pretrain_gpt 入口：自动 attach probing training phase spans."""
from __future__ import annotations

import os
import runpy
import sys
from pathlib import Path

_SCRIPTS = Path(__file__).resolve().parent
_MEGATRON = Path(os.environ.get("MEGATRON_ROOT", "/home/yjr/work/Megatron-LM"))

if str(_SCRIPTS) not in sys.path:
    sys.path.insert(0, str(_SCRIPTS))
if str(_MEGATRON) not in sys.path:
    sys.path.insert(0, str(_MEGATRON))

import megatron_probing_patch


def _wrap_pretrain() -> None:
    import megatron.training
    import megatron.training.training as mt

    if getattr(mt, "_probing_pretrain_wrapped", False):
        return
    original = mt.pretrain

    def pretrain(*args, **kwargs):
        megatron_probing_patch.install()
        return original(*args, **kwargs)

    mt.pretrain = pretrain
    megatron.training.pretrain = pretrain
    mt._probing_pretrain_wrapped = True


_wrap_pretrain()

runpy.run_path(str(_MEGATRON / "pretrain_gpt.py"), run_name="__main__")
