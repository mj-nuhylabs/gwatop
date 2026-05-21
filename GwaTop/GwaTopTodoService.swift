//
//  GwaTopTodoService.swift
//  GwaTop
//
//  GET    /v1/todos?start=&end=&course_id=&schedule_id=&is_done=&priority=
//  POST   /v1/todos
//  PATCH  /v1/todos/{id}
//  DELETE /v1/todos/{id}
//
//  Day 6: schedule(type=exam/assignment) 생성 시 백엔드가 자동 todos 만들어줌.
//   - exam:       D-14 / D-7 / D-3 / D-1 (priority: low / medium / high / high)
//   - assignment: D-7 / D-3 / D-1 (medium / high / high)
//   - schedule 수정/삭제 시 is_auto=true 인 todos는 재생성됨 (수동 todos는 link만 끊김)
//

import Foundation

struct GwaTopTodoDTO: Decodable, Identifiable {
    let id: String
    let courseId: String
    let scheduleId: String?
    let courseName: String
    let courseColor: String?
    let title: String
    let dueDate: Date
    let priority: String       // "low" / "medium" / "high"
    let isDone: Bool
    let isAuto: Bool
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case courseId    = "course_id"
        case scheduleId  = "schedule_id"
        case courseName  = "course_name"
        case courseColor = "course_color"
        case title
        case dueDate     = "due_date"
        case priority
        case isDone      = "is_done"
        case isAuto      = "is_auto"
        case createdAt   = "created_at"
    }
}

struct GwaTopTodoCreateRequest: Encodable {
    let courseId: String
    let scheduleId: String?
    let title: String
    let dueDate: String      // ISO "yyyy-MM-dd'T'HH:mm:ss"
    let priority: String     // "low" / "medium" / "high"

    enum CodingKeys: String, CodingKey {
        case courseId   = "course_id"
        case scheduleId = "schedule_id"
        case title
        case dueDate    = "due_date"
        case priority
    }
}

struct GwaTopTodoUpdateRequest: Encodable {
    let title: String?
    let dueDate: String?
    let priority: String?
    let isDone: Bool?

    enum CodingKeys: String, CodingKey {
        case title
        case dueDate  = "due_date"
        case priority
        case isDone   = "is_done"
    }
}

actor GwaTopTodoService {
    static let shared = GwaTopTodoService()

    static func encode(_ date: Date) -> String {
        GwaTopDateFormatters.serverDateTime.string(from: date)
    }

    func fetchAll(
        start: Date? = nil,
        end: Date? = nil,
        courseId: String? = nil,
        scheduleId: String? = nil,
        isDone: Bool? = nil,
        priority: String? = nil
    ) async throws -> [GwaTopTodoDTO] {
        var q: [URLQueryItem] = []
        if let s = start    { q.append(.init(name: "start",       value: Self.encode(s))) }
        if let e = end      { q.append(.init(name: "end",         value: Self.encode(e))) }
        if let c = courseId { q.append(.init(name: "course_id",   value: c)) }
        if let s = scheduleId { q.append(.init(name: "schedule_id", value: s)) }
        if let d = isDone   { q.append(.init(name: "is_done",     value: d ? "true" : "false")) }
        if let p = priority { q.append(.init(name: "priority",    value: p)) }
        return try await GwaTopAPIClient.shared.get("/v1/todos", query: q)
    }

    func create(
        courseId: String,
        scheduleId: String? = nil,
        title: String,
        dueDate: Date,
        priority: String = "low"
    ) async throws -> GwaTopTodoDTO {
        let body = GwaTopTodoCreateRequest(
            courseId: courseId,
            scheduleId: scheduleId,
            title: title,
            dueDate: Self.encode(dueDate),
            priority: priority
        )
        return try await GwaTopAPIClient.shared.post("/v1/todos", body: body)
    }

    func update(
        id: String,
        title: String? = nil,
        dueDate: Date? = nil,
        priority: String? = nil,
        isDone: Bool? = nil
    ) async throws -> GwaTopTodoDTO {
        let body = GwaTopTodoUpdateRequest(
            title: title,
            dueDate: dueDate.map(Self.encode),
            priority: priority,
            isDone: isDone
        )
        return try await GwaTopAPIClient.shared.patch("/v1/todos/\(id)", body: body)
    }

    func toggleDone(id: String, isDone: Bool) async throws -> GwaTopTodoDTO {
        try await update(id: id, isDone: isDone)
    }

    func delete(id: String) async throws {
        try await GwaTopAPIClient.shared.deleteNoContent("/v1/todos/\(id)")
    }
}
