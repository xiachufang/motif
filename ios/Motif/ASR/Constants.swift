import Foundation

/// Frozen constants from the Doubao IME client (Pixel 7 Pro emulation).
/// All values copy faithfully from the upstream Python lib's constants.py.
enum DoubaoConst {
    static let aid: Int = 401734
    static let samiAppKey = "SYlxZr6LnvBaIVmF"

    // HKDF info string used for the Wave session key derivation.
    static let hkdfInfo = Data("4e30514609050cd3".utf8)

    // Endpoints
    static let registerURL  = URL(string: "https://log.snssdk.com/service/2/device_register/")!
    static let settingsURL  = URL(string: "https://is.snssdk.com/service/settings/v3/")!
    static let handshakeURL = URL(string: "https://keyhub.zijieapi.com/handshake")!
    static let websocketURL = URL(string: "wss://frontier-audio-ime-ws.doubao.com/ocean/api/v1/ws")!

    static let userAgent =
        "com.bytedance.android.doubaoime/100102018 (Linux; U; Android 16; en_US; Pixel 7 Pro; Build/BP2A.250605.031.A2; Cronet/TTNetVersion:94cf429a 2025-11-17 QuicVersion:1f89f732 2025-05-08)"

    /// Mirrors the upstream APP_CONFIG dictionary.
    static let app: [String: Any] = [
        "aid": aid,
        "app_name": "oime",
        "version_code": 100_102_018,
        "version_name": "1.1.2",
        "manifest_version_code": 100_102_018,
        "update_version_code": 100_102_018,
        "channel": "official",
        "package": "com.bytedance.android.doubaoime"
    ]

    /// Mirrors DEFAULT_DEVICE_CONFIG. Pixel 7 Pro on Android 16.
    static let device: [String: Any] = [
        "device_platform": "android",
        "os": "android",
        "os_api": "34",
        "os_version": "16",
        "device_type": "Pixel 7 Pro",
        "device_brand": "google",
        "device_model": "Pixel 7 Pro",
        "resolution": "1080*2400",
        "dpi": "420",
        "language": "zh",
        "timezone": 8,
        "access": "wifi",
        "rom": "UP1A.231005.007",
        "rom_version": "UP1A.231005.007"
    ]
}
