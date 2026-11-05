> NOTE: このファイルは原則として人間が運用する。例外的に許可があった場合のみClaude Codeが修正しても良い。

## [lang/dart] テスト方針

- 純 Dart パッケージは `package:test`、Flutter アプリとプラグインは `flutter_test` を用いる
- GUI テストの原則は testing.md「GUI (画面) のテスト」に従い、ウィジェットテストで実装する
  - 要素は `find.text` / `find.bySemanticsLabel` で探す。`Key` による検索は最終手段にする
  - 操作は `tester.tap` / `tester.enterText` など実際のユーザー操作として発火させる。コールバックを直接呼ばない
- データ駆動は、ケースのレコードのリストを `for` で回して `test` を生成する
- テストの命名は testing.md「テストの命名」を次のとおり割り当てる
  - `[区分:大機能(:中機能)]小機能` = 最も外側の `group` (例: `group('[本体:注文]送料計算')`)
  - ケースの名前 = `test` / `testWidgets` (例: `test('注文金額が3000円のとき、送料は無料になる')`)
  - 共通の前提・共通の操作・種別・正常異常 = 入れ子の `group`

## [lang/dart] docs コメント

- docs コメントは dartdoc (`///`) 形式で書き、最初の 1 文を要約にする
- 引数・戻り値は本文中の角括弧参照 (`[value]`) で書く。型から読み取れない情報 (単位・制約・null の意味・副作用など) がある場合にのみ書く

## [lang/dart] 命名

- クラス・列挙・型は UpperCamelCase、メソッド・変数・定数は lowerCamelCase、ファイルとディレクトリは snake_case にする
- getter は動詞を付けず対象名にする
- Flutter の慣用 (Widget 名・`build`・`State` など) はフレームワークの規約を優先する

## [lang/dart] 分岐

- 種別の分岐は列挙か `sealed class` で表し、`switch` で網羅する。`default` や `_` で想定外の値を無言に通さない
- 列挙型や `sealed class` で表せない値 (例: 外部から受け取った配送業者コードの文字列) が想定外なら、`adapter` と `presentation` で例外を投げる

## [lang/dart] 型と不変性

- ドメインの値は `final` フィールドの不変クラスで表し、更新は `copyWith` で新しい値を返す (system-design.md「不変性」の Dart での具体化)
- `dynamic` を使わない。JSON は `adapter` と `presentation` の中で型付きのクラスに変換し、それ以外のコードに `Map<String, dynamic>` を持ち込まない
- null 強制 (`!`) を使わない。null になり得ないことを型で表すか、null の場合を分岐で扱う

## [lang/dart] 静的解析と整形

- 純 Dart パッケージは `package:lints` の recommended、Flutter は `package:flutter_lints` を有効にし、警告を残さない
- `dart format` の既定に従う。`// ignore` は理由を添えて最小限にする

## [lang/dart] 依存の向き

- 業務ロジックは Flutter に依存しない純 Dart パッケージに置き、Flutter・Firebase・プラットフォーム API への依存はアプリ側のアダプタに閉じ込める (system-design.md「SOLID 原則」の依存性逆転の Dart での具体化)
