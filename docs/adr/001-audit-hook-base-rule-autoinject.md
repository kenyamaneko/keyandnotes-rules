# ADR-001: commit-audit hook が注入する base ルール一覧を principles.md から動的導出する

## ステータス

Accepted

## 結論

各リポの pre-commit SOFT audit hook が auditor に注入する base ルール (`principles.md` が `@import` するファイル) の一覧は、hook 側で手書きリストとして持つことをやめ、`principles.md` から動的に導出する。

本リポに `scripts/claude-audit-common.sh` を追加し、`kn_discover_base_refs` (`principles.md` の `@import` 参照を抽出) と `kn_auto_inject_refs` (診断除外込みで自動注入対象を返す。参照先ファイルが実在しない場合や `principles.md` 自体が見つからない場合は fail-closed) を提供する。各リポの hook はこれを `source` して使う。

不変条件: `principles.md` が `@import` する全ファイルは、監査対象リポの hook で注入されるか、さもなくば commit を fail-close する。

## 背景・課題

`principles.md` は `@coding.md` / `@testing.md` / `@documentation.md` / `@cicd.md` を `@import` で参照するが、各リポの hook はこの一覧を独立した手書きリストとして個別に持っていた。`principles.md` 側でルールを追加・変更しても、この手書きリストは追従しない二重管理になっていた。

pokelingual (Issue #186) と overload-party-common (Issue #223) で、実際に `coding.md` / `documentation.md` / `cicd.md` が auditor に一度も注入されないまま運用され、pokelingual では coding.md 違反が audit をすり抜けて commit された実例がある。urahack は overlay の配線漏れを検出する RULESET の仕組みを持っていたが、これは overlay のみが対象で、overlay を持たない base ファイルの欠落は検出できなかった。

「手書きリストが principles.md の内容を正しく反映しているか」をチェックする仕組みでは、チェック漏れの再発を防げない。手書きリストそのものを廃止し、`principles.md` を唯一の SSoT として動的導出する方が二重管理を構造的に排除できる。

## 不採用案

- **手書きリストの内容が `principles.md` と一致しているかを検証する CI チェックを追加する**：手書きリストという二重管理そのものは残り、`principles.md` 側の更新のたびに検証と手書きリスト更新の両方が要る。二重管理の解消にならない。
