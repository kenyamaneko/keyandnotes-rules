#!/usr/bin/env bash
# Pre-commit SOFT (semantic) rule audit via headless Claude — 全リポ共通。
# 別 Claude プロセスを auditor として起動し、staged diff を共通ルール (keyandnotes-rules = base) と
# 対象リポの overlay (rules/) に照らしてレビューさせる。worker 自身の authorship bias を構造的に
# 排除するため別 session で実行する。
#
# 使い方: 各リポの .claude/scripts/pre-commit-claude-audit.sh から対象リポのルートを第 1 引数に渡して呼ばれる。
# 対象リポ固有の差 (言語判定・注入するルール・overlay の名前) は、対象リポの .claude/audit-config.json に置く。
#
# base を注入したら同じ相対パスの overlay も必ず注入する不変条件を emit_rule に閉じ込め、
# overlay (固有ルール) の注入漏れを構造的に防ぐ。加えて、rules/ 配下の overlay が一つも注入されないまま
# 残る配線漏れも検知して fail-closed にする。
#
# 各違反を 2 軸で分類し、principles「ルール違反への対応」に従って自律修正と user 委譲を仕分ける:
#   - clarity    : 違反の明白度 (obvious = 解釈の余地なし / interpretive = 解釈次第)
#   - fix_safety : 是正の安全性 (safe = 修正しても設計上の実害なし / harmful = 是正に実害ありうる)
# 出力契約:
#   - obvious かつ safe の違反あり → permissionDecision=deny で worker に差し戻し自律修正させる
#   - それ以外の違反のみ (interpretive / harmful を含む) → permissionDecision=ask で user に判断委譲
#   - violations 0 件 → exit 0
#   - audit 不能 (入力欠落 / 設定欠落 / ルール欠落 / auditor 起動失敗 / API エラー / 出力欠落 / 単一ファイル超過) → exit 2 で fail-closed block
#   - staged diff が auditor の context に収まらない場合はファイル単位でチャンク分割し全グループを監査

set -uo pipefail

readonly AUDIT_LOG_DIR="${HOME}/.claude/audit-logs"
readonly AUDIT_LOG_FILE="${AUDIT_LOG_DIR}/pre-commit-claude-audit.log"
readonly CONFIG_RELATIVE_PATH=".claude/audit-config.json"
readonly ALWAYS_CONDITION="always"
readonly FLEET_LANG_CONDITION_PREFIX="lang:"

# auditor に使う headless Claude のモデル。頻繁に走るため reasoning と速度のバランスで sonnet を用いる。
readonly AUDITOR_MODEL="claude-sonnet-5"

# auditor の context window に収めるためのプロンプト上限 (bytes)。headless claude の基盤プロンプト分を差し引いた安全側の値。
readonly MAX_PROMPT_BYTES=350000

# diff に割ける最小予算。これを下回るとチャンク分割しても監査が成立しないため fail-closed する。
readonly MIN_DIFF_BUDGET_BYTES=20000

SHARED_REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
readonly SHARED_REPO_DIR
readonly BASE_RULES="${SHARED_REPO_DIR}/rules"
readonly COMMON_LIB="${SHARED_REPO_DIR}/scripts/claude-audit-common.sh"

# permissionDecisionReason は確認ダイアログに一度表示されるだけで保存されないため、単一ファイルに追記する。
log_audit_reason() {
  local decision="$1" repo="$2" text="$3"
  mkdir -p "$AUDIT_LOG_DIR" || return 0
  {
    printf '\n=== %s | decision=%s | target=%s ===\n' "$(date '+%Y-%m-%d %H:%M:%S %z')" "$decision" "$repo"
    printf '%s\n' "$text"
  } >> "$AUDIT_LOG_FILE" || true
}

fail_closed() {
  printf '⚠️  pre-commit-claude-audit: %s 監査不能のため fail-safe で commit ブロック。\n' "$1" >&2
  exit 2
}

# auditor の stderr を捕捉する一時ファイル (並行 commit のレース回避に mktemp を使う)。
err_file=$(mktemp)
trap 'rm -f "$err_file"' EXIT

expected_repo_root="${1:-}"
if [ -z "$expected_repo_root" ]; then
  fail_closed '対象リポのルートが第 1 引数に渡されていない。'
fi
expected_repo_root=$(cd "$expected_repo_root" 2>/dev/null && pwd -P) || fail_closed "対象リポのルート (${1}) が開けない。"

input=$(cat)
if [ -z "$input" ]; then
  fail_closed '空入力で起動。'
fi
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // ""' 2>/dev/null)
jq_rc=$?
if [ "$jq_rc" -ne 0 ]; then
  fail_closed "JSON parse 失敗 (jq exit ${jq_rc})。"
fi

# 文字列リテラル / HEREDOC 内の偶発マッチを避けるため実行可能部分のみ抽出
exec_cmd=$(printf '%s' "$cmd" | sed -E '/<</q' | sed -E 's/"[^"]*"//g; s/'\''[^'\'']*'\''//g')

if ! printf '%s' "$exec_cmd" | grep -qE '(^|[[:space:]&|;`(])git[[:space:]]+commit'; then
  exit 0
fi
if printf '%s' "$exec_cmd" | grep -qE 'git[[:space:]]+commit[[:space:]]+(--help|-h)([[:space:]]|$)'; then
  exit 0
fi

# --- (0/HARD) git add/rm/mv や git commit -a(m)/--all と git commit を同一コマンドにまとめない ---
# hook は Bash コマンド実行前に発火するため、同一コマンドに add 等をまとめると実行前時点では
# ステージ済み差分が空に見え、下の staged_diff 空チェック (exit 0) を素通りして無審査で commit が成立する。
if printf '%s' "$exec_cmd" | grep -qE '(^|[[:space:]&|;`(])git[[:space:]]+(add|rm|mv)([[:space:]]|$)'; then
  printf '\n❌ pre-commit-claude-audit: git add/rm/mv と git commit が同一 Bash 呼び出しに含まれています。\n\nステージ操作 (git add/rm/mv) と git commit を別の Bash 呼び出しに分けてから commit してください。\n' >&2
  exit 2
fi
if printf '%s' "$exec_cmd" | grep -qE 'git[[:space:]]+commit[[:space:]]+(-[a-zA-Z]*a[a-zA-Z]*|--all)([[:space:]]|=|$)'; then
  printf '\n❌ pre-commit-claude-audit: git commit -a/-am/--all はステージ操作を commit 自体が兼ねます。\n\n事前に git add で明示的にステージしてから commit してください。\n' >&2
  exit 2
fi

# commit コマンドの書き方 (git -C / cd / 素の commit) で監査対象 cwd がぶれても拾えるようにする
target_cwd=$(printf '%s' "$cmd" | grep -oE 'git[[:space:]]+-C[[:space:]]+"?[^"&|;[:space:]]+' | head -1 | sed -E 's|^git[[:space:]]+-C[[:space:]]+"?||')
if [ -z "$target_cwd" ]; then
  before_commit=$(printf '%s' "$cmd" | sed -E 's/git[[:space:]]+commit.*//')
  target_cwd=$(printf '%s' "$before_commit" | grep -oE '(^|[&|;[:space:]])cd[[:space:]]+"?[^"&|;[:space:]]+' | tail -1 | sed -E 's|.*cd[[:space:]]+"?||')
fi
if [ -z "$target_cwd" ]; then
  target_cwd=$(printf '%s' "$input" | jq -r '.cwd // ""' 2>/dev/null)
fi
if [ -z "$target_cwd" ]; then
  target_cwd=$(pwd)
fi
if ! cd "$target_cwd" 2>/dev/null; then
  exit 0
fi
if ! git rev-parse --git-dir >/dev/null 2>&1; then
  exit 0
fi

config_file="${expected_repo_root}/${CONFIG_RELATIVE_PATH}"

# 1 つのフックが複数のリポ (fleet) の commit を受け持つ設定は、commit 先を下の registry から求めるため、本体リポかどうかでは絞らない。
is_fleet=false
if [ -f "$config_file" ] && [ "$(jq -r 'has("fleet")' "$config_file" 2>/dev/null)" = "true" ]; then
  is_fleet=true
fi

# commit 先が対象リポ (その worktree を含む) でなければ、対象リポのルールを当てないため監査しない。
# worktree はチェックアウトの場所が本体と違うため、場所でなく共通の .git で同じリポかを判定する。
target_common_dir=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
expected_common_dir=$(git -C "$expected_repo_root" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
if [ "$is_fleet" = false ] && [ "$(cd "$target_common_dir" 2>/dev/null && pwd -P)" != "$(cd "$expected_common_dir" 2>/dev/null && pwd -P)" ]; then
  exit 0
fi

# --- 対象リポの設定 ---
if [ ! -f "$config_file" ]; then
  fail_closed "設定 (${config_file}) が見つからない。"
fi
config_valid=$(jq -r '
  (.name | type == "string" and length > 0)
  and (.conditions | type == "object")
  and (.rules | type == "array") and all(.rules[]; (.rule | type == "string") and (.when | type == "string"))
  and (.overlay_names | type == "object")
  and (.replace_overlay | type == "array")
  and (.exempt_overlays | type == "array") and all(.exempt_overlays[]; (.path | type == "string") and (.reason | type == "string" and length > 0))
  and (.exclude_pathspecs | type == "array")
  and (if has("fleet") then (.fleet.registry | type == "string") and (.fleet.extra_docs | type == "array") else true end)
' "$config_file" 2>/dev/null)
if [ "$config_valid" != "true" ]; then
  fail_closed "設定 (${config_file}) の形式が不正。name / conditions / rules / overlay_names / replace_overlay / exempt_overlays (path と reason) / exclude_pathspecs が必要。fleet を使うときは fleet.registry と fleet.extra_docs も必要。"
fi

repo_name=$(jq -r '.name' "$config_file")
OVERLAY_RULES="${expected_repo_root}/rules"

exclude_pathspecs=()
while IFS= read -r pathspec; do
  [ -n "$pathspec" ] && exclude_pathspecs+=("$pathspec")
done < <(jq -r '.exclude_pathspecs[]' "$config_file")

# 空配列の展開は bash 3.2 の set -u でエラーになるため、要素があるときだけ展開する。
staged_diff=$(git diff --cached -U10 --diff-filter=ACM -- . ${exclude_pathspecs[@]+"${exclude_pathspecs[@]}"} 2>/dev/null)
if [ -z "$staged_diff" ]; then
  exit 0
fi

# worktree は作成場所に規則性が無く target_cwd を registry のパスへ直接一致させられないため、git の共通 .git dir から
# 実チェックアウトパスを逆引きし、照合候補に加える。
fleet_lang=""
fleet_prereq_docs=""
if [ "$is_fleet" = true ]; then
  git_common_dir=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
  main_worktree_root=""
  [ -n "$git_common_dir" ] && main_worktree_root=$(dirname "$git_common_dir")
  fleet_registry=$(jq -r '.fleet.registry' "$config_file")
  resolved=$(python3 - "$expected_repo_root" "$fleet_registry" "$target_cwd" "$main_worktree_root" <<'PY'
import sys, os, json, yaml
repo_root, registry, target_cwd, main_worktree_root = sys.argv[1:5]
with open(os.path.join(repo_root, registry)) as f:
    data = yaml.safe_load(f)
candidates = {os.path.realpath(target_cwd)}
if main_worktree_root:
    candidates.add(os.path.realpath(main_worktree_root))
for r in data.get("repos", []):
    if os.path.realpath(os.path.join(repo_root, r["path"])) in candidates:
        print(json.dumps({"name": r["name"], "lang": r.get("lang", "none"), "prereq_docs": r.get("prereq_docs", [])}))
        break
PY
)
  if [ -z "$resolved" ]; then
    fail_closed "commit 対象リポ (${main_worktree_root:-$target_cwd}) が ${fleet_registry} に未登録のため解決不能。登録が必要な場合は ${fleet_registry} への追記を人間に提案してください (Claude は rules/ 配下を書き換えない)。"
  fi
  repo_name=$(printf '%s' "$resolved" | jq -r '.name')
  fleet_lang=$(printf '%s' "$resolved" | jq -r '.lang')
  fleet_prereq_docs=$(printf '%s' "$resolved" | jq -r '.prereq_docs[]?')
fi

# principles.md が @import する base ルール一覧を手書きリストで複製すると、principles.md 側の
# 更新に追従しない二重管理になる。共有ロジックから動的に導出する。
if [ ! -f "$COMMON_LIB" ]; then
  fail_closed "共有ロジック (${COMMON_LIB}) が見つからない。"
fi
# shellcheck source=/dev/null
source "$COMMON_LIB"

# 設定の rules に挙げたルールは条件付きで呼び出し側 (このスクリプト) が注入するため、自動導出から除外する。
config_rule_names=()
while IFS= read -r rule_name; do
  config_rule_names+=("$rule_name")
done < <(jq -r '.rules[].rule' "$config_file")

auto_inject_refs_raw=$(kn_auto_inject_refs "$BASE_RULES" "${BASE_RULES}/principles.md" ${config_rule_names[@]+"${config_rule_names[@]}"})
if [ $? -ne 0 ]; then
  fail_closed 'principles.md が参照する base ルールの自動導出に失敗。'
fi
AUTO_INJECT_REFS=()
while IFS= read -r ref; do
  [ -n "$ref" ] && AUTO_INJECT_REFS+=("$ref")
done <<< "$auto_inject_refs_raw"

# 監査対象の言語・種別を、設定の conditions (ファイル名の正規表現) でステージ済みファイルから判定し、注入するルールを絞る。
staged_names=$(git diff --cached --name-only --diff-filter=ACM -- . ${exclude_pathspecs[@]+"${exclude_pathspecs[@]}"} 2>/dev/null)
active_conditions="$ALWAYS_CONDITION"
while IFS=$'\t' read -r condition_name condition_regex; do
  [ -z "$condition_name" ] && continue
  if printf '%s\n' "$staged_names" | grep -qE -- "$condition_regex"; then
    active_conditions="${active_conditions}"$'\n'"${condition_name}"
  fi
done < <(jq -r '.conditions | to_entries[] | "\(.key)\t\(.value)"' "$config_file")

# fleet の対象リポの言語は registry から求めるため、条件名 lang:<言語> でも rules から参照できる。
if [ -n "$fleet_lang" ] && [ "$fleet_lang" != "none" ]; then
  active_conditions="${active_conditions}"$'\n'"${FLEET_LANG_CONDITION_PREFIX}${fleet_lang}"
fi

for when_name in $(jq -r '.rules[].when' "$config_file"); do
  if [ "$when_name" = "$ALWAYS_CONDITION" ]; then
    continue
  fi
  if [ "$is_fleet" = true ] && [ "${when_name#"$FLEET_LANG_CONDITION_PREFIX"}" != "$when_name" ]; then
    continue
  fi
  if [ "$(jq -r --arg c "$when_name" '.conditions | has($c)' "$config_file")" != "true" ]; then
    fail_closed "設定の rules が未定義の条件 ${when_name} を参照している。"
  fi
done

is_condition_active() {
  printf '%s\n' "$active_conditions" | grep -qxF -- "$1"
}

is_in_config_list() {
  local key="$1" rel="$2"
  [ "$(jq -r --arg k "$key" --arg r "$rel" '.[$k] | index($r) != null' "$config_file")" = "true" ]
}

# 対応する overlay のファイル名。設定の overlay_names にあればそれ、なければ base と同じ相対パス。
resolve_overlay_name() {
  jq -r --arg r "$1" '.overlay_names[$r] // $r' "$config_file"
}

# 注入候補の全ルール (条件を問わない)。検証と配線漏れ検査はこの一覧を使う。
all_rule_rels=("principles.md")
for ref in ${AUTO_INJECT_REFS[@]+"${AUTO_INJECT_REFS[@]}"}; do
  all_rule_rels+=("$ref")
done
for rule_name in ${config_rule_names[@]+"${config_rule_names[@]}"}; do
  all_rule_rels+=("$rule_name")
done

# build_prompt はパイプのサブシェルで走り exit が親に伝播しないため、存在検証は必ず本文脈 (メインシェル) で行う。
covered_overlays=""
for rel in "${all_rule_rels[@]}"; do
  overlay_name=$(resolve_overlay_name "$rel")
  covered_overlays="${covered_overlays}"$'\n'"${overlay_name}"
  if is_in_config_list replace_overlay "$rel"; then
    [ -f "${OVERLAY_RULES}/${overlay_name}" ] || fail_closed "${repo_name} の overlay rules/${overlay_name} が見つからず、共通 ${rel} を置き換えられない。"
  else
    [ -f "${BASE_RULES}/${rel}" ] || fail_closed "共通ルール rules/${rel} が見つからず実効ルール集を構成できない。"
    if [ "$overlay_name" != "$rel" ]; then
      [ -f "${OVERLAY_RULES}/${overlay_name}" ] || fail_closed "${repo_name} の overlay rules/${overlay_name} が見つからず実効ルール集を構成できない。"
    fi
  fi
done

# overlay を足しても配線し忘れると監査から静かに漏れるため、配線漏れを検知して fail-closed にする。
while IFS= read -r overlay_file; do
  [ -z "$overlay_file" ] && continue
  rel="${overlay_file#"${OVERLAY_RULES}/"}"
  [ "$(jq -r --arg p "$rel" '.exempt_overlays | map(.path) | index($p) != null' "$config_file")" = "true" ] && continue
  if ! printf '%s\n' "$covered_overlays" | grep -qxF -- "$rel"; then
    fail_closed "overlay rules/${rel} が監査に注入されない。.claude/audit-config.json の rules に追加する (ルールでなければ exempt_overlays に理由を添えて追加する)。"
  fi
done < <(find "$OVERLAY_RULES" -type f -name '*.md' 2>/dev/null)

# 不変条件: ある相対パスのルールを注入するときは base と overlay を必ず対で出す。
# base だけ出して overlay を落とす事故を、注入を 1 関数に括ることで構造的に防ぐ。
emit_rule() {
  local rel="$1"
  local base="${BASE_RULES}/${rel}"
  local overlay_name overlay
  overlay_name=$(resolve_overlay_name "$rel")
  overlay="${OVERLAY_RULES}/${overlay_name}"
  if is_in_config_list replace_overlay "$rel"; then
    printf '\n\n## [overlay/%s] rules/%s (共通 %s を全面置換。本ファイルを正とする)\n' "$repo_name" "$overlay_name" "$rel"
    cat "$overlay"
    return 0
  fi
  if [ -f "$base" ]; then
    printf '\n\n## [base] rules/%s\n' "$rel"
    cat "$base"
  fi
  if [ -f "$overlay" ]; then
    printf '\n\n## [overlay/%s] rules/%s (base と衝突する場合はこちらを優先)\n' "$repo_name" "$overlay_name"
    cat "$overlay"
  fi
}

# auditor prompt を組み立てる。ルール群を毎回 inline 注入し auditor に fresh Read を強制する。
build_prompt() {
  cat <<HEADER
あなたは ${repo_name} リポの SOFT (意味解釈型) ルール auditor です。
別の Claude が書いた staged diff を、以下の共通ルール (base) と ${repo_name} 固有ルール (overlay) に照らしてレビューしてください。
overlay は対応する base のルールを上書きする階層です。base と overlay が衝突する場合は overlay を優先して判定してください。

レビュー方針:
- 明確なルール違反のみ列挙する。主観的な改善提案・スタイル好みは含めない
- 各違反は file / line / rule / evidence / why / clarity / fix_safety を埋める。line は違反箇所の行番号 (diff の追加行) を必ず入れる
- 違反 0 件なら "violations": [] を返す

各違反を 2 軸で分類してください (hook が「worker が自律修正してよいか」を判定するのに使う):
- clarity (明白度):
  - "obvious"      = ルール文面に照らして違反が明白で、解釈の余地がない
  - "interpretive" = ルールの解釈次第で違反とみなされ、判断が分かれうる
- fix_safety (是正の安全性):
  - "safe"    = 違反を修正しても設計上の実害がない (例: docstring 追加, What コメント削除)
  - "harmful" = 是正することで設計上の実害が生じうる (例: 公開 API のリネーム, 責務分割による境界変更)
- diff だけでは確信が持てないときは "interpretive" / "harmful" (= 安全側) に倒す。自律修正は明白かつ安全な違反に限定するため

# 適用ルール (target repo: ${repo_name})
HEADER

  emit_rule "principles.md"
  for ref in ${AUTO_INJECT_REFS[@]+"${AUTO_INJECT_REFS[@]}"}; do
    emit_rule "$ref"
  done
  while IFS=$'\t' read -r rule_name when_name; do
    is_condition_active "$when_name" && emit_rule "$rule_name"
  done < <(jq -r '.rules[] | "\(.rule)\t\(.when)"' "$config_file")

  # fleet では、用語集などの共通ドキュメントと、対象リポ固有の前提ドキュメントも、ルールと同じく auditor に読ませる。
  if [ "$is_fleet" = true ]; then
    while IFS= read -r doc; do
      [ -z "$doc" ] && continue
      [ -f "${expected_repo_root}/${doc}" ] || continue
      printf '\n\n## %s\n' "$doc"
      cat "${expected_repo_root}/${doc}"
    done < <(jq -r '.fleet.extra_docs[]' "$config_file")
    while IFS= read -r doc; do
      [ -z "$doc" ] && continue
      [ -f "${expected_repo_root}/${doc}" ] || continue
      printf '\n\n## (prereq) %s\n' "$doc"
      cat "${expected_repo_root}/${doc}"
    done <<< "$fleet_prereq_docs"
  fi

  printf '\n\n# 対象 staged diff\n\n```diff\n%s\n```\n\n# 出力\n指定スキーマの JSON のみを返してください。\n' "$1"
}

schema='{
  "type": "object",
  "required": ["violations"],
  "additionalProperties": false,
  "properties": {
    "violations": {
      "type": "array",
      "items": {
        "type": "object",
        "required": ["file", "line", "rule", "evidence", "why", "clarity", "fix_safety"],
        "additionalProperties": false,
        "properties": {
          "file": {"type": "string"},
          "line": {"type": "integer"},
          "rule": {"type": "string"},
          "evidence": {"type": "string"},
          "why": {"type": "string"},
          "clarity": {"type": "string", "enum": ["obvious", "interpretive"]},
          "fix_safety": {"type": "string", "enum": ["safe", "harmful"]}
        }
      }
    }
  }
}'

all_violations='[]'

# 1 グループ分の diff を auditor にかけ、違反を all_violations に集約する。
# auditor が起動失敗 / API エラー / 出力欠落いずれかなら audit 不能とみなし exit 2 で fail-closed。
audit_diff() {
  local diff_text="$1"
  [ -z "$diff_text" ] && return 0

  local out exit_code is_error err_msg vtype group_viol
  out=$(build_prompt "$diff_text" | claude -p \
    --model "$AUDITOR_MODEL" \
    --tools "" \
    --output-format json \
    --json-schema "$schema" \
    --no-session-persistence 2>"$err_file")
  exit_code=$?

  if [ "$exit_code" -ne 0 ]; then
    printf '⚠️  pre-commit-claude-audit: Claude auditor 起動に失敗 (exit %d)。監査不能のため fail-safe で commit ブロック。\n%s\n' \
      "$exit_code" "$(head -20 "$err_file" 2>/dev/null)" >&2
    exit 2
  fi

  is_error=$(printf '%s' "$out" | jq -r '.is_error // false')
  if [ "$is_error" = "true" ]; then
    err_msg=$(printf '%s' "$out" | jq -r '.result // ""')
    printf '⚠️  pre-commit-claude-audit: Claude auditor が API エラー。監査不能のため fail-safe で commit ブロック。\n%s\n' "$err_msg" >&2
    exit 2
  fi

  # structured_output.violations が配列でなければ (欠落・型不正) 監査不能とみなす。
  # jq の null indexing は length 0 を返すため、必ず type を見て判定する。
  vtype=$(printf '%s' "$out" | jq -r '.structured_output.violations | type' 2>/dev/null)
  if [ "$vtype" != "array" ]; then
    printf '⚠️  pre-commit-claude-audit: auditor 出力の structured_output.violations が配列でない (type=%s)。監査不能のため fail-safe で commit ブロック。\nresult preview:\n%s\n' \
      "$vtype" "$(printf '%s' "$out" | jq -r '.result // ""' | head -c 500)" >&2
    exit 2
  fi

  group_viol=$(printf '%s' "$out" | jq -c '.structured_output.violations')
  all_violations=$(jq -cn --argjson a "$all_violations" --argjson b "$group_viol" '$a + $b')
}

rules_bytes=$(build_prompt "" | wc -c | tr -d ' ')
diff_budget=$(( MAX_PROMPT_BYTES - rules_bytes ))
if [ "$diff_budget" -lt "$MIN_DIFF_BUDGET_BYTES" ]; then
  printf '⚠️  pre-commit-claude-audit: ルール群が大きく diff 予算を確保できない (rules=%d bytes, max=%d)。監査不能のため fail-safe で commit ブロック。\n' \
    "$rules_bytes" "$MAX_PROMPT_BYTES" >&2
  exit 2
fi

staged_bytes=$(printf '%s' "$staged_diff" | wc -c | tr -d ' ')

if [ "$staged_bytes" -le "$diff_budget" ]; then
  audit_diff "$staged_diff"
else
  staged_files=()
  while IFS= read -r f; do
    [ -n "$f" ] && staged_files+=("$f")
  done <<< "$staged_names"

  group_files=()
  group_bytes=0

  # 現在のグループに溜めた staged ファイルの diff をまとめて監査し、グループをリセットする。
  flush_group() {
    [ "${#group_files[@]}" -eq 0 ] && return 0
    local gdiff
    gdiff=$(git diff --cached -U10 --diff-filter=ACM -- "${group_files[@]}" 2>/dev/null)
    audit_diff "$gdiff"
    group_files=()
    group_bytes=0
  }

  if [ "${#staged_files[@]}" -gt 0 ]; then
    for f in "${staged_files[@]}"; do
      fbytes=$(git diff --cached -U10 --diff-filter=ACM -- "$f" 2>/dev/null | wc -c | tr -d ' ')
      if [ "$fbytes" -gt "$diff_budget" ]; then
        printf '⚠️  pre-commit-claude-audit: 単一ファイルの diff が監査予算を超過 (%s: %d bytes > %d)。分割できず監査不能のため fail-safe で commit ブロック。当該ファイルの変更を分けてコミットしてください。\n' \
          "$f" "$fbytes" "$diff_budget" >&2
        exit 2
      fi
      if [ $(( group_bytes + fbytes )) -gt "$diff_budget" ] && [ "${#group_files[@]}" -gt 0 ]; then
        flush_group
      fi
      group_files+=("$f")
      group_bytes=$(( group_bytes + fbytes ))
    done
    flush_group
  fi
fi

violations_count=$(printf '%s' "$all_violations" | jq 'length')
if [ "$violations_count" -eq 0 ]; then
  exit 0
fi

autofix=$(printf '%s' "$all_violations" | jq -c '[.[] | select(.clarity == "obvious" and .fix_safety == "safe")]')
escalate=$(printf '%s' "$all_violations" | jq -c '[.[] | select(.clarity != "obvious" or .fix_safety != "safe")]')
autofix_count=$(printf '%s' "$autofix" | jq 'length')
escalate_count=$(printf '%s' "$escalate" | jq 'length')

# 混在時は明白な違反を先に deny で解消させ、解釈次第 / 是正に実害ありうる違反は再 commit 時に
# 別途 ask に載せる (auditor は 1 diff を一括判定するため、両者を同一 commit で同時には出せない)。
if [ "$autofix_count" -gt 0 ]; then
  reason=$(
    printf '明白かつ修正に実害のないルール違反 %d 件を検出。principles「ルール違反への対応」に従い、自律修正してから再 commit してください:\n\n' "$autofix_count"
    printf '%s' "$autofix" | jq -r '.[] | "- \(.file):\(.line)\n    rule: \(.rule)\n    evidence: \(.evidence)\n    why: \(.why)"'
    if [ "$escalate_count" -gt 0 ]; then
      printf '\n\n(解釈次第 / 是正に実害ありうる違反 %d 件は、上記修正後の再 commit で別途確認します。今は触れないでください。)' "$escalate_count"
    fi
    printf '\n\n検出が false positive だと判断する場合のみ、その理由を添えてユーザに確認してください。'
  )
  log_audit_reason "deny" "$repo_name" "$reason"
  jq -nc --arg r "$reason" '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
  exit 0
fi

reason=$(
  printf 'Claude auditor が判断を要するルール違反 %d 件を検出。明白でない、または是正に設計上の実害がありうるため、修正可否を判断してください:\n\n' "$escalate_count"
  printf '%s' "$escalate" | jq -r '.[] | "- \(.file):\(.line)  [明白度: \(if .clarity == "obvious" then "明白" else "解釈次第" end) / 是正の安全性: \(if .fix_safety == "safe" then "実害なし" else "実害ありうる" end)]\n    rule: \(.rule)\n    evidence: \(.evidence)\n    why: \(.why)"'
  printf '\n\n修正するなら拒否、意図的に commit するなら許可してください。'
)
log_audit_reason "ask" "$repo_name" "$reason"
jq -nc --arg r "$reason" '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "ask", permissionDecisionReason: $r}}'
exit 0
