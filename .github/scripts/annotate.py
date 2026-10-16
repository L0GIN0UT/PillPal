"""Emit a text file as GitHub Actions annotations, split into readable chunks.

Annotation messages are capped at 4096 characters and each step may emit at
most 10 annotations per level, so long output (analyzer findings, test
failures, format diffs) is split into numbered chunks ("<title> 3/7") spread
over the error, warning and notice levels. Concatenating the chunks in order
restores the text. Usage: annotate.py <title> <file>
"""

import sys

CHUNK = 3800
LEVELS = ["error"] * 10 + ["warning"] * 10 + ["notice"] * 10
MAX_CHUNKS = 15  # a job keeps at most 50 annotations in total


def main() -> None:
    title, path = sys.argv[1], sys.argv[2]
    with open(path, encoding="utf-8", errors="replace") as handle:
        text = handle.read()
    chunks = [text[i : i + CHUNK] for i in range(0, len(text), CHUNK)] or ["(empty)"]
    for index, chunk in enumerate(chunks[:MAX_CHUNKS]):
        body = chunk.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
        print(f"::{LEVELS[index]} title={title} {index + 1}/{len(chunks)}::{body}")


if __name__ == "__main__":
    main()
