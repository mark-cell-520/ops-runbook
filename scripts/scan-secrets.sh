#!/bin/bash
# scan-secrets.sh — 提交前的密钥自查。
#
# 这个仓库的约定是"只放方法，不放值"，所以在 git add / commit 前后跑一遍这个脚本，
# 确认没有把真实凭据带进来。
#
# 设计要点：脚本分两类模式。
#   1. 通用形态（下面的 GENERIC）—— 与具体机器无关，可以安全提交。
#   2. 本机已知真实值 —— **绝不写进这个文件**，放在 local/known-values.txt
#      （已被 .gitignore 忽略），格式见 local/known-values.txt.example。
# 否则"用来查泄漏的脚本"自己就成了泄漏源。
#
# 用法：
#   bash scripts/scan-secrets.sh          扫所有被 git 跟踪/未忽略的文件
#   bash scripts/scan-secrets.sh --staged 只扫暂存区（配合 pre-commit 用）
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

# ---- 通用形态：密钥的形状，不含任何真实值 ----
GENERIC=(
  'sk-[A-Za-z0-9_-]{16,}'                     # 各类 LLM API key
  'gh[pousr]_[A-Za-z0-9]{20,}'                # GitHub token
  'github_pat_[A-Za-z0-9_]{20,}'              # GitHub fine-grained PAT
  'AKIA[0-9A-Z]{16}'                          # AWS access key id
  'xox[baprs]-[A-Za-z0-9-]{10,}'              # Slack
  '\$2[aby]\$[0-9]{2}\$[A-Za-z0-9./]{20,}'    # bcrypt 哈希
  'BEGIN [A-Z ]*PRIVATE KEY'                  # PEM 私钥
  'enc:v1:[A-Za-z0-9+/]{20,}'                 # NasCabOS 加密后的密码密文
)

# ---- 本机已知真实值：从 gitignored 的 local/ 读 ----
LOCAL_FILE=local/known-values.txt
LOCAL=()
if [ -f "$LOCAL_FILE" ]; then
  while IFS= read -r line; do
    case "$line" in ''|\#*) continue ;; esac
    LOCAL+=("$line")
  done < "$LOCAL_FILE"
  echo "已载入 $LOCAL_FILE 的 ${#LOCAL[@]} 条本机特征串"
else
  echo "提示：没有 $LOCAL_FILE，只做通用形态扫描（cp local/known-values.txt.example local/known-values.txt 可启用）"
fi

if [ "${1:-}" = "--staged" ]; then
  files=$(git diff --cached --name-only --diff-filter=ACM 2>/dev/null)
else
  files=$(git ls-files --others --cached --exclude-standard 2>/dev/null)
fi

if [ -z "$files" ]; then
  echo "没有要扫的文件（还没 git add？）"
  exit 0
fi

fail=0
scanned=0
while IFS= read -r f; do
  [ -f "$f" ] || continue
  scanned=$((scanned + 1))
  for p in "${GENERIC[@]}" "${LOCAL[@]}"; do
    if grep -qEH "$p" "$f" 2>/dev/null; then
      echo "  [泄漏] $f  匹配: $p"
      grep -nEH "$p" "$f" 2>/dev/null | head -3 | sed 's/^/         /'
      fail=1
    fi
  done
done <<< "$files"

if [ "$fail" = 0 ]; then
  echo "OK —— 扫了 $scanned 个文件，未发现已知真实值或密钥形态"
else
  echo
  echo "发现可疑内容，提交前先处理。确认是误报就收窄模式，或把值挪进 local/。"
fi
exit "$fail"
