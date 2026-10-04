#!/usr/bin/env python3
"""Write the ids the Swift tokenizer is held to: `parity/tokens.json`.

    uv run python tokens.py

Hugging Face's tokenizers library runs Android's `tokenizer.json` (`App/Models/ToxicityTokenizer.json`) over every
text below, and the file keeps each text with its ids, [CLS] and [SEP] included, cut to LENGTH tokens.
`SentencePieceTokenizerTests` in KnitAppCoreTests reads it on Linux. The texts are knit-next's goldens
(`SentencePieceTokenizerTest.kt`), then the corners of the normalizer and the pre-tokenizer: case, accents and
compatibility forms, scripts the vocabulary barely knows, emoji, whitespace of every kind, and a text past LENGTH.
"""

from __future__ import annotations

import json
import sys

from common import LENGTH, ROOT, encode, tokenizer

TOKENS = ROOT / "parity" / "tokens.json"

ANDROID = [
    "shut up moron",
    "Have a great day!",
    "You're an IDIOT!!!",
    "café CAFÉ naïve",
    "  weird    spacing here ",
    "thanks so much for the help",
    "kys",
    "people of that religion are subhuman",
    "I will find you and hurt you",
    "you are a complete idiot and everyone hates you",
    "g0 t0 h3ll",
    "MixEd CaSe WoRdS",
    "emoji test 🔥😡",
    "ﬁle ligature ＦＵＬＬ",
    "résumé",
    "normal sentence with numbers 1234 and symbols",
    "@user said #stuff",
    "die in a fire loser",
    "have a wonderful evening everyone",
    "",
]

CORNERS = [
    " ",
    "\t\n",
    "a",
    "``quoted'' and \"quoted\"",
    "it's ok, isn't it?",
    "ΣΟΦΟΣ σοφός",
    "İstanbul DIŞ ışık",
    "Straße STRASSE",
    "Ångström Øresund æsir",
    "ŉ ǅ ﬀ ﬃ ㎏ ½ ²",
    "x́̂y",
    "é vs é",
    "東京 タワー カタカナ",
    "한국어 텍스트",
    "مرحبا بالعالم",
    "привет мир",
    "👍🏽 👨‍👩‍👧 🇳🇿 ❤️",
    "zero​width and nbsp and em space",
    "line\r\nbreaks here\u0085too",
    "tabs\tand\vvertical\ffeeds",
    "https://example.com/a?b=c&d=e",
    "me@example.com 555-0123 #tag @name",
    "geo:-41.2865,174.7762 meet here",
    "sh1t $h!t shiiiit f u c k",
    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    "supercalifragilisticexpialidocious antidisestablishmentarianism",
    "\u0000nul\u0007bell",
    "हिन्दी नमस्ते a\u0903b x\u20dd",
    "\U0001d54f\U0001d550\U0001d551 math letters",
    "word " * 140,
]


def main() -> int:
    words = tokenizer()
    texts = ANDROID + CORNERS
    items = [{"text": text, "ids": encode(words, text)} for text in texts]
    TOKENS.parent.mkdir(exist_ok=True)
    TOKENS.write_text(json.dumps({"length": LENGTH, "items": items}, indent=2, ensure_ascii=False) + "\n")
    print(f"wrote {len(items)} texts to {TOKENS.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
