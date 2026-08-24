#!/usr/bin/env python3
"""UTF-8 slice audit checker.

Scans every String slice site (`var[a..b]`) across the cj_tui and
learn_agent_cj sources and diffs them against the reviewed line sets in
UTF8_SLICE_AUDIT.md. Any unreviewed slice site fails the check — run it
before full regression after touching parsing/rendering code.

Run from anywhere:
    python3 tools/utf8_slice_audit.py
"""
import pathlib
import re
import sys

BASE = pathlib.Path(__file__).resolve().parent.parent.parent  # playground/
AUDIT = BASE / "learn_agent_cj" / "UTF8_SLICE_AUDIT.md"

ROOTS = [
    "cj_tui/packages/core/src",
    "cj_tui/packages/cj_markdown/src",
    "cj_tui/packages/markdown/src",
    "learn_agent_cj/agent_tui/src",
    "learn_agent_cj/agent_cli/src",
    "learn_agent_cj/agent_core/src",
    "learn_agent_cj/agent_domain/src",
    "learn_agent_cj/agent_client/src",
    "learn_agent_cj/agent_app/src",
]

# Matches `var[a..b]` / `var[..b]` / `var[a..]` slice expressions.
PAT = re.compile(r"([a-zA-Z_][a-zA-Z_0-9]*)\[([^\]]*\.\.[^\]]*)\]")


def scan():
    found = {}  # relative path -> set(line)
    for rel in ROOTS:
        for f in sorted((BASE / rel).glob("*.cj")):
            lines = set()
            for ln, line in enumerate(f.read_text(encoding="utf-8").splitlines(), 1):
                s = line.strip()
                if s.startswith("//") or not s:
                    continue
                if PAT.search(line):
                    lines.add(ln)
            if lines:
                found[str(f.relative_to(BASE))] = lines
    return found


def reviewed():
    text = AUDIT.read_text(encoding="utf-8") if AUDIT.exists() else ""
    out = {}
    cur = None
    for line in text.splitlines():
        m = re.match(r"### (.+\.cj)", line)
        if m:
            cur = m.group(1).strip()
            continue
        m = re.match(r"-?\s*已审:\s*(.*)", line)
        if m and cur:
            nums = [int(x) for x in m.group(1).split(",") if x.strip()]
            out.setdefault(cur, set()).update(nums)
    return out


def main():
    found = scan()
    rev = reviewed()
    if "--refresh" in sys.argv:
        # Rewrite the reviewed line sets from the current scan, keeping the
        # judgement lines. Use after adding/removing lines in audited files.
        lines = AUDIT.read_text(encoding="utf-8").splitlines() if AUDIT.exists() else []
        out = []
        i = 0
        while i < len(lines):
            line = lines[i]
            m = re.match(r"### (.+\.cj)", line)
            if m:
                out.append(line)
                i += 1
                if i < len(lines) and re.match(r"- 判定:", lines[i]):
                    out.append(lines[i])
                    i += 1
                if i < len(lines) and re.match(r"-?\s*已审:", lines[i]):
                    path = m.group(1).strip()
                    nums = sorted(found.get(path, set()))
                    out.append("- 已审: " + ",".join(str(x) for x in nums))
                    i += 1
                else:
                    out.append("- 已审: ")
                continue
            out.append(line)
            i += 1
        AUDIT.write_text("\n".join(out) + "\n", encoding="utf-8")
        print(f"refreshed reviewed lines in {AUDIT.name}")
        rev = reviewed()
    new = []
    for path, lines in sorted(found.items()):
        for ln in sorted(lines - rev.get(path, set())):
            new.append(f"{path}:{ln}")
    if new:
        print(f"UNREVIEWED STRING SLICE SITES: {len(new)}")
        for item in new[:60]:
            print("  " + item)
        return 1
    total = sum(len(v) for v in found.values())
    print(f"OK: all {total} slice sites reviewed across {len(found)} files")
    return 0


if __name__ == "__main__":
    sys.exit(main())
