#!/usr/bin/env bash
# git commit 直前に、機械で判定できるルール違反を検出する。意味解釈が要るルールは pre-commit-claude-audit.sh が担当する。
#
# 違反の分類と exit コントラクト (Claude Code hook 規約):
# - HARD 違反あり  → exit 2。stderr を worker に返して commit をブロックする
# - SOFT 違反のみ  → permissionDecision=ask を stdout に返し、user に許否を委ねる
# - 違反なし / 対象外 → exit 0
# - 監査不能 (入力欠落 / JSON parse 失敗) → exit 2 で fail-closed

set -uo pipefail

SHARED_REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
readonly SHARED_REPO_DIR
readonly COMMON_LIB="${SHARED_REPO_DIR}/scripts/claude-audit-common.sh"
readonly REPOS_CONFIG_FILE="${SHARED_REPO_DIR}/scripts/audit-repos.json"

fail_closed() {
  printf '⚠️  pre-commit-machine-audit: %s 監査不能のため fail-safe で commit ブロック。\n' "$1" >&2
  exit 2
}

# shellcheck source=/dev/null
source "$COMMON_LIB" || fail_closed "共有ロジック (${COMMON_LIB}) を読み込めない。"

input=$(cat)
[ -z "$input" ] && fail_closed '空入力で起動。'
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // ""' 2>/dev/null) || fail_closed 'JSON parse 失敗。'

exec_cmd=$(kn_extract_exec_cmd "$cmd")
kn_is_commit_command "$exec_cmd" || exit 0

target_cwd=$(kn_resolve_commit_dir "$cmd" "$input")
cd "$target_cwd" 2>/dev/null || exit 0
git rev-parse --git-dir >/dev/null 2>&1 || exit 0

[ -f "$REPOS_CONFIG_FILE" ] || fail_closed "全リポの設定 (${REPOS_CONFIG_FILE}) が見つからない。"
kn_is_excluded_repo "$REPOS_CONFIG_FILE" "$(kn_repo_name "$target_cwd")" && exit 0

staged=$(git diff --cached --name-only --diff-filter=ACM 2>/dev/null)
[ -z "$staged" ] && exit 0

hard_violations=()
soft_violations=()

# --- (1/HARD) コメントに ADR・BDR の番号を書かない (coding.md コーディング方針) ---
while IFS= read -r f; do
  [ -z "$f" ] && continue
  case "$f" in
    *.md|*CHANGELOG*) continue ;;
  esac
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    hard_violations+=("$f: $line  [ADR・BDR の番号をコメントに書かない — coding.md]")
  done < <(git diff --cached -U0 -- "$f" 2>/dev/null | grep -nE '^\+.*\b(ADR|BDR)-[0-9]+\b' || true)
done <<< "$staged"

# --- (2/SOFT) CLAUDE.md の編集 (principles.md 禁止事項) ---
# user 自身が更新して commit を Claude に依頼するケースがあるため SOFT。
while IFS= read -r f; do
  [ -z "$f" ] && continue
  case "$f" in
    CLAUDE.md|*/CLAUDE.md)
      soft_violations+=("$f  [CLAUDE.md は Claude が書き換えない — principles.md 禁止事項]")
      ;;
  esac
done <<< "$staged"

# --- (3/SOFT) rules/ 配下の編集 (principles.md 禁止事項) ---
# 明示許可があった場合のみ Claude が修正できるため SOFT。
while IFS= read -r f; do
  [ -z "$f" ] && continue
  case "$f" in
    rules/*|*/rules/*)
      soft_violations+=("$f  [rules/ 配下は Claude が書き換えない — principles.md 禁止事項]")
      ;;
  esac
done <<< "$staged"

# --- (4/HARD) terraform の variable に default を使わない (lang/iac.md) ---
while IFS= read -r f; do
  [ -z "$f" ] && continue
  case "$f" in *.tf) ;; *) continue ;; esac
  hits=$(git diff --cached -U20 -- "$f" 2>/dev/null | awk '
    BEGIN { in_var = 0; depth = 0 }
    /^@@/ { in_var = 0; depth = 0; next }
    /^[+ ]variable[[:space:]]+"/ { in_var = 1; depth = 0 }
    in_var && /\{/ { depth++ }
    in_var && /\}/ { depth--; if (depth <= 0) in_var = 0 }
    in_var && /^\+[[:space:]]*default[[:space:]]*=/ { print "default = (variable block 内)" }
  ' || true)
  if [ -n "$hits" ]; then
    hard_violations+=("$f  [terraform の variable に default = を使わない — lang/iac.md]")
  fi
done <<< "$staged"

# --- (5/HARD) Google Cloud を GCP と書かない (documentation.md 語の選び方) ---
while IFS= read -r f; do
  [ -z "$f" ] && continue
  case "$f" in
    *.lock|*.sum|*.png|*.jpg|*.jpeg|*.svg|*.ico|*.pdf|*.gif|*.woff*) continue ;;
  esac
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    hard_violations+=("$f: $line  [Google Cloud を GCP と書かない — documentation.md]")
  done < <(git diff --cached -U0 -- "$f" 2>/dev/null | grep -nE '^\+.*\bGCP\b' | grep -v 'GCPRO\|GCP_' || true)
done <<< "$staged"

# --- (6/HARD) 新規 workflow に timeout-minutes と concurrency を設定する (cicd.md CI方針) ---
# 各ステップへの name 付与は構造解析が要り、paths-ignore の要否は required status check の使用で分かれるため、意味解釈側 (pre-commit-claude-audit.sh) に委ねる。
added_workflows=$(git diff --cached --name-only --diff-filter=A 2>/dev/null | grep -E '\.github/workflows/.+\.ya?ml$' || true)
while IFS= read -r f; do
  [ -z "$f" ] && continue
  content=$(git show ":$f" 2>/dev/null || cat "$f" 2>/dev/null || true)
  [ -z "$content" ] && continue
  # reusable workflow を呼ぶだけのジョブには timeout-minutes を設定できないため、runs-on を持つ workflow だけを対象にする。
  if printf '%s' "$content" | grep -qE '^[[:space:]]*runs-on[[:space:]]*:' \
    && ! printf '%s' "$content" | grep -qE '^[[:space:]]*timeout-minutes[[:space:]]*:'; then
    hard_violations+=("$f  [新規 workflow に timeout-minutes が必要 — cicd.md CI方針]")
  fi
  if ! printf '%s' "$content" | grep -qE '^concurrency[[:space:]]*:'; then
    hard_violations+=("$f  [新規 workflow に concurrency が必要 — cicd.md CI方針]")
  fi
done <<< "$added_workflows"

hard_n=${#hard_violations[@]}
soft_n=${#soft_violations[@]}

[ "$hard_n" -eq 0 ] && [ "$soft_n" -eq 0 ] && exit 0

# HARD があれば block する (SOFT も併せて表示)。
if [ "$hard_n" -gt 0 ]; then
  {
    printf '\n❌ pre-commit-machine-audit: HARD 違反 %d 件 / SOFT 違反 %d 件を検出 (target: %s)\n\n' "$hard_n" "$soft_n" "$target_cwd"
    printf '[HARD] commit ブロック対象:\n'
    for v in "${hard_violations[@]}"; do
      printf '  - %s\n' "$v"
    done
    if [ "$soft_n" -gt 0 ]; then
      printf '\n[SOFT] (HARD があるので合わせてブロック):\n'
      for v in "${soft_violations[@]}"; do
        printf '  - %s\n' "$v"
      done
    fi
    printf '\n意味解釈が必要なルールは本 hook 対象外。pre-commit-claude-audit.sh で別途確認される。\n'
  } >&2
  exit 2
fi

# SOFT のみなら ask で user に判断を委ねる。
reason=$(
  printf '機械検出した SOFT 違反 %d 件:\n' "$soft_n"
  for v in "${soft_violations[@]}"; do
    printf '  - %s\n' "$v"
  done
  printf '\n意図的な編集 (ユーザーによる手動修正等) なら許可、想定外なら拒否してください。'
)
jq -nc --arg r "$reason" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "ask",
    permissionDecisionReason: $r
  }
}'
exit 0
