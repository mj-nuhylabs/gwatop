//
//  GwaTopCourseService.swift
//  GwaTop
//

import Foundation

struct GwaTopCourseDTO: Decodable, Identifiable, Equatable {
    let id: String
    let semesterId: String
    let name: String
    let professor: String?
    let color: String?

    enum CodingKeys: String, CodingKey {
        case id
        case semesterId = "semester_id"
        case name
        case professor
        case color
    }
}

struct GwaTopCourseCreateRequest: Encodable {
    let name: String
    let professor: String?
    let color: String
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
}
