#!/usr/bin/env bash
# 報告の検査を、応答を出す前の草稿の検査 (check-report.sh) と、応答の完了時の検査 (review-report.sh) で同じ判定にするため、検査の部品をまとめる。
# 両スクリプトから source される。

readonly CHILD_GUARD_ENV='KN_DECISION_CHECK_CHILD'
readonly REPORT_HEADING='## 報告事項'
readonly DECISION_HEADING='## 判断事項'
readonly VERDICT_RESOLVABLE='ルールで解決できる'
readonly REVIEWER_MODEL='sonnet'
readonly MIN_QUOTE_LENGTH=10
readonly FAILURE_OUTPUT_LENGTH=500
readonly READ_LOG_DIR="${HOME}/.claude/kn-read-log"
readonly REVIEW_SCHEMA='{"type":"object","properties":{"items":{"type":"array","items":{"type":"object","properties":{"number":{"type":"integer"},"verdict":{"type":"string","enum":["ルールで解決できる","聞いてよい"]},"basis_file":{"type":"string"},"basis_quote":{"type":"string"},"chosen_option":{"type":"string"},"explanation":{"type":"string"}},"required":["number","verdict","basis_file","basis_quote","chosen_option","explanation"]}},"concise_issues":{"type":"array","items":{"type":"object","properties":{"sentence":{"type":"string"},"basis_file":{"type":"string"},"basis_quote":{"type":"string"},"problem":{"type":"string"}},"required":["sentence","basis_file","basis_quote","problem"]}}},"required":["items","concise_issues"]}'

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
rules_dir="${repo_dir}/rules"
templates_dir="${repo_dir}/templates"
principles_file="${rules_dir}/principles.md"
report_template_file="${templates_dir}/report.template.md"

extract_decision_section() {
  awk -v heading="$DECISION_HEADING" '
    $0 == heading { in_section = 1; next }
    in_section && /^## / { exit }
    in_section { print }
  '
}

# 報告ではない応答に無関係な指摘を出さないため、報告か判断事項の項目を含む応答だけを検査の対象にする。
is_report_message() {
  local message="$1" section
  section=$(printf '%s\n' "$message" | extract_decision_section)
  printf '%s\n' "$message" | grep -qxF -- "$REPORT_HEADING" && return 0
  printf '%s\n' "$section" | grep -qE '^[0-9]+\. '
}

has_decision_items() {
  local message="$1"
  printf '%s\n' "$message" | extract_decision_section | grep -qE '^[0-9]+\. '
}

# 草稿と最終の応答を打ち直したときの行末の空白や前後の空行の違いで一致しなくなるのを防ぐため、これらを除いてからハッシュを取る。
hash_message() {
  local message="$1"
  printf '%s\n' "$message" \
    | sed 's/[[:space:]]*$//' \
    | awk '{ lines[NR] = $0 } END {
        first = 1
        while (first <= NR && lines[first] == "") first++
        last = NR
        while (last >= first && lines[last] == "") last--
        for (i = first; i <= last; i++) print lines[i]
      }' \
    | shasum -a 256 | cut -d' ' -f1
}

record_passed_message() {
  local session_id="$1" message_hash="$2"
  mkdir -p "$READ_LOG_DIR"
  printf '%s\n' "$message_hash" >> "${READ_LOG_DIR}/${session_id}.passed"
}

is_passed_message() {
  local session_id="$1" message_hash="$2"
  grep -qxF -- "$message_hash" "${READ_LOG_DIR}/${session_id}.passed" 2>/dev/null
}

# 画面に出さなかった報告を Stop フックが再び検査せずに差し戻せるよう、違反の指摘を報告のハッシュごとに残す。
save_review_reasons() {
  local session_id="$1" message_hash="$2" reasons="$3"
  mkdir -p "$READ_LOG_DIR"
  printf '%s' "$reasons" > "${READ_LOG_DIR}/${session_id}.reasons.${message_hash}"
}

load_review_reasons() {
  local session_id="$1" message_hash="$2"
  cat "${READ_LOG_DIR}/${session_id}.reasons.${message_hash}" 2>/dev/null
}

list_unread_rule_files() {
  local session_id="$1" prompt_id="$2"
  local log_file="${READ_LOG_DIR}/${session_id}.tsv"
  local required_file
  for required_file in "$principles_file" "$report_template_file"; do
    grep -qxF -- "${prompt_id}"$'\t'"${required_file}" "$log_file" 2>/dev/null || printf '%s\n' "$required_file"
  done
}

build_reviewer_prompt() {
  local message="$1"
  cat <<EOF
あなたは、ユーザーへの報告を検査するレビュアーである。
最初に ${principles_file} と ${report_template_file} を Read で全文読む。そのあと、下の報告について次の二つを検査する。

検査1: 判断事項の各項目が、ユーザーに聞くべきでない項目かを判定する。判断事項の項目がなければ、items を空の配列にする。
判定基準 (ユーザーの指示、原文):
Aこのままだとーー
B修正すればよくなるけど、ーーを書き換える手間が発生
みたいな二択ならユーザーに聞かずBを選択するなど
根拠にしてよいのは、読んだファイルに書かれた条文だけである。項目ごとに verdict を次のどちらかにする。
- ${VERDICT_RESOLVABLE}: 根拠の条文が読んだファイルにあり、その条文が選ぶ案を決めている。
- 聞いてよい: 根拠の条文を示せない。
verdict が「${VERDICT_RESOLVABLE}」のときは、basis_file に根拠のファイルの絶対パス、basis_quote に根拠の条文を一行分そのまま (要約や複数行の連結をせず) 引用し、chosen_option に選ぶ案の記号を書く。
verdict が「聞いてよい」のときは、basis_file・basis_quote・chosen_option を空文字にする。

検査2: 報告全体 (判断事項以外を含む) に、${principles_file} の「## [base] ユーザーへの報告と質問」の節のうち、報告を簡潔に書くことに関わる条文へ違反している文があれば、concise_issues に書く。節の条文を上から一つずつ報告に当てはめて、見落としをなくす。
sentence に違反している文を一行分そのまま (要約や複数行の連結をせず) 引用し、basis_file に根拠のファイルの絶対パス、basis_quote に根拠の条文を一行分そのまま引用し、problem に何が違反かを書く。
根拠の条文を示せない指摘は書かない。違反がなければ concise_issues を空の配列にする。

報告:
${message}
EOF
}

# 子プロセスが親のフック・MCP・スキルを読み込むと遅く高価になるうえ再帰するため、設定の読み込みを切り、ツールを Read だけにする。
run_reviewer() {
  local prompt="$1"
  local work_dir status
  work_dir=$(mktemp -d) || return 1
  (
    cd "$work_dir" || exit 1
    env "${CHILD_GUARD_ENV}=1" claude -p "$prompt" \
      --model "$REVIEWER_MODEL" \
      --settings '{"disableAllHooks": true}' \
      --setting-sources "" \
      --strict-mcp-config \
      --disable-slash-commands \
      --tools Read \
      --add-dir "$repo_dir" \
      --no-session-persistence \
      --output-format json \
      --json-schema "$REVIEW_SCHEMA" < /dev/null
  )
  status=$?
  rm -rf "$work_dir"
  return "$status"
}

# 短い断片は何にでも一致するため、一定の長さ以上の引用だけを実在する条文として扱う。
is_quote_in_rules() {
  local quote="$1"
  [ "${#quote}" -ge "$MIN_QUOTE_LENGTH" ] && grep -rqF -- "$quote" "$rules_dir" "$templates_dir"
}

# レビュアーの作話を除くため、報告に実在する文だけを違反箇所として扱う。
is_sentence_in_message() {
  local sentence="$1" message="$2"
  [ "${#sentence}" -ge "$MIN_QUOTE_LENGTH" ] && printf '%s' "$message" | grep -qF -- "$sentence"
}

count_lines_in_log() {
  local log_file="$1" prompt_id="$2"
  if [ ! -f "$log_file" ]; then
    printf '0\n'
    return 0
  fi
  grep -cxF -- "$prompt_id" "$log_file" || true
}

collect_decision_reasons() {
  local review_json="$1" item quote number basis_file chosen_option explanation
  while IFS= read -r item; do
    quote=$(printf '%s' "$item" | jq -r '.basis_quote')
    is_quote_in_rules "$quote" || continue
    number=$(printf '%s' "$item" | jq -r '.number')
    basis_file=$(printf '%s' "$item" | jq -r '.basis_file')
    chosen_option=$(printf '%s' "$item" | jq -r '.chosen_option')
    explanation=$(printf '%s' "$item" | jq -r '.explanation')
    printf '判断事項 %s は、ルールで解決できる。ユーザーに聞かず案%sで解決して報告事項に書く。根拠 (%s): %s\n%s\n\n' \
      "$number" "$chosen_option" "$basis_file" "$quote" "$explanation"
  done < <(printf '%s' "$review_json" | jq -c --arg verdict "$VERDICT_RESOLVABLE" '.items[] | select(.verdict == $verdict)')
}

collect_concise_reasons() {
  local review_json="$1" message="$2" issue sentence quote basis_file problem
  while IFS= read -r issue; do
    sentence=$(printf '%s' "$issue" | jq -r '.sentence')
    quote=$(printf '%s' "$issue" | jq -r '.basis_quote')
    is_sentence_in_message "$sentence" "$message" || continue
    is_quote_in_rules "$quote" || continue
    basis_file=$(printf '%s' "$issue" | jq -r '.basis_file')
    problem=$(printf '%s' "$issue" | jq -r '.problem')
    printf '簡潔さの指摘: 「%s」は、%s の「%s」に反する。%s\n\n' "$sentence" "$basis_file" "$quote" "$problem"
  done < <(printf '%s' "$review_json" | jq -c '.concise_issues[]')
}

# 呼び出し側が違反と検査の失敗を見分けられるよう、違反の指摘は標準出力に出し、検査の失敗は標準エラー出力に出して 2 を返す。
review_message() {
  local message="$1" session_id="$2" prompt_id="$3"
  local reasons="" unread_files reviewer_output reviewer_status review_json

  if has_decision_items "$message"; then
    unread_files=$(list_unread_rule_files "$session_id" "$prompt_id")
    if [ -n "$unread_files" ]; then
      reasons+="このターンで次のファイルを Read していない。Read してから、判断事項に出す内容をルールに照らして見直す。
${unread_files}

"
    fi
  fi

  reviewer_output=$(run_reviewer "$(build_reviewer_prompt "$message")" 2>&1)
  reviewer_status=$?
  review_json=$(printf '%s' "$reviewer_output" | jq -c '.structured_output' 2>/dev/null)

  if [ "$reviewer_status" -ne 0 ] || [ -z "$review_json" ] || [ "$review_json" = "null" ]; then
    printf '報告の検査 (別プロセスの Claude) が失敗した。報告の依頼事項に、検査フック (report-review-common.sh) の修正を書く。失敗の出力: %s\n' \
      "$(printf '%s' "$reviewer_output" | head -c "$FAILURE_OUTPUT_LENGTH")" >&2
    return 2
  fi

  local decision_reasons concise_reasons
  decision_reasons=$(collect_decision_reasons "$review_json")
  concise_reasons=$(collect_concise_reasons "$review_json" "$message")
  [ -n "$decision_reasons" ] && reasons+="${decision_reasons}"$'\n\n'
  [ -n "$concise_reasons" ] && reasons+="${concise_reasons}"$'\n\n'
  [ -n "$reasons" ] && printf '%s' "$reasons"
  return 0
}
