#!/usr/bin/env python3
"""Fail closed on empty, skipped, or incomplete app-hosted XCTest evidence."""
import json
import os
from pathlib import Path
import sys


def verify(summary, tests):
    counts = ("totalTestCount", "passedTests", "failedTests", "skippedTests", "expectedFailures")
    if any(type(summary.get(key)) is not int or summary[key] < 0 for key in counts):
        raise ValueError("Missing or invalid XCTest summary counts")
    total = summary["totalTestCount"]
    if (summary.get("result") != "Passed" or total <= 0
            or summary["passedTests"] != total
            or any(summary[key] != 0 for key in counts[2:])):
        raise ValueError(f"All HomeClawTests must pass without skips: {summary}")

    def walk(nodes):
        for node in nodes:
            yield node
            yield from walk(node.get("children", []))

    bundles = [node for node in walk(tests.get("testNodes", []))
               if node.get("nodeType") == "Unit test bundle"]
    if len(bundles) != 1 or bundles[0].get("name") not in ("HomeClawTests", "HomeClawTests.xctest"):
        raise ValueError("Expected exactly the HomeClawTests unit test bundle")
    cases = [node for node in walk(bundles[0].get("children", []))
             if node.get("nodeType") == "Test Case"]
    if len(cases) != total or any(case.get("result") != "Passed" for case in cases):
        raise ValueError("Individual test results disagree with the passing summary")
    return f"HomeClawTests (Mac Catalyst): {total} passed; 0 failed; 0 skipped."


def main():
    try:
        with open(sys.argv[1]) as handle:
            summary = json.load(handle)
        with open(sys.argv[2]) as handle:
            tests = json.load(handle)
        message = verify(summary, tests)
    except (ValueError, OSError, IndexError, TypeError, KeyError) as error:
        print(f"Invalid Catalyst test evidence: {error}", file=sys.stderr)
        return 1
    print(message)
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with Path(os.environ["GITHUB_STEP_SUMMARY"]).open("a") as handle:
            handle.write(f"### Catalyst unit tests\n\n{message}\n\n"
                         "Full log, individual results, and xcresult bundle are attached as artifacts.\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
