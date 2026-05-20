//
//  GwaTopScheduleService.swift
//  GwaTop
//
//  백엔드 schedules 목록을 가져와 GwaTopCalendarEvent로 매핑.
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

actor GwaTopScheduleService {
    static let shared = GwaTopScheduleService()

    func fetchAll() async throws -> [GwaTopScheduleDTO] {
        try await GwaTopAPIClient.shared.get("/v1/schedules")
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
