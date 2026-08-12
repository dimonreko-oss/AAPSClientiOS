#!/usr/bin/env python3
"""Static pre-flight checks that run without an Xcode toolchain.

This project is developed on Windows, where nothing can be compiled: the GitHub
Actions macOS runner is the only place the code is ever really built. A CI round
trip costs ~10 minutes, so this script front-loads the mistake classes that can be
caught by reading alone, and is wired into a pre-push hook (scripts/install-hooks.ps1).

It is NOT a compiler and never will be. Type inference, overload resolution,
@MainActor isolation and Sendable capture checking all need a real frontend - CI
remains the authority. What is here is exact where it can be and clearly labelled
as heuristic where it cannot.

Usage:
    python scripts/precheck.py            # fail on errors only
    python scripts/precheck.py --strict   # also fail on warnings
    python scripts/precheck.py --list     # show what each check does, run nothing
"""

from __future__ import annotations

import argparse
import plistlib
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SWIFT_ROOTS = ["App", "Shared", "Widget", "AppTests"]
PRODUCT_ROOTS = ["App", "Shared", "Widget"]

errors: list[str] = []
warnings: list[str] = []


def error(msg: str) -> None:
    errors.append(msg)


def warn(msg: str) -> None:
    warnings.append(msg)


def swift_files(roots: list[str]) -> list[Path]:
    out: list[Path] = []
    for root in roots:
        out.extend(sorted((ROOT / root).rglob("*.swift")))
    return out


def rel(path: Path) -> str:
    return path.relative_to(ROOT).as_posix()


# ---------------------------------------------------------------------------
# A Swift scanner that yields only real code characters.
#
# Comments and string bodies are dropped, but string *interpolation* contents are
# kept - `"\(items.map { $0.id })"` contains braces that genuinely have to balance,
# and a naive strip would either miss them or count the literal's own braces.
# Handles nested block comments, multiline strings and raw strings with any number
# of hashes, all of which appear in this codebase.
# ---------------------------------------------------------------------------
def code_chars(src: str) -> list[tuple[int, str]]:
    out: list[tuple[int, str]] = []
    strings: list[dict] = []
    i, n = 0, len(src)

    while i < n:
        ctx = strings[-1] if strings else None

        if ctx is not None and ctx["paren"] == 0:
            terminator = ('"""' if ctx["multi"] else '"') + "#" * ctx["hashes"]
            escape = "\\" + "#" * ctx["hashes"]
            if src.startswith(terminator, i):
                strings.pop()
                i += len(terminator)
            elif src.startswith(escape, i):
                j = i + len(escape)
                if j < n and src[j] == "(":
                    ctx["paren"] = 1
                    i = j + 1
                else:
                    i = min(j + 1, n)
            elif not ctx["multi"] and src[i] == "\n":
                strings.pop()  # unterminated literal; recover at end of line
            else:
                i += 1
            continue

        c = src[i]

        if src.startswith("//", i):
            j = src.find("\n", i)
            i = n if j < 0 else j
            continue

        if src.startswith("/*", i):
            depth, i = 1, i + 2
            while i < n and depth:
                if src.startswith("/*", i):
                    depth += 1
                    i += 2
                elif src.startswith("*/", i):
                    depth -= 1
                    i += 2
                else:
                    i += 1
            continue

        if c in '#"':
            j = i
            while j < n and src[j] == "#":
                j += 1
            hashes = j - i
            if j < n and src[j] == '"':
                multi = src.startswith('"""', j)
                strings.append({"hashes": hashes, "multi": multi, "paren": 0})
                i = j + (3 if multi else 1)
                continue
            if hashes:  # #available, #filePath, #selector ...
                out.append((i, "#"))
                i += 1
                continue

        if ctx is not None:  # inside an interpolation
            if c == "(":
                ctx["paren"] += 1
            elif c == ")":
                ctx["paren"] -= 1
                if ctx["paren"] == 0:
                    i += 1
                    continue

        out.append((i, c))
        i += 1

    if strings:
        return out  # unterminated string; the balance check will surface it
    return out


def line_of(src: str, index: int) -> int:
    return src.count("\n", 0, index) + 1


# ---------------------------------------------------------------------------
# Checks
# ---------------------------------------------------------------------------
def check_swift_syntax() -> None:
    """Exact when a Swift toolchain is present, approximate otherwise.

    `swiftc -parse` is purely syntactic - it does not resolve imports, so it works
    on Windows against a toolchain with no iOS SDK. If swiftc is absent we fall
    back to bracket balancing, which still catches the truncated or mis-merged file
    that is the realistic failure mode for machine-written diffs.
    """
    files = swift_files(SWIFT_ROOTS)
    swiftc = shutil.which("swiftc")

    if swiftc:
        chunk = 40  # keep command lines under Windows' limit
        for start in range(0, len(files), chunk):
            batch = files[start : start + chunk]
            proc = subprocess.run(
                [swiftc, "-parse", *[str(f) for f in batch]],
                capture_output=True,
                text=True,
            )
            for line in proc.stderr.splitlines():
                if ": error:" in line:
                    error(f"swiftc: {line.strip()}")
        return

    warn(
        "swiftc not found - syntax checked by bracket balancing only. "
        "Install a Swift toolchain from swift.org/install/windows for real parsing "
        "(`swiftc -parse` needs no iOS SDK)."
    )
    pairs = {")": "(", "]": "[", "}": "{"}
    for path in files:
        src = path.read_text(encoding="utf-8", errors="replace")
        stack: list[tuple[int, str]] = []
        for index, ch in code_chars(src):
            if ch in "([{":
                stack.append((index, ch))
            elif ch in ")]}":
                if not stack:
                    error(f"{rel(path)}:{line_of(src, index)}: unmatched '{ch}'")
                    break
                open_index, open_ch = stack.pop()
                if open_ch != pairs[ch]:
                    error(
                        f"{rel(path)}:{line_of(src, index)}: '{ch}' closes "
                        f"'{open_ch}' opened at line {line_of(src, open_index)}"
                    )
                    break
        else:
            if stack:
                open_index, open_ch = stack[-1]
                error(
                    f"{rel(path)}:{line_of(src, open_index)}: "
                    f"'{open_ch}' is never closed"
                )


def load_project() -> dict | None:
    try:
        import yaml
    except ImportError:
        warn("pyyaml not installed (`pip install pyyaml`) - project.yml checks skipped")
        return None
    try:
        return yaml.safe_load((ROOT / "project.yml").read_text(encoding="utf-8"))
    except Exception as exc:  # noqa: BLE001 - surfacing any parse failure is the point
        error(f"project.yml: not valid YAML: {exc}")
        return None


def check_project(project: dict | None) -> None:
    """project.yml parses, its source paths exist, and its schemes name real targets."""
    if not project:
        return
    targets = project.get("targets", {})
    for name, target in targets.items():
        for source in target.get("sources", []):
            path = source["path"] if isinstance(source, dict) else source
            if not (ROOT / path).exists():
                error(f"project.yml: target {name} lists missing source path '{path}'")

    schemes = project.get("schemes", {})
    if not schemes:
        error(
            "project.yml: no `schemes:` block. xcodegen then writes no shared scheme, "
            "so `xcodebuild -scheme` fails on a clean checkout (i.e. in CI)."
        )
    for scheme_name, scheme in schemes.items():
        named = list((scheme.get("build") or {}).get("targets", {}).keys())
        named += list((scheme.get("test") or {}).get("targets", []) or [])
        for target_name in named:
            if target_name not in targets:
                error(
                    f"project.yml: scheme {scheme_name} references "
                    f"unknown target '{target_name}'"
                )


def check_background_task_ids(project: dict | None) -> None:
    """Every registered BGTask identifier is declared, and vice versa.

    Registering an identifier absent from BGTaskSchedulerPermittedIdentifiers raises
    at launch, before any UI appears - a crash no test would catch.
    """
    if not project:
        return
    info = (
        project.get("targets", {})
        .get("AAPSClientiOS", {})
        .get("info", {})
        .get("properties", {})
    )
    declared = set(info.get("BGTaskSchedulerPermittedIdentifiers", []))
    modes = set(info.get("UIBackgroundModes", []))

    source = (ROOT / "App/Background/BackgroundScheduler.swift").read_text(
        encoding="utf-8", errors="replace"
    )
    constants = dict(
        re.findall(r'static let (\w+)\s*=\s*"([^"]+)"', source)
    )
    used: set[str] = set()
    for match in re.finditer(
        r"(?:forTaskWithIdentifier:|BGAppRefreshTaskRequest\(identifier:|"
        r"BGProcessingTaskRequest\(identifier:)\s*(?:Self\.)?(\w+)",
        source,
    ):
        name = match.group(1)
        if name in constants:
            used.add(constants[name])

    for identifier in sorted(used - declared):
        error(
            f"BGTask '{identifier}' is registered in BackgroundScheduler.swift but "
            f"missing from BGTaskSchedulerPermittedIdentifiers - this crashes at launch"
        )
    for identifier in sorted(declared - used):
        warn(f"BGTask '{identifier}' is declared in project.yml but never registered")

    if "BGProcessingTaskRequest" in source and "processing" not in modes:
        error(
            "BGProcessingTaskRequest is submitted but 'processing' is absent from "
            "UIBackgroundModes - submit() throws NotPermitted"
        )


def check_info_plist(project: dict | None) -> None:
    """The tracked Info.plist matches what xcodegen would generate from project.yml.

    Info.plist is a generated file that is nonetheless committed, so it drifts the
    moment someone edits project.yml without regenerating.
    """
    if not project:
        return
    plist_path = ROOT / "App/Info.plist"
    if not plist_path.exists():
        return
    declared = (
        project.get("targets", {})
        .get("AAPSClientiOS", {})
        .get("info", {})
        .get("properties", {})
    )
    try:
        actual = plistlib.loads(plist_path.read_bytes())
    except Exception as exc:  # noqa: BLE001
        error(f"App/Info.plist: not a valid plist: {exc}")
        return
    for key, expected in declared.items():
        if key not in actual:
            error(
                f"App/Info.plist is stale: missing '{key}' declared in project.yml "
                f"- run `xcodegen generate` and commit the result"
            )
        elif actual[key] != expected:
            error(
                f"App/Info.plist is stale: '{key}' is {actual[key]!r}, "
                f"project.yml says {expected!r} - run `xcodegen generate`"
            )


STRINGS_ENTRY = re.compile(r'^\s*"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;', re.M)

# The C "space" flag (`% d`) is deliberately NOT accepted: prose like "5-10% overnight"
# would otherwise read as a specifier, and a space-flagged conversion never appears in
# a .strings file. `%%` is matched only so it can be discarded - it is a literal percent,
# not an argument, so it must not count towards the en/ru comparison.
FORMAT_SPEC = re.compile(
    r"%(?:%|(?:\d+\$)?[-+#0]*[\d*]*(?:\.\d+)?(?:hh|h|ll|l|q|L|z|t|j)?[@dDiuUxXoOfeEgGcCsSpaAF])"
)


def format_specs(value: str) -> list[str]:
    return sorted(spec for spec in FORMAT_SPEC.findall(value) if spec != "%%")


def parse_strings(path: Path) -> dict[str, str]:
    text = path.read_text(encoding="utf-8", errors="replace")
    entries: dict[str, str] = {}
    for match in STRINGS_ENTRY.finditer(text):
        key, value = match.group(1), match.group(2)
        if key in entries:
            error(f"{rel(path)}: duplicate key '{key}'")
        entries[key] = value
    return entries


def check_localization() -> None:
    """Both .strings files carry the same keys with compatible format specifiers,
    and every dotted key referenced from code exists.

    A key missing from one language renders as the raw dotted identifier; a
    specifier mismatch between languages is a crash in the localized build.
    """
    resources = ROOT / "App/Resources"
    en_path, ru_path = resources / "en.lproj/Localizable.strings", resources / "ru.lproj/Localizable.strings"
    if not en_path.exists() or not ru_path.exists():
        error("App/Resources: en.lproj or ru.lproj Localizable.strings is missing")
        return

    en, ru = parse_strings(en_path), parse_strings(ru_path)

    for key in sorted(set(en) - set(ru)):
        error(f"localization: '{key}' exists in en but not ru")
    for key in sorted(set(ru) - set(en)):
        error(f"localization: '{key}' exists in ru but not en")

    for key in sorted(set(en) & set(ru)):
        if format_specs(en[key]) != format_specs(ru[key]):
            error(
                f"localization: format specifiers differ for '{key}': "
                f"en {format_specs(en[key])} vs ru {format_specs(ru[key])}"
            )

    referenced: dict[str, str] = {}
    pattern = re.compile(r'(?:String\(localized:\s*|NSLocalizedString\(\s*)"([^"\\]+)"')
    for path in swift_files(PRODUCT_ROOTS):
        for match in pattern.finditer(path.read_text(encoding="utf-8", errors="replace")):
            referenced.setdefault(match.group(1), rel(path))

    for key, where in sorted(referenced.items()):
        # Only dotted identifiers are keys by this repo's convention; a bare English
        # sentence passed to String(localized:) is its own default and is fine.
        if "." in key and " " not in key and key not in en:
            error(f"localization: {where} uses key '{key}' that is in neither .strings file")


def check_fixtures() -> None:
    """Every loadFixture("x") resolves to AppTests/Fixtures/x.v3.json."""
    fixtures_dir = ROOT / "AppTests/Fixtures"
    on_disk = {p.name[: -len(".v3.json")] for p in fixtures_dir.glob("*.v3.json")}
    referenced: dict[str, str] = {}
    for path in swift_files(["AppTests"]):
        text = path.read_text(encoding="utf-8", errors="replace")
        for match in re.finditer(r'loadFixture\(\s*"([^"]+)"', text):
            referenced.setdefault(match.group(1), rel(path))

    for name, where in sorted(referenced.items()):
        if name not in on_disk:
            error(f"{where}: loadFixture(\"{name}\") has no AppTests/Fixtures/{name}.v3.json")

    # Fixtures reached through a variable can't be resolved statically, so an unused
    # fixture is only ever a hint, never an error.
    dynamic = any(
        re.search(r"loadFixture\(\s*[a-zA-Z_]", p.read_text(encoding="utf-8", errors="replace"))
        for p in swift_files(["AppTests"])
    )
    if not dynamic:
        for name in sorted(on_disk - set(referenced)):
            warn(f"AppTests/Fixtures/{name}.v3.json is referenced by no test")


TOP_LEVEL_TYPE = re.compile(
    r"^(?:@\w+(?:\([^)]*\))?\s+)*"
    r"(?:public\s+|internal\s+|private\s+|fileprivate\s+|final\s+|indirect\s+)*"
    r"(class|struct|enum|protocol|actor)\s+(\w+)",
    re.M,
)


def check_duplicate_types() -> None:
    """No type name is declared at top level in two files of the same target.

    Independent agents adding the same helper in two places is a redeclaration error
    that only shows up at link time.
    """
    seen: dict[str, list[str]] = {}
    for path in swift_files(PRODUCT_ROOTS):
        src = path.read_text(encoding="utf-8", errors="replace")
        for match in TOP_LEVEL_TYPE.finditer(src):
            # Column 0 only: an indented match is a nested type and is legal.
            if match.start() and src[match.start() - 1] != "\n":
                continue
            seen.setdefault(match.group(2), []).append(rel(path))
    for name, files in sorted(seen.items()):
        if len(files) > 1:
            error(f"type '{name}' is declared at top level in: {', '.join(files)}")


# Symbols this project could plausibly reach for that postdate its iOS 16.0 floor.
# Deliberately short: a long list of rarely-used API produces noise, and CI is the
# real check. Extend it when a version-availability bug actually gets through.
IOS_17_PLUS = {
    "ContentUnavailableView": "17.0",
    "@Observable": "17.0",
    "Observable()": "17.0",
    "BGContinuedProcessingTask": "26.0",
    "AlarmManager": "26.0",
    "onChange(of:initial:": "17.0",
    "scrollBounceBehavior": "16.4",
    "AppIntent": "16.0",
}


def check_ios_availability() -> None:
    """Heuristic: a post-iOS-16 symbol with no #available guard nearby."""
    for path in swift_files(PRODUCT_ROOTS):
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
        for number, line in enumerate(lines, start=1):
            if line.lstrip().startswith("//"):
                continue
            for symbol, since in IOS_17_PLUS.items():
                if symbol not in line:
                    continue
                window = "\n".join(lines[max(0, number - 12) : number + 2])
                if "#available" in window or "@available" in window:
                    continue
                warn(
                    f"{rel(path)}:{number}: '{symbol}' needs iOS {since} but the "
                    f"deployment target is 16.0 and no #available guard is nearby"
                )


def check_protocol_conformance() -> None:
    """Heuristic: a declared conformer that never mentions a protocol requirement.

    Name-based, not signature-based, and aware of protocol-extension defaults. It
    exists because a test double missing a newly added protocol member fails the whole
    test target, which is a slow and confusing way to learn about it. Generics and
    class inheritance can make it cry wolf, hence a warning.
    """
    files = swift_files(SWIFT_ROOTS)
    sources = {rel(p): p.read_text(encoding="utf-8", errors="replace") for p in files}

    requirements: dict[str, set[str]] = {}
    defaults: dict[str, set[str]] = {}
    for text in sources.values():
        for match in re.finditer(r"^protocol\s+(\w+)[^{]*\{", text, re.M):
            name = match.group(1)
            body = _block_after(text, match.end() - 1)
            members = set(re.findall(r"^\s*(?:static\s+)?func\s+(\w+)", body, re.M))
            members |= set(re.findall(r"^\s*(?:static\s+)?var\s+(\w+)\s*:[^{]*\{\s*get", body, re.M))
            # A requirement with a body is a default, not a requirement.
            requirements[name] = members
        for match in re.finditer(r"^extension\s+(\w+)\s*\{", text, re.M):
            name = match.group(1)
            body = _block_after(text, match.end() - 1)
            defaults.setdefault(name, set()).update(re.findall(r"\bfunc\s+(\w+)", body))
            defaults.setdefault(name, set()).update(re.findall(r"\bvar\s+(\w+)\s*:", body))

    for filename, text in sources.items():
        for match in re.finditer(
            r"^(?:@\w+(?:\([^)]*\))?\s+)*(?:public\s+|final\s+|private\s+|internal\s+)*"
            r"(?:class|struct|actor|enum)\s+(\w+)\s*:\s*([^{\n]+)\{",
            text,
            re.M,
        ):
            type_name, inherits = match.group(1), match.group(2)
            conformed = [p.strip().split("<")[0] for p in inherits.split(",")]
            body = _block_after(text, match.end() - 1)
            # Members can also live in `extension TypeName { ... }` anywhere in the repo.
            for other in sources.values():
                for ext in re.finditer(rf"^extension\s+{re.escape(type_name)}\b[^{{]*\{{", other, re.M):
                    body += _block_after(other, ext.end() - 1)
            for protocol in conformed:
                for member in sorted(requirements.get(protocol, set())):
                    if member in defaults.get(protocol, set()):
                        continue
                    if not re.search(rf"\b{re.escape(member)}\b", body):
                        warn(
                            f"{filename}: {type_name} conforms to {protocol} but never "
                            f"mentions '{member}' - missing requirement?"
                        )


def _block_after(text: str, brace_index: int) -> str:
    """Return the source between a '{' and its matching '}'."""
    depth, i, n = 0, brace_index, len(text)
    start = brace_index + 1
    while i < n:
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return text[start:i]
        i += 1
    return text[start:]


CHECKS = [
    ("swift syntax", "exact with swiftc -parse; bracket balancing as a fallback"),
    ("project.yml", "valid YAML, source paths exist, schemes name real targets"),
    ("bgtask ids", "registered identifiers are declared, and 'processing' mode is present"),
    ("info.plist", "the committed generated plist matches project.yml"),
    ("localization", "en/ru key parity, duplicates, format specifiers, dangling keys"),
    ("fixtures", "every loadFixture() name resolves to a file"),
    ("duplicate types", "no top-level type declared twice"),
    ("ios availability", "post-iOS-16 API without a guard (HEURISTIC - warns only)"),
    ("protocol conformance", "conformer missing a requirement (HEURISTIC - warns only)"),
]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--strict", action="store_true", help="fail on warnings too")
    parser.add_argument("--list", action="store_true", help="describe the checks and exit")
    args = parser.parse_args()

    if args.list:
        for name, description in CHECKS:
            print(f"  {name:22} {description}")
        return 0

    project = load_project()
    check_swift_syntax()
    check_project(project)
    check_background_task_ids(project)
    check_info_plist(project)
    check_localization()
    check_fixtures()
    check_duplicate_types()
    check_ios_availability()
    check_protocol_conformance()

    for message in warnings:
        print(f"warning: {message}")
    for message in errors:
        print(f"error: {message}")

    print(
        f"\nprecheck: {len(errors)} error(s), {len(warnings)} warning(s) "
        f"across {len(swift_files(SWIFT_ROOTS))} Swift files"
    )
    if not errors:
        print("This is a static pre-flight, NOT a compile. CI is the authority.")

    if errors or (args.strict and warnings):
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
