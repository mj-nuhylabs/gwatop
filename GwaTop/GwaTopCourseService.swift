//
//  GwaTopCourseService.swift
//  GwaTop
//

import Foundation

struct GwaTopClassTimeDTO: Decodable, Equatable, Hashable {
    let day: String        // MON/TUE/WED/THU/FRI/SAT/SUN
    let startTime: String  // "HH:MM"
    let endTime: String    // "HH:MM"

    enum CodingKeys: String, CodingKey {
        case day
        case startTime = "start_time"
        case endTime   = "end_time"
    }
}

struct GwaTopCourseDTO: Decodable, Identifiable, Equatable {
    let id: String
    let semesterId: String
    let name: String
    let professor: String?
    let color: String?
    let schedule: [GwaTopClassTimeDTO]?

    enum CodingKeys: String, CodingKey {
        case id
        case semesterId = "semester_id"
        case name
        case professor
        case color
        case schedule
    }
}

struct GwaTopCourseCreateRequest: Encodable {
    let name: String
    let professor: String?
    let color: String
}

struct GwaTopCourseUpdateRequest: Encodable {
    let name: String?
    let professor: String?
    let color: String?
}

actor GwaTopCourseService {
    static let shared = GwaTopCourseService()

    func fetchAll() async throws -> [GwaTopCourseDTO] {
        try await GwaTopAPIClient.shared.get("/v1/courses")
    }

    func create(
        semesterId: String,
        name: String,
        professor: String?,
        color: String
    ) async throws -> GwaTopCourseDTO {
        let body = GwaTopCourseCreateRequest(name: name, professor: professor, color: color)
        return try await GwaTopAPIClient.shared.post(
            "/v1/semesters/\(semesterId)/courses",
            body: body
        )
    }

    func update(
        id: String,
        name: String? = nil,
        professor: String? = nil,
        color: String? = nil
    ) async throws -> GwaTopCourseDTO {
        let body = GwaTopCourseUpdateRequest(name: name, professor: professor, color: color)
        return try await GwaTopAPIClient.shared.put("/v1/courses/\(id)", body: body)
    }

    func delete(id: String) async throws {
        try await GwaTopAPIClient.shared.deleteNoContent("/v1/courses/\(id)")
    }
}
