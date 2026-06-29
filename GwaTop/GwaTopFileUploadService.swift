//
//  GwaTopFileUploadService.swift
//  GwaTop
//
//  강의 자료 / 강의계획서 업로드 파이프라인:
//    1) POST /v1/courses/{courseId}/files/presigned-url
//    2) PUT  upload_url (S3 직접 업로드)
//    3) POST /v1/courses/{courseId}/files/{fileId}/confirm
//

import Foundation

struct GwaTopPresignedRequest: Encodable {
    let filename: String
    let fileType: String
    let fileSizeBytes: Int
    let isSyllabus: Bool

    enum CodingKeys: String, CodingKey {
        case filename
        case fileType      = "file_type"
        case fileSizeBytes = "file_size_bytes"
        case isSyllabus    = "is_syllabus"
    }
}

struct GwaTopPresignedResponse: Decodable {
    let uploadUrl: String
    let storageKey: String
    let fileId: String

    enum CodingKeys: String, CodingKey {
        case uploadUrl  = "upload_url"
        case storageKey = "storage_key"
        case fileId     = "file_id"
    }
}

struct GwaTopFileDTO: Decodable {
    let id: String
    let status: String
    let isSyllabus: Bool
    let parseError: String?

    enum CodingKeys: String, CodingKey {
        case id, status
        case isSyllabus = "is_syllabus"
        case parseError = "parse_error"
    }
}

struct GwaTopFileConfirmResponse: Decodable {
    let file: GwaTopFileDTO
}

/// /v1/files/{id}/debug 응답 (status 폴링용)
struct GwaTopFileDebugResponse: Decodable {
    struct FileBlock: Decodable {
        let id: String
        let status: String
        let parseError: String?

        enum CodingKeys: String, CodingKey {
            case id, status
            case parseError = "parse_error"
        }
    }
    let file: FileBlock
    let schedulesCount: Int

    enum CodingKeys: String, CodingKey {
        case file
        case schedulesCount = "schedules_count"
    }
}

actor GwaTopFileUploadService {
    static let shared = GwaTopFileUploadService()

    /// 파일을 업로드하고 confirm까지 완료. Celery 파싱은 비동기로 진행됨.
    /// - Returns: 업로드된 file_id
    func upload(
        courseId: String,
        filename: String,
        fileType: String,
        data: Data,
        isSyllabus: Bool
    ) async throws -> String {
        let req = GwaTopPresignedRequest(
            filename: filename,
            fileType: fileType,
            fileSizeBytes: data.count,
            isSyllabus: isSyllabus
        )
        let presigned: GwaTopPresignedResponse = try await GwaTopAPIClient.shared.post(
            "/v1/courses/\(courseId)/files/presigned-url",
            body: req
        )

        let contentType = Self.contentType(for: fileType)
        try await GwaTopAPIClient.shared.uploadPUT(
            toAbsoluteURL: presigned.uploadUrl,
            body: data,
            contentType: contentType
        )

        let _: GwaTopFileConfirmResponse = try await GwaTopAPIClient.shared.postEmpty(
            "/v1/courses/\(courseId)/files/\(presigned.fileId)/confirm"
        )

        return presigned.fileId
    }

    /// 과목을 미리 선택하지 않고 강의계획서만 업로드. 백엔드가 파싱 결과로 자동
    /// 과목 매칭/생성 후 file.course_id 를 채운다.
    /// - Returns: 업로드된 file_id (파싱 진행 중인 동안엔 course_id 는 NULL)
    func uploadSyllabusWithoutCourse(
        filename: String,
        data: Data,
        fileType: String = "pdf"
    ) async throws -> String {
        let req = GwaTopPresignedRequest(
            filename: filename,
            fileType: fileType,
            fileSizeBytes: data.count,
            isSyllabus: true
        )
        let presigned: GwaTopPresignedResponse = try await GwaTopAPIClient.shared.post(
            "/v1/files/syllabus/presigned-url",
            body: req
        )

        let contentType = Self.contentType(for: fileType)
        try await GwaTopAPIClient.shared.uploadPUT(
            toAbsoluteURL: presigned.uploadUrl,
            body: data,
            contentType: contentType
        )

        let _: GwaTopFileConfirmResponse = try await GwaTopAPIClient.shared.postEmpty(
            "/v1/files/syllabus/\(presigned.fileId)/confirm"
        )

        return presigned.fileId
    }

    /// 무차별(auto) 업로드 — 학기/과목/타입을 미리 지정하지 않고 아무 파일이나 올린다.
    /// 백엔드가 텍스트를 추출해 강의계획서(→ 과목 매칭/생성 + 시험·과제 일정 자동 등록)인지
    /// 강의자료(→ 과목 매칭/생성 + 주차 자동 분류)인지 스스로 판정하고, file.course_id 도
    /// 백엔드가 채운다. (classification_source="auto_pending" 마커 → 워커의 _auto_dispatch)
    /// - Returns: 업로드된 file_id (분류 진행 중인 동안엔 course_id 는 NULL)
    func uploadAuto(
        filename: String,
        data: Data,
        fileType: String
    ) async throws -> String {
        let req = GwaTopPresignedRequest(
            filename: filename,
            fileType: fileType,
            fileSizeBytes: data.count,
            isSyllabus: false  // 무의미 — 백엔드가 auto_pending 마커로 종류를 직접 판정한다.
        )
        let presigned: GwaTopPresignedResponse = try await GwaTopAPIClient.shared.post(
            "/v1/files/auto/presigned-url",
            body: req
        )

        let contentType = Self.contentType(for: fileType)
        try await GwaTopAPIClient.shared.uploadPUT(
            toAbsoluteURL: presigned.uploadUrl,
            body: data,
            contentType: contentType
        )

        let _: GwaTopFileConfirmResponse = try await GwaTopAPIClient.shared.postEmpty(
            "/v1/files/auto/\(presigned.fileId)/confirm"
        )

        return presigned.fileId
    }

    /// 유튜브 영상 링크를 강의자료로 등록. S3 업로드 없이 백엔드가 자막을 추출한다.
    /// - Returns: 생성된 file_id (자막 추출/분류는 비동기로 진행)
    func addYouTubeLink(courseId: String, youtubeURL: String) async throws -> String {
        struct Req: Encodable {
            let youtubeURL: String
            enum CodingKeys: String, CodingKey { case youtubeURL = "youtube_url" }
        }
        let resp: GwaTopFileConfirmResponse = try await GwaTopAPIClient.shared.post(
            "/v1/courses/\(courseId)/files/youtube",
            body: Req(youtubeURL: youtubeURL)
        )
        return resp.file.id
    }

    /// 파일 파싱 완료까지 폴링.
    /// - Returns: (성공 여부, 마지막 status, 에러 메시지, 최종 schedules_count)
    func waitForParseCompletion(
        fileId: String,
        timeoutSeconds: Int = 45,
        pollIntervalSeconds: Double = 2.0
    ) async -> (succeeded: Bool, status: String, error: String?, schedulesCount: Int) {
        let maxAttempts = max(1, Int(Double(timeoutSeconds) / pollIntervalSeconds))
        let pollNs = UInt64(pollIntervalSeconds * 1_000_000_000)

        var lastStatus = "unknown"
        var lastErr: String? = nil
        var lastCount = 0

        for attempt in 0..<maxAttempts {
            do {
                let debug: GwaTopFileDebugResponse = try await GwaTopAPIClient.shared.get(
                    "/v1/files/\(fileId)/debug"
                )
                lastStatus = debug.file.status
                lastErr = debug.file.parseError
                lastCount = debug.schedulesCount

                if debug.file.status == "parsed" {
                    return (true, lastStatus, lastErr, lastCount)
                }
                if debug.file.status == "failed" {
                    return (false, lastStatus, lastErr, lastCount)
                }
            } catch {
                // 일시적 네트워크 에러는 무시하고 계속 폴링
                print("[Upload] poll attempt \(attempt) failed: \(error)")
            }
            try? await Task.sleep(nanoseconds: pollNs)
        }

        return (false, lastStatus, lastErr ?? "타임아웃 (\(timeoutSeconds)초)", lastCount)
    }

    /// 일반 강의 자료(비-syllabus)의 백엔드 처리가 끝났는지(분류 완료/실패) 폴링.
    /// 학습 탭 행이 "처리 중" → "준비 완료" 로 바뀌는 시점을, 뷰 생명주기와 무관한
    /// 업로드 task 가 직접 감지하기 위한 용도. (상세 화면이 목록을 가려 목록 자체
    /// 폴링이 멈춰도 여기서 완료를 잡아낸다.)
    /// - Returns: 마지막으로 관찰된 status (예: "classified", "unclassified", "failed").
    func waitForMaterialSettled(
        fileId: String,
        timeoutSeconds: Int = 120,
        pollIntervalSeconds: Double = 2.0
    ) async -> String {
        // 아직 처리 중인 상태들. 이 집합을 벗어나면(classified/unclassified/failed 등) 종료.
        // GwaTopAIStudyView.inProgressStatuses 와 동일하게 유지한다.
        let inProgress: Set<String> = [
            "pending", "uploading", "processing", "extracting",
            "extracted", "parsing", "classifying"
        ]
        let maxAttempts = max(1, Int(Double(timeoutSeconds) / pollIntervalSeconds))
        let pollNs = UInt64(pollIntervalSeconds * 1_000_000_000)

        var lastStatus = "processing"
        for _ in 0..<maxAttempts {
            if Task.isCancelled { return lastStatus }
            do {
                let debug: GwaTopFileDebugResponse = try await GwaTopAPIClient.shared.get(
                    "/v1/files/\(fileId)/debug"
                )
                lastStatus = debug.file.status
                if !inProgress.contains(debug.file.status) {
                    return lastStatus   // 종료 상태 도달 (분류 완료/실패 등)
                }
            } catch {
                // 일시적 네트워크 에러는 무시하고 다음 폴 때 재시도.
            }
            try? await Task.sleep(nanoseconds: pollNs)
        }
        return lastStatus
    }

    private static func contentType(for fileType: String) -> String {
        switch fileType {
        case "pdf":   return "application/pdf"
        case "pptx":  return "application/vnd.openxmlformats-officedocument.presentationml.presentation"
        case "docx":  return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case "image": return "image/jpeg"
        default:      return "application/octet-stream"
        }
    }
}
