#!/usr/bin/env bash
# 草稿の検査 (check-report.sh)、報告を画面から隠す処理 (hold-unchecked-report.sh)、報告を差し戻す処理 (block-unchecked-report.sh) が同じ判定を使うため、判定の部品をまとめる。
# 三つのスクリプトから source される。

readonly REPORT_HEADING='## 報告事項'
readonly DECISION_HEADING='## 判断事項'
readonly REQUEST_HEADING='## 依頼事項'
readonly HTML_LOCATION_PATTERN='\.html|claude\.ai/(code/)?artifact/'
readonly VERDICT_RESOLVABLE='ルールで解決できる'
readonly REVIEWER_MODEL='sonnet'
readonly UNCHECKED_REPORT_NOTICE='報告の検査を通せなかったため、検査を通っていない報告をそのまま表示する。'
readonly MIN_QUOTE_LENGTH=10
readonly FAILURE_OUTPUT_LENGTH=500
readonly ISSUE_SCHEMA='{"type":"array","items":{"type":"object","properties":{"sentence":{"type":"string"},"basis_file":{"type":"string"},"basis_quote":{"type":"string"},"problem":{"type":"string"}},"required":["sentence","basis_file","basis_quote","problem"]}}'
readonly ITEM_SCHEMA='{"type":"array","items":{"type":"object","properties":{"number":{"type":"integer"},"verdict":{"type":"string","enum":["ルールで解決できる","聞いてよい"]},"basis_file":{"type":"string"},"basis_quote":{"type":"string"},"chosen_option":{"type":"string"},"explanation":{"type":"string"}},"required":["number","verdict","basis_file","basis_quote","chosen_option","explanation"]}}'
readonly REVIEW_SCHEMA="{\"type\":\"object\",\"properties\":{\"items\":${ITEM_SCHEMA},\"concise_issues\":${ISSUE_SCHEMA},\"document_issues\":${ISSUE_SCHEMA},\"wording_issues\":${ISSUE_SCHEMA}},\"required\":[\"items\",\"concise_issues\",\"document_issues\",\"wording_issues\"]}"

# shellcheck source=../rules-control/read-log-common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../rules-control/read-log-common.sh"

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
rules_dir="${repo_dir}/rules"
templates_dir="${repo_dir}/templates"
principles_file="${rules_dir}/principles.md"
documentation_file="${rules_dir}/documentation.md"
testing_file="${rules_dir}/testing.md"
notation_table_file="${rules_dir}/notation-table.md"
report_template_file="${templates_dir}/report.template.md"

extract_section() {
  local heading="$1"
  awk -v heading="$heading" '
    $0 == heading { in_section = 1; next }
    in_section && /^## / { exit }
    in_section { print }
  '
}

extract_decision_section() {
  extract_section "$DECISION_HEADING"
}

# 報告の項目の詳細を報告用の HTML に書くと、依頼事項にその場所 (ファイルか公開した URL) を書く。依頼事項に HTML の場所があるかで、検査に HTML が要るかを決める。
has_html_location_in_request() {
  local message="$1"
  printf '%s\n' "$message" | extract_section "$REQUEST_HEADING" | grep -qE -- "$HTML_LOCATION_PATTERN"
}

# 雛形で書かれていない応答が検査をすり抜けるのを防ぐため、雛形の三つの見出しのいずれかか判断事項の項目を含む応答を報告として扱う。
is_report_message() {
  local message="$1" section heading
  section=$(printf '%s\n' "$message" | extract_decision_section)
  for heading in "$REPORT_HEADING" "$DECISION_HEADING" "$REQUEST_HEADING"; do
    printf '%s\n' "$message" | grep -qxF -- "$heading" && return 0
  done
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

# 検査を通った報告として、報告の全文のハッシュを記録する。
record_passed_message() {
  local session_id="$1" message_hash="$2"
  mkdir -p "$READ_LOG_DIR"
  printf '%s\n' "$message_hash" >> "${READ_LOG_DIR}/${session_id}.passed"
}

# 報告が検査を通ったものと全文が一致するかを返す。
is_passed_message() {
  local session_id="$1" message_hash="$2"
  grep -qxF -- "$message_hash" "${READ_LOG_DIR}/${session_id}.passed" 2>/dev/null
}

readonly MAX_BLOCKS_PER_PROMPT=5

# 報告を画面から隠す (MessageDisplay) と差し戻す (Stop) を同じ判定にし、隠したのに差し戻さない状態を作らないため、判定を一か所に置く。
# 検査を通っていない (草稿の検査を通した報告と全文が一致しない) 報告で、同じユーザー入力で検査コマンドが失敗しておらず、差し戻しが上限に達していなければ、隠して差し戻す。
should_hold_message() {
  local message="$1" session_id="$2" prompt_id="$3"
  is_report_message "$message" || return 1
  is_passed_message "$session_id" "$(hash_message "$message")" && return 1
  has_check_failure "$session_id" "$prompt_id" && return 1
  has_blocks_remaining "$session_id" "$prompt_id"
}

# 検査コマンドが失敗した報告は隠し続けても画面に出せないため、同じユーザー入力で検査コマンドが失敗した事実を記録する。
record_check_failure() {
  local session_id="$1" prompt_id="$2"
  mkdir -p "$READ_LOG_DIR"
  printf '%s\n' "$prompt_id" >> "${READ_LOG_DIR}/${session_id}.check-failures"
}

# 同じユーザー入力で検査コマンドが失敗したかを返す。
has_check_failure() {
  local session_id="$1" prompt_id="$2"
  [ -n "$prompt_id" ] || return 1
  [ "$(count_lines_in_log "${READ_LOG_DIR}/${session_id}.check-failures" "$prompt_id")" -gt 0 ]
}

# 差し戻しの再試行が終わらず費用が増え続けるのを防ぐため、同じユーザー入力への差し戻しに上限を置く。
has_blocks_remaining() {
  local session_id="$1" prompt_id="$2"
  [ "$(count_lines_in_log "${READ_LOG_DIR}/${session_id}.blocks" "$prompt_id")" -lt "$MAX_BLOCKS_PER_PROMPT" ]
}

# 画面に出す応答の最後が報告でなくても、同じユーザー入力で隠した報告が画面に出るまで Stop フックが差し戻せるよう、隠した事実を残す。
record_held_prompt() {
  local session_id="$1" prompt_id="$2" message="$3"
  mkdir -p "$READ_LOG_DIR"
  printf '%s\n' "$prompt_id" > "${READ_LOG_DIR}/${session_id}.held"
  printf '%s' "$message" > "${READ_LOG_DIR}/${session_id}.held-report"
}

# 隠した報告が画面に出たため、隠した事実と報告の全文の記録を消す。
clear_held_prompt() {
  local session_id="$1"
  rm -f "${READ_LOG_DIR}/${session_id}.held" "${READ_LOG_DIR}/${session_id}.held-report"
}

# 検査を通っていない報告を、警告つきの文面にして返す。
format_unchecked_report() {
  local report="$1"
  printf '%s\n\n%s' "$UNCHECKED_REPORT_NOTICE" "$report"
}

# 隠した報告の全文を返す。
read_held_report() {
  local session_id="$1"
  cat "${READ_LOG_DIR}/${session_id}.held-report"
}

# 同じユーザー入力で報告を隠した記録があるかを返す。
is_prompt_held() {
  local session_id="$1" prompt_id="$2"
  [ "$(cat "${READ_LOG_DIR}/${session_id}.held" 2>/dev/null)" = "$prompt_id" ]
}

list_unread_rule_files() {
  local session_id="$1" prompt_id="$2"
  local log_file="${READ_LOG_DIR}/${session_id}.tsv"
  local required_file
  for required_file in "$principles_file" "$report_template_file"; do
    grep -qxF -- "${prompt_id}"$'\t'"${required_file}" "$log_file" 2>/dev/null || printf '%s\n' "$required_file"
  done
}

format_html_section() {
  local html="$1"
  [ -n "$html" ] || return 0
  printf '\n報告用の HTML (タグを除いた本文のテキスト):\n%s\n' "$html"
}

build_reviewer_prompt() {
  local message="$1" html="$2"
  cat <<EOF
あなたは、ユーザーへの報告を検査するレビュアーである。
最初に ${principles_file}・${documentation_file}・${testing_file}・${notation_table_file}・${report_template_file} を Read で全文読む。そのあと、下の報告について次の四つを検査する。

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

検査2: 報告全体 (判断事項以外を含む) と、報告用の HTML があればその本文に、${principles_file} の「## [base] ユーザーへの報告と質問」の節のうち、報告を簡潔に書くことに関わる条文へ違反している文があれば、concise_issues に書く。節の条文を上から一つずつ報告と HTML に当てはめて、見落としをなくす。
sentence に違反している文を一行分そのまま (要約や複数行の連結をせず) 引用し、basis_file に根拠のファイルの絶対パス、basis_quote に根拠の条文を一行分そのまま引用し、problem に何が違反かを書く。HTML の文は、本文のテキストの一行に収まる範囲で引用する。
根拠の条文を示せない指摘は書かない。違反がなければ concise_issues を空の配列にする。

検査3: 報告用の HTML の本文に、${documentation_file} の条文 (「## 適用範囲」の節で HTML に適用すると定めたもの。「## 語の選び方」の節の条文は検査4で扱う) へ違反している文があれば、document_issues に書く。条文を上から一つずつ HTML に当てはめて、見落としをなくす。書き方は検査2と同じにする。報告用の HTML が無いときは document_issues を空の配列にする。

検査4: 報告全体と、報告用の HTML があればその本文に、${documentation_file} の「## 語の選び方」の節の条文か、${notation_table_file} の表へ違反している文があれば、wording_issues に書く。条文と表の行を上から一つずつ当てはめて、見落としをなくす。表の「避ける表記」の括弧は、違反になる使い方を示す。表記そのものを話題にして挙げているだけの語 (例: 避ける表記の一覧) は違反にしない。書き方は検査2と同じにする。表を根拠にするときは、basis_quote に表の行を一行まるごと引用する。違反がなければ wording_issues を空の配列にする。

検査2から検査4では、報告用の HTML にあるテストの仕様のうち、${testing_file} の条文に従って書いた箇所を違反にしない。

報告:
${message}
$(format_html_section "$html")
EOF
}

build_re_review_prompt() {
  local message="$1" html="$2"
  cat <<EOF
あなたが前に検査した報告が直された。前の指摘が直ったかと、直した箇所に新しい違反がないかを検査し、前と同じ四つの検査の書き方で出力する。直っていない指摘は、もう一度書く。直していない箇所の判定は変えない。

直した報告:
${message}
$(format_html_section "$html")
EOF
}

# 同じユーザー入力の報告を前に検査したレビュアーの会話の ID を返す。前の検査が無ければ何も返さない。
read_reviewer_id() {
  local session_id="$1" prompt_id="$2"
  local id_file="${READ_LOG_DIR}/${session_id}.${prompt_id}.reviewer"
  [ ! -f "$id_file" ] || cat "$id_file"
}

# 同じユーザー入力の報告を検査したレビュアーの会話の ID を記録する。
record_reviewer_id() {
  local session_id="$1" prompt_id="$2" reviewer_id="$3"
  mkdir -p "$READ_LOG_DIR"
  printf '%s\n' "$reviewer_id" > "${READ_LOG_DIR}/${session_id}.${prompt_id}.reviewer"
}

# 子プロセスが親のフック・MCP・スキルを読み込むと遅く高価になるうえ再帰するため、設定の読み込みを切り、ツールを Read だけにする。
run_reviewer() {
  local prompt="$1" reviewer_id="$2"
  # 残るレビュアーの会話の記録先が検査のたびに増えないようにするため、毎回同じ作業ディレクトリで動かす。
  local work_dir="${READ_LOG_DIR}/reviewer-work"
  local resume_args=()
  [ -n "$reviewer_id" ] && resume_args=(--resume "$reviewer_id")
  mkdir -p "$work_dir" || return 1
  (
    cd "$work_dir" || exit 1
    claude -p "$prompt" \
      --model "$REVIEWER_MODEL" \
      --settings '{"disableAllHooks": true}' \
      --setting-sources "" \
      --strict-mcp-config \
      --disable-slash-commands \
      --tools Read \
      --add-dir "$repo_dir" \
      --output-format json \
      --json-schema "$REVIEW_SCHEMA" \
      ${resume_args[@]+"${resume_args[@]}"} < /dev/null
  )
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

# 簡潔さ (concise_issues)・文書の書き方 (document_issues)・語の選び方 (wording_issues) の指摘は同じ形のため、指摘の種類を引数で受けて同じ処理で出す。
collect_issue_reasons() {
  local review_json="$1" message="$2" issues_key="$3" label="$4" issue sentence quote basis_file problem
  while IFS= read -r issue; do
    sentence=$(printf '%s' "$issue" | jq -r '.sentence')
    quote=$(printf '%s' "$issue" | jq -r '.basis_quote')
    is_sentence_in_message "$sentence" "$message" || continue
    is_quote_in_rules "$quote" || continue
    basis_file=$(printf '%s' "$issue" | jq -r '.basis_file')
    problem=$(printf '%s' "$issue" | jq -r '.problem')
    printf '%s: 「%s」は、%s の「%s」に反する。%s\n\n' "$label" "$sentence" "$basis_file" "$quote" "$problem"
  done < <(printf '%s' "$review_json" | jq -c --arg key "$issues_key" '.[$key][]')
}

# 呼び出し側が違反と検査の失敗を見分けられるよう、違反の指摘は標準出力に出し、検査の失敗は標準エラー出力に出して 2 を返す。
review_message() {
  local message="$1" session_id="$2" prompt_id="$3" html="${4:-}"
  local reasons="" unread_files reviewer_output reviewer_status review_json responded_reviewer_id

  if has_decision_items "$message"; then
    unread_files=$(list_unread_rule_files "$session_id" "$prompt_id")
    if [ -n "$unread_files" ]; then
      reasons+="このターンで次のファイルを Read していない。Read してから、判断事項に出す内容をルールに照らして見直す。
${unread_files}

"
    fi
  fi

  local reviewer_id reviewer_prompt
  reviewer_id=$(read_reviewer_id "$session_id" "$prompt_id")
  if [ -n "$reviewer_id" ]; then
    reviewer_prompt=$(build_re_review_prompt "$message" "$html")
  else
    reviewer_prompt=$(build_reviewer_prompt "$message" "$html")
  fi

  reviewer_output=$(run_reviewer "$reviewer_prompt" "$reviewer_id" 2>&1)
  reviewer_status=$?
  review_json=$(printf '%s' "$reviewer_output" | jq -c '.structured_output' 2>/dev/null)
  responded_reviewer_id=$(printf '%s' "$reviewer_output" | jq -r '.session_id | strings' 2>/dev/null)

  if [ "$reviewer_status" -ne 0 ] || [ -z "$review_json" ] || [ "$review_json" = "null" ] || [ -z "$responded_reviewer_id" ]; then
    printf '報告の検査 (別プロセスの Claude) が失敗した。報告の依頼事項に、検査フック (report-review-common.sh) の修正を書く。失敗の出力: %s\n' \
      "$(printf '%s' "$reviewer_output" | head -c "$FAILURE_OUTPUT_LENGTH")" >&2
    return 2
  fi
  record_reviewer_id "$session_id" "$prompt_id" "$responded_reviewer_id"

  local decision_reasons concise_reasons document_reasons wording_reasons quotable_text
  quotable_text="${message}"$'\n'"${html}"
  decision_reasons=$(collect_decision_reasons "$review_json")
  concise_reasons=$(collect_issue_reasons "$review_json" "$quotable_text" concise_issues '簡潔さの指摘')
  document_reasons=$(collect_issue_reasons "$review_json" "$html" document_issues '報告用の HTML の書き方の指摘')
  wording_reasons=$(collect_issue_reasons "$review_json" "$quotable_text" wording_issues '語の選び方の指摘')
  [ -n "$decision_reasons" ] && reasons+="${decision_reasons}"$'\n\n'
  [ -n "$concise_reasons" ] && reasons+="${concise_reasons}"$'\n\n'
  [ -n "$document_reasons" ] && reasons+="${document_reasons}"$'\n\n'
  [ -n "$wording_reasons" ] && reasons+="${wording_reasons}"$'\n\n'
  [ -n "$reasons" ] && printf '%s' "$reasons"
  return 0
}
