#!/usr/bin/env python3
"""Read a Terraform folder and report its shape as JSON.

    python3 read_tf.py <dir>

HCL is not YAML and there is no parser in the runner image, so this does the one
thing the checks actually need: find top-level blocks, keep their labels, and
keep their body as text. Nothing here evaluates an expression — a check that
needs a value asks whether the text references `var.`, not what it resolves to.

Output:

    {
      "files":   ["main.tf", ...],
      "blocks":  [{"type": "resource", "labels": ["docker_container","app"],
                   "body": "...", "file": "main.tf"}, ...],
      "text":    "every .tf file, concatenated, comments stripped"
    }

Comments are stripped first. A `#` inside a quoted string is not a comment, and
`nginx.conf.tftpl` templates are full of them, so the stripper tracks quotes and
heredocs rather than deleting to end of line blindly.
"""
import json
import pathlib
import re
import sys


def strip_comments(src: str) -> str:
    """Remove #, // and /* */ comments without touching string or heredoc bodies."""
    out = []
    i, n = 0, len(src)
    in_str = False
    heredoc = None
    while i < n:
        c = src[i]
        nxt = src[i + 1] if i + 1 < n else ""

        if heredoc is not None:
            # inside <<EOT ... EOT: copy verbatim until the terminator line
            line_end = src.find("\n", i)
            line_end = n if line_end == -1 else line_end
            line = src[i:line_end]
            out.append(line)
            if line.strip() == heredoc:
                heredoc = None
            if line_end < n:
                out.append("\n")
            i = line_end + 1
            continue

        if in_str:
            out.append(c)
            if c == "\\" and nxt:
                out.append(nxt)
                i += 2
                continue
            if c == '"':
                in_str = False
            i += 1
            continue

        if c == '"':
            in_str = True
            out.append(c)
            i += 1
            continue

        m = re.match(r"<<-?([A-Za-z_][A-Za-z0-9_]*)", src[i:])
        if m:
            heredoc = m.group(1)
            out.append(m.group(0))
            i += len(m.group(0))
            continue

        if c == "#" or (c == "/" and nxt == "/"):
            j = src.find("\n", i)
            i = n if j == -1 else j
            continue

        if c == "/" and nxt == "*":
            j = src.find("*/", i + 2)
            i = n if j == -1 else j + 2
            continue

        out.append(c)
        i += 1
    return "".join(out)


BLOCK_HEAD = re.compile(
    r'(?m)^[ \t]*([A-Za-z_][A-Za-z0-9_-]*)((?:[ \t]+"[^"\n]*")*)[ \t]*\{'
)


def blocks_of(src: str, filename: str):
    """Top-level blocks only. Nested ones stay inside their parent's body text."""
    found = []
    for m in BLOCK_HEAD.finditer(src):
        # top level means brace depth zero at the point the block opens
        before = src[: m.start()]
        if before.count("{") != before.count("}"):
            continue
        depth, i, n = 0, m.end() - 1, len(src)
        while i < n:
            if src[i] == "{":
                depth += 1
            elif src[i] == "}":
                depth -= 1
                if depth == 0:
                    break
            i += 1
        found.append({
            "type": m.group(1),
            "labels": re.findall(r'"([^"]*)"', m.group(2)),
            "body": src[m.end():i],
            "file": filename,
        })
    return found


def main():
    root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".")
    files, blocks, chunks = [], [], []
    for p in sorted(root.glob("*.tf")):
        src = strip_comments(p.read_text(errors="replace"))
        files.append(p.name)
        chunks.append(src)
        blocks.extend(blocks_of(src, p.name))
    print(json.dumps({"files": files, "blocks": blocks, "text": "\n".join(chunks)}))


if __name__ == "__main__":
    main()
