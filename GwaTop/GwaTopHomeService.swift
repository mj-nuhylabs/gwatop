//
//  GwaTopHomeService.swift
//  GwaTop
//
//  GET /v1/home/dashboard — 홈 화면 첫 진입에 필요한 데이터를 한 번에 받음.
//  내부적으로 today_schedules / upcoming_todos / this_week_summary / next_event 4종.
//

import Foundation

struct GwaTopWeekSummaryDTO: Decodable {
    let total: Int
    let done: Int
    let rate: Double
}

struct GwaTopNextEventDTO: Decodable {
    let id: String
    let title: String
    let type: String
    let dueDate: Date
    let dDay: Int
    // 외부(Apple) 일정이 next 일 수 있어 course 정보는 옵셔널.
    let courseId: String?
    let courseName: String?
    let courseColor: String?

    enum CodingKeys: String, CodingKey {
        case id, title, type
        case dueDate     = "due_date"
        case dDay        = "d_day"
        case courseId    = "course_id"
        case courseName  = "course_name"
        case courseColor = "course_color"
    }
}

struct GwaTopHomeDashboardDTO: Decodable {
    let todaySchedules: [GwaTopScheduleDTO]
    let upcomingTodos: [GwaTopTodoDTO]
    let thisWeekSummary: GwaTopWeekSummaryDTO
    let nextEvent: GwaTopNextEventDTO?

    enum CodingKeys: String, CodingKey {
        case todaySchedules   = "today_schedules"
        case upcomingTodos    = "upcoming_todos"
        case thisWeekSummary  = "this_week_summary"
        case nextEvent        = "next_event"
    }
}

actor GwaTopHomeService {
    static let shared = GwaTopHomeService()

    func fetchDashboard(upcomingLimit: Int = 10) async throws -> GwaTopHomeDashboardDTO {
        let q: [URLQueryItem] = [
            .init(name: "upcoming_limit", value: String(upcomingLimit))
        ]
        return try await GwaTopAPIClient.shared.get("/v1/home/dashboard", query: q)
    }
}
