#!/usr/bin/env python3

"""Scan an Xcode project for branch-pinned SPM dependencies and check tag availability."""

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path
from typing import Dict, List, Optional


_PKG_REF_RE = re.compile(
    r"(/\*\s*XCRemoteSwiftPackageReference\s+\"(?P<name>[^\"]+)\"\s*\*/\s*=\s*\{[^}]*?"
    r"repositoryURL\s*=\s*\"(?P<url>[^\"]+)\"[^}]*?"
    r"requirement\s*=\s*\{(?P<req>[^}]*)\})",
    re.DOTALL,
)

_KIND_RE = re.compile(r"kind\s*=\s*(\w+)\s*;")
_BRANCH_RE = re.compile(r"branch\s*=\s*(\w+)\s*;")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Check branch-pinned SPM dependencies for available tags."
    )
    parser.add_argument(
        "--project",
        required=True,
        help="Path to the .xcodeproj directory",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Output results as JSON",
    )
    return parser.parse_args()


def find_branch_pins(pbxproj: str) -> List[Dict[str, str]]:
    results: List[Dict[str, str]] = []
    for match in _PKG_REF_RE.finditer(pbxproj):
        name = match.group("name")
        url = match.group("url")
        req = match.group("req")
        kind_match = _KIND_RE.search(req)
        if not kind_match:
            continue
        kind = kind_match.group(1)
        if kind != "branch":
            continue
        branch_match = _BRANCH_RE.search(req)
        branch = branch_match.group(1) if branch_match else "unknown"
        results.append({"name": name, "url": url, "branch": branch})
    return results


def find_json_branch_pins(document: Dict) -> List[Dict[str, str]]:
    """Read package requirements from Apple's project.xcproj representation."""
    results: List[Dict[str, str]] = []
    for package in document.get("packages", []):
        if package.get("kind") != "remote":
            continue
        requirement = package.get("version", {})
        branch = requirement.get("branch")
        if not isinstance(branch, str):
            continue
        url = package["repository"]
        name = package.get("name")
        if not name:
            name = url.rstrip("/").rsplit("/", 1)[-1]
            if name.endswith(".git"):
                name = name[:-4]
        results.append({"name": name, "url": url, "branch": branch})
    return results


def read_branch_pins(project: Path) -> List[Dict[str, str]]:
    definitions = [path for path in (project / "project.pbxproj", project / "project.xcproj") if path.is_file()]
    if len(definitions) != 1:
        raise ValueError(f"Expected exactly one project.pbxproj or project.xcproj in {project}")
    definition = definitions[0]
    if definition.suffix == ".pbxproj":
        return find_branch_pins(definition.read_text())
    # Apple's JSON includes trailing commas; macOS plutil accepts that syntax.
    normalized = subprocess.run(
        ["/usr/bin/plutil", "-convert", "json", "-o", "-", str(definition)],
        capture_output=True, text=True, check=True,
    )
    document = json.loads(normalized.stdout)
    if not isinstance(document, dict) or not isinstance(document.get("packages", []), list):
        raise ValueError(f"Invalid package list in {definition}")
    return find_json_branch_pins(document)


def check_tags(url: str) -> List[str]:
    try:
        result = subprocess.run(
            ["git", "ls-remote", "--tags", url],
            capture_output=True,
            text=True,
            timeout=15,
        )
        if result.returncode != 0:
            return []
        tags: List[str] = []
        for line in result.stdout.strip().splitlines():
            ref = line.split("\t")[-1] if "\t" in line else ""
            if ref.startswith("refs/tags/") and not ref.endswith("^{}"):
                tags.append(ref.replace("refs/tags/", ""))
        return tags
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return []


def main() -> int:
    args = parse_args()
    try:
        pins = read_branch_pins(Path(args.project))
    except (OSError, ValueError, KeyError, TypeError, AttributeError, subprocess.CalledProcessError) as error:
        sys.stderr.write(f"Unable to read project package requirements: {error}\n")
        return 1

    if not pins:
        print("No branch-pinned SPM dependencies found.")
        return 0

    results: List[Dict] = []
    for pin in pins:
        tags = check_tags(pin["url"])
        entry = {
            "name": pin["name"],
            "url": pin["url"],
            "branch": pin["branch"],
            "tags_available": len(tags) > 0,
            "latest_tags": tags[-5:] if tags else [],
        }
        results.append(entry)

    if args.json:
        print(json.dumps(results, indent=2))
    else:
        for r in results:
            status = "tags available" if r["tags_available"] else "no tags (pin to revision)"
            latest = f" (latest: {', '.join(r['latest_tags'])})" if r["latest_tags"] else ""
            print(f"  {r['name']}: branch={r['branch']} -> {status}{latest}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
