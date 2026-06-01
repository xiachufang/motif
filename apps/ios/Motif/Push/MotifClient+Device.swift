import Foundation
import TalkerCommonLogging

// Push device registration RPCs. The device token + per-device AES-256-GCM
// key are uploaded to the connected motifd over the authenticated RPC channel
// — the relay never sees the key, so notification content is end-to-end
// encrypted (the Notification Service Extension decrypts on device).
//
// NOTE: this file is NOT yet a member of the Motif target — add it in Xcode
// alongside PushManager.swift. See the push wiring checklist.
extension MotifClient {
    /// Register this device's APNs token + encryption key with the connected
    /// motifd. Safe to call repeatedly (server upserts by token). No-op when
    /// not connected.
    func registerDevice(token: String, encKeyBase64: String, environment: String) async {
        guard let rpc else { return }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        do {
            let r = try await rpc.call(
                "device.register",
                params: MotifProto.DeviceRegisterParams(
                    device_token: token,
                    platform: "ios",
                    environment: environment,
                    enc_key: encKeyBase64,
                    app_version: version
                ),
                as: MotifProto.DeviceRegisterResult.self
            )
            log.notice("device registered; motifd instance=\(r.instance_id, privacy: .public)")
            PushManager.shared.noteRegistered(instanceID: r.instance_id)
        } catch {
            infoLog("[Push] device.register failed: \(error)")
        }
    }

    /// Best-effort unregister (e.g. on sign-out / server removal).
    func unregisterDevice(token: String) async {
        guard let rpc else { return }
        _ = try? await rpc.call(
            "device.unregister",
            params: MotifProto.DeviceUnregisterParams(device_token: token)
        )
    }
}
