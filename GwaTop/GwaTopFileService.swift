//
//  GwaTopFileService.swift
//  GwaTop
//
//  업로드된 강의 자료 목록/상세 조회.
//

import Foundation
import SwiftUI  // GwaTopFileStatusBadge.color (Color 반환)
import Combine  // @Published, ObservableObject — Swift 6 모드에서 SwiftUI re-export 만으로는 부족

/// AI 출력 언어 힌트 — 백엔드 language 파라미터로 전달할 값.
/// 앱 UI 는 아직 한국어 고정이라 인앱 언어 설정이 없으므로 **기기 시스템 언어**를 따른다:
/// 기기가 영어면 "en"(AI 학습물·튜터 답변이 영어로), 그 외엔 nil(기본 한국어 — 요청
/// 페이로드·캐시 scope 모두 기존과 동일해 하위호환). 나중에 인앱 언어 설정이 생기면
/// 이 computed property 의 소스만 바꾸면 모든 호출부에 일괄 반영된다.
enum GwaTopAILanguage {
    static var current: String? {
        Locale.preferredLanguages.first?.lowercased().hasPrefix("en") == true ? "en" : nil
    }
}

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
    let externalURL: String?
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
        case externalURL = "external_url"
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

// MARK: - 학습 탭용 DTO

struct GwaTopPresignedDownload: Decodable {
    let url: String
    let expiresIn: Int
    let filename: String

    enum CodingKeys: String, CodingKey {
        case url
        case expiresIn = "expires_in"
        case filename
    }
}

struct GwaTopAISummarySection: Decodable, Hashable {
    let title: String
    let body: String
}

struct GwaTopAISummary: Decodable, Hashable {
    let headline: String
    let keyPoints: [String]
    let sections: [GwaTopAISummarySection]
    let studyTip: String

    enum CodingKeys: String, CodingKey {
        case headline
        case keyPoints = "key_points"
        case sections
        case studyTip = "study_tip"
    }
}

/// `content` 가 content_type 마다 모양이 달라 일단 raw JSON 으로 받고
/// 각 화면에서 필요한 모양으로 디코딩한다.
struct GwaTopAIContentResponse: Decodable {
    let fileId: String
    let contentType: String
    let status: String        // "pending" | "ready"
    let content: GwaTopJSON?  // pending 일 땐 nil
    let fileStatus: String?
    let generatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case fileId = "file_id"
        case contentType = "content_type"
        case status, content
        case fileStatus = "file_status"
        case generatedAt = "generated_at"
    }

    func summary() -> GwaTopAISummary? {
        guard let json = content else { return nil }
        guard let data = try? JSONEncoder().encode(json) else { return nil }
        return try? GwaTopAPI.makeJSONDecoder().decode(GwaTopAISummary.self, from: data)
    }
}

// MARK: - 학습 탭 7종 DTO

struct GwaTopQuizQuestion: Decodable, Hashable, Identifiable {
    var id: String { question }
    let type: String              // "multiple_choice" | "short_answer"
    let question: String
    let choices: [String]?        // 객관식만
    let answerIndex: Int?         // 객관식만
    let answer: String?           // 주관식만
    let explanation: String

    enum CodingKeys: String, CodingKey {
        case type, question, choices, explanation, answer
        case answerIndex = "answer_index"
    }
}

struct GwaTopQuizContent: Decodable {
    let questions: [GwaTopQuizQuestion]
}

/// 학습 탭의 플래시카드. 옛 Mock 타입 GwaTopFlashcard (GwaTopAcademicModels.swift) 와 충돌을
/// 피하려고 GwaTopAIFlashcard 로 명명. 추후 Mock 제거 시 통합 검토.
struct GwaTopAIFlashcard: Decodable, Hashable, Identifiable {
    var id: String { front }
    let front: String
    let back: String
    let hint: String?
}

struct GwaTopFlashcardContent: Decodable {
    let cards: [GwaTopAIFlashcard]
}

/// `GET /flashcards/status` 응답 — 카드 식별자(front) → "known" | "unknown".
struct GwaTopFlashcardStatusList: Decodable {
    let statuses: [String: String]
}

/// `POST /flashcards/more` 응답 — 기존 카드에 새 카드가 추가된 전체 content + 추가 개수.
struct GwaTopFlashcardMoreResponse: Decodable {
    let content: GwaTopFlashcardContent
    let added: Int
}

struct GwaTopMindmapNode: Decodable, Hashable, Identifiable {
    var id: String { label }
    let label: String
    let children: [GwaTopMindmapNode]
}

struct GwaTopMindmapContent: Decodable {
    let root: String
    let children: [GwaTopMindmapNode]
}

struct GwaTopMemorizePoint: Decodable, Hashable, Identifiable {
    var id: String { "\(category)/\(text)" }
    let category: String
    let text: String
    let importance: Int
}

struct GwaTopMemorizeContent: Decodable {
    let points: [GwaTopMemorizePoint]
}

struct GwaTopTopic: Decodable, Hashable, Identifiable {
    var id: String { title }
    let title: String
    let body: String
    let examples: [String]
}

struct GwaTopTopicsContent: Decodable {
    let topics: [GwaTopTopic]
}

extension GwaTopAIContentResponse {
    private func decode<T: Decodable>(_ type: T.Type) -> T? {
        guard let json = content,
              let data = try? JSONEncoder().encode(json)
        else { return nil }
        return try? GwaTopAPI.makeJSONDecoder().decode(T.self, from: data)
    }

    /// 백엔드가 생성 실패 시 저장한 마커 (`{"error": "..."}`). iOS 가 무한 폴링 안 하고
    /// 즉시 에러 메시지 표시 + 재생성 버튼 노출에 사용.
    var generationError: String? {
        struct Marker: Decodable { let error: String? }
        guard let json = content,
              let data = try? JSONEncoder().encode(json),
              let marker = try? GwaTopAPI.makeJSONDecoder().decode(Marker.self, from: data),
              let err = marker.error, !err.isEmpty
        else { return nil }
        return err
    }

    func quiz() -> GwaTopQuizContent?         { decode(GwaTopQuizContent.self) }
    func flashcards() -> GwaTopFlashcardContent? { decode(GwaTopFlashcardContent.self) }
    func mindmap() -> GwaTopMindmapContent?   { decode(GwaTopMindmapContent.self) }
    func memorize() -> GwaTopMemorizeContent? { decode(GwaTopMemorizeContent.self) }
    func topics() -> GwaTopTopicsContent?     { decode(GwaTopTopicsContent.self) }
}

// MARK: - 노트

struct GwaTopUserNote: Decodable, Identifiable, Equatable {
    let id: String
    let fileId: String
    let title: String?
    let body: String
    let createdAt: Date
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, title, body
        case fileId = "file_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

// MARK: - 튜터

struct GwaTopTutorMessage: Decodable, Identifiable, Equatable {
    let id: String
    let role: String     // "user" | "assistant"
    let body: String
    let tokens: Int?
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, role, body, tokens
        case createdAt = "created_at"
    }
}

struct GwaTopTutorAskResponse: Decodable {
    let userMessage: GwaTopTutorMessage
    let assistantMessage: GwaTopTutorMessage

    enum CodingKeys: String, CodingKey {
        case userMessage = "user_message"
        case assistantMessage = "assistant_message"
    }
}

/// SSE 튜터 스트림 이벤트. 백엔드 `event_stream` 의 5종 페이로드를 그대로 매핑.
enum GwaTopTutorStreamEvent {
    /// 사용자 메시지가 DB 에 저장된 직후 — UI 에 echo 해서 즉시 말풍선 표시.
    case userMessage(GwaTopTutorMessage)
    /// AI 응답 토큰 생성 시작.
    case start
    /// 토큰 청크 (점진 누적).
    case delta(String)
    /// 최종 assistant 메시지 (DB id 포함).
    case done(GwaTopTutorMessage)
    /// 백엔드/OpenAI 에러.
    case error(String)
}

/// 임의 JSON 값을 그대로 보존하기 위한 wrapper (Encodable 재인코딩에 사용).
enum GwaTopJSON: Codable {
    case object([String: GwaTopJSON])
    case array([GwaTopJSON])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let v = try? c.decode(Bool.self) { self = .bool(v); return }
        if let v = try? c.decode(Double.self) { self = .number(v); return }
        if let v = try? c.decode(String.self) { self = .string(v); return }
        if let v = try? c.decode([GwaTopJSON].self) { self = .array(v); return }
        if let v = try? c.decode([String: GwaTopJSON].self) { self = .object(v); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unknown JSON value")
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null:           try c.encodeNil()
        case .bool(let v):    try c.encode(v)
        case .number(let v):  try c.encode(v)
        case .string(let v):  try c.encode(v)
        case .array(let v):   try c.encode(v)
        case .object(let v):  try c.encode(v)
        }
    }
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

    /// 업로드한 파일(강의계획서/학습자료) 삭제. 표준 REST 경로 DELETE /v1/files/{id}.
    func delete(fileId: String) async throws {
        try await GwaTopAPIClient.shared.deleteNoContent("/v1/files/\(fileId)")
    }

    /// 학습 탭 PDF 보기 — S3 presigned GET URL.
    func presignedDownloadURL(fileId: String) async throws -> GwaTopPresignedDownload {
        try await GwaTopAPIClient.shared.get("/v1/files/\(fileId)/presigned-download")
    }

    /// AI 콘텐츠 (summary/quiz/flashcard/...) 조회. scope 가 nil 이면 "all".
    /// 기기 언어가 영어면 language=en 을 붙여 영어 캐시(scope '#en')를 조회한다.
    func aiContent(fileId: String, contentType: String, scope: String? = nil) async throws -> GwaTopAIContentResponse {
        var query: [URLQueryItem] = []
        if let scope, scope != "all", !scope.isEmpty {
            query.append(URLQueryItem(name: "pages", value: scope))
        }
        if let lang = GwaTopAILanguage.current {
            query.append(URLQueryItem(name: "language", value: lang))
        }
        return try await GwaTopAPIClient.shared.get(
            "/v1/files/\(fileId)/ai-contents/\(contentType)",
            query: query
        )
    }

    /// AI 콘텐츠 생성 요청. 백엔드는 캐시가 있으면 즉시 ready 응답,
    /// 없으면 Celery 워커로 큐잉 후 202 ("queued") 반환. force=true 면 캐시 무시 후 재생성.
    /// `excludeQuestions` 는 퀴즈 한정 — 이전에 출제됐던 문제 텍스트를 넘기면 GPT 가 중복을 피한다.
    func generateAIContent(
        fileId: String, contentType: String, pages: String? = nil, force: Bool = false,
        excludeQuestions: [String]? = nil
    ) async throws -> GwaTopAIContentResponse {
        struct Body: Encodable {
            let pages: String?
            let force: Bool
            let exclude_questions: [String]?
            let language: String?
        }
        // 기기 언어가 영어면 AI 출력도 영어로 (nil 이면 백엔드 기본 한국어).
        let body = Body(pages: pages, force: force, exclude_questions: excludeQuestions,
                        language: GwaTopAILanguage.current)
        return try await GwaTopAPIClient.shared.post(
            "/v1/files/\(fileId)/ai-contents/\(contentType)/generate",
            body: body
        )
    }

    /// Speculative prefetch — 파일 학습 화면 진입 시 호출. 백엔드가 5종 학습 콘텐츠를
    /// 'all' scope 으로 백그라운드 큐잉. 이미 결과가 있는 type 은 워커에서 즉시 skip.
    /// 사용자가 인트로 보는 동안 백엔드가 미리 만들어 두어, '시작' 버튼 클릭 시 캐시 hit.
    func prefetchAIContents(fileId: String) async {
        struct Response: Decodable {}
        do {
            let _: Response = try await GwaTopAPIClient.shared.postEmpty(
                "/v1/files/\(fileId)/ai-contents/prefetch"
            )
        } catch {
            // 단순 hint 라 실패해도 무시. 사용자가 시작 버튼 누르면 그때 generate 가 트리거됨.
        }
    }

    /// 큐잉된 작업의 완료를 폴링한다. ready 응답 받을 때까지 `pollInterval` 마다 재조회.
    /// `maxAttempts` 회 초과 시 마지막 응답 반환 (status="pending" 그대로).
    /// View 의 Task 가 취소되면 즉시 중단되므로 .task modifier 안에서 호출하면 안전.
    func generateAIContentAndWait(
        fileId: String,
        contentType: String,
        pages: String? = nil,
        force: Bool = false,
        excludeQuestions: [String]? = nil,
        // 1초 간격 폴링 — 백엔드 GET 한 번이라 부담 미미. OpenAI 가 5초만에 끝나면
        // 사용자도 5초 안에 결과 받음 (기존 3초 폴링은 최대 3초 손실).
        pollInterval: TimeInterval = 1.0,
        maxAttempts: Int = 90
    ) async throws -> GwaTopAIContentResponse {
        // 1) generate POST — 캐시 있으면 ready 즉시, 없으면 queued.
        let initial = try await generateAIContent(
            fileId: fileId, contentType: contentType, pages: pages, force: force,
            excludeQuestions: excludeQuestions
        )
        if initial.status == "ready" { return initial }

        // 2) GET 폴링.
        for attempt in 0..<maxAttempts {
            try Task.checkCancellation()
            let ns = UInt64(pollInterval * 1_000_000_000)
            try await Task.sleep(nanoseconds: ns)
            let resp = try await aiContent(
                fileId: fileId, contentType: contentType, scope: pages
            )
            if resp.status == "ready" { return resp }
            _ = attempt
        }
        // maxAttempts 까지 못 받았으면 마지막 상태 반환 (UI 에서 "다시 시도" 안내).
        return try await aiContent(fileId: fileId, contentType: contentType, scope: pages)
    }

    /// summary 전용 재생성 — files 라우트.
    @discardableResult
    func regenerateAIContent(fileId: String, contentType: String) async throws -> [String: String] {
        try await GwaTopAPIClient.shared.postEmpty(
            "/v1/files/\(fileId)/ai-contents/\(contentType)/regenerate"
        )
    }

    // MARK: - 플래시카드 상태 (알아요 / 몰라요)

    /// 사용자가 이 파일/scope 에서 이전에 마킹한 카드 상태 전체. 카드 시작 시 한 번만 호출.
    func flashcardStatuses(fileId: String, scope: String? = nil) async throws -> [String: String] {
        var query: [URLQueryItem] = []
        if let scope, scope != "all", !scope.isEmpty {
            query.append(URLQueryItem(name: "pages", value: scope))
        }
        let resp: GwaTopFlashcardStatusList = try await GwaTopAPIClient.shared.get(
            "/v1/files/\(fileId)/flashcards/status", query: query
        )
        return resp.statuses
    }

    /// 카드 한 장의 상태 저장 또는 해제. status 가 nil 이면 "none" (해제) 으로 전송.
    @discardableResult
    func setFlashcardStatus(
        fileId: String, scope: String? = nil,
        cardFront: String, status: String?
    ) async throws -> [String: String] {
        struct Body: Encodable {
            let card_front: String
            let status: String
            let pages: String?
        }
        let pages = (scope == "all" || (scope?.isEmpty ?? true)) ? nil : scope
        let body = Body(
            card_front: cardFront,
            status: status ?? "none",
            pages: pages,
        )
        let resp: [String: GwaTopJSON] = try await GwaTopAPIClient.shared.put(
            "/v1/files/\(fileId)/flashcards/status", body: body
        )
        _ = resp
        return [:]
    }

    /// 기존 카드와 다른 새 카드를 동기적으로 생성 후 append. OpenAI 호출 동안 5~10초 대기.
    /// 기기 언어가 영어면 영어 덱(scope '#en')에 영어 카드를 append 한다.
    func generateMoreFlashcards(fileId: String, scope: String? = nil) async throws -> GwaTopFlashcardMoreResponse {
        struct Body: Encodable { let pages: String?; let language: String? }
        let pages = (scope == "all" || (scope?.isEmpty ?? true)) ? nil : scope
        return try await GwaTopAPIClient.shared.post(
            "/v1/files/\(fileId)/flashcards/more",
            body: Body(pages: pages, language: GwaTopAILanguage.current)
        )
    }

    // MARK: - 노트

    func listNotes(fileId: String) async throws -> [GwaTopUserNote] {
        try await GwaTopAPIClient.shared.get("/v1/files/\(fileId)/notes")
    }

    func createNote(fileId: String, title: String?, body: String) async throws -> GwaTopUserNote {
        struct Body: Encodable { let title: String?; let body: String }
        return try await GwaTopAPIClient.shared.post(
            "/v1/files/\(fileId)/notes",
            body: Body(title: title, body: body)
        )
    }

    func updateNote(fileId: String, noteId: String, title: String?, body: String?) async throws -> GwaTopUserNote {
        struct Body: Encodable { let title: String?; let body: String? }
        return try await GwaTopAPIClient.shared.patch(
            "/v1/files/\(fileId)/notes/\(noteId)",
            body: Body(title: title, body: body)
        )
    }

    func deleteNote(fileId: String, noteId: String) async throws {
        try await GwaTopAPIClient.shared.deleteNoContent("/v1/files/\(fileId)/notes/\(noteId)")
    }

    // MARK: - 튜터

    func listTutorMessages(fileId: String) async throws -> [GwaTopTutorMessage] {
        try await GwaTopAPIClient.shared.get("/v1/files/\(fileId)/tutor/messages")
    }

    func askTutor(
        fileId: String,
        question: String,
        images: [String]? = nil
    ) async throws -> GwaTopTutorAskResponse {
        struct Body: Encodable {
            let question: String
            let images: [String]?
            let language: String?
        }
        return try await GwaTopAPIClient.shared.post(
            "/v1/files/\(fileId)/tutor/messages",
            body: Body(question: question, images: images,
                       language: GwaTopAILanguage.current)
        )
    }

    /// SSE 스트리밍 채널 열기. 호출자는 AsyncThrowingStream 으로 이벤트를 받는다.
    /// 각 이벤트는 GwaTopTutorStreamEvent (start/delta/done/error/userMessage).
    /// nonisolated — Stream 자체는 actor 격리 밖에서 동작해야 SwiftUI .task 안에서 자유롭게 사용 가능.
    nonisolated func askTutorStream(
        fileId: String,
        question: String,
        images: [String]? = nil
    ) -> AsyncThrowingStream<GwaTopTutorStreamEvent, Error> {
        GwaTopAPIClient.shared.tutorSSEStream(
            path: "/v1/files/\(fileId)/tutor/messages/stream",
            question: question,
            images: images,
            language: GwaTopAILanguage.current
        )
    }

    func clearTutorMessages(fileId: String) async throws {
        try await GwaTopAPIClient.shared.deleteNoContent("/v1/files/\(fileId)/tutor/messages")
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
    /// 일반 강의 자료 업로드 (syllabus 아님) 의 S3 PUT + confirm 이 끝났음을 알린다.
    /// 학습 탭이 구독해서 즉시 fileByCourse 갱신 → 방금 올린 자료가 바로 목록에 보이게.
    /// userInfo["course_id"] = String, userInfo["file_id"] = String.
    static let materialUploadCompleted = Notification.Name("GwaTopMaterialUploadCompleted")
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
