//
//  GwaTopSyllabusWatcher.swift
//  GwaTop
//
//  강의계획서 파싱 진행 상태를 백그라운드에서 추적하는 글로벌 ObservableObject.
//
//  왜 필요한가:
//   - 업로드 시트는 confirm 직후 즉시 닫힘 (사용자가 30~45초 멍 때리지 않게).
//   - 그 후에도 사용자는 캘린더/홈 어디에서나 "지금 분석 중인지" 알 수 있어야 함.
//   - 완료되면 캘린더가 자동 새로고침되어야 함.
//
//  동작:
//   - 앱이 foreground 일 때만 폴링 (background 진입 시 task 취소).
//   - 8초 간격으로 GET /v1/files/in-flight-syllabi.
//   - 직전 폴 결과와 비교해서 사라진 file_id 가 있으면 "완료(또는 실패)" 로 간주하고
//     NotificationCenter 로 .syllabusParseCompleted 발행.
//   - 캘린더/홈 뷰가 그 알림을 받아 자동 reload.

import Foundation
import SwiftUI
import Combine

extension Notification.Name {
    /// 강의계획서 파싱이 끝났음을 알리는 알림. userInfo["file_id"] = String.
    static let syllabusParseCompleted = Notification.Name("GwaTopSyllabusParseCompleted")
}

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

    private init() {}

    /// 앱 foreground 진입 시 호출. 이미 실행 중이면 idempotent.
    func startWatching() {
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            await self?.pollLoop()
        }
    }

    /// 앱 background 진입 시 호출. polling task 취소.
    func stopWatching() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    /// 업로드 시트가 confirm 직후 호출. 즉시 1회 폴해서 inFlight 에 새 파일 추가.
    /// (그냥 polling 다음 tick 기다리면 최대 8초 늦게 보임 — 즉시성 위해 즉발 폴.)
    func notifyUploaded(fileId: String) {
        Task { await pollOnce() }
    }

    // MARK: - 내부

    private func pollLoop() async {
        // 첫 폴은 즉시 (앱 시작 시 진행 중 작업이 이미 있을 수 있음).
        await pollOnce()
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
            if Task.isCancelled { break }
            await pollOnce()
        }
    }

    private func pollOnce() async {
        do {
            let fresh = try await GwaTopFileService.shared.fetchInFlightSyllabi()
            let previousIds = Set(inFlight.map(\.id))
            let freshIds = Set(fresh.map(\.id))

            // previous 에 있었는데 fresh 에 없는 = 완료(parsed) 또는 실패(failed) 로 빠진 것.
            // 백엔드 list_in_flight_syllabi 가 둘 다 제외하므로 두 케이스를 여기서 구분하지 않는다.
            // 완료/실패 구분이 필요한 화면(시트 등)은 별도로 /files/{id}/debug 폴 하면 됨.
            let completed = previousIds.subtracting(freshIds)
            await MainActor.run {
                self.inFlight = fresh
                self.lastPolledAt = Date()
            }
            for fileId in completed {
                NotificationCenter.default.post(
                    name: .syllabusParseCompleted,
                    object: nil,
                    userInfo: ["file_id": fileId]
                )
            }
        } catch {
            // 폴 실패는 silent — 다음 tick 에서 다시 시도. 네트워크 일시 끊김 대비.
            if isCancellation(error) { return }
            // 디버그용 print 만 남김. 사용자에게 노출할 정도의 에러는 아님.
            print("[SyllabusWatcher] poll failed: \(error.localizedDescription)")
        }
    }
}
