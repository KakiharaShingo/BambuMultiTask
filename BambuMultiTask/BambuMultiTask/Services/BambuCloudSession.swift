import Foundation
import Combine

struct BambuTokens: Codable, Equatable {
    var accessToken: String
    var refreshToken: String
    var userID: String
    var savedAt: Date

    var mqttUsername: String { "u_\(userID)" }
}

struct BambuCloudDevice: Identifiable, Hashable {
    let dev_id: String
    let name: String
    let online: Bool?
    let dev_access_code: String?
    let print_status: String?

    var id: String { dev_id }
}

extension BambuCloudDevice: Codable {
    enum CodingKeys: String, CodingKey {
        case dev_id, name, online, print_status
        case dev_access_code
        case access_code       // P2S 等の代替フィールド名
        case password          // さらに別の代替
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        dev_id = try c.decode(String.self, forKey: .dev_id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        online = try c.decodeIfPresent(Bool.self, forKey: .online)
        print_status = try c.decodeIfPresent(String.self, forKey: .print_status)
        // access code は複数の候補名から最初に空でないものを採用
        let candidates: [CodingKeys] = [.dev_access_code, .access_code, .password]
        var code: String? = nil
        for k in candidates {
            if let v = try c.decodeIfPresent(String.self, forKey: k), !v.isEmpty {
                code = v
                break
            }
        }
        dev_access_code = code
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(dev_id, forKey: .dev_id)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(online, forKey: .online)
        try c.encodeIfPresent(dev_access_code, forKey: .dev_access_code)
        try c.encodeIfPresent(print_status, forKey: .print_status)
    }
}

enum BambuCloudError: LocalizedError {
    case badResponse
    case needsVerification
    case loginFailed(String)
    case notAuthenticated
    case network(Error)

    var errorDescription: String? {
        switch self {
        case .badResponse: return "予期しないレスポンス"
        case .needsVerification: return "メール認証コードが必要です"
        case .loginFailed(let msg): return "ログイン失敗: \(msg)"
        case .notAuthenticated: return "未ログイン"
        case .network(let e): return e.localizedDescription
        }
    }
}

@MainActor
final class BambuCloudSession: ObservableObject {
    @Published private(set) var tokens: BambuTokens?
    @Published private(set) var devices: [BambuCloudDevice] = []
    @Published var region: BambuRegion = .us {
        didSet { UserDefaults.standard.set(region.rawValue, forKey: regionKey) }
    }
    @Published private(set) var lastError: String?

    var isLoggedIn: Bool { tokens != nil }
    var mqttHost: String { region.mqttHost }

    private let tokensKey = "bambuCloudTokens.v1"
    private let regionKey = "bambuCloudRegion.v1"

    init() {
        if let saved = UserDefaults.standard.string(forKey: regionKey),
           let r = BambuRegion(rawValue: saved) {
            self.region = r
        }
        if let data = UserDefaults.standard.data(forKey: tokensKey),
           var t = try? JSONDecoder().decode(BambuTokens.self, from: data) {
            if t.userID.isEmpty, let uid = Self.decodeUserID(from: t.accessToken), !uid.isEmpty {
                t.userID = uid
                if let encoded = try? JSONEncoder().encode(t) {
                    UserDefaults.standard.set(encoded, forKey: tokensKey)
                }
            }
            self.tokens = t
        }
    }

    func logout() {
        tokens = nil
        devices = []
        UserDefaults.standard.removeObject(forKey: tokensKey)
    }

    func login(email: String, password: String) async throws {
        let url = region.apiURL.appendingPathComponent("/v1/user-service/user/login")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["account": email, "password": password, "apiError": ""]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        try await perform(loginRequest: req)
    }

    func requestEmailCode(email: String) async throws {
        let url = region.apiURL.appendingPathComponent("/v1/user-service/user/sendemail/code")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["email": email, "type": "codeLogin"]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (_, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw BambuCloudError.loginFailed("コード送信失敗")
        }
    }

    func loginWithEmailCode(email: String, code: String) async throws {
        let url = region.apiURL.appendingPathComponent("/v1/user-service/user/login")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["account": email, "code": code]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        try await perform(loginRequest: req)
    }

    func fetchDevices() async throws {
        guard let tokens else { throw BambuCloudError.notAuthenticated }
        let url = region.apiURL.appendingPathComponent("/v1/iot-service/api/user/bind")
        var req = URLRequest(url: url)
        req.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw BambuCloudError.badResponse
        }
        struct Wrapper: Decodable {
            let devices: [BambuCloudDevice]
        }
        let wrapper = try JSONDecoder().decode(Wrapper.self, from: data)
        self.devices = wrapper.devices
    }

    private func perform(loginRequest req: URLRequest) async throws {
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw BambuCloudError.badResponse }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BambuCloudError.badResponse
        }
        if http.statusCode >= 400 {
            let msg = obj["message"] as? String ?? "HTTP \(http.statusCode)"
            throw BambuCloudError.loginFailed(msg)
        }
        if let loginType = obj["loginType"] as? String, loginType == "verifyCode" {
            throw BambuCloudError.needsVerification
        }
        guard let access = obj["accessToken"] as? String, !access.isEmpty else {
            if let msg = obj["message"] as? String { throw BambuCloudError.loginFailed(msg) }
            throw BambuCloudError.badResponse
        }
        let refresh = obj["refreshToken"] as? String ?? ""
        var uid = Self.extractUserID(fromLoginResponse: obj)
            ?? Self.decodeUserID(from: access)
            ?? ""
        if uid.isEmpty {
            NSLog("BambuCloud: uid not in login response/JWT, trying profile API")
            uid = (try? await Self.fetchUserID(accessToken: access, region: region)) ?? ""
        }
        if uid.isEmpty {
            NSLog("BambuCloud: could not extract userID; MQTT auth will fail")
        } else {
            NSLog("BambuCloud: resolved userID=\(uid)")
        }
        let tokens = BambuTokens(accessToken: access, refreshToken: refresh, userID: uid, savedAt: Date())
        self.tokens = tokens
        if let encoded = try? JSONEncoder().encode(tokens) {
            UserDefaults.standard.set(encoded, forKey: tokensKey)
        }
    }

    func refreshUserIDIfNeeded() async {
        guard var t = tokens, t.userID.isEmpty else { return }
        if let uid = try? await Self.fetchUserID(accessToken: t.accessToken, region: region), !uid.isEmpty {
            t.userID = uid
            self.tokens = t
            if let encoded = try? JSONEncoder().encode(t) {
                UserDefaults.standard.set(encoded, forKey: tokensKey)
            }
            NSLog("BambuCloud: refreshed userID=\(uid)")
        }
    }

    static func fetchUserID(accessToken: String, region: BambuRegion) async throws -> String? {
        let candidates = [
            "/v1/user-service/my/profile",
            "/v1/user-service/my/account",
            "/v1/user-service/my/preference"
        ]
        for path in candidates {
            let url = region.apiURL.appendingPathComponent(path)
            var req = URLRequest(url: url)
            req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            guard let (data, resp) = try? await URLSession.shared.data(for: req),
                  let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            NSLog("BambuCloud: profile \(path) keys=\(Array(obj.keys))")
            if let uid = extractUserID(fromLoginResponse: obj) { return uid }
            if let userInfo = obj["userInfo"] as? [String: Any],
               let uid = extractUserID(fromLoginResponse: userInfo) { return uid }
        }
        return nil
    }

    static func extractUserID(fromLoginResponse obj: [String: Any]) -> String? {
        for key in ["uidStr", "uid", "userId", "user_id", "username"] {
            if let s = obj[key] as? String, !s.isEmpty {
                return s.hasPrefix("u_") ? String(s.dropFirst(2)) : s
            }
            if let n = obj[key] as? Int { return String(n) }
        }
        return nil
    }

    static func decodeUserID(from jwt: String) -> String? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
        let rem = payload.count % 4
        if rem > 0 { payload += String(repeating: "=", count: 4 - rem) }
        let urlSafe = payload.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        guard let data = Data(base64Encoded: urlSafe),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            NSLog("BambuCloud: JWT payload decode failed")
            return nil
        }
        NSLog("BambuCloud: JWT payload keys=\(Array(obj.keys))")
        for key in ["username", "preferred_username", "sub", "userId", "user_id", "uid", "uidStr"] {
            if let s = obj[key] as? String, !s.isEmpty {
                return s.hasPrefix("u_") ? String(s.dropFirst(2)) : s
            }
            if let n = obj[key] as? Int { return String(n) }
        }
        return nil
    }
}

enum BambuRegion: String, CaseIterable, Identifiable {
    case us = "US"
    case china = "CN"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .us: return "グローバル (bambulab.com)"
        case .china: return "中国 (bambulab.cn)"
        }
    }

    var apiURL: URL {
        switch self {
        case .us: return URL(string: "https://api.bambulab.com")!
        case .china: return URL(string: "https://api.bambulab.cn")!
        }
    }

    var mqttHost: String {
        switch self {
        case .us: return "us.mqtt.bambulab.com"
        case .china: return "cn.mqtt.bambulab.com"
        }
    }
}
