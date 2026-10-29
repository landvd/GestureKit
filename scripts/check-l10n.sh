#!/bin/bash
# 检查 Sources/*.swift 里每个 L("…") 字面量 key 都在英文表里（L10n.swift 与 L10n+*.swift）。
# 只读；缺失时列出并以非 0 退出。兼容 macOS 自带 bash 3.2 / BSD grep / sed。
#
# 约定（见 Sources/L10n.swift）：
#   - 英文表位于 "BEGIN-EN" 与 "END-EN" 两行之间，一行一条 `"key": "value",`
#   - key 里不写 \" （中文文案用「」）
#   - 动态 key（L(变量)）不在此检查范围，由 --selftest 的 i18n 断言覆盖
set -u
cd "$(dirname "$0")/.." || exit 2
TABLE=Sources/L10n.swift
[ -f "$TABLE" ] || { echo "check-l10n: $TABLE not found" >&2; exit 2; }
TABLES=$(ls Sources/L10n.swift Sources/L10n+*.swift 2>/dev/null)

tmp=$(mktemp -d "${TMPDIR:-/tmp}/check-l10n.XXXXXX") || exit 2
trap 'rm -rf "$tmp"' EXIT

# 英文表的 key
for t in $TABLES; do sed -n '/BEGIN-EN/,/END-EN/p' "$t"; done \
  | sed -n 's/^[[:space:]]*"\([^"]*\)":[[:space:]]*".*$/\1/p' \
  | LC_ALL=C sort -u > "$tmp/table"

# 源码里的 L("…") 字面量（前一个字符不能是标识符字符，排除 URL("…") 之类）
# 跳过注释行（以 // 开头）
for f in Sources/*.swift; do
  grep -v '^[[:space:]]*//' "$f" \
    | grep -oE '(^|[^A-Za-z0-9_.])L\("[^"]*"' \
    | sed 's/^.*L("//; s/"$//'
done | LC_ALL=C sort -u > "$tmp/used"

# 同一张表里重复的 key：Swift 字典字面量遇到重复 key 会在运行时崩溃
dups=""
for t in $TABLES; do
  d=$(sed -n '/BEGIN-EN/,/END-EN/p' "$t" | sed -n 's/^[[:space:]]*"\([^"]*\)":[[:space:]]*".*$/\1/p' | LC_ALL=C sort | uniq -d)
  [ -n "$d" ] && dups="$dups$t: $d
"
done
if [ -n "$dups" ]; then
  echo "check-l10n: duplicate key(s) inside one table (would crash at launch):"
  printf '%s' "$dups" | sed 's/^/  /'
  exit 1
fi

LC_ALL=C comm -23 "$tmp/used" "$tmp/table" > "$tmp/missing"

used=$(wc -l < "$tmp/used" | tr -d ' ')
table=$(wc -l < "$tmp/table" | tr -d ' ')
if [ -s "$tmp/missing" ]; then
  echo "check-l10n: $(wc -l < "$tmp/missing" | tr -d ' ') key(s) missing from the English tables (Sources/L10n*.swift):"
  sed 's/^/  /' "$tmp/missing"
  exit 1
fi
echo "check-l10n: OK ($used literal keys, $table English entries)"
