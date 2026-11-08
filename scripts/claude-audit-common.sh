#!/usr/bin/env bash
# commit 前の監査フック (pre-commit-claude-audit.sh・pre-commit-machine-audit.sh) から source される。
# 複数のフックが同じ判断をするため、commit 先の解決と、principles.md の @import 一覧の導出をここに置く。

KN_SHARED_REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
readonly KN_SHARED_REPO_DIR
readonly REPOS_CONFIG_FILE="${KN_SHARED_REPO_DIR}/scripts/config/audit-repos.yaml"

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

# 指定したディレクトリが属するリポの本体のチェックアウト (worktree の場合は本体) のルートを返す。
kn_main_checkout_root() {
  local common_dir
  common_dir=$(cd "$1" 2>/dev/null && git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  dirname "$common_dir"
}

# 指定したディレクトリが属するリポの名前を返す。worktree は本体のディレクトリ名になる。
kn_repo_name() {
  basename "$(kn_main_checkout_root "$1")"
}

readonly KN_CONFIG_ERROR_MAX_LINES=5

# 全リポの設定 (YAML) を JSON にして返す。読めなかったときは、利用者に見せるエラーメッセージを標準出力に書いて 1 を返す。
kn_load_repos_config() {
  local out err_file err
  err_file=$(mktemp)
  # macOS 標準の ruby は YAML を標準ライブラリで読めるため、ruby で変換する。
  if ! out=$(ruby -ryaml -rjson -e 'puts JSON.generate(YAML.safe_load(File.read(ARGV[0])))' "$1" 2>"$err_file"); then
    err=$(head -n "$KN_CONFIG_ERROR_MAX_LINES" "$err_file")
    rm -f "$err_file"
    printf '全リポの設定 (%s) を YAML として読めない。YAML の構文を直すか、ruby が使えることを確認してください。ruby の出力: %s' "$1" "$err"
    return 1
  fi
  rm -f "$err_file"
  if ! printf '%s' "$out" | jq -e '.repos | type == "object"' >/dev/null 2>&1; then
    printf '全リポの設定 (%s) の repos が、リポ名ごとの設定を並べた形になっていない。repos の下にリポ名をキーとして設定を書いてください。' "$1"
    return 1
  fi
  printf '%s' "$out"
}

# 全リポの設定 (JSON) に書かれたリポ (監査対象) なら 0 を返す。リポの設定が空のときも、書かれていれば監査対象とする。
kn_is_audit_target() {
  local repos_config="$1" repo_name="$2"
  [ "$(printf '%s' "$repos_config" | jq -r --arg name "$repo_name" '.repos | has($name)')" = "true" ]
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
