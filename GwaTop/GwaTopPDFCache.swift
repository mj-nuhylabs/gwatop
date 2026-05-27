//
//  GwaTopPDFCache.swift
//  GwaTop
//
//  파일별 PDFDocument 메모리 캐시 + 다운로드 양보(suspend) + TTL 자동 정리.
//
//  배경:
//   - PDF 탭은 SwiftUI Group/switch 안에서 렌더링됨 → 다른 탭으로 갔다 오면 struct 재생성.
//     → @State 의 pdfDocument 가 nil 로 초기화 → 다시 다운로드.
//   - 사용자 입장에선 "한 번 본 PDF 가 또 로딩되는" 끔찍한 UX.
//
//  해결:
//   - 공유 singleton 캐시. 한 번 로드한 PDFDocument 는 file_id 키로 보관.
//   - 파일 학습 화면 진입 시 미리 load(fileId:) 호출 → 사용자가 PDF 탭 누를 때 즉시 표시.
//
//  추가된 두 가지 정책 (메모리 낭비 + 네트워크 대역폭 경쟁 완화):
//   1) TTL 자동 정리 — FileStudyView 가 dismiss 되면 scheduleEviction() 호출.
//      10분 안에 같은 파일로 재진입하면 cancelEviction() 으로 취소되고 캐시 유지.
//      메모리 경고(UIApplication.didReceiveMemoryWarningNotification) 수신 시 즉시 clear().
//   2) AI 생성 양보 — 퀴즈/플래시카드/마인드맵/암기/주요 주제 생성 직전에
//      suspendDownload() 가 호출되면 진행 중인 URLSessionDataTask 를 suspend.
//      생성 끝나고 resumeDownload() 로 재개. ref-counted 라 동시 호출 안전.
//

import Combine
import Foundation
import PDFKit
import UIKit

@MainActor
final class GwaTopPDFCache: ObservableObject {
    static let shared = GwaTopPDFCache()

    /// file_id → PDFDocument. 이미 로드된 것은 즉시 반환.
    @Published private(set) var documents: [String: PDFDocument] = [:]

    /// 진행 중인 wrapper Task (presign + 다운로드 + PDFDocument 생성).
    private var loadingTasks: [String: Task<Void, Never>] = [:]

    /// 진행 중인 URLSession data task. suspend()/resume() 를 호출하려면 별도 보관 필요.
    private var downloadTasks: [String: URLSessionDataTask] = [:]

    /// fileId → 자동 정리 대기 Task. cancel() 로 정리 취소.
    private var evictionTasks: [String: Task<Void, Never>] = [:]

    /// 양보 요청 카운트. 여러 탭의 generate 가 겹쳐도 안전한 ref counting.
    private var suspensionCount: Int = 0

    /// 자동 정리까지 대기 시간 (10분). 같은 파일 재진입 시 타이머 취소.
    private static let evictionDelay: TimeInterval = 600

    private init() {
        observeMemoryWarning()
    }

    private func observeMemoryWarning() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.clear()
            }
        }
    }

    // MARK: - 조회

    func document(for fileId: String) -> PDFDocument? {
        // 접근이 있었다는 건 곧 다시 쓰일 가능성 — eviction 취소.
        cancelEviction(fileId: fileId)
        return documents[fileId]
    }

    func isLoading(_ fileId: String) -> Bool {
        loadingTasks[fileId] != nil
    }

    // MARK: - 로딩

    /// 캐시에 없으면 백그라운드 다운로드 시작. idempotent.
    func load(fileId: String, fileType: String = "pdf") {
        guard fileType == "pdf" else { return }
        cancelEviction(fileId: fileId)
        guard documents[fileId] == nil, loadingTasks[fileId] == nil else { return }

        let task = Task { @MainActor in
            defer {
                self.loadingTasks[fileId] = nil
                self.downloadTasks[fileId] = nil
            }
            do {
                let info = try await GwaTopFileService.shared.presignedDownloadURL(fileId: fileId)
                guard let url = URL(string: info.url) else { return }
                let data = try await downloadResumable(fileId: fileId, url: url)
                if Task.isCancelled { return }
                if let doc = PDFDocument(data: data) {
                    self.documents[fileId] = doc
                }
            } catch {
                // 로딩 실패는 silent — PDF 탭이 자기 상태로 재시도하면 됨.
            }
        }
        loadingTasks[fileId] = task
    }

    // MARK: - 양보 (suspend / resume)

    /// AI 생성 시작 직전에 호출. 진행 중인 PDF 다운로드를 일시 정지.
    /// 여러 곳에서 동시에 호출되어도 안전 (ref-counted).
    func suspendDownload() {
        suspensionCount += 1
        if suspensionCount == 1 {
            downloadTasks.values.forEach { $0.suspend() }
        }
    }

    /// AI 생성 완료 후 호출. suspendDownload 와 1:1 페어링.
    func resumeDownload() {
        guard suspensionCount > 0 else { return }
        suspensionCount -= 1
        if suspensionCount == 0 {
            downloadTasks.values.forEach { $0.resume() }
        }
    }

    /// suspend → block 실행 → resume 을 자동으로 묶어주는 async 헬퍼.
    /// block 이 throw 하거나 cancel 되어도 defer 로 안전하게 resume.
    func withDownloadSuspended<T>(_ block: () async throws -> T) async throws -> T {
        suspendDownload()
        defer { resumeDownload() }
        return try await block()
    }

    // MARK: - 자동 정리 (TTL eviction)

    /// FileStudyView 가 dismiss 될 때 호출. N분 후 자동으로 캐시에서 제거.
    /// 같은 파일로 다시 진입하면 cancelEviction 으로 취소되고 캐시 유지.
    func scheduleEviction(fileId: String) {
        cancelEviction(fileId: fileId)
        let task = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(Self.evictionDelay * 1_000_000_000))
            } catch {
                return  // 취소됨
            }
            guard !Task.isCancelled else { return }
            self?.evict(fileId: fileId)
        }
        evictionTasks[fileId] = task
    }

    func cancelEviction(fileId: String) {
        evictionTasks[fileId]?.cancel()
        evictionTasks[fileId] = nil
    }

    private func evict(fileId: String) {
        documents[fileId] = nil
        loadingTasks[fileId]?.cancel()
        loadingTasks[fileId] = nil
        downloadTasks[fileId]?.cancel()
        downloadTasks[fileId] = nil
        evictionTasks[fileId] = nil
    }

    /// 전체 정리 — 메모리 경고 + 명시적 호출 시.
    func clear() {
        documents.removeAll()
        loadingTasks.values.forEach { $0.cancel() }
        loadingTasks.removeAll()
        downloadTasks.values.forEach { $0.cancel() }
        downloadTasks.removeAll()
        evictionTasks.values.forEach { $0.cancel() }
        evictionTasks.removeAll()
        suspensionCount = 0
    }

    // MARK: - Private

    /// URLSessionDataTask 로 다운로드. 동기 PDFDocument(url:) 와 달리 suspend/resume 가능.
    /// suspendDownload() 가 이미 호출된 상태라면 새로 만든 task 도 suspend 상태로 대기.
    private func downloadResumable(fileId: String, url: URL) async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
                let task = URLSession.shared.dataTask(with: url) { data, _, error in
                    if let error {
                        cont.resume(throwing: error)
                        return
                    }
                    if let data {
                        cont.resume(returning: data)
                    } else {
                        cont.resume(throwing: URLError(.cannotParseResponse))
                    }
                }
                // 같은 fileId 의 잔여 task 가 있으면 정리 후 새 task 등록.
                self.downloadTasks[fileId]?.cancel()
                self.downloadTasks[fileId] = task
                // 현재 양보 중이면 task 를 시작하지 않음.
                // resumeDownload() 가 카운트를 0 으로 만들 때 .resume() 이 호출됨.
                if self.suspensionCount == 0 {
                    task.resume()
                }
            }
        } onCancel: {
            // 외부 Task 취소 시 URLSession task 도 함께 cancel.
            Task { @MainActor [weak self] in
                self?.downloadTasks[fileId]?.cancel()
                self?.downloadTasks[fileId] = nil
            }
        }
    }
}
