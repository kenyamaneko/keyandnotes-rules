# セットアップ

## フックの登録

次のコマンドで、このリポジトリのフックを `~/.claude/settings.json` に登録し、すべてのリポジトリの git のフックの置き場を、このリポジトリの git 用のフックに設定する。

```sh
make setup-hooks
```

## コミット前の監査の対象リポジトリ

以下のファイルをコピーして、監査対象のリポジトリを記載する。

```sh
cp scripts/commit-audit/config/audit-repos.template.yaml scripts/commit-audit/config/audit-repos.yaml
```
