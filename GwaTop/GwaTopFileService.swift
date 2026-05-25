//
//  GwaTopFileService.swift
//  GwaTop
//
//  업로드된 강의 자료 목록/상세 조회.
//

import Foundation
import SwiftUI  // GwaTopFileStatusBadge.color (Color 반환)

struct GwaTopFileSummary: Decodable, Identifiable, Equatable {
    let id: String
    let courseId: String
    let filename: String
    let fileType: String
    let status: String
    let week: Int?
    let aiConfidence: Double?
    let classificationSource: String?
    let isSyllabus: Bool
    let parseError: String?
    let createdAt: Date
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case courseId = "course_id"
        case filename
        case fileType = "file_type"
        case status
        case week
        case aiConfidence = "ai_confidence"
        case classificationSource = "classification_source"
        case isSyllabus = "is_syllabus"
        case parseError = "parse_error"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

struct GwaTopFileDebugCourse: Decodable {
    let id: String
    let name: String
    let weeklyTopicsCount: Int?
    let hasWeekEmbeddings: Bool?

    enum CodingKeys: String, CodingKey {
        case id, name
        case weeklyTopicsCount = "weekly_topics_count"
        case hasWeekEmbeddings = "has_week_embeddings"
    }
}

struct GwaTopFileDebugFile: Decodable {
    let id: String
    let filename: String
    let status: String
    let week: Int?
    let aiConfidence: Double?
    let classificationSource: String?
    let isSyllabus: Bool
    let parseError: String?
    let extractedTextLength: Int
    let extractedTextPreview: String

    enum CodingKeys: String, CodingKey {
        case id, filename, status, week
        case aiConfidence = "ai_confidence"
        case classificationSource = "classification_source"
        case isSyllabus = "is_syllabus"
        case parseError = "parse_error"
        case extractedTextLength = "extracted_text_length"
        case extractedTextPreview = "extracted_text_preview"
    }
}

struct GwaTopFileDebug: Decodable {
    let file: GwaTopFileDebugFile
    let course: GwaTopFileDebugCourse
}

actor GwaTopFileService {
    static let shared = GwaTopFileService()

    func fetchFiles(courseId: String) async throws -> [GwaTopFileSummary] {
        try await GwaTopAPIClient.shared.get("/v1/courses/\(courseId)/files")
    }

    func fetchDebug(fileId: String) async throws -> GwaTopFileDebug {
        try await GwaTopAPIClient.shared.get("/v1/files/\(fileId)/debug")
    }

    /// 현재 진행 중인 강의계획서 파일 목록 (status in pending/uploading/processing/extracted/parsing).
    /// GwaTopSyllabusWatcher 가 사용 — 시트가 닫힌 뒤에도 백그라운드로 완료 시점 감지.
    func fetchInFlightSyllabi() async throws -> [GwaTopFileSummary] {
        try await GwaTopAPIClient.shared.get("/v1/files/in-flight-syllabi")
    }

    /// 분류 결과가 부정확할 때 다시 자동 분류를 실행한다.
    func reclassify(fileId: String) async throws {
        let _: ReclassifyResponse = try await GwaTopAPIClient.shared.postEmpty(
            "/v1/files/\(fileId)/reclassify"
        )
    }

    private struct ReclassifyResponse: Decodable {
        let fileId: String
        let status: String

        enum CodingKeys: String, CodingKey {
            case fileId = "file_id"
            case status
        }
    }
}

// MARK: - 분류 상태 라벨/색상

enum GwaTopFileStatusBadge {
    case classified(week: Int?, confidence: Double?)
    case classifying
    case extracted
    case processing
    case unclassified
    case failed(reason: String?)
    case other(String)

    static func from(_ summary: GwaTopFileSummary) -> GwaTopFileStatusBadge {
        switch summary.status {
        case "classified":
            return .classified(week: summary.week, confidence: summary.aiConfidence)
        case "classifying":
            return .classifying
        case "extracted":
            return .extracted
        case "processing", "extracting", "parsing":
            return .processing
        case "unclassified":
            return .unclassified
        case "failed":
            return .failed(reason: summary.parseError)
        default:
            return .other(summary.status)
        }
    }

    var label: String {
        switch self {
        case .classified(let week, let conf):
            let w = week.map { "\($0)주차" } ?? "분류됨"
            if let conf {
                return "\(w) · \(Int(conf * 100))%"
            }
            return w
        case .classifying:   return "분류 중…"
        case .extracted:     return "분류 대기"
        case .processing:    return "처리 중"
        case .unclassified:  return "미분류"
        case .failed(let r): return "실패\(r.map { " · \($0)" } ?? "")"
        case .other(let s):  return s
        }
    }

    var color: Color {
        switch self {
        case .classified:                 return .green
        case .classifying, .processing:   return .orange
        case .extracted:                  return .blue
        case .unclassified:               return .gray
        case .failed:                     return .red
        case .other:                      return .gray
        }
    }
}

/// 강의 자료 분류 출처 라벨 (`classification_source` 응답 값을 한국어로 변환).
enum GwaTopClassificationSource {
    static func label(_ src: String) -> String {
        switch src {
        case "filename":  return "파일명 기반"
        case "embedding": return "AI 임베딩"
        case "manual":    return "수동 지정"
        default:          return src
        }
    }
}
