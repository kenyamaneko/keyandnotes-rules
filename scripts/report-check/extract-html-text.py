#!/usr/bin/env python3
"""HTML のファイルから、画面に表示される本文のテキストを標準出力に出す。

使い方: extract-html-text.py <HTML のファイル>
段落・見出し・箇条書きの項目など、ブロックの区切りで改行する。太字などの行の中のタグは取り除き、前後の文字をつなげる。
"""

import sys
from html.parser import HTMLParser

SKIPPED_TAGS = {"style", "script", "head"}
BLOCK_TAGS = {
    "address", "article", "aside", "blockquote", "br", "dd", "details", "div", "dl", "dt",
    "fieldset", "figcaption", "figure", "footer", "form", "h1", "h2", "h3", "h4", "h5", "h6",
    "header", "hr", "li", "main", "nav", "ol", "p", "pre", "section", "summary", "table",
    "tbody", "td", "tfoot", "th", "thead", "tr", "ul",
}


class BodyTextExtractor(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.lines: list[str] = [""]
        self.skipped_depth = 0

    def handle_starttag(self, tag: str, attrs: list) -> None:
        if tag in SKIPPED_TAGS:
            self.skipped_depth += 1
        if tag in BLOCK_TAGS:
            self.lines.append("")

    def handle_endtag(self, tag: str) -> None:
        if tag in SKIPPED_TAGS and self.skipped_depth > 0:
            self.skipped_depth -= 1
        if tag in BLOCK_TAGS:
            self.lines.append("")

    def handle_data(self, data: str) -> None:
        if self.skipped_depth == 0:
            self.lines[-1] += data


def extract_body_text(html: str) -> str:
    extractor = BodyTextExtractor()
    extractor.feed(html)
    extractor.close()
    lines = (" ".join(line.split()) for line in extractor.lines)
    return "\n".join(line for line in lines if line)


def main() -> int:
    if len(sys.argv) != 2:
        print("使い方: extract-html-text.py <HTML のファイル>", file=sys.stderr)
        return 2
    with open(sys.argv[1], encoding="utf-8") as html_file:
        print(extract_body_text(html_file.read()))
    return 0


if __name__ == "__main__":
    sys.exit(main())
