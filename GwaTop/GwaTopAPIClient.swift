//
//  GwaTopAPIClient.swift
//  GwaTop
//
//  공통 백엔드 호출 헬퍼.
//  - baseURL은 한 곳에서 관리 (EC2 IP 변경 시 여기만 고치면 됨)
//  - @AppStorage("accessToken")의 JWT를 Bearer로 자동 부착
//  - JSON 인코딩/디코딩 (snake_case + ISO8601 with fractional seconds)
//

import Foundation

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
        case .transport(let e):         return e.localizedDescription
        }
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
    // EC2 us-east-1 인스턴스. Public IP는 인스턴스 재시작 시 바뀌므로 DNS 형태로 적어두면
    // 콘솔 재할당 후 ec2-...-...-compute-1.amazonaws.com 형태가 그대로 유효한 경우가 많다.
    // Elastic IP를 붙이면 영구 고정. Info.plist ATS 예외도 같은 도메인으로 등록되어 있음.
    static let baseURL: String = "http://ec2-54-160-132-244.compute-1.amazonaws.com:8000"

    static func currentAccessToken() -> String? {
        let t = UserDefaults.standard.string(forKey: "accessToken") ?? ""
        return t.isEmpty ? nil : t
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

        var req = URLRequest(url: url, timeoutInterval: 20)
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

    private func perform<Response: Decodable>(_ req: URLRequest) async throws -> Response {
        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await session.data(for: req)
        } catch {
            throw GwaTopAPIError.transport(error)
        }
        guard let http = resp as? HTTPURLResponse else {
            throw GwaTopAPIError.server(-1, "Invalid response")
        }
        if http.statusCode == 401 {
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
}
