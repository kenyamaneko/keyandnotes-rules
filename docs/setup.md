# セットアップ

## フックの登録

次のコマンドで、このリポのフックを `~/.claude/settings.json` に登録する。

```sh
make setup-hooks
```

## コミット前の監査の対象リポ

以下のファイルをコピーして、監査対象のリポジトリを記載する。

```sh
cp scripts/commit-audit/config/audit-repos.template.yaml scripts/commit-audit/config/audit-repos.yaml
```
