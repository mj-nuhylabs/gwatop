//
//  GwaTopPDFCache.swift
//  GwaTop
//
//  파일별 PDFDocument 영속 캐시 (앱 실행 동안).
//
//  배경:
//   - PDF 탭은 SwiftUI Group/switch 안에서 렌더링됨 → 다른 탭으로 갔다 오면 struct 재생성
//     → @State 의 pdfDocument 가 nil 로 초기화 → 다시 다운로드.
//   - 사용자 입장에선 "한 번 본 PDF 가 또 로딩되는" 끔찍한 UX.
//
//  해결:
//   - 공유 singleton 캐시. 한 번 로드한 PDFDocument 는 file_id 키로 보관.
//   - 파일 학습 화면 진입 시 미리 load(fileId:) 호출 → 사용자가 PDF 탭 누를 때 즉시 표시.
//   - 다른 탭(퀴즈/마인드맵)에 갔다 다시 PDF 와도 캐시 그대로.
//

import Combine
import Foundation
import PDFKit

@MainActor
final class GwaTopPDFCache: ObservableObject {
    static let shared = GwaTopPDFCache()

    /// file_id → PDFDocument. 이미 로드된 것은 즉시 반환.
    @Published private(set) var documents: [String: PDFDocument] = [:]

    /// 진행 중인 로딩 Task. 중복 호출 방지 + 외부에서 진행 상태 관찰 가능.
    private var loadingTasks: [String: Task<Void, Never>] = [:]

    private init() {}

    func document(for fileId: String) -> PDFDocument? {
        documents[fileId]
    }

    func isLoading(_ fileId: String) -> Bool {
        loadingTasks[fileId] != nil
    }

    /// 캐시에 없으면 백그라운드 다운로드 시작. 호출은 idempotent (이미 로딩 중이면 중복 호출 무시).
    func load(fileId: String, fileType: String = "pdf") {
        guard fileType == "pdf" else { return }
        guard documents[fileId] == nil, loadingTasks[fileId] == nil else { return }

        let task = Task { @MainActor in
            defer { loadingTasks[fileId] = nil }
            do {
                let info = try await GwaTopFileService.shared.presignedDownloadURL(fileId: fileId)
                guard let url = URL(string: info.url) else { return }
                // PDFDocument(url:) 는 동기 + Disk I/O. detached 로 백그라운드 큐에서 실행.
                let doc = await Task.detached(priority: .userInitiated) {
                    PDFDocument(url: url)
                }.value
                if let doc {
                    self.documents[fileId] = doc
                }
            } catch {
                // 로딩 실패는 silent — PDF 탭이 자기 상태로 재시도하면 됨.
            }
        }
        loadingTasks[fileId] = task
    }

    /// 메모리 압박 시 또는 명시적 정리. 운영에서 자동 정리는 안 함 — 앱 실행 동안 누적되어도
    /// 일반 학습 세션에선 수십 MB 수준.
    func clear() {
        documents.removeAll()
        loadingTasks.values.forEach { $0.cancel() }
        loadingTasks.removeAll()
    }
}
