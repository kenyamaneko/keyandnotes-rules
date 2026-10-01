# keyandnotes-rules

各プロジェクトの CLAUDE.md が `@import` する共通開発ルール。このリポジトリ自身も同じルールに従う。

@rules/principles.md
@rules/flow/github-flow.md

## ルールを書き換えるとき

- 書き換える前に、対象のファイルを全部読む。言語・デプロイ方式のルール (rules/lang/・rules/deploy/) は読み込まれていないので、触るときに読む
- rules/ は Edit / Write で書き換える。sed などのシェルで書き換えない
  - なぜ: rules/ の書き換えはフックでユーザーの確認を通すが、シェルで書くとフックを通らないため
- ルールに書く例は EC (注文・送料・会員ランクなど) にそろえる
