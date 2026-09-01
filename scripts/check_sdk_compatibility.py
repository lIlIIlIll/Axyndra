#!/usr/bin/env python3
"""Offline compatibility gate for stable agent_sdk and axyndra_agent_testkit APIs."""

from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
BASELINES = {
    "agent_sdk": ROOT / "compat" / "agent-sdk-v2.api.json",
    "axyndra_agent_testkit": ROOT / "compat" / "axyndra-agent-testkit-v2.api.json",
}
SOURCES = {
    "agent_sdk": sorted(
        path for path in (ROOT / "agent_sdk" / "src").glob("*.cj")
        if not path.name.endswith("_test.cj")
    ),
    "axyndra_agent_testkit": sorted(
        path for path in (ROOT / "axyndra_agent_testkit" / "src").glob("*.cj")
        if not path.name.endswith("_test.cj")
    ),
}
FROZEN_STABLE_CONSUMERS = {
    "support_tests/sdk_fixture_extension": {"HostOperationIntent"},
    "support_tests/testkit_consumer": {"HostOperationIntent", "FaultPlan", "FaultRule"},
}
EXPERIMENTAL_PREFIXES = {
    "agent_sdk": {
        "class:HostOperationIntent",
        "class:HostOperationIntent.",
        "enum:OperationIntent.variant:HostOperation",
    },
    "axyndra_agent_testkit": {
        "class:FaultRule", "class:FaultRule.",
        "class:FaultPlan", "class:FaultPlan.",
    },
}


@dataclass(frozen=True)
class Symbol:
    key: str
    signature: str
    stability: str


def normalize(value: str) -> str:
    return re.sub(r"\s+", " ", value.strip())


def brace_delta(line: str) -> int:
    # API headers in these packages contain no brace-bearing string defaults.
    return line.count("{") - line.count("}")


def declaration_key(header: str, owner: str | None) -> tuple[str, str] | None:
    match = re.match(r"public\s+(class|enum|interface|struct)\s+([A-Za-z_][A-Za-z0-9_]*)", header)
    if match:
        kind, name = match.groups()
        return f"{kind}:{name}", name
    match = re.match(r"public\s+func\s+([A-Za-z_][A-Za-z0-9_]*)", header)
    if match:
        name = match.group(1)
        return (f"{owner}.func:{name}" if owner else f"func:{name}"), ""
    if re.match(r"public\s+init\b", header):
        return (f"{owner}.init" if owner else "init"), ""
    match = re.match(r"public\s+(let|var|prop)\s+([A-Za-z_][A-Za-z0-9_]*)", header)
    if match:
        kind, name = match.groups()
        return (f"{owner}.{kind}:{name}" if owner else f"{kind}:{name}"), ""
    return None


def header_complete(header: str, kind_hint: str) -> bool:
    parens = header.count("(") - header.count(")")
    if parens > 0:
        return False
    if kind_hint in {"let", "var", "prop"}:
        return True
    if "{" in header:
        return True
    # Interface members have no body.
    return parens == 0 and (header.rstrip().endswith(")") or "):" in header)


def stability_for(package: str, key: str) -> str:
    for prefix in EXPERIMENTAL_PREFIXES[package]:
        if key == prefix or key.startswith(prefix):
            return "EXPERIMENTAL"
    return "STABLE"


def scan_file(package: str, path: Path) -> list[Symbol]:
    lines = path.read_text(encoding="utf-8").splitlines()
    symbols: list[Symbol] = []
    depth = 0
    owner: str | None = None
    owner_depth = -1
    index = 0
    while index < len(lines):
        start_index = index
        raw = lines[index]
        stripped = raw.strip()
        if owner is not None and depth < owner_depth:
            owner = None
            owner_depth = -1
        implicit_interface_member = (
            owner is not None and owner.startswith("interface:") and
            depth == owner_depth and stripped.startswith("func ")
        )
        direct_public = (
            stripped.startswith("public ") and
            (depth == 0 or (owner is not None and depth == owner_depth))
        ) or implicit_interface_member
        if direct_public:
            canonical_start = "public " + stripped if implicit_interface_member else stripped
            kind_match = re.match(r"public\s+([A-Za-z]+)", canonical_start)
            kind_hint = kind_match.group(1) if kind_match else ""
            header_lines = [canonical_start]
            cursor = index
            while not header_complete(" ".join(header_lines), kind_hint) and cursor + 1 < len(lines):
                cursor += 1
                header_lines.append(lines[cursor].strip())
            header = normalize(" ".join(header_lines))
            # Bodies are implementation, not API. Preserve enum variant lists below.
            signature = normalize(header.split("{", 1)[0])
            if kind_hint in {"let", "var"} and "=" in signature:
                signature = normalize(signature.split("=", 1)[0])
            keyed = declaration_key(signature, owner)
            if keyed is not None:
                key, opened_owner = keyed
                symbols.append(Symbol(key, signature, stability_for(package, key)))
                if opened_owner and depth == 0 and "{" in header:
                    owner = f"{kind_hint}:{opened_owner}"
                    owner_depth = 1
            index = cursor
        depth += sum(brace_delta(lines[line_index]) for line_index in range(start_index, index + 1))
        index += 1

    text = path.read_text(encoding="utf-8")
    for match in re.finditer(
        r"public\s+enum\s+([A-Za-z_][A-Za-z0-9_]*)(?:\s*<[^>{}]+>)?\s*\{",
        text,
    ):
        name = match.group(1)
        start = match.end()
        cursor = start
        enum_depth = 1
        while cursor < len(text) and enum_depth > 0:
            if text[cursor] == "{":
                enum_depth += 1
            elif text[cursor] == "}":
                enum_depth -= 1
            cursor += 1
        body = text[start:cursor - 1]
        variants = body.split("public ", 1)[0]
        variants = re.sub(r"@Derive\[[^\]]+\]", "", variants)
        for raw_variant in variants.split("|"):
            variant = normalize(raw_variant)
            if not variant or variant.startswith("//"):
                continue
            variant = re.sub(r"//.*", "", variant).strip()
            if not variant:
                continue
            variant_name = variant.split("(", 1)[0].strip().split()[-1]
            key = f"enum:{name}.variant:{variant_name}"
            symbols.append(Symbol(key, variant, stability_for(package, key)))
    return symbols


def current_surface(package: str) -> dict[str, Symbol]:
    result: dict[str, Symbol] = {}
    for source in SOURCES[package]:
        for symbol in scan_file(package, source):
            if symbol.key in result:
                raise SystemExit(f"duplicate public API key: {package}:{symbol.key}")
            result[symbol.key] = symbol
    return result


def parse_version(value: str) -> tuple[int, int, int]:
    if not re.fullmatch(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)", value):
        raise ValueError(f"invalid canonical version: {value}")
    parts = tuple(int(part) for part in value.split("."))
    if any(part > 2**63 - 1 for part in parts):
        raise ValueError(f"version component overflow: {value}")
    return parts  # type: ignore[return-value]


def compare_surface(
    baseline: dict[str, object],
    current: dict[str, Symbol],
    current_version: str,
) -> list[str]:
    baseline_version = str(baseline["api_version"])
    baseline_major = parse_version(baseline_version)[0]
    current_major = parse_version(current_version)[0]
    previous = {
        str(item["key"]): Symbol(str(item["key"]), str(item["signature"]), str(item["stability"]))
        for item in baseline["symbols"]  # type: ignore[index]
    }
    errors: list[str] = []
    major_changed = current_major > baseline_major
    for key, old in previous.items():
        new = current.get(key)
        if new is None:
            if old.stability == "STABLE" and not major_changed:
                errors.append(f"removed STABLE symbol without major bump: {key}")
            continue
        if old.stability == "STABLE" and new.stability == "EXPERIMENTAL" and not major_changed:
            errors.append(f"demoted STABLE symbol without major bump: {key}")
        if old.signature != new.signature and old.stability == "STABLE" and not major_changed:
            errors.append(
                f"changed STABLE signature without major bump: {key}\n"
                f"  baseline: {old.signature}\n  current:  {new.signature}"
            )
    if not major_changed:
        for key, new in current.items():
            if key in previous or new.stability != "STABLE" or ".variant:" not in key:
                continue
            enum_key = key.split(".variant:", 1)[0]
            if enum_key in previous and previous[enum_key].stability == "STABLE":
                errors.append(f"added variant to STABLE enum without major bump: {key}")
    return errors


def self_test() -> None:
    base = {
        "api_version": "1.0.0",
        "symbols": [
            {"key": "func:stable", "signature": "public func stable(x: Int64): Unit", "stability": "STABLE"},
            {"key": "func:experiment", "signature": "public func experiment(): Unit", "stability": "EXPERIMENTAL"},
        ],
    }
    additive = {
        "func:stable": Symbol("func:stable", "public func stable(x: Int64): Unit", "STABLE"),
        "func:new": Symbol("func:new", "public func new(): Unit", "STABLE"),
    }
    if compare_surface(base, additive, "1.1.0"):
        raise AssertionError("additive stable API must be minor-compatible")
    removed = {"func:experiment": Symbol("func:experiment", "public func experiment(): Unit", "EXPERIMENTAL")}
    if not compare_surface(base, removed, "1.1.0"):
        raise AssertionError("stable removal must fail without major bump")
    changed = {"func:stable": Symbol("func:stable", "public func stable(x: Int64, y: Int64): Unit", "STABLE")}
    if not compare_surface(base, changed, "1.1.0"):
        raise AssertionError("stable signature change must fail without major bump")
    if compare_surface(base, changed, "2.0.0"):
        raise AssertionError("explicit major bump must permit baseline replacement")
    demoted = {
        "func:stable": Symbol("func:stable", "public func stable(x: Int64): Unit", "EXPERIMENTAL"),
        "func:experiment": Symbol("func:experiment", "public func experiment(): Unit", "EXPERIMENTAL"),
    }
    if not compare_surface(base, demoted, "1.1.0"):
        raise AssertionError("stable-to-experimental demotion must fail")
    promoted = {
        "func:stable": Symbol("func:stable", "public func stable(x: Int64): Unit", "STABLE"),
        "func:experiment": Symbol("func:experiment", "public func experiment(): Unit", "STABLE"),
    }
    if compare_surface(base, promoted, "1.1.0"):
        raise AssertionError("experimental promotion must be additive")
    enum_base = {
        "api_version": "1.0.0",
        "symbols": [
            {"key": "enum:Choice", "signature": "public enum Choice", "stability": "STABLE"},
            {"key": "enum:Choice.variant:Old", "signature": "Old", "stability": "STABLE"},
        ],
    }
    if not compare_surface(enum_base, {}, "1.1.0"):
        raise AssertionError("removing a stable enum variant must fail")
    enum_added = {
        "enum:Choice": Symbol("enum:Choice", "public enum Choice", "STABLE"),
        "enum:Choice.variant:Old": Symbol("enum:Choice.variant:Old", "Old", "STABLE"),
        "enum:Choice.variant:New": Symbol("enum:Choice.variant:New", "New", "STABLE"),
    }
    if not compare_surface(enum_base, enum_added, "1.1.0"):
        raise AssertionError("adding a variant to a stable exhaustive enum must fail")


def sdk_version() -> str:
    text = (ROOT / "agent_sdk" / "src" / "extension.cj").read_text(encoding="utf-8")
    match = re.search(r'public\s+let\s+AGENT_SDK_VERSION\s*=\s*"([^"]+)"', text)
    if match is None:
        raise SystemExit("AGENT_SDK_VERSION owner is missing")
    parse_version(match.group(1))
    return match.group(1)


def package_version(package: str) -> str:
    if package == "agent_sdk":
        return sdk_version()
    text = (ROOT / package / "cjpm.toml").read_text(encoding="utf-8")
    match = re.search(r'^\s*version\s*=\s*"([^"]+)"', text, re.MULTILINE)
    if match is None:
        raise SystemExit(f"{package} package version is missing")
    parse_version(match.group(1))
    return match.group(1)


def baseline_document(package: str, version: str) -> dict[str, object]:
    return {
        "format": 1,
        "package": package,
        "api_version": version,
        "symbols": [
            {"key": item.key, "stability": item.stability, "signature": item.signature}
            for item in sorted(current_surface(package).values(), key=lambda value: value.key)
        ],
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dump", choices=sorted(BASELINES))
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        print("SDK API diff policy self-test passed")
        return 0
    if args.dump:
        version = package_version(args.dump)
        print(json.dumps(baseline_document(args.dump, version), indent=2, ensure_ascii=False))
        return 0
    errors: list[str] = []
    for package, baseline_path in BASELINES.items():
        baseline = json.loads(baseline_path.read_text(encoding="utf-8"))
        current_version = package_version(package)
        errors.extend(f"{package}: {error}" for error in compare_surface(
            baseline, current_surface(package), current_version
        ))
    for relative_root, experimental_names in FROZEN_STABLE_CONSUMERS.items():
        for source in sorted((ROOT / relative_root / "src").glob("**/*.cj")):
            text_value = source.read_text(encoding="utf-8")
            for name in sorted(experimental_names):
                if re.search(rf"\b{re.escape(name)}\b", text_value):
                    errors.append(
                        f"stable consumer {relative_root} uses EXPERIMENTAL API {name}: "
                        f"{source.relative_to(ROOT)}"
                    )
    if errors:
        print("SDK compatibility gate failed:\n  " + "\n  ".join(errors), file=sys.stderr)
        return 1
    print("SDK compatibility baselines passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
