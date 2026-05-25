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
/// 왜 필요한가:
///  - 업로드 시트는 confirm 직후 즉시 닫힘 (사용자가 30~45초 멍 때리지 않게).
///  - 그 후에도 사용자는 캘린더/홈 어디에서나 "지금 분석 중인지" 알 수 있어야 함.
///  - 완료되면 캘린더가 자동 새로고침되어야 함.
///
/// 동작:
///  - 앱이 foreground 일 때만 폴링 (background 진입 시 task 취소).
///  - 8초 간격으로 GET /v1/files/in-flight-syllabi.
///  - 직전 폴 결과와 비교해서 사라진 file_id 가 있으면 "완료(또는 실패)" 로 간주하고
///    NotificationCenter 로 .syllabusParseCompleted 발행.
///  - 캘린더/홈 뷰가 그 알림을 받아 자동 reload.
@MainActor
final class GwaTopSyllabusWatcher: ObservableObject {
    static let shared = GwaTopSyllabusWatcher()

    /// UI 가 표시할 진행 중 syllabus 목록. 캘린더 배너의 데이터 소스.
    @Published private(set) var inFlight: [GwaTopFileSummary] = []
    /// 마지막 폴 시간. 디버그/UI 표시용.
    @Published private(set) var lastPolledAt: Date? = nil

    private var pollingTask: Task<Void, Never>? = nil
    /// 폴 간격. 너무 짧으면 서버/배터리 부담, 너무 길면 사용자 체감 latency 증가.
    /// 8초면 30초 파싱 기준 평균 12초 지연으로 완료 감지.
    private let pollInterval: TimeInterval = 8.0

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

    /// 업로드 시트가 confirm 직후 호출. 즉시 1회 폴해서 inFlight 에 새 파일 추가.
    /// (그냥 polling 다음 tick 기다리면 최대 8초 늦게 보임 — 즉시성 위해 즉발 폴.)
    ///
    /// 폴링이 어떤 이유로든 멈춰있어도 업로드 시점에 자동 시작되도록 startWatching 동반.
    func notifyUploaded(fileId: String) {
        print("[SyllabusWatcher] notifyUploaded: \(fileId)")
        startWatching()  // idempotent — 이미 도는 중이면 무시됨
        Task { await pollOnce(reason: "after-upload") }
    }

    // MARK: - 내부

    private func pollLoop() async {
        // 첫 폴은 즉시 (앱 시작 시 진행 중 작업이 이미 있을 수 있음).
        await pollOnce(reason: "loop-start")
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
            if Task.isCancelled { break }
            await pollOnce(reason: "loop-tick")
        }
        print("[SyllabusWatcher] pollLoop exited")
    }

    private func pollOnce(reason: String) async {
        print("[SyllabusWatcher] pollOnce(\(reason)) — calling fetchInFlightSyllabi")
        do {
            let fresh = try await GwaTopFileService.shared.fetchInFlightSyllabi()
            let previousIds = Set(inFlight.map(\.id))
            let freshIds = Set(fresh.map(\.id))

            // previous 에 있었는데 fresh 에 없는 = 완료(parsed) 또는 실패(failed) 로 빠진 것.
            let completed = previousIds.subtracting(freshIds)
            let added = freshIds.subtracting(previousIds)
            self.inFlight = fresh
            self.lastPolledAt = Date()

            print("[SyllabusWatcher] poll done — inFlight=\(fresh.count) (prev=\(previousIds.count), added=\(added.count), completed=\(completed.count))")
            for fileId in completed {
                print("[SyllabusWatcher] >>> COMPLETED: \(fileId) — posting .syllabusParseCompleted")
                NotificationCenter.default.post(
                    name: .syllabusParseCompleted,
                    object: nil,
                    userInfo: ["file_id": fileId]
                )
            }
        } catch {
            // 폴 실패는 silent — 다음 tick 에서 다시 시도. 네트워크 일시 끊김 대비.
            if isCancellation(error) {
                print("[SyllabusWatcher] poll cancelled")
                return
            }
            print("[SyllabusWatcher] !!! poll FAILED: \(error.localizedDescription) (\(error))")
        }
    }
}
