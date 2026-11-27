#!/usr/bin/env bash
# commit 前の監査フック (pre-commit-claude-audit.sh・pre-commit-machine-audit.sh) から source される。
# 複数のフックが同じ判断をするため、コミット先の解決・principles.md の @import 一覧の導出・ステージ内容の読み取り・監査を通した記録の読み書き (git の pre-commit フックも使う) をここに置く。

KN_SHARED_REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
readonly KN_SHARED_REPO_DIR
readonly REPOS_CONFIG_FILE="${KN_SHARED_REPO_DIR}/scripts/commit-audit/config/audit-repos.yaml"

# git と副コマンドの間に置ける -C <dir>・-c <key=value> (引数は quote を消した後に空になりうる)。
readonly KN_GIT_GLOBAL_OPTS='([[:space:]]+-[Cc]([[:space:]]+[^[:space:]]+)?)*'

# 文字列リテラルや HEREDOC 内の偶発マッチを避けるため、コマンドのうち実行される部分だけを返す。
kn_extract_exec_cmd() {
  printf '%s' "$1" | sed -E '/<</q' | sed -E 's/"[^"]*"//g; s/'\''[^'\'']*'\''//g'
}

# 実行される部分が git commit なら 0 を返す。git commit --help・-h は commit しないため含めない。
kn_is_commit_command() {
  printf '%s' "$1" | grep -qE "(^|[[:space:]&|;\`(])git${KN_GIT_GLOBAL_OPTS}[[:space:]]+commit([[:space:]]|\$)" || return 1
  ! printf '%s' "$1" | grep -qE "git${KN_GIT_GLOBAL_OPTS}[[:space:]]+commit[[:space:]]+(--help|-h)([[:space:]]|\$)"
}

# 実行される部分に、index を書き換える git の操作が commit と同居していれば、その説明を返して 0 を返す。
kn_find_staging_with_commit() {
  local exec_cmd="$1" git_cmd="(^|[[:space:]&|;\`(])git${KN_GIT_GLOBAL_OPTS}[[:space:]]+"
  if printf '%s' "$exec_cmd" | grep -qE "${git_cmd}(add|rm|mv)([[:space:]]|\$)"; then
    printf 'git add/rm/mv と git commit が同一 Bash 呼び出しに含まれています。別の Bash 呼び出しに分けてから commit してください。'
  elif printf '%s' "$exec_cmd" | grep -qE "${git_cmd}checkout[[:space:]].*[[:space:]]--[[:space:]]"; then
    printf 'git checkout <ref> -- <path> は index を書き換えます。別の Bash 呼び出しに分けてから commit してください。'
  elif printf '%s' "$exec_cmd" | grep -qE "${git_cmd}restore[[:space:]].*--staged"; then
    printf 'git restore --staged は index を書き換えます。別の Bash 呼び出しに分けてから commit してください。'
  elif printf '%s' "$exec_cmd" | grep -qE "git${KN_GIT_GLOBAL_OPTS}[[:space:]]+commit[[:space:]]+([^;&|]*[[:space:]])?(--all|--include|--patch|-[A-Za-z]*[aip][A-Za-z]*)([[:space:]=]|\$)"; then
    printf 'git commit の -a/--all/-i/--include/-p/--patch は commit 自体がステージ操作を兼ねます。git add で明示的にステージしてから commit してください。'
  else
    return 1
  fi
}

# commit の書き方 (git -C / cd / 素の commit) によらず、commit 先のディレクトリを求める。
kn_resolve_commit_dir() {
  local cmd="$1" input="$2" dir before_commit
  dir=$(printf '%s' "$cmd" | grep -oE 'git[[:space:]]+-C[[:space:]]+"?[^"&|;[:space:]]+' | head -1 | sed -E 's|^git[[:space:]]+-C[[:space:]]+"?||')
  if [ -z "$dir" ]; then
    before_commit=$(printf '%s' "$cmd" | sed -E 's/git[[:space:]]+commit.*//')
    dir=$(printf '%s' "$before_commit" | grep -oE '(^|[&|;[:space:]])cd[[:space:]]+"?[^"&|;[:space:]]+' | tail -1 | sed -E 's|.*cd[[:space:]]+"?||')
  fi
  [ -z "$dir" ] && dir=$(printf '%s' "$input" | jq -r '.cwd // ""' 2>/dev/null)
  [ -z "$dir" ] && dir=$(pwd)
  printf '%s' "$dir"
}

# 指定したディレクトリが属するリポジトリの本体のチェックアウト (worktree の場合は本体) のルートを返す。
kn_main_checkout_root() {
  local common_dir
  common_dir=$(cd "$1" 2>/dev/null && git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  dirname "$common_dir"
}

# 指定したディレクトリが属するリポジトリの名前を返す。worktree は本体のディレクトリ名になる。
kn_repo_name() {
  basename "$(kn_main_checkout_root "$1")"
}

readonly KN_CONFIG_ERROR_MAX_LINES=5

# 全リポジトリの設定 (YAML) を JSON にして返す。読めなかったときは、利用者に見せるエラーメッセージを標準出力に書いて 1 を返す。
kn_load_repos_config() {
  local out err_file err
  err_file=$(mktemp)
  # macOS 標準の ruby は YAML を標準ライブラリで読めるため、ruby で変換する。
  if ! out=$(ruby -ryaml -rjson -e 'puts JSON.generate(YAML.safe_load(File.read(ARGV[0])))' "$1" 2>"$err_file"); then
    err=$(head -n "$KN_CONFIG_ERROR_MAX_LINES" "$err_file")
    rm -f "$err_file"
    printf '全リポジトリの設定 (%s) を YAML として読めない。YAML の構文を直すか、ruby が使えることを確認してください。ruby の出力: %s' "$1" "$err"
    return 1
  fi
  rm -f "$err_file"
  if ! printf '%s' "$out" | jq -e '.repos | type == "object"' >/dev/null 2>&1; then
    printf '全リポジトリの設定 (%s) の repos が、リポジトリ名ごとの設定を並べた形になっていない。repos の下にリポジトリ名をキーとして設定を書いてください。' "$1"
    return 1
  fi
  printf '%s' "$out"
}

# 全リポジトリの設定 (JSON) に書かれたリポジトリ (監査対象) なら 0 を返す。リポジトリの設定が空のときも、書かれていれば監査対象とする。
kn_is_audit_target() {
  local repos_config="$1" repo_name="$2"
  [ "$(printf '%s' "$repos_config" | jq -r --arg name "$repo_name" '.repos | has($name)')" = "true" ]
}

readonly KN_AUDITED_CHANGE_TYPES=ACMR
readonly KN_ADDED_CHANGE_TYPE=A

# ステージされたファイルのうち、指定した種類の変更があるものの名前を、1 行に 1 つ返す。引数は、変更の種類を表す git の文字と、対象を絞るパスの指定。
kn_list_staged_files() {
  local change_types="$1"
  shift
  # 日本語のファイル名が引用符で囲んだ表記になると中身の差分を取れないため、-z で受ける。
  git diff --cached -M --name-only -z --diff-filter="$change_types" -- "$@" | tr '\0' '\n'
}

# 指定したファイルのステージ内容の差分を返す。引数は、変更の前後に含める行数と、1 つ以上のファイル名。
kn_diff_staged_files() {
  local context_lines="$1" old_name new_name file
  shift
  local paths=("$@")
  # 名前を変えたファイルは、前の名前も指定しないと全体が追加した行になるため、前の名前を加える。
  while IFS= read -r -d '' _ && IFS= read -r -d '' old_name && IFS= read -r -d '' new_name; do
    for file in "$@"; do
      [ "$file" = "$new_name" ] && paths+=("$old_name")
    done
  done < <(git diff --cached -M --name-status -z --diff-filter=R)
  git diff --cached -M -U"$context_lines" --diff-filter="$KN_AUDITED_CHANGE_TYPES" -- "${paths[@]}"
}

# 今ステージされている内容のツリーを作り、その ID を返す。コミット先のリポジトリの中で呼ぶ。
kn_write_staged_tree() (
  index_path=$(git rev-parse --path-format=absolute --git-path index) || exit 1
  copy_dir=$(mktemp -d) || exit 1
  trap 'rm -rf "$copy_dir"' EXIT
  # インデックスのファイルが無いリポジトリでも空のツリーを作れるようにするため、ファイルがあるときだけ複製する。
  if [ -e "$index_path" ]; then
    cp "$index_path" "${copy_dir}/index" || exit 1
  fi
  # 同時に動く監査がインデックスのロックを取り合わないようにするため、インデックスの複製からツリーを作る。
  GIT_INDEX_FILE="${copy_dir}/index" git write-tree
)

readonly KN_AUDIT_RECORD_DIR_NAME="kn-commit-audit"

# 監査の確認ダイアログで許可を待つ間に記録が古くならないため、記録を有効とみなす時間 (分) を長めにする。
readonly KN_AUDIT_RECORD_TTL_MINUTES=30

readonly KN_AUDIT_NAMES=(machine claude)

readonly KN_AUDIT_RECORDS_MISSING=1
readonly KN_AUDIT_RECORDS_UNREADABLE=2

kn_build_audit_record_path() {
  local audit_name="$1" tree="$2" git_common_dir
  git_common_dir=$(git rev-parse --path-format=absolute --git-common-dir) || return 1
  printf '%s/%s/%s-%s' "$git_common_dir" "$KN_AUDIT_RECORD_DIR_NAME" "$audit_name" "$tree"
}

# 今ステージされている内容を、監査がコミットを通したと記録する。コミット先のリポジトリの中で呼ぶ。
kn_record_audit_pass() {
  local audit_name="$1" tree record_path
  tree=$(kn_write_staged_tree) || return 1
  record_path=$(kn_build_audit_record_path "$audit_name" "$tree") || return 1
  mkdir -p "$(dirname "$record_path")" || return 1
  # コミットされなかった記録が溜まり続けるのを防ぐため、有効期限を過ぎた記録を消す。
  find "$(dirname "$record_path")" -type f -mmin "+${KN_AUDIT_RECORD_TTL_MINUTES}" -delete || return 1
  : > "$record_path"
}

# 今ステージされている内容について、すべての監査の記録が有効なら、記録を消費して 0 を返す。1 つでも欠けていれば、何も消費せず KN_AUDIT_RECORDS_MISSING を返す。git の操作に失敗したときは KN_AUDIT_RECORDS_UNREADABLE を返す。コミット先のリポジトリの中で呼ぶ。
kn_consume_audit_records() {
  local tree audit_name record_path
  local record_paths=()
  tree=$(kn_write_staged_tree) || return "$KN_AUDIT_RECORDS_UNREADABLE"
  for audit_name in "${KN_AUDIT_NAMES[@]}"; do
    record_path=$(kn_build_audit_record_path "$audit_name" "$tree") || return "$KN_AUDIT_RECORDS_UNREADABLE"
    [ -n "$(find "$record_path" -mmin "-${KN_AUDIT_RECORD_TTL_MINUTES}" 2>/dev/null)" ] || return "$KN_AUDIT_RECORDS_MISSING"
    record_paths+=("$record_path")
  done
  rm -f "${record_paths[@]}"
}

# principles.md が @import する参照先を1行1件で返す。
kn_discover_base_refs() {
  local principles_path="$1"
  grep -oE '@[A-Za-z0-9_./-]+\.md' "$principles_path" | sed 's/^@//' | sort -u
}

# kn_discover_base_refs の結果を注入対象として返す。
# principles_path または参照先ファイルが存在しない場合は fail-closed で非ゼロ終了する。
kn_auto_inject_refs() {
  local base_rules_dir="$1" principles_path="$2"
  local ref path missing=0

  if [ ! -f "$principles_path" ]; then
    printf 'kn_auto_inject_refs: principles.md (%s) が見つかりません。\n' "$principles_path" >&2
    return 2
  fi

  while IFS= read -r ref; do
    [ -z "$ref" ] && continue

    path="${base_rules_dir}/${ref}"
    if [ ! -f "$path" ]; then
      printf 'kn_auto_inject_refs: principles.md が参照する %s が %s に見つかりません。\n' "$ref" "$path" >&2
      missing=1
      continue
    fi
    printf '%s\n' "$ref"
  done < <(kn_discover_base_refs "$principles_path")

  [ "$missing" -eq 1 ] && return 2
  return 0
}
