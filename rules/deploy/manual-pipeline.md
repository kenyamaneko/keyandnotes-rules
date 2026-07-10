> NOTE: このファイルは原則として人間が運用する。例外的に許可があった場合のみClaude Codeが修正しても良い。

# Deployment Strategy (Manual Pipeline)

各環境への反映を、パイプラインの手動実行で行う戦略。

## 概要

自動デプロイを持たず、dev / stg / prod の各環境をパイプライン (CI の手動実行ジョブ) で人が順に反映する。反映の実行そのものが人の判断になる。

## 環境とトリガー

| 環境 | トリガー |
|---|---|
| dev / stg / prod | 各環境ともパイプラインを人が手動実行 (`workflow_dispatch` / apply ジョブ等) |

環境差分はコードで表現する (例: `envs/{dev,stg,prod}/` + `*.tfvars`)。反映は dev → stg → prod の順で行う。

## ゲート

各環境のパイプライン実行そのものがゲート。実行前に PR で lint / test / plan を green にしておく。

## 反映方式

手動パイプライン。人がジョブを起動し、対象環境へ apply / デプロイする。

## タグ・バージョニング

タグを使わないことがある (例: Terraform は state がソース・オブ・トゥルース)。使う場合は SemVer 形式 (`vX.Y.Z`)。

## 想定リポ / 選定の目安

- IaC (Terraform 等)。state が SSoT でタグ運用しないもの
- 本番反映を常に人の手動操作に固定したいもの (サーバレス関数 / ジョブの手動 dispatch デプロイ等)
