# Flutter desktop PTY restore performance investigation

Date: 2026-07-11

## Summary

Flutter desktop PTY restore latency is dominated by local PTY decoding,
Ghostty ingestion, and restore scheduling rather than transport setup.

The active PTY starts first, but the current staged restore only waits for its
WebSocket to become ready. After the 32 ms background delay, other PTYs begin
restoring before the active PTY has finished consuming its replay. All PTYs
share the upstream `PtyFrameProcessor`, so background replay competes with the
active PTY. A busy terminal also produces many small live frames, each of which
crosses isolates and is fed to Ghostty separately.

This combination makes the active terminal take longer to catch up to live
output. The effect should grow with the number of tabs, replay size, and live
output rate.

## Reproduction

The issue was reproduced against the local embedded server with the macOS
Flutter desktop client. A dedicated shell PTY generated numbered lines with a
short delay while the client was restarted and reattached.

The test kept the server-side PTY alive, reopened the session while output was
still being generated, and compared these stages:

1. server connection and session attach;
2. PTY WebSocket ready and first decoded output;
3. TerminalWorker queue delay and Ghostty feed time;
4. the first non-empty terminal snapshot and subsequent live-frame queue lag.

The synthetic output process was stopped after the measurement. Its test tab
was left open rather than deleting user-visible terminal state automatically.

## Measurements

Representative desktop measurements:

| Stage | Observed time |
| --- | ---: |
| Server connection | 124–173 ms |
| Session attach | 88–99 ms |
| Active PTY WebSocket to first decoded bytes | 102–106 ms |
| Feed a 58,398-byte restore snapshot into Ghostty | 224.7 ms |
| Initial live-frame queue lag behind that feed | 231–234 ms |
| First content-bearing worker snapshot after attach began | about 550 ms |
| Steady-state queue lag after catch-up | under 10 µs in the test |

The network-to-terminal sink path stayed synchronized (`queuedBytes=0`). This
rules out the connection, WebSocket, and Flutter main-isolate byte queue as the
primary cause in the desktop reproduction.

The first large Ghostty feed was the largest single measured cost. While that
feed was running, hundreds of small live frames accumulated. The queue drained
after the worker warmed up, but this creates a visible stale/blank interval.

## Contributing implementation details

### Background restore begins before active replay completes

`DesktopMotifClientRuntime` restores the active PTY first, then waits 32 ms
before adding each background PTY. `syncPtyStreams` completes when sockets are
open; it does not mean that the active replay has been decoded and consumed.

Consequently, background snapshot decoding can begin while the active PTY is
still catching up. The shared `PtyFrameProcessor` makes this contention visible
even though each rendered terminal owns its own TerminalWorker isolate.

### Small live frames have high per-frame overhead

The sustained-output reproduction produced roughly 189-byte frames. Each frame
was independently:

- received and decoded by `PtyFrameProcessor`;
- transferred back to the client isolate;
- copied/queued for the terminal surface;
- transferred to TerminalWorker;
- passed to Ghostty through FFI.

The worker could eventually keep up, but the per-frame path magnified the queue
created by the initial large snapshot feed.

### Cold desktop attach has no reusable local terminal state

After a client restart, PTY cursors alone cannot reconstruct the local Ghostty
state, so each mounted terminal needs a server replay or snapshot. Restoring all
background tabs immediately increases startup work even though only the active
tab affects perceived readiness.

## Diagnostic instrumentation added

Instrumentation now records:

- application pause/resume and reconnect decisions;
- transport resolution, direct probing, ping, attach, and reconnect stages;
- events and PTY WebSocket readiness;
- first decoded PTY output;
- server-declared replay byte count and replay completion;
- TerminalWorker enqueue delay, Ghostty feed duration, and snapshot duration.

The framed PTY meta response now includes optional `replay_bytes`. Older servers
remain compatible; clients log it as unknown until the server is upgraded.

## Recommended optimization order

1. Gate background PTY restoration on active replay completion, not merely
   active WebSocket readiness. Add a small upper-bound timeout so a broken
   active stream cannot block background tabs forever.
2. Coalesce small live PTY chunks before crossing into TerminalWorker, using a
   short time/size budget such as 8–16 ms or 32–64 KiB. Preserve low latency for
   interactive echo.
3. Avoid publishing the initial blank TerminalWorker snapshot when restore
   bytes are already pending, or replace it as soon as the first feed completes.
4. Re-measure with multiple large-scrollback tabs and rendezvous transport.

## Implementation status

Implemented on 2026-07-11:

- The active PTY now exposes a replay-completion future. Desktop background
  restore waits for it, with a 750 ms compatibility timeout for older servers
  that do not advertise `replay_bytes`.
- Terminal surfaces coalesce small remote chunks for up to 8 ms or 32 KiB
  before crossing into TerminalWorker. Output immediately following local
  input bypasses the delay to preserve interactive echo latency.
- A new worker can wait for its first PTY feed before publishing a snapshot.
  New/empty terminals have a 100 ms fallback; worker recovery for the same PTY
  keeps the previous UI snapshot until fresh terminal content is available.

The existing desktop server used during compatibility testing did not yet
advertise `replay_bytes`. Its fallback trace showed the active terminal's first
content-bearing snapshot at 09:45:57.805 and background restore beginning at
09:45:57.861, so background work no longer overlapped the visible restore in
that run.

## Suggested success criteria

- Active PTY reaches replay-complete before background PTY replay begins.
- Local/direct desktop restore displays active PTY content within 300 ms for a
  typical snapshot.
- Active PTY catches up to live output within 500 ms under the synthetic
  sustained-output workload.
- Adding background tabs does not materially change active PTY readiness.
- Interactive input remains responsive while chunk coalescing is enabled.

## Verification performed

- `flutter analyze --no-pub`
- Flutter tests covering TerminalWorker, connection lifecycle, and reconnect
- `cargo fmt --check`
- `cargo test -p motif-server pty_ws --lib`

All checks passed during the investigation.
