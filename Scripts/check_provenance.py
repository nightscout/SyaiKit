#!/usr/bin/env python3
# Copyright (c) 2026 Nightscout Foundation.
# Licensed under the MIT License. See LICENSE in the project root.
"""
check_provenance.py — lint for phased-out provenance citations in shipped code.

TV-/§- citations and references to Research/TEST_VECTORS.md are development-only
artifacts; they are being removed from shipped source comments in favor of plain-
English invariant explanations. This script enforces the phase-out:

  - any TV-NN citation in shipped Swift source is an error;
  - the drift signature (UNVERIFIED / "assumed" / TODO( co-occurring with a TV
    citation in one doc block) is still an error — it means a comment contradicts
    itself.

Run: `python3 Scripts/check_provenance.py` from the repo root, or anywhere
(paths are resolved relative to this file). Exit 0 = clean.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
SWIFT_DIRS = ["SyaiKit", "SyaiKitUI", "SyaiKitPlugin"]

TV_REF_RE = re.compile(r"TV-(\d+)")
DRIFT_WORDS_RE = re.compile(r"\bUNVERIFIED\b|\bassumed\b|\bTODO\(", re.IGNORECASE)


def find_swift_files() -> list[Path]:
    files = []
    for d in SWIFT_DIRS:
        base = REPO_ROOT / d
        if base.exists():
            files.extend(base.rglob("*.swift"))
    return sorted(files)


def check_drift_signature(path: Path, lines: list[str]) -> list[str]:
    """UNVERIFIED/assumed/TODO( co-occurring with a TV citation in one doc block."""
    findings = []
    # Scan contiguous ///-comment blocks as a whole, since the two signals can be
    # a few lines apart within the same comment.
    i = 0
    while i < len(lines):
        if lines[i].strip().startswith("///"):
            start = i
            while i < len(lines) and lines[i].strip().startswith("///"):
                i += 1
            block_text = "\n".join(lines[start:i])
            has_drift_word = DRIFT_WORDS_RE.search(block_text)
            has_tv = TV_REF_RE.search(block_text)
            if has_drift_word and has_tv:
                findings.append(
                    f"{path}:{start + 1}: drift signature — comment claims "
                    f"'{has_drift_word.group(0)}' but also cites TV-{has_tv.group(1)}; "
                    f"resolve which one is true"
                )
        else:
            i += 1
    return findings


def check_tv_citations(path: Path, text: str) -> list[str]:
    """TV-NN citations are phased out in shipped source."""
    findings = []
    for m in TV_REF_RE.finditer(text):
        line_no = text.count("\n", 0, m.start()) + 1
        findings.append(
            f"{path}:{line_no}: TV-{m.group(1)} citation in shipped source "
            f"(phased out; express the invariant in plain English or keep it in Research/)"
        )
    return findings


def main() -> int:
    swift_files = find_swift_files()
    if not swift_files:
        print(f"[!] no Swift files found under {SWIFT_DIRS} — wrong working directory?", file=sys.stderr)
        return 2

    all_findings: list[str] = []
    for path in swift_files:
        text = path.read_text(errors="ignore")
        lines = text.splitlines()
        all_findings += check_drift_signature(path, lines)
        all_findings += check_tv_citations(path, text)

    if all_findings:
        print(f"check_provenance: {len(all_findings)} finding(s)\n")
        for f in all_findings:
            print(f"  {f}")
        return 1

    print(f"check_provenance: clean ({len(swift_files)} Swift files)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
