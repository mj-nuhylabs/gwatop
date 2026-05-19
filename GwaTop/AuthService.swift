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

    private let baseURL = "http://100.55.22.248:8000"

    func googleLogin(idToken: String) async throws -> AuthResponse {
        guard let url = URL(string: "\(baseURL)/v1/auth/social") else {
            throw AuthError.serverError("서버 주소가 올바르지 않습니다.")
        }

        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            SocialLoginRequest(provider: "google", idToken: idToken)
        )

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let msg = parseErrorMessage(from: data) ?? "로그인에 실패했습니다."
            throw AuthError.serverError(msg)
        }

        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode(AuthResponse.self, from: data)
        } catch {
            throw AuthError.serverError("서버 응답을 처리할 수 없습니다.")
        }
    }

    private func parseErrorMessage(from data: Data) -> String? {
        // {"detail": {"message": "..."}}  또는  {"detail": "..."}
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let detail = json["detail"] as? [String: Any],
               let message = detail["message"] as? String {
                return message
            }
            if let detail = json["detail"] as? String {
                return detail
            }
        }
        return nil
    }
}
