import Foundation
import Combine

struct BambuTokens: Codable, Equatable {
    var accessToken: String
    var refreshToken: String
    var userID: String
    var savedAt: Date

    var mqttUsername: String { "u_\(userID)" }
}

struct BambuCloudDevice: Codable, Identifiable, Hashable {
    let dev_id: String
    let name: String
    let online: Bool?
    let dev_access_code: String?
    let print_status: String?

    var id: String { dev_id }
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
           let t = try? JSONDecoder().decode(BambuTokens.self, from: data) {
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
        let uid = decodeUserID(from: access) ?? ""
        let tokens = BambuTokens(accessToken: access, refreshToken: refresh, userID: uid, savedAt: Date())
        self.tokens = tokens
        if let encoded = try? JSONEncoder().encode(tokens) {
            UserDefaults.standard.set(encoded, forKey: tokensKey)
        }
    }

    private func decodeUserID(from jwt: String) -> String? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
        let rem = payload.count % 4
        if rem > 0 { payload += String(repeating: "=", count: 4 - rem) }
        let urlSafe = payload.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        guard let data = Data(base64Encoded: urlSafe),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let u = obj["username"] as? String { return u }
        if let u = obj["userId"] as? String { return u }
        if let u = obj["uid"] as? String { return u }
        if let u = obj["uid"] as? Int { return String(u) }
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
