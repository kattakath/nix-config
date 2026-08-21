#!/usr/bin/env python3
"""Deterministic linter for llms.txt files (llmstxt.org spec, v2).

Zero third-party dependencies — stdlib only, so it runs anywhere `python3`
does and needs no package manager, lockfile, or network at check time.

The spec (https://llmstxt.org/index.md) defines this exact document order:

    optional BOM
    # H1 project/site name            <- the ONLY required element
    > blockquote summary              <- conventional, strongly recommended
    ...markdown of any type EXCEPT headings...
    ## Section name                   <- zero or more "file list" sections
    - [name](url): optional notes

ERRORS are spec violations. WARNINGS are the spec's own authoring guidance and
the widely-followed conventions around it. `--strict` promotes warnings to
errors (same flag semantics as `claude plugin validate --strict`).

Usage:
    llms_txt_lint.py [--strict] [--quiet] [--max-bytes N] FILE...

Exit codes: 0 clean, 1 findings, 2 usage error.
"""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass
from urllib.parse import urlsplit

# Advisory ceiling: the spec's whole point is that the file "stays small enough
# to fit in context" — detail lives behind the links, not inline.
DEFAULT_MAX_BYTES = 20_000

HEADING_RE = re.compile(r"^(#{1,6})\s+(.*?)\s*$")
FENCE_RE = re.compile(r"^\s*(```|~~~)")
LIST_ITEM_RE = re.compile(r"^\s*[-*+]\s+(.*)$")
LINK_ITEM_RE = re.compile(r"^\[([^\]]*)\]\(\s*([^)\s]+)[^)]*\)\s*(?::\s*(?P<notes>.*))?$")
# Extensions an agent can consume directly. Anything else is probably an HTML
# page, which the spec says links SHOULD avoid in favour of the .md version.
LLM_FRIENDLY_SUFFIXES = (".md", ".markdown", ".txt", ".rst", ".json", ".yaml", ".yml", ".csv")


@dataclass(frozen=True)
class Finding:
    line: int
    level: str  # "error" | "warning"
    code: str
    message: str


class Linter:
    def __init__(self, path: str, text: str, max_bytes: int) -> None:
        self.path = path
        self.text = text
        self.max_bytes = max_bytes
        self.findings: list[Finding] = []

    # -- reporting ---------------------------------------------------------
    def error(self, line: int, code: str, message: str) -> None:
        self.findings.append(Finding(line, "error", code, message))

    def warn(self, line: int, code: str, message: str) -> None:
        self.findings.append(Finding(line, "warning", code, message))

    # -- lexing ------------------------------------------------------------
    def _headings(self, lines: list[str]) -> list[tuple[int, int, str]]:
        """(line_no, level, title) for every ATX heading outside a code fence."""
        out: list[tuple[int, int, str]] = []
        in_fence = False
        for i, raw in enumerate(lines, start=1):
            if FENCE_RE.match(raw):
                in_fence = not in_fence
                continue
            if in_fence:
                continue
            m = HEADING_RE.match(raw)
            if m:
                out.append((i, len(m.group(1)), m.group(2)))
        return out

    # -- the pass ----------------------------------------------------------
    def run(self) -> list[Finding]:
        lines = self.text.splitlines()
        headings = self._headings(lines)

        if not self.text.strip():
            self.error(1, "E005", "file is empty")
            return self.findings

        size = len(self.text.encode("utf-8"))
        if size > self.max_bytes:
            self.warn(
                1,
                "W011",
                f"file is {size} bytes (> {self.max_bytes}); llms.txt is an index — "
                "move detail behind links, or into a companion llms-full.txt",
            )

        # 1. H1 — the only required element, and it must come first.
        first_content = next(((i, ln) for i, ln in enumerate(lines, 1) if ln.strip()), None)
        if first_content is None:
            self.error(1, "E005", "file is empty")
            return self.findings
        first_no, first_line = first_content
        h1s = [h for h in headings if h[1] == 1]
        if not h1s:
            self.error(first_no, "E001", "no H1: an llms.txt must start with '# <project or site name>'")
        else:
            if h1s[0][0] != first_no or not HEADING_RE.match(first_line):
                self.error(
                    first_no,
                    "E001",
                    "the H1 must be the first content in the file (only a BOM may precede it)",
                )
            if not h1s[0][2].strip():
                self.error(h1s[0][0], "E001", "the H1 has no title text")
            for extra in h1s[1:]:
                self.error(extra[0], "E002", "second H1: exactly one H1 (the project name) is allowed")

        h2s = [h for h in headings if h[1] == 2]
        for line_no, level, title in headings:
            if level >= 3:
                self.warn(
                    line_no,
                    "W003",
                    f"H{level} '{title}': the spec defines only an H1 title and H2 section headers",
                )

        # 2. Blockquote summary, between the H1 and the first other block.
        body_start = (h1s[0][0] if h1s else first_no) + 1
        self._check_blockquote(lines, body_start)

        # 3. Detail region (H1..first H2) may hold any markdown EXCEPT headings.
        first_h2_line = h2s[0][0] if h2s else len(lines) + 1
        for line_no, level, title in headings:
            if level != 1 and body_start <= line_no < first_h2_line:
                self.error(
                    line_no,
                    "E003",
                    f"heading '{title}' before the first H2: the detail region between the H1 "
                    "and the first section must contain no headings",
                )

        # 4. The H2 "file list" sections.
        self._check_sections(lines, h2s)
        return self.findings

    def _check_blockquote(self, lines: list[str], body_start: int) -> None:
        idx = body_start - 1
        while idx < len(lines) and not lines[idx].strip():
            idx += 1
        if idx >= len(lines) or not lines[idx].lstrip().startswith(">"):
            self.warn(
                min(body_start, max(len(lines), 1)),
                "W001",
                "no blockquote summary after the H1: '> <one-paragraph summary>' carries the key "
                "information needed to understand the rest of the file",
            )
            return
        quoted = []
        while idx < len(lines) and lines[idx].lstrip().startswith(">"):
            quoted.append(lines[idx].lstrip()[1:].strip())
            idx += 1
        if not "".join(quoted).strip():
            self.warn(idx, "W002", "the blockquote summary is empty")

    def _check_sections(self, lines: list[str], h2s: list[tuple[int, int, str]]) -> None:
        seen_titles: dict[str, int] = {}
        seen_urls: dict[str, int] = {}
        for pos, (line_no, _level, title) in enumerate(h2s):
            end = h2s[pos + 1][0] if pos + 1 < len(h2s) else len(lines) + 1
            body = list(enumerate(lines[line_no:end - 1], start=line_no + 1))

            key = title.strip().lower()
            if key in seen_titles:
                self.warn(line_no, "W009", f"duplicate section '{title}' (first at line {seen_titles[key]})")
            else:
                seen_titles[key] = line_no

            if key == "optional" and pos != len(h2s) - 1:
                self.warn(
                    line_no,
                    "W008",
                    "'## Optional' is conventionally the LAST section — it holds secondary links "
                    "an agent can skip when a shorter context is needed",
                )

            links = 0
            in_fence = False
            for body_no, raw in body:
                if FENCE_RE.match(raw):
                    in_fence = not in_fence
                    continue
                if in_fence or not raw.strip():
                    continue
                item = LIST_ITEM_RE.match(raw)
                if not item:
                    if raw.startswith((" ", "\t")):
                        continue  # continuation of the previous list item
                    self.warn(
                        body_no,
                        "W004",
                        "non-list content in a section: an H2 section is a 'file list' — a markdown "
                        "list of '[name](url): notes' items",
                    )
                    continue
                links += 1
                self._check_link(body_no, item.group(1).strip(), seen_urls)

            if links == 0:
                self.warn(line_no, "W012", f"section '{title}' contains no links")

    def _check_link(self, line_no: int, item_text: str, seen_urls: dict[str, int]) -> None:
        m = LINK_ITEM_RE.match(item_text)
        if not m:
            self.error(
                line_no,
                "E004",
                "list item is not a link: every file-list item requires a markdown hyperlink "
                "'[name](url)', optionally followed by ': notes'",
            )
            return
        name, url, notes = m.group(1), m.group(2), m.group("notes")

        if not name.strip():
            self.warn(line_no, "W006", f"link to {url} has an empty name")
        if not (notes or "").strip():
            self.warn(
                line_no,
                "W006",
                f"link '{name}' has no notes: add ': <brief, informative description>' so an agent "
                "can choose without fetching",
            )

        if url in seen_urls:
            self.warn(line_no, "W010", f"duplicate URL {url} (first at line {seen_urls[url]})")
        else:
            seen_urls[url] = line_no

        parts = urlsplit(url)
        if not parts.scheme and not url.startswith("//"):
            self.warn(
                line_no,
                "W005",
                f"relative link '{url}': llms.txt file lists are URLs, and agents may read the file "
                "detached from its origin — use an absolute URL",
            )
            return
        path = parts.path.lower()
        if path and not path.endswith(LLM_FRIENDLY_SUFFIXES) and parts.scheme in ("http", "https"):
            self.warn(
                line_no,
                "W007",
                f"'{url}' does not look like clean markdown: links should point at LLM-friendly "
                "content — the page's '.md' version ('page.html.md' or 'page.md'; 'index.md' for a "
                "directory URL)",
            )


def lint_file(path: str, max_bytes: int) -> list[Finding]:
    try:
        with open(path, "rb") as fh:
            raw = fh.read()
    except OSError as exc:
        print(f"{path}: error: cannot read ({exc})", file=sys.stderr)
        raise SystemExit(2) from exc
    # A BOM is explicitly permitted as the first bytes of an llms.txt.
    text = raw.decode("utf-8-sig", errors="replace")
    return Linter(path, text, max_bytes).run()


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(
        prog="llms_txt_lint.py",
        description="Lint an llms.txt file against the llmstxt.org v2 spec.",
    )
    ap.add_argument("files", metavar="FILE", nargs="+", help="llms.txt file(s) to lint")
    ap.add_argument("--strict", action="store_true", help="treat warnings as errors")
    ap.add_argument("--quiet", action="store_true", help="print findings only, no summary")
    ap.add_argument(
        "--max-bytes",
        type=int,
        default=DEFAULT_MAX_BYTES,
        metavar="N",
        help=f"warn above this size (default {DEFAULT_MAX_BYTES})",
    )
    args = ap.parse_args(argv)

    errors = warnings = 0
    for path in args.files:
        for f in sorted(lint_file(path, args.max_bytes), key=lambda x: (x.line, x.code)):
            print(f"{path}:{f.line}: {f.level} [{f.code}] {f.message}")
            if f.level == "error":
                errors += 1
            else:
                warnings += 1

    if not args.quiet:
        verdict = "FAIL" if errors or (args.strict and warnings) else "PASS"
        print(f"{verdict}: {errors} error(s), {warnings} warning(s)")
    return 1 if errors or (args.strict and warnings) else 0


if __name__ == "__main__":
    raise SystemExit(main())
