> NOTE: このファイルは原則として人間が運用する。例外的に許可があった場合のみClaude Codeが修正しても良い。

## [lang/iac] Terraform 方針

- `variable` ブロックで `default` を使わない。環境ごとの値は呼び出し側 (`environments/<env>/` 等) で必ず明示指定する
  - 理由: `default` があるとフォールバックで意図しない値が無言のまま適用される。必須指定を強制することで「どの環境が何を渡しているか」を常に明示する
- `output` は必要なもの以外作らない
  - 理由: 使われない output を増やすと、本当に参照されている値が埋もれて把握しにくくなり、削除コストも膨らむ
- Terraform から Secret Manager のバージョン値を投入しない (state に平文で機密情報が残るため)

## [lang/iac] Secret / 認証情報

- 認証情報 (password / token / API key 等) は Secret Manager から実行時取得する
- k8s Secret を介した env への直接注入は新規採用しない
