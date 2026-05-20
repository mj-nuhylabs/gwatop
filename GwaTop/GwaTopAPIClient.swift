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

enum GwaTopAPI {
    static let baseURL: String = "http://100.55.22.248:8000"

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
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let raw = try c.decode(String.self)
            if let date = iso.date(from: raw) ?? isoBasic.date(from: raw) {
                return date
            }
            // FastAPI naive datetime (no timezone)
            let fmt = DateFormatter()
            fmt.locale = Locale(identifier: "en_US_POSIX")
            fmt.timeZone = TimeZone(secondsFromGMT: 0)
            fmt.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS"
            if let d = fmt.date(from: raw) { return d }
            fmt.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
            if let d = fmt.date(from: raw) { return d }
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

    func uploadPUT(toAbsoluteURL urlString: String, body: Data, contentType: String) async throws {
        guard let url = URL(string: urlString) else { throw GwaTopAPIError.invalidURL }
        var req = URLRequest(url: url, timeoutInterval: 60)
        req.httpMethod = "PUT"
        req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        let (_, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            throw GwaTopAPIError.server(code, "S3 upload failed")
        }
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
        if http.statusCode == 401 { throw GwaTopAPIError.unauthorized }
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
