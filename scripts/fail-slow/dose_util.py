#!/usr/bin/env python3
"""dose_recipes.yaml 读取工具：按 case + dose 取 accept_min_ratio。

路径优先级：
  1) 显式 --recipes / recipes_path
  2) 环境变量 FS_DOSE_RECIPES（华为 env.sh 会设为 probing-huawei 本仓 recipes）
  3) 本脚本同目录 dose_recipes.yaml（沐曦默认）
"""
from __future__ import annotations

import os
from pathlib import Path
from typing import Any

DOSE_DEFAULT_RATIO = {
    "loud": 1.3,
    "quiet": 1.15,
    "masked": 1.05,
}


def normalize_dose(dose: str) -> str:
    d = (dose or "loud").strip().lower()
    if d not in DOSE_DEFAULT_RATIO:
        raise ValueError(f"unknown dose={dose!r}; expect loud|quiet|masked")
    return d


def resolve_recipes_path(explicit: str | Path | None = None) -> Path | None:
    if explicit:
        p = Path(explicit).expanduser()
        return p if p.is_file() else None
    env = os.environ.get("FS_DOSE_RECIPES", "").strip()
    if env:
        p = Path(env).expanduser()
        if p.is_file():
            return p
    sibling = Path(__file__).resolve().parent / "dose_recipes.yaml"
    return sibling if sibling.is_file() else None


def load_recipes(path: Path | None) -> dict[str, Any]:
    if path is None or not path.is_file():
        return {}
    try:
        import yaml  # type: ignore
    except ImportError as e:
        raise SystemExit(
            f"PyYAML required to read dose recipes ({path}); pip install pyyaml"
        ) from e
    data = yaml.safe_load(path.read_text()) or {}
    return data if isinstance(data, dict) else {}


def recipe_accept_min_ratio(
    case: str,
    dose: str,
    *,
    recipes_path: str | Path | None = None,
    recipes: dict[str, Any] | None = None,
    fallback: float | None = None,
) -> tuple[float, str]:
    """返回 (ratio, source_note)。

    source_note 便于 accept/score 报告写清阈值来源。
    """
    d = normalize_dose(dose)
    path = resolve_recipes_path(recipes_path) if recipes is None else (
        Path(recipes_path) if recipes_path else resolve_recipes_path(None)
    )
    data = recipes if recipes is not None else load_recipes(path)
    cases = data.get("cases") if isinstance(data, dict) else None
    entry = None
    if isinstance(cases, dict):
        case_block = cases.get(case) or {}
        if isinstance(case_block, dict):
            entry = case_block.get(d)

    if isinstance(entry, dict) and entry.get("accept_min_ratio") is not None:
        try:
            r = float(entry["accept_min_ratio"])
        except (TypeError, ValueError):
            r = None
        if r is not None:
            src = f"recipes:{path}:{case}.{d}" if path else f"recipes:{case}.{d}"
            return r, src

    if fallback is not None:
        return float(fallback), f"fallback:{fallback}"

    return float(DOSE_DEFAULT_RATIO[d]), f"dose_default:{d}"


def parse_recipe_args(args: str | None) -> dict[str, str]:
    """Parse `k=v,k2=v2` recipe args into a flat dict (values stay strings)."""
    out: dict[str, str] = {}
    if not args:
        return out
    for part in str(args).split(","):
        part = part.strip()
        if not part or "=" not in part:
            continue
        k, v = part.split("=", 1)
        out[k.strip()] = v.strip()
    return out


def recipe_entry(
    case: str,
    dose: str,
    *,
    recipes_path: str | Path | None = None,
    recipes: dict[str, Any] | None = None,
) -> dict[str, Any] | None:
    """Return the raw recipes[case][dose] dict, or None."""
    d = normalize_dose(dose)
    path = resolve_recipes_path(recipes_path) if recipes is None else (
        Path(recipes_path) if recipes_path else resolve_recipes_path(None)
    )
    data = recipes if recipes is not None else load_recipes(path)
    cases = data.get("cases") if isinstance(data, dict) else None
    if not isinstance(cases, dict):
        return None
    case_block = cases.get(case) or {}
    if not isinstance(case_block, dict):
        return None
    entry = case_block.get(d)
    return entry if isinstance(entry, dict) else None


def recipe_arg_int(
    case: str,
    dose: str,
    key: str,
    *,
    recipes_path: str | Path | None = None,
    fallback: int | None = None,
) -> tuple[int | None, str]:
    """Read int `key` from recipes[case][dose].args; else fallback.

    Returns (value_or_None, source_note).
    """
    entry = recipe_entry(case, dose, recipes_path=recipes_path)
    if entry is not None:
        parsed = parse_recipe_args(entry.get("args"))
        if key in parsed:
            try:
                return int(parsed[key]), f"recipes:{case}.{normalize_dose(dose)}.args.{key}"
            except (TypeError, ValueError):
                pass
    if fallback is not None:
        return int(fallback), f"fallback:{fallback}"
    return None, "missing"
