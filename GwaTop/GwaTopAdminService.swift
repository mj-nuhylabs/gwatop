//
//  GwaTopAdminService.swift
//  GwaTop
//
//  출시 전 테스트용 관리자 화면이 호출하는 API 래퍼.
//  서버에서 ADMIN_EMAILS 화이트리스트가 비어있거나 현재 사용자가 없으면 404를 돌려준다 →
//  화면은 "권한 없음"으로 그래이스풀하게 표시한다.
//

import Foundation

// MARK: - DTO

struct GwaTopAdminOverview: Decodable {
    let counts: [String: Int]
    let fileStatus: [String: Int]

    enum CodingKeys: String, CodingKey {
        case counts
        case fileStatus = "file_status"
    }
}

struct GwaTopAdminUserBrief: Decodable, Identifiable, Equatable {
    let id: String
    let email: String
    let name: String
    let provider: String
    let isActive: Bool
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, email, name, provider
        case isActive = "is_active"
        case createdAt = "created_at"
    }
}

struct GwaTopAdminSemester: Decodable, Identifiable {
    let id: String
    let name: String
    let startDate: String
    let endDate: String
    let isActive: Bool

    enum CodingKeys: String, CodingKey {
        case id, name
        case startDate = "start_date"
        case endDate = "end_date"
        case isActive = "is_active"
    }
}

struct GwaTopAdminCourse: Decodable, Identifiable {
    let id: String
    let semesterId: String
    let name: String
    let professor: String?
    let color: String?
    let scheduleCount: Int
    let fileCount: Int

    enum CodingKeys: String, CodingKey {
        case id, name, professor, color
        case semesterId = "semester_id"
        case scheduleCount = "schedule_count"
        case fileCount = "file_count"
    }
}

struct GwaTopAdminFile: Decodable, Identifiable {
    let id: String
    let courseId: String?
    let courseName: String?
    let userEmail: String?
    let filename: String
    let fileType: String
    let status: String
    let week: Int?
    let isSyllabus: Bool
    let aiConfidence: Double?
    let classificationSource: String?
    let parseError: String?
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, filename, status, week
        case courseId = "course_id"
        case courseName = "course_name"
        case userEmail = "user_email"
        case fileType = "file_type"
        case isSyllabus = "is_syllabus"
        case aiConfidence = "ai_confidence"
        case classificationSource = "classification_source"
        case parseError = "parse_error"
        case createdAt = "created_at"
    }
}

struct GwaTopAdminSchedule: Decodable, Identifiable {
    let id: String
    let title: String
    let type: String
    let dueDate: Date
    let isAuto: Bool
    let description: String?
    let courseId: String
    let courseName: String?
    let userEmail: String?

    enum CodingKeys: String, CodingKey {
        case id, title, type, description
        case dueDate = "due_date"
        case isAuto = "is_auto"
        case courseId = "course_id"
        case courseName = "course_name"
        case userEmail = "user_email"
    }
}

struct GwaTopAdminTodo: Decodable, Identifiable {
    let id: String
    let title: String
    let priority: String
    let dueDate: Date
    let isDone: Bool
    let isAuto: Bool
    let courseId: String
    let courseName: String?
    let userEmail: String?

    enum CodingKeys: String, CodingKey {
        case id, title, priority
        case dueDate = "due_date"
        case isDone = "is_done"
        case isAuto = "is_auto"
        case courseId = "course_id"
        case courseName = "course_name"
        case userEmail = "user_email"
    }
}

struct GwaTopAdminDevice: Decodable, Identifiable {
    let id: String
    let platform: String
    let apnsTokenPreview: String
    let lastSeenAt: Date

    enum CodingKeys: String, CodingKey {
        case id, platform
        case apnsTokenPreview = "apns_token_preview"
        case lastSeenAt = "last_seen_at"
    }
}

struct GwaTopAdminUserDetail: Decodable {
    let user: GwaTopAdminUserBrief
    let semesters: [GwaTopAdminSemester]
    let courses: [GwaTopAdminCourse]
    let files: [GwaTopAdminFile]
    let schedules: [GwaTopAdminSchedule]
    let todos: [GwaTopAdminTodo]
    let devices: [GwaTopAdminDevice]
}

// MARK: - Service

actor GwaTopAdminService {
    static let shared = GwaTopAdminService()

    func fetchOverview() async throws -> GwaTopAdminOverview {
        try await GwaTopAPIClient.shared.get("/v1/admin/overview")
    }

    func fetchUsers() async throws -> [GwaTopAdminUserBrief] {
        try await GwaTopAPIClient.shared.get("/v1/admin/users")
    }

    func fetchUserDetail(userId: String) async throws -> GwaTopAdminUserDetail {
        try await GwaTopAPIClient.shared.get("/v1/admin/users/\(userId)")
    }

    func fetchAllFiles() async throws -> [GwaTopAdminFile] {
        try await GwaTopAPIClient.shared.get("/v1/admin/files")
    }

    func fetchAllSchedules() async throws -> [GwaTopAdminSchedule] {
        try await GwaTopAPIClient.shared.get("/v1/admin/schedules")
    }

    func fetchAllTodos() async throws -> [GwaTopAdminTodo] {
        try await GwaTopAPIClient.shared.get("/v1/admin/todos")
    }
}
