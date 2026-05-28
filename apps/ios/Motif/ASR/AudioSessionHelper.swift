import AVFoundation

/// Caller-side glue the upstream `DoubaoASR` package deliberately doesn't own:
/// mic permission + AVAudioSession activation. Settings mirror the previous
/// in-tree `AudioCapture` so behaviour with Bluetooth / background audio is
/// unchanged.
@MainActor
enum AudioSessionHelper {
    /// Returns nil on success, or a user-facing error string on denial / failure.
    static func prepareForRecording() async -> String? {
        let granted = await AVAudioApplication.requestRecordPermission()
        guard granted else { return "Microphone permission denied" }
        do {
            let s = AVAudioSession.sharedInstance()
            try s.setCategory(.playAndRecord, mode: .measurement,
                              options: [.allowBluetoothHFP, .defaultToSpeaker, .mixWithOthers])
            try s.setActive(true, options: [])
            return nil
        } catch {
            return "Audio session error: \(error.localizedDescription)"
        }
    }

    static func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }
}
