#!/usr/bin/env python3
"""Remove a [Peer] block tagged '# name=<NAME>' from a wg-quick config file.
Usage: _strip_peer.py <conf-path> <name>
Rewrites the file in place.
"""
import sys

conf_path, name = sys.argv[1], sys.argv[2]
tag = f"# name={name}"

with open(conf_path) as f:
    lines = f.readlines()

out = []
i = 0
while i < len(lines):
    line = lines[i]
    if line.strip() == "[Peer]":
        # collect the full block (until next blank-line-separated section or EOF)
        block = [line]
        j = i + 1
        while j < len(lines) and lines[j].strip() != "" and not lines[j].startswith("["):
            block.append(lines[j])
            j += 1
        # also swallow a single trailing blank line as part of the block
        trailing_blank = None
        if j < len(lines) and lines[j].strip() == "":
            trailing_blank = lines[j]
            j += 1
        is_target = any(tag in b for b in block)
        if not is_target:
            out.extend(block)
            if trailing_blank is not None:
                out.append(trailing_blank)
        i = j
    else:
        out.append(line)
        i += 1

with open(conf_path, "w") as f:
    f.writelines(out)
