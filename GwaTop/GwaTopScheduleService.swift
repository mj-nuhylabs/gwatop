//
//  GwaTopScheduleService.swift
//  GwaTop
//
//  GET    /v1/schedules
//  POST   /v1/schedules
//  PUT    /v1/schedules/{id}
//  DELETE /v1/schedules/{id}
//

import Foundation
import SwiftUI

struct GwaTopScheduleDTO: Decodable, Identifiable {
    let id: String
    let courseId: String
    let courseName: String
    let courseColor: String?
    let title: String
    let type: String
    let dueDate: Date
    let description: String?
    let isAuto: Bool
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case courseId     = "course_id"
        case courseName   = "course_name"
        case courseColor  = "course_color"
        case title
        case type
        case dueDate      = "due_date"
        case description
        case isAuto       = "is_auto"
        case createdAt    = "created_at"
    }
}

struct GwaTopScheduleCreateRequest: Encodable {
    let courseId: String
    let title: String
    let type: String
    let dueDate: String     // ISO 8601 — "2026-06-19T10:00:00" 형식
    let description: String?

    enum CodingKeys: String, CodingKey {
        case courseId    = "course_id"
        case title
        case type
        case dueDate     = "due_date"
        case description
    }
}

struct GwaTopCalendarDaySummary: Decodable {
    let date: String       // "YYYY-MM-DD"
    let total: Int
    let byType: [String: Int]

    enum CodingKeys: String, CodingKey {
        case date, total
        case byType = "by_type"
    }
}

struct GwaTopCalendarSummary: Decodable {
    let start: Date
    let end: Date
    let days: [GwaTopCalendarDaySummary]
}

struct GwaTopScheduleUpdateRequest: Encodable {
    let courseId: String?
    let title: String?
    let type: String?
    let dueDate: String?
    let description: String?

    enum CodingKeys: String, CodingKey {
        case courseId    = "course_id"
        case title
        case type
        case dueDate     = "due_date"
        case description
    }
}

actor GwaTopScheduleService {
    static let shared = GwaTopScheduleService()

    static func encode(_ date: Date) -> String {
        GwaTopDateFormatters.serverDateTime.string(from: date)
    }

    func fetchAll(
        start: Date? = nil,
        end: Date? = nil,
        courseId: String? = nil
    ) async throws -> [GwaTopScheduleDTO] {
        var q: [URLQueryItem] = []
        if let s = start { q.append(.init(name: "start", value: Self.encode(s))) }
        if let e = end   { q.append(.init(name: "end",   value: Self.encode(e))) }
        if let c = courseId { q.append(.init(name: "course_id", value: c)) }
        return try await GwaTopAPIClient.shared.get("/v1/schedules", query: q)
    }

    func fetchCalendarSummary(start: Date, end: Date) async throws -> GwaTopCalendarSummary {
        let q: [URLQueryItem] = [
            .init(name: "start", value: Self.encode(start)),
            .init(name: "end",   value: Self.encode(end)),
        ]
        return try await GwaTopAPIClient.shared.get("/v1/schedules/calendar/summary", query: q)
    }

    func create(
        courseId: String,
        title: String,
        type: String,
        dueDate: Date,
        description: String?
    ) async throws -> GwaTopScheduleDTO {
        let body = GwaTopScheduleCreateRequest(
            courseId: courseId,
            title: title,
            type: type,
            dueDate: Self.encode(dueDate),
            description: description
        )
        return try await GwaTopAPIClient.shared.post("/v1/schedules", body: body)
    }

    func update(
        id: String,
        courseId: String? = nil,
        title: String? = nil,
        type: String? = nil,
        dueDate: Date? = nil,
        description: String? = nil
    ) async throws -> GwaTopScheduleDTO {
        let body = GwaTopScheduleUpdateRequest(
            courseId: courseId,
            title: title,
            type: type,
            dueDate: dueDate.map(Self.encode),
            description: description
        )
        return try await GwaTopAPIClient.shared.put("/v1/schedules/\(id)", body: body)
    }

    func delete(id: String) async throws {
        try await GwaTopAPIClient.shared.deleteNoContent("/v1/schedules/\(id)")
    }
}

extension GwaTopCalendarEvent {
    init(dto: GwaTopScheduleDTO) {
        let type: GwaTopCalendarEventType
        switch dto.type.lowercased() {
        case "exam":       type = .exam
        case "assignment": type = .assignment
        case "lecture":    type = .lecture
        case "meeting":    type = .meeting
        case "upload":     type = .upload
        default:           type = .assignment
        }

        let course = GwaTopCourseSummary(
            id: dto.courseId,
            name: dto.courseName,
            professor: "",
            colorHex: dto.courseColor ?? "#4F8EF7",
            iconName: "book.closed.fill",
            currentWeek: 0,
            progress: 0.0
        )

        self.init(
            id: dto.id,
            course: course,
            title: dto.title,
            eventType: type,
            startDate: dto.dueDate,
            endDate: nil,
            location: "—",
            memo: dto.description ?? "",
            source: dto.isAuto ? "ai_parsed" : "manual"
        )
    }
}
