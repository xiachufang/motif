# Motif coding-agent notification hook, installed explicitly from the desktop
# app. It is globally discoverable by the agents but inert outside Motif PTYs.

try {
    if ($env:MOTIF_BOOTSTRAPPED -ne '1' -or
        $env:TERM_PROGRAM -ne 'motif' -or
        [string]::IsNullOrWhiteSpace($env:MOTIF_SESSION_ID) -or
        [string]::IsNullOrWhiteSpace($env:MOTIF_HOOK_URL) -or
        [string]::IsNullOrWhiteSpace($env:MOTIF_HOOK_TOKEN)) {
        exit 0
    }

    $body = [Console]::In.ReadToEnd()
    $headers = @{
        'X-Motif-Session' = if ($env:MOTIF_SESSION_NAME) { $env:MOTIF_SESSION_NAME } else { '' }
        'X-Motif-Pty' = if ($env:MOTIF_SESSION_ID) { $env:MOTIF_SESSION_ID } else { '' }
        'X-Motif-Hook-Token' = $env:MOTIF_HOOK_TOKEN
    }
    Invoke-WebRequest `
        -Uri $env:MOTIF_HOOK_URL `
        -Method Post `
        -Headers $headers `
        -ContentType 'application/json' `
        -Body $body `
        -TimeoutSec 3 | Out-Null
} catch {
    # Best effort by design.
}

exit 0
