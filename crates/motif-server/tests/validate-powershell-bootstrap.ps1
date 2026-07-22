$ErrorActionPreference = 'Stop'

$bootstrap = Join-Path $PSScriptRoot '..\assets\shell\powershell.ps1'
$tokens = $null
$parseErrors = $null
[System.Management.Automation.Language.Parser]::ParseFile(
    $bootstrap,
    [ref] $tokens,
    [ref] $parseErrors
) | Out-Null
if ($parseErrors.Count -ne 0) {
    throw ($parseErrors | Out-String)
}

# Keep the smoke test deterministic and independent of the runner's profile.
function global:prompt { 'USER> ' }
$global:FakeHistoryId = $null
function global:Get-History {
    if ($null -ne $global:FakeHistoryId) {
        [pscustomobject]@{ Id = $global:FakeHistoryId }
    }
}

. $bootstrap

$first = [string] (prompt)
if (-not $first.Contains((__MotifMarker 'A')) -or
    -not $first.Contains((__MotifMarker 'B')) -or
    $first.Contains((__MotifMarker 'D'))) {
    throw 'The initial prompt emitted an invalid lifecycle.'
}

$empty = [string] (prompt)
if (-not $empty.Contains((__MotifMarker 'D'))) {
    throw 'An empty line or Ctrl+C must finish without an exit code.'
}

$global:FakeHistoryId = 7
$completed = [string] (prompt)
if (-not $completed.Contains((__MotifMarker 'D' '0'))) {
    throw 'A new history entry must finish with its exit code.'
}

$Error.Clear()
$global:LASTEXITCODE = 23
if ((__MotifLastExitCode -Succeeded $false) -ne 23) {
    throw 'The native application exit code was not preserved.'
}

# GitHub Actions' PowerShell wrapper exits with the final $LASTEXITCODE when
# the variable exists. Do not let the deliberately injected test value make a
# successful validation step report failure.
$global:LASTEXITCODE = 0

Write-Output 'PowerShell bootstrap validation passed.'
