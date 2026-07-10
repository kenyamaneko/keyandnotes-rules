> NOTE: このファイルは原則として人間が運用する。例外的に許可があった場合のみClaude Codeが修正しても良い。

# Deployment Strategy (GitOps Sync)

dev / stg / prod の3環境を持ち、GitOps エージェント (ArgoCD 等) の sync で反映する戦略。

## 概要

CI は成果物 (コンテナイメージ) をレジストリへ push するだけで、環境への反映は GitOps エージェントがマニフェストを追跡して sync することで行う (pull 型)。環境差分は Kustomize overlay で表現する。dev と stg は自動 sync、prod は手動 sync とする。

## 環境とトリガー

| 環境 | トリガー |
|---|---|
| dev | `main` へのマージ → 自動 sync (タグ不要) |
| stg | タグ (`vX.Y.Z`) push → 自動 sync |
| prod | 同一タグを手動で sync (承認) |

## ゲート

prod の手動 sync が手動ゲート。stg で検証したうえで、人が prod の Application を sync して反映する。

## 反映方式

pull 型 GitOps。CI は image を push するのみ。GitOps エージェントが overlay の変更を追跡し、対象環境へ sync する。stg / prod へは dev で検証した成果物を再ビルドせず、同一成果物 (同一 digest) を昇格させる。

あるタグがどの環境まで到達しているかは、各環境の Application が現在 sync している revision で確認する。

## タグ・バージョニング

SemVer 形式のタグ (`vX.Y.Z`) を人が手動で打つ。

## ロールアウト

ローリング更新。詳細はデプロイ先のサービスに従う。

## 想定リポ / 選定の目安

- GitOps エージェント (ArgoCD 等) と overlay で環境を管理するサービス
- 2環境で足りるなら `merge-dev-tag-prod.md` を検討する
