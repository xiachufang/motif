# Motif shell integration for PowerShell 5.1 and PowerShell 7+.
# Dot-sourced by motifd after the user's normal profile has loaded.

if ($global:__MotifShellIntegrationLoaded) { return }
$global:__MotifShellIntegrationLoaded = $true
$script:__MotifEscape = [char]27

function global:__MotifHex([string] $Text) {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    return (($bytes | ForEach-Object { $_.ToString('x2') }) -join '')
}

function global:__MotifMarker([string] $Code, [string] $Payload = $null) {
    if (-not $PSBoundParameters.ContainsKey('Payload')) {
        return "$($script:__MotifEscape)]7777;$Code`a"
    }
    return "$($script:__MotifEscape)]7777;$Code;$Payload`a"
}

# PowerShell's `$?` covers PowerShell commands while `$LASTEXITCODE` covers
# native applications. The history/error correlation mirrors Windows
# Terminal's documented shell-integration prompt so a stale native exit code
# is not reported for a PowerShell exception.
function global:__MotifLastExitCode([bool] $Succeeded) {
    if ($Succeeded) { return 0 }

    $lastHistoryEntry = Get-History -Count 1
    if ($null -ne $lastHistoryEntry -and $Error.Count -gt 0) {
        $invocation = $Error[0].InvocationInfo
        if ($null -ne $invocation -and $invocation.HistoryId -eq $lastHistoryEntry.Id) {
            return -1
        }
    }
    if ($null -ne $global:LASTEXITCODE) { return [int] $global:LASTEXITCODE }
    return -1
}

function global:__MotifContext {
    $context = [ordered]@{}
    if (Get-Command git -ErrorAction SilentlyContinue) {
        $branch = (& git symbolic-ref --short HEAD 2>$null)
        $head = (& git rev-parse --short HEAD 2>$null)
        if ($branch) { $context.branch = "$branch".Trim() }
        if ($head) { $context.head = "$head".Trim() }
    }
    if ($env:VIRTUAL_ENV) { $context.venv = Split-Path $env:VIRTUAL_ENV -Leaf }
    if ($env:CONDA_DEFAULT_ENV) { $context.conda = $env:CONDA_DEFAULT_ENV }
    return ($context | ConvertTo-Json -Compress)
}

$script:__MotifOriginalPrompt = $function:global:prompt
$script:__MotifOriginalReadLine = $function:global:PSConsoleHostReadLine
$script:__MotifLastHistoryId = -1

function global:prompt {
    # This must remain the first statement: any command run before capturing
    # `$?` would overwrite the status of the command that just completed.
    $succeeded = $?
    $exitCode = __MotifLastExitCode -Succeeded $succeeded
    $lastHistoryEntry = Get-History -Count 1

    $prefix = ''
    if ($script:__MotifLastHistoryId -ne -1) {
        if ($null -eq $lastHistoryEntry -or
            $lastHistoryEntry.Id -eq $script:__MotifLastHistoryId) {
            # No new history item means an empty line or Ctrl+C. Finish the
            # region without inventing a success/failure result.
            $prefix += __MotifMarker 'D'
        } else {
            $prefix += __MotifMarker 'D' "$exitCode"
        }
    }
    $prefix += __MotifMarker 'A'
    try {
        $cwdPath = (Get-Location).ProviderPath
        $cwdUri = if ($cwdPath.StartsWith('\\')) {
            $cwdPath
        } else {
            ([UriBuilder]::new('file', '', -1, $cwdPath)).Uri.AbsoluteUri
        }
    } catch {
        $cwdUri = (Get-Location).Path
    }
    $prefix += __MotifMarker 'P' "Cwd=$cwdUri"
    $prefix += __MotifMarker 'P' "Context=$(__MotifHex (__MotifContext))"

    $rendered = if ($script:__MotifOriginalPrompt) {
        & $script:__MotifOriginalPrompt
    } else {
        "PS $((Get-Location).Path)> "
    }
    $script:__MotifLastHistoryId = if ($null -eq $lastHistoryEntry) {
        $null
    } else {
        $lastHistoryEntry.Id
    }
    return "$prefix$rendered$(__MotifMarker 'B')"
}

# PSReadLine is the only reliable point between accepting a line and executing
# it. Preserve a profile-provided implementation when present; otherwise call
# PSReadLine's public static entry point.
function global:PSConsoleHostReadLine {
    if ($script:__MotifOriginalReadLine) {
        $line = & $script:__MotifOriginalReadLine
    } elseif ('Microsoft.PowerShell.PSConsoleReadLine' -as [type]) {
        $line = [Microsoft.PowerShell.PSConsoleReadLine]::ReadLine(
            $Host.Runspace,
            $ExecutionContext
        )
    } else {
        $line = [Console]::ReadLine()
    }
    [Console]::Write((__MotifMarker 'E' (__MotifHex "$line")))
    [Console]::Write((__MotifMarker 'C'))
    return $line
}

if ($env:MOTIF_HOOK_URL -and $env:MOTIF_CLAUDE_SETTINGS) {
    function global:claude {
        $app = Get-Command claude -CommandType Application -ErrorAction Stop |
            Select-Object -First 1
        & $app.Source --settings $env:MOTIF_CLAUDE_SETTINGS @args
    }
}

if ($env:MOTIF_HOOK_URL -and $env:MOTIF_CODEX_NOTIFY) {
    function global:codex {
        $app = Get-Command codex -CommandType Application -ErrorAction Stop |
            Select-Object -First 1
        $escaped = $env:MOTIF_CODEX_NOTIFY.Replace('\\', '\\\\').Replace('"', '\"')
        $hookConfig = 'hooks.Stop=[{hooks=[{type="command",command="' + $escaped + '"}]}]'
        & $app.Source -c $hookConfig @args
    }
}
