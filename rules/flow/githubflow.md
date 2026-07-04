> NOTE: このファイルは原則として人間が運用する。例外的に許可があった場合のみClaude Codeが修正しても良い。

# Branching Strategy (GitHub Flow)

GitHub Flow を採用するリポ共通のブランチ戦略。ops / infra / k8s 系リポなど、環境別の永続ブランチを持たず main 一本で運用するリポで採用する。

## 概要

`main` を唯一の永続ブランチとし、短命の `feature/*` ブランチを切って PR で `main` へマージする運用。`develop` / `release` ブランチは持たない。

環境差分はブランチではなくコードで表現する (例: Terraform は `envs/{dev,stg,prod}/` のディレクトリ + `*.tfvars`、Kubernetes は kustomize の `overlays/{dev,stg,prod}/`)。stg → prod の昇格は「同じコードを順次 apply する」運用で行い、ブランチでは表現しない。

## ブランチ一覧

| ブランチ | 寿命 | 派生元 | マージ先 | 保護 |
|---|---|---|---|---|
| `main` | 永続 | — | — | 最大 |
| `feature/xxx` | 短命 | `main` | `main` | なし |

## ブランチ運用ルール

### main

- **唯一の永続ブランチ**。常にデプロイ可能な状態を保つ
- 直 push 禁止。PR 経由のマージのみ
- force push 禁止、履歴書き換え禁止
- タグは CI が自動で打つ。手動タグ付けは禁止

### feature/xxx

- すべての変更 (新機能・バグ修正・リファクタ・ドキュメント) はこのブランチで行う
- `main` から切って `main` にマージ
- 命名: `feature/{issue番号}-{概要}` (例: `feature/42-add-foo`)
- 短命に保つ (目安: 数時間〜数日)。長期化する場合は分割を検討する
- PR マージ時にブランチ削除

## 通常フロー

```
1. feature ブランチを切る
   └─ git fetch origin && git switch -c feature/{n}-{summary} origin/main

2. 実装・コミット
   └─ ローカルでテスト・ビルド・lint を通す

3. push → PR
   └─ feature/xxx → main (PR)
   └─ CI green + レビュー OK 後にマージ

4. main マージ後
   └─ CI が必要に応じてタグを打ち、対象環境へデプロイ
   └─ feature ブランチ削除
```

## 緊急修正 (hotfix)

GitHub Flow では hotfix は通常の feature と同じ扱いとし、専用のブランチ種別を設けない。

- `main` から `feature/{issue番号}-{概要}` を切る
- 修正 → PR → `main` マージ
- back-merge は不要 (`develop` が存在しないため)
- 急ぎの場合でも PR を経由する。直 push でのバイパスは禁止

## 環境への反映

`main` への merge を契機に、各環境への apply / デプロイを行う。具体的な順序や承認ゲートは各リポの CI/CD ドキュメント (`docs/CI_AND_RELEASE.md` 等) を参照。

典型的な反映パターン:

- **Terraform**: `main` merge 後、`envs/dev` → `envs/stg` → `envs/prod` の順で plan / apply
- **Kubernetes (Argo CD 等)**: `main` の overlay を各クラスタが pull
- **ops スクリプト**: `main` の HEAD をそのまま実行環境に配布

## バージョニング

Semantic Versioning (SemVer) を採用する。

- **MAJOR**: 破壊的変更 (環境互換を壊す変更、既存リソースの destroy/replace を強制する変更等)
- **MINOR**: 後方互換のある機能追加
- **PATCH**: バグ修正、ドキュメント修正、内部リファクタ

タグ運用が不要なリポ (Terraform state がソース・オブ・トゥルースなど) では SemVer を適用しないこともある。各リポの CI/CD ドキュメントを参照。

## ブランチ保護設定

GitHub Rulesets で以下を設定する。必須ステータスチェックの具体名は各リポの CI/CD ドキュメントを参照。

### main

- 直 push 禁止
- PR マージのみ許可 (linear history)
- force push 禁止、削除禁止
- 履歴書き換え禁止
- 必須ステータスチェック: CI の lint / test / plan が green
- required reviews: 1 (一人開発リポでは self-approve 可で速度優先)
