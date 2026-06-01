# iOS push (APNs) — status & remaining steps

Most of this is **done and building**. What's left is the Apple Developer
portal work + running the relay (neither can be done in this repo).

## Done (in the repo, builds on simulator)

- **Live / foreground channel**: a `notification` event over the events WS sets
  `MotifClient.latestNotification` + fires a haptic (`MotifClient+Events.swift`).
- **project.yml**: Push Notifications (`aps-environment` via `MOTIF_APS_ENV`,
  development in Debug / production in Release), App Groups
  (`group.io.allsunday.motif`), Keychain Sharing (`io.allsunday.motif.push`),
  and the **`MotifNotifyService`** notification-service-extension target,
  embedded into the app. `xcodegen generate` already run.
- **Source, in their targets**:
  - `Motif/Push/PushManager.swift`, `Motif/Push/MotifClient+Device.swift` (app)
  - `MotifNotifyService/NotificationService.swift` (extension; AES-GCM decrypt,
    layout matches the Rust `relay::tests::encrypt_roundtrips_with_aes_gcm`)
- **Activation wiring (done)**:
  - `MotifApp.swift`: `@UIApplicationDelegateAdaptor(MotifAppDelegate.self)`.
  - `ContentView.task`: sets `PushManager.shared.appState` + calls
    `requestAuthorizationAndRegister()`.
  - `MotifClient+Connection`: on every successful connect, fires
    `registerIfPossible(client:serverID:)` (idempotent `device.register`).
  - Deep-link: `AppState.pendingDeepLink` set on tap (`PushManager`), consumed
    by `SessionListView.consumeDeepLinkIfReady()` — switches to the mapped
    server if needed, then attaches + pushes the `/session` route.

## Remaining — Apple Developer portal (one-time, can't be scripted here)

1. App ID `io.allsunday.motif`: enable **Push Notifications** + **App Groups**
   (`group.io.allsunday.motif`). Automatic signing then provisions both the
   dev (sandbox) and distribution (production) entitlements as you build
   Debug/Release.
2. Create an **APNs Auth Key** (`.p8`); note **Key ID** + **Team ID**. It goes
   ONLY on the relay (never in motifd or the app).

## Remaining — run the relay + motifd

The relay is implemented at `crates/motif-push-relay` (see its README):

```sh
cargo run -p motif-push-relay -- \
  --apns-key-path AuthKey_XXXX.p8 --apns-key-id XXXX --apns-team-id UWNR93L682
motifd --push-relay-url http://127.0.0.1:8088/v1/push   # https in production
```

## Verify end-to-end

1. Install a Debug build on a real device (push needs a device, not the
   simulator). Grant the notification prompt.
2. Confirm `device.register` reaches motifd — the device shows up in the
   in-memory store (add a temporary log, or watch the relay receive a push).
3. Background/kill the app; trigger a Claude Code Notification/Stop hook in a
   motif PTY; the encrypted push should arrive and the **service extension**
   should decrypt it to the real title/body (a "🔒 New notification" placeholder
   means the key isn't shared — recheck the Keychain group on both targets).
4. Tap it → app routes to the originating session.
