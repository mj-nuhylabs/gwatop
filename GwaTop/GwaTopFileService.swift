//
//  GwaTopFileService.swift
//  GwaTop
//
//  업로드된 강의 자료 목록/상세 조회.
//

import Foundation
import SwiftUI  // GwaTopFileStatusBadge.color (Color 반환)
import Combine  // @Published, ObservableObject — Swift 6 모드에서 SwiftUI re-export 만으로는 부족

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

// MARK: - Syllabus Watcher (전역 파싱 진행 추적)
// 별도 파일로 만들면 Xcode pbxproj 등록이 필요해서 같은 파일에 둠.

extension Notification.Name {
    /// 강의계획서 파싱이 끝났음을 알리는 알림. userInfo["file_id"] = String.
    static let syllabusParseCompleted = Notification.Name("GwaTopSyllabusParseCompleted")
}

/// 강의계획서 파싱 진행 상태를 백그라운드에서 추적하는 글로벌 ObservableObject.
///
/// 설계: 업로드 시트가 confirm 받자마자 notifyUploaded(fileId:) 로 추적 ID 를
/// 등록. watcher 가 각 ID 마다 GET /v1/files/{id}/debug 로 status 폴링.
/// status 가 "parsed" 또는 "failed" 가 되면 추적에서 빼고 .syllabusParseCompleted 발행.
///
/// EC2 의 라우트 등록 상태와 무관하게 동작 — fetchDebug 는 Day 4 부터 있던 안정된
/// endpoint 라 어떤 배포 상태에서도 작동.
///
/// 한계: 앱 재시작 시 trackedIds 가 메모리에서 사라짐 → 백그라운드 진행 중 작업은
/// 다음 reload 때 (예: 캘린더 진입 시 events 조회) 자연스럽게 반영.
@MainActor
final class GwaTopSyllabusWatcher: ObservableObject {
    static let shared = GwaTopSyllabusWatcher()

    /// 추적 중인 file_id 집합. 시트가 notifyUploaded 로 추가하고, pollOnce 가 완료 시 제거.
    @Published private(set) var inFlightFileIds: Set<String> = []
    /// 마지막 폴 시간. 디버그/UI 표시용.
    @Published private(set) var lastPolledAt: Date? = nil

    private var pollingTask: Task<Void, Never>? = nil
    /// 폴 간격. fileId 기반은 호출 수가 N(보통 1-2)으로 한정되어 2초도 부담 없음.
    /// 백엔드 파싱이 4-5초로 빨라진 만큼 사용자 체감 latency 추가 단축.
    private let pollInterval: TimeInterval = 2.0

    private init() {
        print("[SyllabusWatcher] init — singleton created")
    }

    /// 앱 foreground 진입 시 호출. 이미 실행 중이면 idempotent.
    func startWatching() {
        if pollingTask != nil {
            print("[SyllabusWatcher] startWatching — already running, skip")
            return
        }
        print("[SyllabusWatcher] startWatching — beginning poll loop")
        pollingTask = Task { [weak self] in
            await self?.pollLoop()
        }
    }

    /// 앱 background 진입 시 호출. polling task 취소.
    func stopWatching() {
        print("[SyllabusWatcher] stopWatching — cancelling poll loop")
        pollingTask?.cancel()
        pollingTask = nil
    }

    /// 업로드 시트가 confirm 직후 호출. fileId 를 추적 시작.
    func notifyUploaded(fileId: String) {
        print("[SyllabusWatcher] notifyUploaded: \(fileId)")
        inFlightFileIds.insert(fileId)
        startWatching()  // idempotent
        Task { await pollOnce(reason: "after-upload") }
    }

    // MARK: - 내부

    private func pollLoop() async {
        await pollOnce(reason: "loop-start")
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
            if Task.isCancelled { break }
            // 추적할 ID 가 없으면 폴 스킵 — 네트워크 호출 0
            if !inFlightFileIds.isEmpty {
                await pollOnce(reason: "loop-tick")
            }
        }
        print("[SyllabusWatcher] pollLoop exited")
    }

    private func pollOnce(reason: String) async {
        let ids = inFlightFileIds
        guard !ids.isEmpty else {
            self.lastPolledAt = Date()
            return
        }
        print("[SyllabusWatcher] pollOnce(\(reason)) — checking \(ids.count) id(s)")

        var completed: Set<String> = []
        for id in ids {
            do {
                let debug = try await GwaTopFileService.shared.fetchDebug(fileId: id)
                let status = debug.file.status
                print("[SyllabusWatcher]   id=\(id) status=\(status)")
                if status == "parsed" || status == "failed" {
                    completed.insert(id)
                }
            } catch {
                if isCancellation(error) { return }
                print("[SyllabusWatcher]   id=\(id) fetchDebug failed: \(error.localizedDescription)")
                // 호출 실패는 그냥 다음 폴 때 재시도. 일시적 네트워크 끊김 대비.
            }
        }

        self.lastPolledAt = Date()
        for id in completed {
            inFlightFileIds.remove(id)
            print("[SyllabusWatcher] >>> COMPLETED: \(id) — posting .syllabusParseCompleted")
            NotificationCenter.default.post(
                name: .syllabusParseCompleted,
                object: nil,
                userInfo: ["file_id": id]
            )
        }
    }
}
