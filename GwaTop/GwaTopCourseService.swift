//
//  GwaTopCourseService.swift
//  GwaTop
//

import Foundation

struct GwaTopClassTimeDTO: Codable, Equatable, Hashable {
    var day: String        // MON/TUE/WED/THU/FRI/SAT/SUN
    var startTime: String  // "HH:MM"
    var endTime: String    // "HH:MM"
    /// 이 요일(슬롯) 전용 강의실. 요일마다 다른 강의실을 가질 수 있도록 슬롯 단위로 보관.
    /// 비어 있으면 과목 전체 location(course.location) 으로 폴백해 표시한다.
    var location: String?  // 예: "공학관 301호"

    enum CodingKeys: String, CodingKey {
        case day
        case startTime = "start_time"
        case endTime   = "end_time"
        case location
    }
}

struct GwaTopCourseDTO: Decodable, Identifiable, Equatable {
    let id: String
    let semesterId: String
    let name: String
    let professor: String?
    let color: String?
    let location: String?
    let schedule: [GwaTopClassTimeDTO]?

    enum CodingKeys: String, CodingKey {
        case id
        case semesterId = "semester_id"
        case name
        case professor
        case color
        case location
        case schedule
    }
}

struct GwaTopCourseCreateRequest: Encodable {
    let name: String
    let professor: String?
    let color: String
    let location: String?
    let schedule: [GwaTopClassTimeDTO]?
}

struct GwaTopCourseUpdateRequest: Encodable {
    let name: String?
    let professor: String?
    let color: String?
    let location: String?
    let schedule: [GwaTopClassTimeDTO]?
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
        color: String,
        location: String? = nil,
        schedule: [GwaTopClassTimeDTO]? = nil
    ) async throws -> GwaTopCourseDTO {
        let body = GwaTopCourseCreateRequest(
            name: name, professor: professor, color: color, location: location, schedule: schedule
        )
        return try await GwaTopAPIClient.shared.post(
            "/v1/semesters/\(semesterId)/courses",
            body: body
        )
    }

    func update(
        id: String,
        name: String? = nil,
        professor: String? = nil,
        color: String? = nil,
        location: String? = nil,
        schedule: [GwaTopClassTimeDTO]? = nil
    ) async throws -> GwaTopCourseDTO {
        let body = GwaTopCourseUpdateRequest(
            name: name, professor: professor, color: color, location: location, schedule: schedule
        )
        return try await GwaTopAPIClient.shared.put("/v1/courses/\(id)", body: body)
    }

    func delete(id: String) async throws {
        try await GwaTopAPIClient.shared.deleteNoContent("/v1/courses/\(id)")
    }
}
