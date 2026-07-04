> NOTE: このファイルは原則として人間が運用する。例外的に許可があった場合のみClaude Codeが修正しても良い。

# Branching Strategy (Git flow)

Git flow を採用するリポ共通のブランチ戦略。

## 概要

GitFlow をベースに、環境とブランチを対応付けた運用を採用する。本番品質を担保するため、stg 環境での実機検証を挟む昇格モデルを必須とする。

## ブランチ一覧

| ブランチ | 環境 | 寿命 | 派生元 | マージ先 | 保護 |
|---|---|---|---|---|---|
| `main` | prod | 永続 | — | — | 最大 |
| `release/vX.Y.Z` | stg | 短命 | `develop` | `main` | あり |
| `develop` | dev | 永続 | `main` (初回のみ) | — | あり |
| `feature/xxx` | なし | 短命 | `develop` | `develop` | なし |
| `hotfix/xxx` | なし | 短命 | `main` | `main` + `develop` (+ `release` if exists) | なし |

## ブランチ運用ルール

### main

- **prod 環境のソース・オブ・トゥルース**。main の HEAD = prod で動作しているコード
- 直 push 禁止。PR 経由のマージのみ
- マージ元として許可するのは `release/*` と `hotfix/*` のみ
- `develop` や `feature/*` を直接 main にマージしない
- タグは CI が自動で打つ。手動タグ付けは禁止
- force push 禁止、履歴書き換え禁止

### develop

- **dev 環境のソース**。次リリースに向けた統合ブランチ
- 直 push 禁止。PR 経由のマージのみ
- マージ元として許可するのは `feature/*` と `hotfix/*` の back-merge
- CI green 必須。レビューは self-approve 可(速度優先)

### release/vX.Y.Z

- **stg 環境のソース**。リリース候補の検証ブランチ
- 短命。main にマージ後、削除する
- ブランチ名に候補バージョンを含める(例: `release/v1.2.0`)
- `develop` から切る。切った時点で feature の取り込みは停止する
- release 中に feature を追加で取り込みたい場合は、原則として次の release に回す
- バグ修正やリリース準備(CHANGELOG 更新等)のコミットは PR 経由で release に入れる
- release に入れた修正は、main マージ後に develop にも back-merge する(後述)

### feature/xxx

- 新機能・改善の作業ブランチ
- `develop` から切って `develop` にマージ
- 命名: `feature/{issue番号}-{概要}` (例: `feature/42-add-foo`)
- PR マージ時にブランチ削除

### hotfix/xxx

- **prod 緊急修正**の作業ブランチ
- `main` から切る(develop からではない — develop には未リリース変更が混ざっているため)
- main と develop の両方にマージする(back-merge 必須)
- release ブランチが存在する場合は、release にもマージする
- 命名例: `hotfix/fix-webhook-signature`, `hotfix/critical-payment-bug`

## リリースフロー

### 通常リリース

```
1. develop で feature を統合・dev 環境で検証
   └─ feature/xxx → develop (PR)

2. release ブランチを切る
   └─ git switch -c release/v1.2.0 develop
   └─ push → stg 環境に自動デプロイ

3. stg 環境で検証
   └─ 実機検証、外部システムとの疎通確認など
   └─ バグ発見時は PR 経由で release ブランチに修正を入れる

4. main にマージ
   └─ release/v1.2.0 → main (PR)
   └─ CI が自動でタグ v1.2.0 を打つ
   └─ main が prod 環境に自動デプロイ

5. develop に back-merge
   └─ release/v1.2.0 → develop (PR)
   └─ release 中に入れた修正を develop に戻す

6. release ブランチ削除
```

### hotfix リリース

```
1. hotfix ブランチを切る
   └─ git switch -c hotfix/fix-webhook-500 main

2. 修正 → PR → main にマージ
   └─ hotfix/xxx → main (PR)
   └─ CI が自動でタグ v1.2.1 を打つ(patch bump)
   └─ prod 環境に自動デプロイ

3. develop に back-merge(必須)
   └─ hotfix/xxx → develop (PR)

4. release ブランチが存在する場合は release にも back-merge
   └─ hotfix/xxx → release/vX.Y.Z (PR)

5. hotfix ブランチ削除
```

### hotfix の back-merge 忘れ対策

hotfix を main にマージしたが develop に戻し忘れると、次のリリースでバグが再発する。

対策:

- PR テンプレートに back-merge チェックリストを入れる
- main に hotfix が入ったら、CI で develop への back-merge PR を自動生成する workflow を用意する(各リポの実装状況による)

## バージョニング

Semantic Versioning (SemVer) を採用する。

- **MAJOR**: 破壊的変更(REST API スキーマ破壊、DB マイグレーション等、既存クライアントが動かなくなる変更)
- **MINOR**: 後方互換のある機能追加
- **PATCH**: バグ修正、ドキュメント修正、内部リファクタ

具体的なタグ自動生成ワークフローおよびサブパッケージのバージョニングは、各リポの CI/CD ドキュメントを参照。

## ブランチ保護設定

GitHub Rulesets で以下を設定する。必須ステータスチェックの具体名は各リポの CI/CD ドキュメントを参照。

### main

- 直 push 禁止
- PR マージのみ許可(linear history)
- force push 禁止、削除禁止
- 履歴書き換え禁止
- 必須ステータスチェック: CI の lint / test / マージ元ブランチ制限が green
- required reviews: 1(self-approve 不可)
- マージ元ブランチ制限: `release/*` と `hotfix/*` のみ

### release/*

- 直 push 禁止。PR 経由のマージのみ
- force push 禁止、削除は手動で可
- 必須ステータスチェック: CI の lint / test が green

### develop

- 直 push 禁止
- PR マージのみ許可
- 必須ステータスチェック: CI の lint / test が green
- required reviews: 不要(一人開発での速度優先)
