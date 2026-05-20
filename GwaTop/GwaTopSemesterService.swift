//
//  GwaTopSemesterService.swift
//  GwaTop
//
//  GET  /v1/semesters
//  POST /v1/semesters
//

import Foundation

struct GwaTopSemesterDTO: Decodable, Identifiable, Equatable {
    let id: String
    let userId: String
    let name: String
    let startDate: Date
    let endDate: Date
    let isActive: Bool
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case userId    = "user_id"
        case name
        case startDate = "start_date"
        case endDate   = "end_date"
        case isActive  = "is_active"
        case createdAt = "created_at"
    }
}

/// Date를 "YYYY-MM-DD" 평문으로 보내야 FastAPI의 date 필드가 받아준다.
/// JSONEncoder의 .iso8601은 datetime 형식이라 거부됨.
struct GwaTopSemesterCreateRequest: Encodable {
    let name: String
    let startDate: String   // "YYYY-MM-DD"
    let endDate: String     // "YYYY-MM-DD"
    let isActive: Bool

    enum CodingKeys: String, CodingKey {
        case name
        case startDate = "start_date"
        case endDate   = "end_date"
        case isActive  = "is_active"
    }
}

actor GwaTopSemesterService {
    static let shared = GwaTopSemesterService()

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Asia/Seoul")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    func fetchAll() async throws -> [GwaTopSemesterDTO] {
        try await GwaTopAPIClient.shared.get("/v1/semesters")
    }

    func create(
        name: String,
        startDate: Date,
        endDate: Date,
        isActive: Bool
    ) async throws -> GwaTopSemesterDTO {
        let body = GwaTopSemesterCreateRequest(
            name: name,
            startDate: Self.dateFormatter.string(from: startDate),
            endDate: Self.dateFormatter.string(from: endDate),
            isActive: isActive
        )
        return try await GwaTopAPIClient.shared.post("/v1/semesters", body: body)
    }

    func update(
        id: String,
        name: String? = nil,
        startDate: Date? = nil,
        endDate: Date? = nil,
        isActive: Bool? = nil
    ) async throws -> GwaTopSemesterDTO {
        struct UpdateBody: Encodable {
            let name: String?
            let startDate: String?
            let endDate: String?
            let isActive: Bool?
            enum CodingKeys: String, CodingKey {
                case name
                case startDate = "start_date"
                case endDate   = "end_date"
                case isActive  = "is_active"
            }
        }
        let body = UpdateBody(
            name: name,
            startDate: startDate.map(Self.dateFormatter.string(from:)),
            endDate: endDate.map(Self.dateFormatter.string(from:)),
            isActive: isActive
        )
        return try await GwaTopAPIClient.shared.put("/v1/semesters/\(id)", body: body)
    }

    func setActive(id: String) async throws -> GwaTopSemesterDTO {
        try await GwaTopAPIClient.shared.patchEmpty("/v1/semesters/\(id)/set-active")
    }

    func delete(id: String) async throws {
        try await GwaTopAPIClient.shared.deleteNoContent("/v1/semesters/\(id)")
    }
}
