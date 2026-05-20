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
