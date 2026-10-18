#!/usr/bin/env python3
"""Checks that every interface text in Sources (tr / trFormat, keyed by the English) is translated
in each Sources/KlavkoCore/Translations/*.swift table, with the same number of %@ placeholders.

    scripts/check-translations.py            # report; exit 1 if anything is missing
    scripts/check-translations.py --keys     # print the English texts as JSON (for translating)
"""
import json, pathlib, re, sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCES = ROOT / "Sources"
TABLES = SOURCES / "KlavkoCore" / "Translations"


def read_literal(s, i):
    """s[i] is the opening quote of a Swift string literal; returns (raw text, index after it)."""
    i += 1
    out = []
    while True:
        c = s[i]
        if c == "\\":
            if s[i + 1] == "(":
                depth, j = 1, i + 2
                while depth:
                    depth += {"(": 1, ")": -1}.get(s[j], 0)
                    j += 1
                out.append(s[i:j])
                i = j
                continue
            out.append(s[i:i + 2])
            i += 2
            continue
        if c == '"':
            return "".join(out), i + 1
        out.append(c)
        i += 1


def read_concatenation(s, i):
    """"a" + "b" ... starting at s[i] (whitespace allowed); returns (text or None, index after it)."""
    parts = []
    while True:
        while s[i].isspace():
            i += 1
        if s[i] != '"':
            return None, i
        text, i = read_literal(s, i)
        parts.append(text)
        j = i
        while s[j].isspace():
            j += 1
        if s[j] != "+":
            return "".join(parts), j
        i = j + 1


def unescape(text):
    return re.sub(r'\\(["\\])', r"\1", text)


def english_keys():
    keys = {}
    for path in sorted(SOURCES.rglob("*.swift")):
        if TABLES in path.parents or path.name == "Localization.swift":
            continue
        s = path.read_text()
        for m in re.finditer(r"(?<![\w.])tr(?:Format)?\(", s):
            ukrainian, i = read_concatenation(s, m.end())
            if ukrainian is None or s[i] != ",":
                continue
            english, i = read_concatenation(s, i + 1)
            if english is None:
                continue
            line = s.count("\n", 0, m.start()) + 1
            keys.setdefault(unescape(english), (unescape(ukrainian), f"{path.relative_to(ROOT)}:{line}"))
    return keys


def table(path):
    s = path.read_text()
    entries, i = {}, s.index("[", s.index("=")) + 1
    while True:
        key, i = read_concatenation(s, i)
        if key is None:
            return entries
        value, i = read_concatenation(s, s.index(":", i) + 1)
        entries[unescape(key)] = unescape(value)
        i = s.index(",", i) + 1


def main():
    keys = english_keys()
    if "--keys" in sys.argv:
        json.dump([{"en": k, "uk": uk, "at": at} for k, (uk, at) in keys.items()], sys.stdout,
                  ensure_ascii=False, indent=1)
        return 0
    problems = 0
    for path in sorted(TABLES.glob("*.swift")):
        entries = table(path)
        missing = [k for k in keys if k not in entries]
        unused = [k for k in entries if k not in keys]
        placeholders = [k for k in keys if k in entries and k.count("%@") != entries[k].count("%@")
                        and len(re.findall(r"%\d\$@", entries[k])) != k.count("%@")]
        for title, items in (("missing", missing), ("placeholders differ", placeholders), ("unused", unused)):
            for k in items:
                print(f"{path.name}: {title}: {k!r}")
        problems += len(missing) + len(placeholders)
        print(f"{path.name}: {len(entries) - len(unused)}/{len(keys)}")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
