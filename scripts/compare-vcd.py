#!/usr/bin/env python3
"""Compare logical VCD signal transitions across files or result directories."""

from __future__ import annotations

import argparse
from pathlib import Path
import sys


def parse_vcd(path: Path) -> dict[str, list[tuple[int, str]]]:
    ids: dict[str, list[tuple[str, int]]] = {}
    signals: dict[str, list[tuple[int, str]]] = {}
    scope: list[str] = []
    in_header = True
    time = 0

    with path.open(encoding="utf-8", errors="replace") as handle:
        for raw in handle:
            line = raw.strip()
            if not line:
                continue
            if in_header:
                parts = line.split()
                tag = parts[0]
                if tag == "$scope" and len(parts) >= 3:
                    scope.append(parts[2])
                elif tag == "$upscope" and scope:
                    scope.pop()
                elif tag == "$var" and len(parts) >= 6:
                    width = int(parts[2])
                    identifier = parts[3]
                    leaf = parts[4].split("[", 1)[0]
                    name = ".".join(scope[1:] + [leaf]) if len(scope) > 1 else leaf
                    ids.setdefault(identifier, []).append((name, width))
                    signals.setdefault(name, [])
                elif tag == "$enddefinitions":
                    in_header = False
                continue

            head = line[0]
            if head == "#":
                time = int(line[1:])
                continue
            if head in "bB":
                parts = line.split()
                if len(parts) < 2:
                    continue
                raw_val, identifier = parts[0][1:].lower(), parts[1]
            elif head in "01xXzZ" and len(line) >= 2:
                raw_val, identifier = head.lower(), line[1:].strip()
            else:
                continue

            targets = ids.get(identifier)
            if targets is None:
                raise ValueError(f"{path}: unknown VCD identifier {identifier!r}")
            pad = raw_val[0] if raw_val[0] in "xz" else "0"
            for name, width in targets:
                val = raw_val.rjust(width, pad)[-width:]
                series = signals[name]
                if series and series[-1][0] == time:
                    series.pop()
                if not series or series[-1][1] != val:
                    series.append((time, val))

    if in_header:
        raise ValueError(f"{path}: missing $enddefinitions")
    return signals


def vcd_relpaths(root: Path) -> list[Path]:
    files = sorted(root.glob("*/wave.vcd")) or sorted(root.glob("*.vcd"))
    if not files:
        raise ValueError(f"{root}: no VCD files found")
    return [path.relative_to(root) for path in files]


def resolve_pairs(reference: Path, candidate: Path) -> list[tuple[Path, Path]]:
    if reference.is_dir() and candidate.is_dir():
        rels = sorted(set(vcd_relpaths(reference)) | set(vcd_relpaths(candidate)))
        return [(reference / rel, candidate / rel) for rel in rels]
    if reference.is_dir():
        by_test = reference / candidate.parent.name / candidate.name
        return [(by_test if by_test.exists() else reference / candidate.name, candidate)]
    if candidate.is_dir():
        by_test = candidate / reference.parent.name / reference.name
        return [(reference, by_test if by_test.exists() else candidate / reference.name)]
    return [(reference, candidate)]


def compare_pair(reference: Path, candidate: Path) -> int:
    expected = parse_vcd(reference)
    actual = parse_vcd(candidate)

    expected_names = set(expected)
    actual_names = set(actual)
    if expected_names != actual_names:
        missing = sorted(expected_names - actual_names)
        extra = sorted(actual_names - expected_names)
        print(f"VCD MISMATCH: {reference} != {candidate}", file=sys.stderr)
        if missing:
            print("  missing signals: " + ", ".join(missing), file=sys.stderr)
        if extra:
            print("  extra signals: " + ", ".join(extra), file=sys.stderr)
        return 1

    for name in sorted(expected_names):
        left_seq, right_seq = expected[name], actual[name]
        if left_seq != right_seq:
            limit = min(len(left_seq), len(right_seq))
            idx = next((i for i in range(limit) if left_seq[i] != right_seq[i]), limit)
            left = left_seq[idx] if idx < len(left_seq) else "<end>"
            right = right_seq[idx] if idx < len(right_seq) else "<end>"
            print(
                f"VCD MISMATCH: {name} transition {idx} ({reference} vs {candidate})",
                file=sys.stderr,
            )
            print(f"  reference: {left}", file=sys.stderr)
            print(f"  candidate: {right}", file=sys.stderr)
            return 1

    print(f"VCD MATCH: {reference} == {candidate} ({len(expected_names)} signals)")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("reference", type=Path)
    parser.add_argument("candidate", type=Path)
    args = parser.parse_args()
    try:
        for ref, cand in resolve_pairs(args.reference, args.candidate):
            rc = compare_pair(ref, cand)
            if rc != 0:
                return rc
    except (OSError, ValueError) as error:
        print(f"VCD ERROR: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
