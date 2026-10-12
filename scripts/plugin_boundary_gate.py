#!/usr/bin/env python3
"""Inventory and ratchet optional capability dependencies during issue #45.

The default gate rejects additions to the reviewed migration baseline. --minimal
rejects every optional capability path, regardless of baseline. Neither mode
claims to inspect machine code or prove that a clean build succeeds.
"""

from __future__ import annotations

import argparse
from collections import deque
import json
from pathlib import Path
import re
import sys
import tomllib

ROOT = Path(__file__).resolve().parents[1]
IMPORT = re.compile(
    r"\bimport\s+([A-Za-z_][A-Za-z0-9_]*)(?:\s*[.{]|\s+as\b|[ \t]*$)",
    re.MULTILINE,
)
# Blank literals/comments before recognizing imports. Preserve newlines for
# diagnostics. This also avoids treating fixture source text as an import.
NON_CODE = re.compile(
    r'"""[\s\S]*?"""|\'\'\'[\s\S]*?\'\'\'|'
    r'"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'|'
    r"//[^\n]*|/\*[\s\S]*?\*/"
)


def imported_packages(source: str) -> set[str]:
    code = NON_CODE.sub(lambda match: "\n" * match.group(0).count("\n"), source)
    return set(IMPORT.findall(code))


def dependencies(value: object):
    """Include target-specific dependencies, excluding binary link options."""
    if isinstance(value, dict):
        for key, child in value.items():
            if key == "dependencies" and isinstance(child, dict):
                yield from child.items()
            elif key not in {"dev-dependencies", "test-dependencies", "bin-dependencies"}:
                yield from dependencies(child)


def load_graph(root: Path):
    workspace = tomllib.loads((root / "cjpm.toml").read_text(encoding="utf-8"))
    members = workspace.get("workspace", {}).get("members")
    if not isinstance(members, list) or not members:
        raise ValueError("workspace.members must be a nonempty array")
    package_roots: dict[str, Path] = {}
    manifests: dict[str, dict] = {}
    names_by_path: dict[Path, str] = {}
    # Independently shipped plugins are not host workspace members. Inventory
    # them anyway, so adding a host edge cannot hide a business package merely
    # because its manifest was previously outside the host dependency closure.
    plugin_roots = sorted(path.parent.resolve() for path in (root / "plugins").glob("*/cjpm.toml"))
    pending = deque([(root / member).resolve() for member in members] + plugin_roots)
    while pending:
        package_root = pending.popleft()
        if package_root in names_by_path:
            continue
        if not package_root.is_relative_to(root):
            raise ValueError(f"local dependency escapes checkout: {package_root}")
        manifest_path = package_root / "cjpm.toml"
        if not manifest_path.is_file():
            raise ValueError(f"missing package manifest: {manifest_path.relative_to(root)}")
        manifest = tomllib.loads(manifest_path.read_text(encoding="utf-8"))
        name = manifest.get("package", {}).get("name")
        if not isinstance(name, str) or not name:
            raise ValueError(f"missing package.name: {manifest_path.relative_to(root)}")
        if name in package_roots and package_roots[name] != package_root:
            raise ValueError(f"duplicate package name: {name}")
        names_by_path[package_root] = name
        package_roots[name] = package_root
        manifests[name] = manifest
        for _, specification in dependencies(manifest):
            if isinstance(specification, dict) and "path" in specification:
                local_path = specification["path"]
                if not isinstance(local_path, str) or "${" in local_path:
                    raise ValueError(f"unresolved dependency path in {name}")
                pending.append((package_root / local_path).resolve())

    graph: dict[str, set[str]] = {name: set() for name in manifests}
    manifest_edges: list[dict] = []
    source_edges: list[dict] = []
    for name, manifest in sorted(manifests.items()):
        aliases = {}
        package_root = package_roots[name]
        for alias, specification in dependencies(manifest):
            target = alias
            if isinstance(specification, dict) and "path" in specification:
                target = names_by_path[(package_root / specification["path"]).resolve()]
            aliases[alias] = target
            graph[name].add(target)
            manifest_edges.append({"source": name, "target": target, "alias": alias})
        for source in sorted((package_root / "src").rglob("*.cj")):
            if source.name.endswith("_test.cj") or "tests" in source.relative_to(package_root).parts:
                continue
            for imported in sorted(imported_packages(source.read_text(encoding="utf-8"))):
                target = aliases.get(imported, imported)
                if target in manifests or target in graph[name]:
                    graph[name].add(target)
                    source_edges.append({
                        "source": name, "target": target,
                        "path": source.relative_to(root).as_posix(),
                    })
                elif imported not in {"std", "stdx"}:
                    # Keep undeclared imports: in particular, an optional package
                    # cannot escape the gate simply by omitting its manifest edge.
                    graph[name].add(target)
                    source_edges.append({
                        "source": name, "target": target,
                        "path": source.relative_to(root).as_posix(),
                    })
    return graph, manifest_edges, source_edges, sorted(names_by_path[path] for path in plugin_roots)


def shortest_paths(graph: dict[str, set[str]], origin: str) -> dict[str, list[str]]:
    paths = {origin: [origin]}
    queue = deque([origin])
    while queue:
        current = queue.popleft()
        for dependency in sorted(graph.get(current, set())):
            if dependency not in paths:
                paths[dependency] = paths[current] + [dependency]
                queue.append(dependency)
    return paths


def inventory(root: Path, policy: dict, hosts: list[str] | None = None) -> dict:
    for field in ("host_packages", "optional_capability_packages"):
        values = policy[field]
        if (not isinstance(values, list) or not values or
                any(not isinstance(value, str) or not value.strip() for value in values) or
                len(set(values)) != len(values)):
            raise ValueError(f"policy.{field} must be a nonempty array of unique package names")
    graph, manifest_edges, source_edges, independent_plugins = load_graph(root)
    host_packages = hosts or policy["host_packages"]
    forbidden = set(policy["optional_capability_packages"])
    unclassified_plugins = set(independent_plugins) - forbidden
    if unclassified_plugins:
        raise ValueError("independent plugin missing optional capability policy: " + ", ".join(sorted(unclassified_plugins)))
    for host in host_packages:
        if host not in graph:
            raise ValueError(f"required host package is missing: {host}")
    host_closure: set[str] = set()
    violations = {}
    for host in host_packages:
        paths = shortest_paths(graph, host)
        host_closure.update(paths)
        for target in sorted(forbidden.intersection(paths)):
            key = f"reachable:{host}:{target}"
            violations[key] = {"key": key, "chain": paths[target]}
    for edge in manifest_edges:
        if edge["source"] in host_closure - forbidden and edge["target"] in forbidden:
            key = f"manifest:{edge['source']}:{edge['target']}"
            violations[key] = {"key": key, **edge}
    for edge in source_edges:
        if edge["source"] in host_closure - forbidden and edge["target"] in forbidden:
            key = f"import:{edge['path']}:{edge['target']}"
            violations[key] = {"key": key, **edge}
    return {
        "schema_version": 1,
        "host_packages": sorted(host_packages),
        "package_count": len(graph),
        "independent_plugin_packages": independent_plugins,
        "manifest_edges": sorted(manifest_edges, key=lambda edge: (edge["source"], edge["target"])),
        "source_edges": sorted(source_edges, key=lambda edge: (edge["path"], edge["target"])),
        "violations": [violations[key] for key in sorted(violations)],
        "verification_scope": "source-and-manifests-only; clean-build and binary inspection required separately",
    }


def check(report: dict, baseline: dict, minimal: bool) -> list[dict]:
    if baseline.get("schema_version") != 1:
        raise ValueError("unsupported plugin boundary baseline version")
    allowed = set() if minimal else set(baseline["allowed_violations"])
    return [item for item in report["violations"] if item["key"] not in allowed]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--policy", type=Path)
    parser.add_argument("--baseline", type=Path)
    parser.add_argument("--minimal", action="store_true", help="reject all optional capability dependencies")
    parser.add_argument("--host-package", action="append", help="restrict strict checks to a selected build root; requires --minimal")
    parser.add_argument("--report", type=Path, help="write the measured graph and diagnostic paths as JSON")
    args = parser.parse_args()
    if args.host_package and not args.minimal:
        parser.error("--host-package requires --minimal (the baseline gate always covers all host packages)")
    root = args.root.resolve()
    try:
        policy_path = args.policy or root / "scripts/plugin_boundary_policy.json"
        baseline_path = args.baseline or root / "scripts/plugin_boundary_baseline.json"
        policy = json.loads(policy_path.read_text(encoding="utf-8"))
        if policy.get("schema_version") != 1:
            raise ValueError("unsupported plugin boundary policy version")
        report = inventory(root, policy, args.host_package)
        baseline = json.loads(baseline_path.read_text(encoding="utf-8"))
        violations = check(report, baseline, args.minimal)
        if args.report:
            args.report.parent.mkdir(parents=True, exist_ok=True)
            args.report.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f"plugin boundary gate failed: {error}", file=sys.stderr)
        return 1
    if violations:
        print("plugin boundary gate failed:", file=sys.stderr)
        for item in violations:
            detail = " -> ".join(item.get("chain", []))
            print(f"- {item['key']}" + (f" ({detail})" if detail else ""), file=sys.stderr)
        return 1
    remaining = len(report["violations"])
    mode = "minimal" if args.minimal else "migration ratchet"
    print(f"plugin boundary {mode} passed ({report['package_count']} packages; {remaining} remaining baseline violations)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
