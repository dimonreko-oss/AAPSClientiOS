# Installs a pre-push hook that runs scripts/precheck.py.
#
# The point is cycle time, not gatekeeping: a CI round trip on the macOS runner is
# ~10 minutes, and the mistakes precheck catches (a dangling localization key, a
# fixture that does not exist, a stale Info.plist) are not worth one. CI re-runs the
# same script anyway, so bypassing the hook with `git push --no-verify` costs you
# nothing except finding out later.
#
#   powershell -ExecutionPolicy Bypass -File scripts/install-hooks.ps1
#   powershell -ExecutionPolicy Bypass -File scripts/install-hooks.ps1 -Uninstall
#
# ASCII only, deliberately: Windows PowerShell 5.1 reads a .ps1 with no BOM using the
# system ANSI codepage, so a stray em dash in a comment is a parser error on a
# non-UTF-8 console.

param([switch]$Uninstall)

$ErrorActionPreference = "Stop"

$hooksDir = git rev-parse --git-path hooks
if ($LASTEXITCODE -ne 0) { throw "not inside a git repository" }
if (-not (Test-Path $hooksDir)) { New-Item -ItemType Directory -Force $hooksDir | Out-Null }

$hookPath = Join-Path $hooksDir "pre-push"

if ($Uninstall) {
    if (Test-Path $hookPath) {
        Remove-Item $hookPath -Confirm:$false
        Write-Host "removed $hookPath"
    } else {
        Write-Host "nothing to remove at $hookPath"
    }
    return
}

if (Test-Path $hookPath) {
    $existing = Get-Content $hookPath -Raw
    if ($existing -notmatch "precheck\.py") {
        throw "$hookPath already exists and is not ours. Inspect it before overwriting."
    }
}

# Git runs hooks through its bundled sh, from the repository root, on every platform.
# Python is spelled differently depending on how it was installed, so try the usual
# three. The probe RUNS each candidate instead of asking `command -v`: Windows ships
# an App Execution Alias at python3.exe that exists on PATH but only prints a Microsoft
# Store advert and exits 49, which would otherwise read as "precheck failed".
$hook = @'
#!/bin/sh
for py in python3 python py; do
    if "$py" -c "import sys" >/dev/null 2>&1; then
        "$py" scripts/precheck.py || {
            echo ""
            echo "pre-push blocked by scripts/precheck.py."
            echo "Fix the errors above, or bypass with: git push --no-verify"
            exit 1
        }
        exit 0
    fi
done
echo "pre-push: no python on PATH, skipping precheck" >&2
exit 0
'@

# LF endings and no BOM: Git's sh will not run a script with CRLF or a byte order mark.
$bytes = New-Object Text.UTF8Encoding $false
[IO.File]::WriteAllText($hookPath, ($hook -replace "`r`n", "`n"), $bytes)

Write-Host "installed $hookPath"
Write-Host "run it now with: python scripts/precheck.py"
