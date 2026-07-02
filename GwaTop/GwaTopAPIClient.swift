//
//  GwaTopAPIClient.swift
//  GwaTop
//
//  공통 백엔드 호출 헬퍼.
//  - baseURL은 한 곳에서 관리 (EC2 IP 변경 시 여기만 고치면 됨)
//  - Keychain에 저장된 JWT를 Bearer로 자동 부착
//  - JSON 인코딩/디코딩 (snake_case + ISO8601 with fractional seconds)
//

import Foundation
import Security

enum GwaTopAPIError: LocalizedError {
    case invalidURL
    case unauthorized
    case server(Int, String)
    case decoding(String)
    case transport(Error)

    var errorDescription: String? {
        switch self {
        case .invalidURL:               return "잘못된 서버 주소입니다."
        case .unauthorized:             return "로그인이 만료되었습니다. 다시 로그인해 주세요."
        case .server(let code, let m):  return "서버 오류(\(code)): \(m)"
        case .decoding(let m):          return "응답 파싱 실패: \(m)"
        case .transport(let e):         return GwaTopAPIError.friendlyTransport(e)
        }
    }

    /// URLError 코드를 사용자 친화적 한국어로 변환. raw 영어 메시지("The request timed out.")
    /// 대신 사용자가 어떻게 행동해야 할지 알 수 있는 안내를 보여준다.
    private static func friendlyTransport(_ error: Error) -> String {
        guard let urlError = error as? URLError else {
            return error.localizedDescription
        }
        switch urlError.code {
        case .timedOut:
            return "서버 응답이 늦어요. 잠시 후 다시 시도해 주세요."
        case .cannotConnectToHost, .cannotFindHost:
            return "서버에 연결할 수 없어요. 서버가 점검 중일 수 있어요."
        case .notConnectedToInternet, .networkConnectionLost:
            return "인터넷 연결을 확인해 주세요."
        case .dataNotAllowed:
            return "데이터 사용 권한을 확인해 주세요."
        case .secureConnectionFailed, .serverCertificateUntrusted,
             .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot:
            return "보안 연결에 실패했어요."
        default:
            return urlError.localizedDescription
        }
    }
}

enum GwaTopAuthTokenStore {
    private static let service = "com.gwatop.auth"
    private static let accessAccount = "accessToken"
    private static let refreshAccount = "refreshToken"

    static func save(accessToken: String, refreshToken: String) {
        store(accessToken, account: accessAccount)
        store(refreshToken, account: refreshAccount)
        clearLegacyDefaults()
        // 홈 화면 위젯이 직접 fetch(B) 할 수 있도록 access token + baseURL 을 App Group 에 미러링.
        GwaTopWidgetStore.saveAccessToken(accessToken)
        GwaTopWidgetStore.saveBaseURL(GwaTopAPI.baseURL)
    }

    static func replaceAccessToken(_ token: String) {
        store(token, account: accessAccount)
        UserDefaults.standard.removeObject(forKey: accessAccount)
        GwaTopWidgetStore.saveAccessToken(token)
    }

    static func currentAccessToken() -> String? {
        token(account: accessAccount) ?? migrateLegacyToken(key: accessAccount, account: accessAccount)
    }

    static func currentRefreshToken() -> String? {
        token(account: refreshAccount) ?? migrateLegacyToken(key: refreshAccount, account: refreshAccount)
    }

    static func clear() {
        delete(account: accessAccount)
        delete(account: refreshAccount)
        clearLegacyDefaults()
        // 로그아웃 — 위젯이 보던 스냅샷/토큰도 비운다.
        GwaTopWidgetBridge.clearAuth()
    }

    private static func store(_ value: String, account: String) {
        guard let data = value.data(using: .utf8) else { return }
        delete(account: account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: data
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    private static func token(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty
        else {
            return nil
        }
        return value
    }

    private static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }

    private static func migrateLegacyToken(key: String, account: String) -> String? {
        let legacy = UserDefaults.standard.string(forKey: key) ?? ""
        guard !legacy.isEmpty else { return nil }
        store(legacy, account: account)
        UserDefaults.standard.removeObject(forKey: key)
        return legacy
    }

    private static func clearLegacyDefaults() {
        UserDefaults.standard.removeObject(forKey: accessAccount)
        UserDefaults.standard.removeObject(forKey: refreshAccount)
    }
}

/// SwiftUI의 `.task` modifier는 view가 사라지거나 ID가 바뀔 때 진행 중인 Task를 자동
/// 취소한다. URLSession이나 Swift Concurrency가 던지는 cancellation 에러를 일반 에러로
/// 취급하면 "연동 오류"처럼 잘못 표시되므로, 호출 측에서 이 헬퍼로 한 번 걸러낸다.
///
/// - 사용 예:
///   ```
///   } catch {
///       if isCancellation(error) { return }
///       loadError = ...   // 진짜 실패만 표시
///   }
///   ```
func isCancellation(_ error: Error) -> Bool {
    if error is CancellationError { return true }
    if let urlErr = error as? URLError, urlErr.code == .cancelled { return true }
    // GwaTopAPIError.transport(URLError.cancelled) 같이 한 번 감싸진 케이스도 처리
    if let api = error as? GwaTopAPIError, case .transport(let inner) = api {
        return isCancellation(inner)
    }
    return false
}

enum GwaTopAPI {
    static let baseURL: String = {
        if let raw = Bundle.main.object(forInfoDictionaryKey: "GwaTopAPIBaseURL") as? String {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            }
        }
        #if DEBUG
        return "http://localhost:8000"
        #else
        return "https://api.gwatop.co.kr"
        #endif
    }()

    static func currentAccessToken() -> String? {
        GwaTopAuthTokenStore.currentAccessToken()
    }

    static func makeJSONDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoBasic = ISO8601DateFormatter()
        isoBasic.formatOptions = [.withInternetDateTime]

        // FastAPI 네이브 datetime을 KST로 해석.
        // DateFormatter는 `SSS`(밀리초)까지만 안정적으로 파싱하므로
        // 마이크로초(6자리) 같은 더 긴 fractional은 stripping 후 파싱한다.
        // tzdata에 Asia/Seoul이 없는 비정상 상황은 사실상 없지만, 강제 언래핑은 크래시
        // 위험이라 KST = UTC+9로 폴백한다.
        let kst = TimeZone(identifier: "Asia/Seoul")
            ?? TimeZone(secondsFromGMT: 9 * 3600)
            ?? .current

        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let raw = try c.decode(String.self)

            // 1) ISO 8601 (timezone 포함)
            if let date = iso.date(from: raw) ?? isoBasic.date(from: raw) {
                return date
            }

            // 2) Naive datetime — fractional 초가 있으면 통째로 제거
            //    "2026-05-20T09:32:35.987260" → "2026-05-20T09:32:35"
            let stripped: String = {
                if let dot = raw.firstIndex(of: ".") {
                    // 소수점 뒤가 timezone 표기자(+/-/Z)인지 검사
                    let suffix = raw[raw.index(after: dot)...]
                    if let tzStart = suffix.firstIndex(where: { "Z+-".contains($0) }) {
                        let beforeDot = raw[..<dot]
                        let tz = suffix[tzStart...]
                        return String(beforeDot) + String(tz)
                    }
                    return String(raw[..<dot])
                }
                return raw
            }()

            let fmt = DateFormatter()
            fmt.locale = Locale(identifier: "en_US_POSIX")
            fmt.timeZone = kst
            for pattern in [
                "yyyy-MM-dd'T'HH:mm:ssXXXXX",
                "yyyy-MM-dd'T'HH:mm:ss",
                "yyyy-MM-dd",
            ] {
                fmt.dateFormat = pattern
                if let d = fmt.date(from: stripped) { return d }
            }

            throw DecodingError.dataCorruptedError(
                in: c, debugDescription: "Unrecognized date: \(raw)"
            )
        }
        return d
    }

    static func makeJSONEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }
}

actor GwaTopAPIClient {
    static let shared = GwaTopAPIClient()

    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    private struct RefreshRequestBody: Encodable {
        let refreshToken: String

        enum CodingKeys: String, CodingKey {
            case refreshToken = "refresh_token"
        }
    }

    private struct RefreshResponseBody: Decodable {
        let accessToken: String
        let expiresIn: Int

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case expiresIn = "expires_in"
        }
    }

    init(session: URLSession = .shared) {
        self.session = session
        self.decoder = GwaTopAPI.makeJSONDecoder()
        self.encoder = GwaTopAPI.makeJSONEncoder()
    }

    func get<Response: Decodable>(
        _ path: String,
        query: [URLQueryItem] = [],
        requiresAuth: Bool = true
    ) async throws -> Response {
        let req = try buildRequest(path: path, method: "GET", query: query,
                                   body: nil as EmptyBody?, requiresAuth: requiresAuth)
        return try await perform(req)
    }

    func post<Body: Encodable, Response: Decodable>(
        _ path: String,
        body: Body,
        requiresAuth: Bool = true
    ) async throws -> Response {
        let req = try buildRequest(path: path, method: "POST", body: body, requiresAuth: requiresAuth)
        return try await perform(req)
    }

    func postEmpty<Response: Decodable>(
        _ path: String,
        requiresAuth: Bool = true
    ) async throws -> Response {
        let req = try buildRequest(path: path, method: "POST",
                                   body: nil as EmptyBody?, requiresAuth: requiresAuth)
        return try await perform(req)
    }

    func put<Body: Encodable, Response: Decodable>(
        _ path: String,
        body: Body,
        requiresAuth: Bool = true
    ) async throws -> Response {
        let req = try buildRequest(path: path, method: "PUT", body: body, requiresAuth: requiresAuth)
        return try await perform(req)
    }

    func patchEmpty<Response: Decodable>(
        _ path: String,
        requiresAuth: Bool = true
    ) async throws -> Response {
        let req = try buildRequest(path: path, method: "PATCH",
                                   body: nil as EmptyBody?, requiresAuth: requiresAuth)
        return try await perform(req)
    }

    func patch<Body: Encodable, Response: Decodable>(
        _ path: String,
        body: Body,
        requiresAuth: Bool = true
    ) async throws -> Response {
        let req = try buildRequest(path: path, method: "PATCH",
                                   body: body, requiresAuth: requiresAuth)
        return try await perform(req)
    }

    /// DELETE with JSON body response (for admin endpoints that return counts).
    func deleteJSON<Response: Decodable>(
        _ path: String,
        requiresAuth: Bool = true
    ) async throws -> Response {
        let req = try buildRequest(path: path, method: "DELETE",
                                   body: nil as EmptyBody?, requiresAuth: requiresAuth)
        return try await perform(req)
    }

    func deleteNoContent(_ path: String, requiresAuth: Bool = true) async throws {
        let req = try buildRequest(path: path, method: "DELETE",
                                   body: nil as EmptyBody?, requiresAuth: requiresAuth)
        let (_, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw GwaTopAPIError.server(-1, "Invalid response")
        }
        if http.statusCode == 401 {
            Self.broadcastUnauthorized()
            throw GwaTopAPIError.unauthorized
        }
        guard (200..<300).contains(http.statusCode) else {
            throw GwaTopAPIError.server(http.statusCode, "Delete failed")
        }
    }

    /// API 401 응답 시 ContentView에 신호를 보내 자동 로그아웃 트리거.
    /// main thread 위에서 NotificationCenter post.
    fileprivate static func broadcastUnauthorized() {
        Task { @MainActor in
            NotificationCenter.default.post(name: .gwaTopUnauthorized, object: nil)
        }
    }

    // MARK: - SSE (튜터 스트리밍 전용)

    /// 튜터 SSE 스트리밍. URLSession 의 `bytes(for:)` 비동기 시퀀스로 라인 단위 파싱.
    ///
    /// 백엔드는 각 이벤트를 `data: <JSON>\n\n` 형식으로 보낸다. iOS 는 각 JSON 을
    /// `GwaTopTutorStreamEvent` 로 매핑해 AsyncThrowingStream 에 흘려보낸다.
    ///
    /// nonisolated — actor 격리 밖에서 동기 호출 가능. 내부에서 새로운 Task 가
    /// URLSession 호출을 수행.
    nonisolated func tutorSSEStream(
        path: String,
        question: String,
        images: [String]?,
        language: String? = nil
    ) -> AsyncThrowingStream<GwaTopTutorStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let url = URL(string: GwaTopAPI.baseURL + path) else {
                        throw GwaTopAPIError.invalidURL
                    }
                    guard let token = GwaTopAPI.currentAccessToken() else {
                        throw GwaTopAPIError.unauthorized
                    }
                    var req = URLRequest(url: url, timeoutInterval: 120)
                    req.httpMethod = "POST"
                    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.setValue("text/event-stream", forHTTPHeaderField: "Accept")

                    // 직접 JSON 인코딩 — images 가 nil 일 때도 키를 보내도록 명시적 처리.
                    var payload: [String: Any] = ["question": question]
                    if let images, !images.isEmpty {
                        payload["images"] = images
                    }
                    if let language {
                        payload["language"] = language  // "en" 이면 튜터 답변이 영어로.
                    }
                    req.httpBody = try JSONSerialization.data(withJSONObject: payload)

                    let (bytes, response) = try await URLSession.shared.bytes(for: req)
                    guard let http = response as? HTTPURLResponse else {
                        throw GwaTopAPIError.server(-1, "Invalid SSE response")
                    }
                    if http.statusCode == 401 {
                        GwaTopAPIClient.broadcastUnauthorized()
                        throw GwaTopAPIError.unauthorized
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        // 응답 본문 일부만 모아서 에러로 — 너무 길면 의미 없음.
                        var snippet = ""
                        for try await line in bytes.lines {
                            snippet += line + "\n"
                            if snippet.count > 400 { break }
                        }
                        throw GwaTopAPIError.server(http.statusCode, snippet)
                    }

                    let decoder = GwaTopAPI.makeJSONDecoder()
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        // SSE 라인 포맷: `data: <JSON>` (빈 줄은 이벤트 구분, comment 는 `: ...`).
                        guard line.hasPrefix("data: ") else { continue }
                        let jsonString = String(line.dropFirst(6))
                        if jsonString.isEmpty { continue }
                        guard let data = jsonString.data(using: .utf8) else { continue }
                        if let event = Self.parseTutorEvent(data: data, decoder: decoder) {
                            continuation.yield(event)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// 한 SSE data 줄을 GwaTopTutorStreamEvent 로 디코딩.
    /// 실패하면 nil — 무시하고 다음 줄 진행 (백엔드가 새 이벤트 타입을 추가해도 forward-compatible).
    private static func parseTutorEvent(
        data: Data, decoder: JSONDecoder
    ) -> GwaTopTutorStreamEvent? {
        struct Envelope: Decodable {
            let type: String
            let text: String?
            let message: GwaTopTutorMessage?
            let assistantMessage: GwaTopTutorMessage?

            enum CodingKeys: String, CodingKey {
                case type, text, message
                case assistantMessage = "assistant_message"
            }
        }
        guard let env = try? decoder.decode(Envelope.self, from: data) else {
            return nil
        }
        switch env.type {
        case "user_message":
            return env.message.map { .userMessage($0) }
        case "start":
            return .start
        case "delta":
            return env.text.map { .delta($0) }
        case "done":
            return env.assistantMessage.map { .done($0) }
        case "error":
            return .error(env.text ?? "AI 응답 실패")
        default:
            return nil
        }
    }

    func uploadPUT(toAbsoluteURL urlString: String, body: Data, contentType: String) async throws {
        guard let url = URL(string: urlString) else { throw GwaTopAPIError.invalidURL }
        var req = URLRequest(url: url, timeoutInterval: 60)
        req.httpMethod = "PUT"
        req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            let rawBody = String(data: data, encoding: .utf8) ?? "(empty)"
            // S3 에러 XML에서 <Code> 추출
            let s3Code = Self.extract(tag: "Code", from: rawBody) ?? "?"
            let s3Msg  = Self.extract(tag: "Message", from: rawBody) ?? rawBody.prefix(200).description
            throw GwaTopAPIError.server(code, "S3 \(s3Code): \(s3Msg)")
        }
    }

    private static func extract(tag: String, from xml: String) -> String? {
        guard let start = xml.range(of: "<\(tag)>"),
              let end = xml.range(of: "</\(tag)>") else { return nil }
        return String(xml[start.upperBound..<end.lowerBound])
    }

    // MARK: - Internals

    private struct EmptyBody: Encodable {}

    private func buildRequest<Body: Encodable>(
        path: String,
        method: String,
        query: [URLQueryItem] = [],
        body: Body?,
        requiresAuth: Bool
    ) throws -> URLRequest {
        guard var comps = URLComponents(string: GwaTopAPI.baseURL + path) else {
            throw GwaTopAPIError.invalidURL
        }
        if !query.isEmpty { comps.queryItems = query }
        guard let url = comps.url else { throw GwaTopAPIError.invalidURL }

        // 30초 — 서버 응답이 잠시 느려도 한 번 더 기다린다. AI 생성 폴링은 별도 폴 루프라
        // 이 값과 무관. 일반 GET/POST 용도.
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        if requiresAuth {
            guard let token = GwaTopAPI.currentAccessToken() else { throw GwaTopAPIError.unauthorized }
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body = body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try encoder.encode(body)
        }
        return req
    }

    private func perform<Response: Decodable>(
        _ req: URLRequest,
        allowRefresh: Bool = true
    ) async throws -> Response {
        let started = Date()
        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await session.data(for: req)
        } catch {
            // 전송 실패 — 평균을 더럽히지 않도록 succeeded=false 로 보냄.
            // path 모니터가 offline 판정. 다음 성공 요청 시 자동 회복.
            let elapsedMs = Date().timeIntervalSince(started) * 1000
            await GwaTopNetworkMonitor.shared.recordLatency(elapsedMs, succeeded: false)
            throw GwaTopAPIError.transport(error)
        }
        // 정상 응답 latency 기록 → rolling avg + 오프라인 플래그 자동 해제.
        let elapsedMs = Date().timeIntervalSince(started) * 1000
        await GwaTopNetworkMonitor.shared.recordLatency(elapsedMs, succeeded: true)

        guard let http = resp as? HTTPURLResponse else {
            throw GwaTopAPIError.server(-1, "Invalid response")
        }
        if http.statusCode == 401 {
            if allowRefresh, let refreshed = try? await refreshAccessToken(), refreshed {
                var retry = req
                if let token = GwaTopAPI.currentAccessToken() {
                    retry.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                    return try await perform(retry, allowRefresh: false)
                }
            }
            Self.broadcastUnauthorized()
            throw GwaTopAPIError.unauthorized
        }
        guard (200..<300).contains(http.statusCode) else {
            let msg = parseDetail(data) ?? String(data: data, encoding: .utf8) ?? "(no body)"
            throw GwaTopAPIError.server(http.statusCode, msg)
        }
        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            let raw = String(data: data, encoding: .utf8) ?? "(no data)"
            throw GwaTopAPIError.decoding("\(error)\n\nbody: \(raw.prefix(500))")
        }
    }

    private func parseDetail(_ data: Data) -> String? {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let s = json["detail"] as? String { return s }
            if let d = json["detail"] as? [String: Any], let m = d["message"] as? String { return m }
        }
        return nil
    }

    private func refreshAccessToken() async throws -> Bool {
        guard let refreshToken = GwaTopAuthTokenStore.currentRefreshToken(),
              !refreshToken.isEmpty,
              let url = URL(string: GwaTopAPI.baseURL + "/v1/auth/refresh")
        else {
            return false
        }

        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = try encoder.encode(RefreshRequestBody(refreshToken: refreshToken))

        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            GwaTopAuthTokenStore.clear()
            return false
        }
        let body = try decoder.decode(RefreshResponseBody.self, from: data)
        GwaTopAuthTokenStore.replaceAccessToken(body.accessToken)
        return true
    }
}
