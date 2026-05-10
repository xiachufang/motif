import Foundation
import OSLog

/// One-time device registration with Doubao + the asr-token settings call.
/// The two requests are combined here because they are always run together
/// on first launch, and the resulting credentials are stored as one blob.
actor DeviceRegistry {
    private let log = Logger(subsystem: "io.allsunday.motif", category: "DeviceRegistry")
    private let keychain = Keychain(service: "io.allsunday.motif.doubao")
    private static let storageKey = "credentials.v1"

    struct Credentials: Codable, Sendable, Equatable {
        var deviceID: String
        var installID: String
        var cdid: String
        var openudid: String
        var clientudid: String
        var asrToken: String?
    }

    func loadCachedCredentials() -> Credentials? {
        keychain.getJSON(Credentials.self, forKey: Self.storageKey)
    }

    func clearCachedCredentials() {
        keychain.deleteData(forKey: Self.storageKey)
    }

    /// Either return cached creds (with token already populated) or run the
    /// full register + getToken pipeline and persist the result.
    func ensureCredentials() async throws -> Credentials {
        if let cached = loadCachedCredentials(), cached.asrToken?.isEmpty == false {
            return cached
        }
        var creds = try await registerDevice()
        creds.asrToken = try await fetchAsrToken(deviceID: creds.deviceID, cdid: creds.cdid)
        keychain.setJSON(creds, forKey: Self.storageKey)
        return creds
    }

    // MARK: - Register

    private func registerDevice() async throws -> Credentials {
        let cdid = Self.uuid()
        let openudid = Self.openUDID()
        let clientudid = Self.uuid()

        // Build the URL with the params required by `device_register/`.
        let now = Self.nowMillis()
        var components = URLComponents(url: DoubaoConst.registerURL, resolvingAgainstBaseURL: false)!
        components.queryItems = registerParams(cdid: cdid, rticket: now).map { URLQueryItem(name: $0.0, value: $0.1) }
        let url = components.url!

        // Body: { magic_tag, header: {...}, _gen_time }
        var header: [String: Any] = [
            "device_id": 0, "install_id": 0,
            "openudid": openudid, "clientudid": clientudid, "cdid": cdid,
            "region": "CN", "tz_name": "Asia/Shanghai", "tz_offset": 28800,
            "sim_region": "cn", "carrier_region": "cn",
            "cpu_abi": "arm64-v8a", "build_serial": "unknown",
            "not_request_sender": 0, "sig_hash": "", "google_aid": "",
            "mc": "", "serial_number": ""
        ]
        for (k, v) in DoubaoConst.app    { header[k] = v }
        for (k, v) in DoubaoConst.device { header[k] = v }

        let body: [String: Any] = [
            "magic_tag": "ss_app_log",
            "header": header,
            "_gen_time": now
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: body, options: [])

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(DoubaoConst.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = bodyData

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw RegistrationError.badStatus(code: (response as? HTTPURLResponse)?.statusCode ?? -1, body: String(data: data, encoding: .utf8) ?? "")
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RegistrationError.malformedResponse("not a JSON object")
        }
        // device_id can come back as Int or String depending on path; coerce.
        let deviceID = Self.asString(obj["device_id"]) ?? Self.asString(obj["device_id_str"])
        let installID = Self.asString(obj["install_id"]) ?? Self.asString(obj["install_id_str"]) ?? ""
        guard let did = deviceID, did != "0" else {
            throw RegistrationError.malformedResponse("missing device_id in \(obj)")
        }
        log.notice("registered device \(did, privacy: .public)")
        return Credentials(
            deviceID: did,
            installID: installID,
            cdid: cdid,
            openudid: openudid,
            clientudid: clientudid,
            asrToken: nil
        )
    }

    private func registerParams(cdid: String, rticket: Int64) -> [(String, String)] {
        // Order is preserved deterministically via array of tuples — the
        // server doesn't care about order, but matching the upstream client
        // keeps risk-control fingerprints aligned.
        return [
            ("device_platform", "android"),
            ("os", "android"),
            ("ssmix", "a"),
            ("_rticket", String(rticket)),
            ("cdid", cdid),
            ("channel", DoubaoConst.app["channel"] as! String),
            ("aid", String(DoubaoConst.aid)),
            ("app_name", DoubaoConst.app["app_name"] as! String),
            ("version_code", String(DoubaoConst.app["version_code"] as! Int)),
            ("version_name", DoubaoConst.app["version_name"] as! String),
            ("manifest_version_code", String(DoubaoConst.app["manifest_version_code"] as! Int)),
            ("update_version_code", String(DoubaoConst.app["update_version_code"] as! Int)),
            ("resolution", DoubaoConst.device["resolution"] as! String),
            ("dpi", DoubaoConst.device["dpi"] as! String),
            ("device_type", DoubaoConst.device["device_type"] as! String),
            ("device_brand", DoubaoConst.device["device_brand"] as! String),
            ("language", DoubaoConst.device["language"] as! String),
            ("os_api", DoubaoConst.device["os_api"] as! String),
            ("os_version", DoubaoConst.device["os_version"] as! String),
            ("ac", "wifi")
        ]
    }

    // MARK: - ASR token

    private func fetchAsrToken(deviceID: String, cdid: String) async throws -> String {
        var components = URLComponents(url: DoubaoConst.settingsURL, resolvingAgainstBaseURL: false)!
        components.queryItems = settingsParams(deviceID: deviceID, cdid: cdid)
            .map { URLQueryItem(name: $0.0, value: $0.1) }
        let url = components.url!

        let bodyString = "body=null"
        let bodyData = Data(bodyString.utf8)
        let stub = Crypto.md5HexUppercased(bodyData)

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(DoubaoConst.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue(stub, forHTTPHeaderField: "x-ss-stub")
        req.httpBody = bodyData

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw RegistrationError.badStatus(code: (response as? HTTPURLResponse)?.statusCode ?? -1, body: String(data: data, encoding: .utf8) ?? "")
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataField = obj["data"] as? [String: Any],
              let settings = dataField["settings"] as? [String: Any],
              let asrConfig = settings["asr_config"] as? [String: Any],
              let appKey = asrConfig["app_key"] as? String
        else {
            throw RegistrationError.malformedResponse("no data.settings.asr_config.app_key")
        }
        return appKey
    }

    private func settingsParams(deviceID: String, cdid: String) -> [(String, String)] {
        return [
            ("device_platform", "android"),
            ("os", "android"),
            ("ssmix", "a"),
            ("_rticket", String(Self.nowMillis())),
            ("cdid", cdid),
            ("channel", DoubaoConst.app["channel"] as! String),
            ("aid", String(DoubaoConst.aid)),
            ("app_name", DoubaoConst.app["app_name"] as! String),
            ("version_code", String(DoubaoConst.app["version_code"] as! Int)),
            ("version_name", DoubaoConst.app["version_name"] as! String),
            ("device_id", deviceID)
        ]
    }

    // MARK: - Helpers

    private static func uuid() -> String { UUID().uuidString.lowercased() }

    private static func openUDID() -> String {
        // 16 hex chars, like Python's secrets.token_hex(8).
        var bytes = [UInt8](repeating: 0, count: 8)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func nowMillis() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    private static func asString(_ any: Any?) -> String? {
        switch any {
        case let s as String: return s
        case let i as Int:    return String(i)
        case let i as Int64:  return String(i)
        case let n as NSNumber: return n.stringValue
        default: return nil
        }
    }

    enum RegistrationError: Error, CustomStringConvertible {
        case badStatus(code: Int, body: String)
        case malformedResponse(String)

        var description: String {
            switch self {
            case .badStatus(let code, let body):
                let snippet = body.prefix(200)
                return "device-register HTTP \(code): \(snippet)"
            case .malformedResponse(let msg):
                return "device-register response malformed: \(msg)"
            }
        }
    }
}
