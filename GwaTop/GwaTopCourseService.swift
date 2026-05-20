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

actor GwaTopCourseService {
    static let shared = GwaTopCourseService()

    func fetchAll() async throws -> [GwaTopCourseDTO] {
        try await GwaTopAPIClient.shared.get("/v1/courses")
    }
}
