//! Detect machine wake-from-sleep by watching `SystemTime` advance faster
//! than `Instant`.
//!
//! On macOS `Instant::now()` (mach_absolute_time / CLOCK_UPTIME_RAW) does
//! NOT count time spent asleep, while `SystemTime::now()` does. A tokio
//! `sleep(2s)` parked across a sleep/wake cycle therefore observes a
//! ~2s Instant delta but a wall-clock delta equal to the actual sleep
//! duration. The discrepancy is the wake signal.
//!
//! Linux behaviour: `CLOCK_MONOTONIC` (which `Instant` uses on Linux) DOES
//! count suspend on most kernels, so this detector won't trigger on Linux
//! laptop suspend. That's fine — the motivating bug is Mac-specific.

use std::time::{Duration, Instant, SystemTime};

/// Spawn the wake-detector task. Cheap (two clock reads + a subtract per
/// tick) and decoupled from any other subsystem, so it runs unconditionally.
pub fn spawn() -> tokio::task::JoinHandle<()> {
    const TICK: Duration = Duration::from_secs(2);
    /// Wake-detection threshold. Anything below this is normal scheduler
    /// jitter; above is a real wall-clock jump worth surfacing.
    const WAKE_THRESHOLD: Duration = Duration::from_secs(10);

    tokio::spawn(async move {
        let mut last_inst = Instant::now();
        let mut last_wall = SystemTime::now();
        loop {
            tokio::time::sleep(TICK).await;
            let now_inst = Instant::now();
            let now_wall = SystemTime::now();

            let inst_delta = now_inst.saturating_duration_since(last_inst);
            let wall_delta = now_wall.duration_since(last_wall).unwrap_or(Duration::ZERO);

            if let Some(gap) = wall_delta.checked_sub(inst_delta) {
                if gap >= WAKE_THRESHOLD {
                    tracing::warn!(
                        target: "motif_server::wake",
                        slept_secs   = gap.as_secs(),
                        wall_secs    = wall_delta.as_secs(),
                        monotonic_ms = inst_delta.as_millis() as u64,
                        "system wake detected — wall clock advanced \
                         much faster than monotonic clock during a tick"
                    );
                }
            }

            last_inst = now_inst;
            last_wall = now_wall;
        }
    })
}
