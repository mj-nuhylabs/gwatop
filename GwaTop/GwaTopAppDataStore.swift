//
//  GwaTopAppDataStore.swift
//  GwaTop
//
//  로그인 직후 스플래시 화면에서 한 번에 끌어오는 백엔드 데이터 캐시 + 진행률 publisher.
//
//  목적:
//   - 사용자가 로그인하자마자 탭(홈/캘린더/학습/과제) 사이를 이동할 때 매번 빈 화면을
//     보다가 데이터가 늦게 채워지는 "끊김" 느낌을 제거한다.
//   - 스플래시 화면이 떠 있는 1~3초 동안 핵심 API 응답을 미리 받아 메모리에 캐시.
//   - 각 화면은 자기 .task 안에서 store 의 캐시를 먼저 확인하고 hit 면 즉시 표시,
//     miss 면 평소처럼 네트워크. (이 store 가 fallback 임 — 화면 코드 변경 최소화)
//
//  진행률 계산:
//   - 단계는 prefetch 작업 개수 N. 완료마다 progress = completed / N.
//   - 단계는 동시 실행 (TaskGroup) — 실제 대기 시간은 가장 느린 호출에 수렴.
//

import Foundation
import SwiftUI
import Combine

/// 스플래시에서 끌어오는 데이터의 캐시 + 진행 상태. 메인 액터에서만 mutate.
@MainActor
final class GwaTopAppDataStore: ObservableObject {
    static let shared = GwaTopAppDataStore()

    // MARK: - 진행 상태

    /// 0.0 ~ 1.0. 스플래시 화면의 progress bar 가 이 값을 그대로 사용.
    @Published private(set) var progress: Double = 0
    /// 현재 진행 중인 작업 라벨 ("학기 정보 불러오는 중…" 등).
    @Published private(set) var currentStage: String = "준비 중…"
    /// prefetch 가 한 번이라도 끝난 적 있는지. 두 번째 진입부터는 스플래시 짧게 띄우고 통과.
    @Published private(set) var hasFinishedAtLeastOnce: Bool = false

    // MARK: - 캐시 결과 (각 화면이 우선 사용)

    @Published private(set) var courses: [GwaTopCourseDTO] = []
    @Published private(set) var semesters: [GwaTopSemesterDTO] = []
    @Published private(set) var upcomingTodos: [GwaTopTodoDTO] = []
    /// 캘린더 탭이 사용 — 전체 학기 모든 schedule (date 필터 없음).
    @Published private(set) var allSchedules: [GwaTopScheduleDTO] = []
    /// 홈 탭이 사용 — 대시보드 (오늘/이번 주 진척, upcoming 일정 등).
    @Published private(set) var dashboard: GwaTopHomeDashboardDTO? = nil
    /// 학습 탭이 사용 — 과목별 파일 목록. 키: course.id
    @Published private(set) var filesByCourse: [String: [GwaTopFileSummary]] = [:]

    /// 캐시 신선도 판단용. (Date(0) 이면 미설정.) 5분 이상 지났으면 화면 .task 에서 fresh fetch.
    @Published private(set) var lastRefreshedAt: Date = .distantPast

    /// 캐시가 신선한지(=5분 미만) — 화면 자체 fetch 를 건너뛸지 결정.
    var isCacheFresh: Bool {
        Date().timeIntervalSince(lastRefreshedAt) < 5 * 60
    }

    private init() {}

    // MARK: - 진행 단계 정의

    /// prefetch 단계. 라벨 + 실행 클로저.
    /// 클로저 throw 는 해당 단계만 실패로 기록되고 다른 단계는 계속 진행 (앱이 멈추지 않게).
    private struct Stage {
        let label: String
        let run: @MainActor () async throws -> Void
    }

    private func makeStages() -> [Stage] {
        [
            Stage(label: "학기 정보 불러오는 중…") { [weak self] in
                guard let self else { return }
                let list = try await GwaTopSemesterService.shared.fetchAll()
                self.semesters = list
            },
            Stage(label: "내 과목 불러오는 중…") { [weak self] in
                guard let self else { return }
                let list = try await GwaTopCourseService.shared.fetchAll()
                self.courses = list
            },
            Stage(label: "홈 화면 데이터 정리 중…") { [weak self] in
                guard let self else { return }
                let dash = try await GwaTopHomeService.shared.fetchDashboard(upcomingLimit: 5)
                self.dashboard = dash
            },
            Stage(label: "다가오는 할 일 정리 중…") { [weak self] in
                guard let self else { return }
                let cal = Calendar(identifier: .gregorian)
                let start = cal.startOfDay(for: Date())
                let end = cal.date(byAdding: .day, value: 21, to: start) ?? start.addingTimeInterval(21 * 86400)
                let list = try await GwaTopTodoService.shared.fetchAll(start: start, end: end)
                self.upcomingTodos = list
            },
            Stage(label: "캘린더 일정 가져오는 중…") { [weak self] in
                guard let self else { return }
                // 캘린더 뷰는 date 필터 없이 전체를 받는다 — 여기서도 동일하게 전체 prefetch.
                let list = try await GwaTopScheduleService.shared.fetchAll()
                self.allSchedules = list
            },
            Stage(label: "학습 자료 불러오는 중…") { [weak self] in
                guard let self else { return }
                // 과목별 파일 목록을 병렬 fetch. courses 가 prefetch 단계 순서상 먼저
                // 끝나도 task group 동시 실행이라 아직 비어 있을 수 있음 → 빠르게 다시 가져온다.
                let courses: [GwaTopCourseDTO]
                if !self.courses.isEmpty {
                    courses = self.courses
                } else {
                    courses = (try? await GwaTopCourseService.shared.fetchAll()) ?? []
                }
                if courses.isEmpty { return }
                var collected: [String: [GwaTopFileSummary]] = [:]
                await withTaskGroup(of: (String, [GwaTopFileSummary]?).self) { group in
                    for c in courses {
                        group.addTask {
                            do {
                                let list = try await GwaTopFileService.shared.fetchFiles(courseId: c.id)
                                return (c.id, list)
                            } catch {
                                return (c.id, nil)
                            }
                        }
                    }
                    for await (cid, result) in group {
                        if let result { collected[cid] = result }
                    }
                }
                self.filesByCourse = collected
            },
        ]
    }

    // MARK: - 진입점

    /// 로그인/세션 복구 직후 호출. 모든 단계 끝나면 hasFinishedAtLeastOnce = true.
    /// 이미 신선한 캐시가 있으면 짧게 페이드아웃 정도만 보이고 곧장 통과 (스플래시 0.6초).
    func warmup() async {
        let stages = makeStages()
        let total = stages.count
        guard total > 0 else {
            await markFinished()
            return
        }

        progress = 0
        currentStage = stages[0].label

        // TaskGroup 으로 동시 실행 — 가장 느린 호출만큼만 기다림.
        // 단, UI 진행률은 "완료된 단계 수 / 전체" 로 자연스럽게 0→1 로 증가.
        await withTaskGroup(of: (Int, String).self) { group in
            for (idx, stage) in stages.enumerated() {
                group.addTask { [weak self] in
                    guard let self else { return (idx, stage.label) }
                    do {
                        try await stage.run()
                    } catch {
                        // 단계 실패는 무시 — 화면에서 자체 재시도가 동작.
                        await self.note("prefetch stage failed (\(stage.label)): \(error.localizedDescription)")
                    }
                    return (idx, stage.label)
                }
            }

            var completed = 0
            for await (_, label) in group {
                completed += 1
                // 다음에 보여줄 라벨 — 남은 단계가 있으면 그것, 없으면 마지막 라벨.
                let nextIdx = min(completed, stages.count - 1)
                self.currentStage = stages[nextIdx].label
                withAnimation(.easeOut(duration: 0.25)) {
                    self.progress = Double(completed) / Double(total)
                }
                _ = label
            }
        }

        lastRefreshedAt = Date()
        await markFinished()
    }

    private func markFinished() async {
        currentStage = "준비 완료"
        // bar 가 100% 에 살짝 머물러서 "다 됐다" 인상 주기.
        withAnimation(.easeOut(duration: 0.2)) { progress = 1.0 }
        try? await Task.sleep(nanoseconds: 250_000_000)
        hasFinishedAtLeastOnce = true
    }

    /// 로그아웃 시 캐시 초기화 — 다른 사용자가 같은 디바이스에 로그인해도 잔재가 안 보이게.
    func reset() {
        progress = 0
        currentStage = "준비 중…"
        hasFinishedAtLeastOnce = false
        courses = []
        semesters = []
        upcomingTodos = []
        allSchedules = []
        dashboard = nil
        filesByCourse = [:]
        lastRefreshedAt = .distantPast
    }

    // MARK: - 디버그

    private func note(_ message: String) {
        #if DEBUG
        print("[AppDataStore] \(message)")
        #endif
    }
}
