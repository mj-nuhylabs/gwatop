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
