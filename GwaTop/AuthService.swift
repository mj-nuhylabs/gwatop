//
//  AuthService.swift
//  GwaTop
//

import Foundation

struct SocialLoginRequest: Encodable {
    let provider: String
    let idToken: String

    enum CodingKeys: String, CodingKey {
        case provider
        case idToken = "id_token"
    }
}

struct EmailRegisterRequest: Encodable {
    let email: String
    let password: String
    let name: String
}

struct EmailLoginRequest: Encodable {
    let email: String
    let password: String
}

struct UserOut: Decodable {
    let id: String
    let email: String
    let name: String
}

struct AuthResponse: Decodable {
    let accessToken: String
    let refreshToken: String
    let expiresIn: Int
    let user: UserOut

    enum CodingKeys: String, CodingKey {
        case accessToken  = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn    = "expires_in"
        case user
    }
}

enum AuthError: LocalizedError {
    case noIdToken
    case serverError(String)

    var errorDescription: String? {
        switch self {
        case .noIdToken:             return "Google 토큰을 가져올 수 없습니다."
        case .serverError(let msg):  return msg
        }
    }
}

actor AuthService {
    static let shared = AuthService()

    private var baseURL: String { GwaTopAPI.baseURL }

    func googleLogin(idToken: String) async throws -> AuthResponse {
        try await postAuth(
            path: "/v1/auth/social",
            body: SocialLoginRequest(provider: "google", idToken: idToken),
            expectedStatus: 200,
            fallbackErrorMessage: "로그인에 실패했습니다."
        )
    }

    func register(email: String, password: String, name: String) async throws -> AuthResponse {
        try await postAuth(
            path: "/v1/auth/register",
            body: EmailRegisterRequest(email: email, password: password, name: name),
            expectedStatus: 201,
            fallbackErrorMessage: "회원가입에 실패했습니다."
        )
    }

    func emailLogin(email: String, password: String) async throws -> AuthResponse {
        try await postAuth(
            path: "/v1/auth/login",
            body: EmailLoginRequest(email: email, password: password),
            expectedStatus: 200,
            fallbackErrorMessage: "로그인에 실패했습니다."
        )
    }

    private func postAuth<Body: Encodable>(
        path: String,
        body: Body,
        expectedStatus: Int,
        fallbackErrorMessage: String
    ) async throws -> AuthResponse {
        guard let url = URL(string: "\(baseURL)\(path)") else {
            throw AuthError.serverError("서버 주소가 올바르지 않습니다.")
        }

        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw AuthError.serverError("서버 응답이 올바르지 않습니다.")
        }

        guard http.statusCode == expectedStatus else {
            let parsed = parseErrorMessage(from: data)
            let raw = String(data: data, encoding: .utf8) ?? ""
            print("[AuthService] \(path) failed status=\(http.statusCode) body=\(raw)")

            if let parsed {
                throw AuthError.serverError(parsed)
            }
            let snippet = raw.isEmpty ? "" : " (\(raw.prefix(200)))"
            throw AuthError.serverError("\(fallbackErrorMessage) [HTTP \(http.statusCode)]\(snippet)")
        }

        do {
            return try JSONDecoder().decode(AuthResponse.self, from: data)
        } catch {
            let raw = String(data: data, encoding: .utf8) ?? "(no data)"
            throw AuthError.serverError("파싱 오류: \(raw)")
        }
    }

    private func parseErrorMessage(from data: Data) -> String? {
        // 1) {"detail": {"message": "..."}}
        // 2) {"detail": "..."}
        // 3) {"detail": [{"msg": "...", "loc": [...]}, ...]}  (FastAPI 422)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        if let detail = json["detail"] as? [String: Any],
           let message = detail["message"] as? String {
            return message
        }
        if let detail = json["detail"] as? String {
            return detail
        }
        if let detail = json["detail"] as? [[String: Any]] {
            let messages = detail.compactMap { item -> String? in
                let msg = item["msg"] as? String
                if let loc = item["loc"] as? [Any], let field = loc.last {
                    return "\(field): \(msg ?? "")"
                }
                return msg
            }
            if messages.isEmpty == false {
                return messages.joined(separator: "\n")
            }
        }
        return nil
    }
}
