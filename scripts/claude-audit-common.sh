#!/usr/bin/env bash
# commit 前の監査フック (pre-commit-claude-audit.sh・pre-commit-machine-audit.sh) から source される。
# 複数のフックが同じ判断をするため、commit 先の解決と、principles.md の @import 一覧の導出をここに置く。

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

# 指定したディレクトリが属するリポの名前を返す。worktree は本体のディレクトリ名になる。
kn_repo_name() {
  local common_dir
  common_dir=$(cd "$1" 2>/dev/null && git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  basename "$(dirname "$common_dir")"
}

# 全リポの設定で監査対象外と明示したリポなら 0 を返す。
kn_is_excluded_repo() {
  local repos_config="$1" repo_name="$2"
  [ "$(jq -r --arg name "$repo_name" '.repos[$name].excluded // false' "$repos_config" 2>/dev/null)" = "true" ]
}

# principles.md が @import する参照先を1行1件で返す。
kn_discover_base_refs() {
  local principles_path="$1"
  grep -oE '@[A-Za-z0-9_./-]+\.md' "$principles_path" | sed 's/^@//' | sort -u
}

# kn_discover_base_refs の結果から exclude_refs (呼び出し側が別途扱う参照) を除いた注入対象を返す。
# principles_path または参照先ファイルが存在しない場合は fail-closed で非ゼロ終了する。
kn_auto_inject_refs() {
  local base_rules_dir="$1" principles_path="$2"
  shift 2
  local exclude_refs=("$@")
  local ref path skip ex missing=0

  if [ ! -f "$principles_path" ]; then
    printf 'kn_auto_inject_refs: principles.md (%s) が見つかりません。\n' "$principles_path" >&2
    return 2
  fi

  while IFS= read -r ref; do
    [ -z "$ref" ] && continue
    skip=0
    for ex in "${exclude_refs[@]}"; do
      [ "$ex" = "$ref" ] && { skip=1; break; }
    done
    [ "$skip" -eq 1 ] && continue

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
