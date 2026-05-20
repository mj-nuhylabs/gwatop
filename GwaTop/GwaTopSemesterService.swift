//
//  GwaTopSemesterService.swift
//  GwaTop
//
//  GET /v1/semesters — 새 과목 생성 시 학기 id가 필요해서 사용.
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

actor GwaTopSemesterService {
    static let shared = GwaTopSemesterService()

    func fetchAll() async throws -> [GwaTopSemesterDTO] {
        try await GwaTopAPIClient.shared.get("/v1/semesters")
    }
}
