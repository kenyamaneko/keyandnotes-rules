> NOTE: このファイルは原則として人間が運用する。例外的に許可があった場合のみClaude Codeが修正しても良い。

<!-- TODO: Python (ジョブ系・ops 系) 固有の方針を追加する。ジョブ系も ops 系も共通でこのレイヤを使う (品質基準は同じ)。当面はこのレイヤを enable しても base 以外の追加ルールは適用されない。 -->

## [lang/python] docs コメント

- 関数・メソッド・クラスには Google スタイルの docstring を書く。引数があれば `Args:` セクション、戻り値があれば `Returns:` セクションを必須とする

## [lang/python] テスト方針

- テストは pytest を用いる
- データ駆動は `@pytest.mark.parametrize` でケース化する

## [lang/python] 命名

- @property は動詞を付けず対象名 (名詞) にする
