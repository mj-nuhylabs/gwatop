//
//  GwaTopDeviceService.swift
//  GwaTop
//
//  POST /v1/devices/register, DELETE /v1/devices/{apns_token}
//  - APNs 토큰을 받자마자 register() 호출 (앱 어디서든 1회/세션)
//  - 로그아웃 시 unregister() 호출 권장
//

import Foundation

struct GwaTopDeviceDTO: Decodable {
    let id: String
    let apnsToken: String
    let platform: String
    let lastSeenAt: Date
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, platform
        case apnsToken  = "apns_token"
        case lastSeenAt = "last_seen_at"
        case createdAt  = "created_at"
    }
}

private struct DeviceRegisterRequest: Encodable {
    let apnsToken: String
    let platform: String

    enum CodingKeys: String, CodingKey {
        case apnsToken = "apns_token"
        case platform
    }
}

actor GwaTopDeviceService {
    static let shared = GwaTopDeviceService()

    func register(apnsToken: String, platform: String = "ios") async throws -> GwaTopDeviceDTO {
        let body = DeviceRegisterRequest(apnsToken: apnsToken, platform: platform)
        return try await GwaTopAPIClient.shared.post("/v1/devices/register", body: body)
    }

    func unregister(apnsToken: String) async throws {
        try await GwaTopAPIClient.shared.deleteNoContent("/v1/devices/\(apnsToken)")
    }
}
