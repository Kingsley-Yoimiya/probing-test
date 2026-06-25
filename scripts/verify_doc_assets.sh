#!/usr/bin/env bash
# 校验 probing-visualization-guide.md 中的图片/链接是否存在于 docs/assets/latest/
set -eo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DOC="$ROOT/docs/probing-visualization-guide.md"
ASSETS="$ROOT/docs/assets/latest"
FAIL=0

echo "=== 文档素材校验 ==="
echo "文档: $DOC"
echo "素材: $ASSETS"
echo

while IFS= read -r ref; do
  [[ -z "$ref" ]] && continue
  ref="${ref#./}"
  ref="${ref%%#*}"
  target="$ROOT/docs/$ref"
  if [[ -f "$target" ]]; then
    echo "OK  $ref"
  else
    echo "MISS $ref"
    FAIL=1
  fi
done < <(python3 - "$DOC" <<'PY'
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
for m in re.finditer(r'!\[[^\]]*\]\((\./assets/latest/[^)]+)\)', text):
    print(m.group(1))
for m in re.finditer(r'\]\((\./assets/latest/meta\.txt)\)', text):
    print(m.group(1))
PY
)

echo
echo "=== latest/ 中未在文档引用的 PNG ==="
UNREF=0
for png in "$ASSETS"/*.png; do
  base=$(basename "$png")
  if ! grep -q "$base" "$DOC"; then
    echo "UNREF  $base"
    UNREF=1
  fi
done
[[ "$UNREF" -eq 0 ]] && echo "(无)"

echo
if [[ "$FAIL" -eq 0 ]]; then
  echo "全部图片引用路径存在。"
else
  echo "存在缺失引用，请修复文档或补素材。"
  exit 1
fi
