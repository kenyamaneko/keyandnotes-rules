> NOTE: このファイルは原則として人間が運用する。例外的に許可があった場合のみClaude Codeが修正しても良い。

## [lang/dart] テスト方針

- 純 Dart パッケージは `package:test`、Flutter アプリとプラグインは `flutter_test` を用いる
- GUI テストの原則は testing.md「GUI (画面) のテスト」に従い、ウィジェットテストで実装する
  - 要素は `find.text` / `find.bySemanticsLabel` で探す。`Key` による検索は最終手段にする
  - 操作は `tester.tap` / `tester.enterText` など実際のユーザー操作として発火させる。コールバックを直接呼ばない
- データ駆動は、ケースのレコードのリストを `for` で回して `test` を生成する。ケース名に具体値を埋め込む
- テストの命名は testing.md「テストの命名」を次のとおり割り当てる
  - `group` = テスト対象の要素を日本語で書く (例: `group('[送料] 送料計算')`)。必要なら Given で `group` を重ねる
  - `test` / `testWidgets` = 日本語の自由文で Then まで書く (例: `test('注文金額が 3000 円のとき、送料は無料になる')`)

## [lang/dart] docs コメント

- docs コメントは dartdoc (`///`) 形式で書き、最初の 1 文を要約にする
- 引数・戻り値は本文中の角括弧参照 (`[value]`) で書く。型から読み取れない情報 (単位・制約・null の意味・副作用など) がある場合にのみ書く

## [lang/dart] 命名

- クラス・列挙・型は UpperCamelCase、メソッド・変数・定数は lowerCamelCase、ファイルとディレクトリは snake_case にする
- getter は動詞を付けず対象名にする
- Flutter の慣用 (Widget 名・`build`・`State` など) はフレームワークの規約を優先する

## [lang/dart] 分岐

- 種別の分岐は列挙か `sealed class` で表し、`switch` で網羅する。`default` や `_` で想定外の値を無言に通さない
- 網羅できない値 (外部から受け取った文字列など) は受け取った境界で検証し、想定外なら例外を投げる

## [lang/dart] 型と不変性

- ドメインの値は `final` フィールドの不変クラスで表し、更新は `copyWith` で新しい値を返す
- `dynamic` を使わない。JSON の変換は境界 (リポジトリ・アダプタ) の中で型付きのクラスに変換し、内側に `Map<String, dynamic>` を持ち込まない
- null 強制 (`!`) を使わない。null になり得ないことを型で表すか、null の場合を分岐で扱う

## [lang/dart] 静的解析と整形

- 純 Dart パッケージは `package:lints` の recommended、Flutter は `package:flutter_lints` を有効にし、警告を残さない
- `dart format` の既定に従う。`// ignore` は理由を添えて最小限にする

## [lang/dart] 依存の向き

- 業務ロジックは Flutter に依存しない純 Dart パッケージに置き、Flutter・Firebase・プラットフォーム API への依存はアプリ側のアダプタに閉じ込める (coding.md「業務ロジックは外部の具体的な実装に直接依存しない」の Dart での具体化)
