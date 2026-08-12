#!/usr/bin/env python3
"""Check the checker.

A static analyser that cannot fail is worse than none: it reports "clean" forever
and nobody notices it stopped working. This breaks the tree one way at a time and
asserts precheck.py catches each break, then restores the file byte for byte.

Files are read and written as BYTES, never text - reading with universal newlines
and writing back rewrites CRLF as LF across the whole file, which looks like a huge
diff and is exactly the sort of accident this script must not cause.

Run it after touching precheck.py:
    python scripts/precheck_selftest.py

It requires a clean working tree for the files it mutates and restores them in a
`finally`, but if it is killed mid-run use `git checkout --` on the files listed.
"""

from __future__ import annotations

import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent


def run_precheck() -> tuple[int, str]:
    proc = subprocess.run(
        [sys.executable, "scripts/precheck.py"],
        cwd=ROOT,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    return proc.returncode, (proc.stdout or "") + (proc.stderr or "")


def drop(needle: str):
    return lambda blob: blob.replace(needle.encode(), b"", 1)


def swap(old: str, new: str):
    return lambda blob: blob.replace(old.encode(), new.encode(), 1)


def append(text: str):
    return lambda blob: blob + text.encode()


def truncate_last(marker: str):
    return lambda blob: blob[: blob.rfind(marker.encode())]


CASES = [
    ("localization: key missing from ru",
     "App/Resources/ru.lproj/Localizable.strings",
     drop('"app.title" = "AAPSClient";'),
     "exists in en but not ru"),

    ("localization: format specifier mismatch",
     "App/Resources/ru.lproj/Localizable.strings",
     swap('"alarm.snooze_duration" = "%d', '"alarm.snooze_duration" = "%@'),
     "format specifiers differ"),

    ("localization: code references a key in neither file",
     "App/UI/HomeView.swift",
     swap("import SwiftUI",
          'import SwiftUI\nprivate let _probe = String(localized: "totally.made.up.key")'),
     "in neither .strings file"),

    ("swift: unclosed brace",
     "App/Domain/RunningMode.swift",
     truncate_last("}"),
     "is never closed"),

    ("swift: stray closing paren",
     "App/Alarms/DeadManSwitch.swift",
     swap("import Foundation", "import Foundation\nlet _probe = 1)"),
     "unmatched ')'"),

    ("fixtures: referenced file does not exist",
     "AppTests/NsMappingTests.swift",
     swap('loadFixture("entries")', 'loadFixture("nope_does_not_exist")'),
     "has no AppTests/Fixtures"),

    ("bgtask: registered identifier not declared",
     "project.yml",
     drop('          - "com.nightaps.aapsclientios.resurrect"\n'),
     "crashes at launch"),

    ("info.plist: drifted from project.yml",
     "App/Info.plist",
     drop("<string>com.nightaps.aapsclientios.resurrect</string>"),
     "is stale"),

    ("project.yml: scheme names a nonexistent target",
     "project.yml",
     swap("        - AAPSClientiOSTests\n", "        - GhostTarget\n"),
     "unknown target"),

    ("duplicate top-level type across files",
     "App/Domain/RunningMode.swift",
     append("\n\nstruct DeadManRung {}\n"),
     "is declared at top level in"),
]


def main() -> int:
    passed = failed = 0

    for name, relpath, mutate, expected in CASES:
        path = ROOT / relpath
        original = path.read_bytes()
        mutated = mutate(original)
        if mutated == original:
            print(f"BROKEN {name}: mutation was a no-op - the anchor text moved, fix this case")
            failed += 1
            continue
        path.write_bytes(mutated)
        try:
            code, output = run_precheck()
        finally:
            path.write_bytes(original)

        if code != 0 and expected in output:
            print(f"pass   {name}")
            passed += 1
        else:
            print(f"FAIL   {name}: exit={code}, expected {expected!r} in output")
            for line in output.splitlines():
                if line.startswith(("error", "warning")):
                    print(f"         {line}")
            failed += 1

    code, output = run_precheck()
    if code == 0:
        print("pass   unmutated tree is clean")
        passed += 1
    else:
        print(f"FAIL   unmutated tree is not clean (exit {code})\n{output}")
        failed += 1

    print(f"\n{passed} passed, {failed} failed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
