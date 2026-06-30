//
//  GwaTopWidgetBridge.swift
//  GwaTop  (앱 타겟 전용)
//
//  앱이 받은 대시보드/일정/할 일을 위젯이 읽을 스냅샷(GwaTopWidgetSnapshot)으로 변환해
//  App Group 에 저장하고, WidgetKit 타임라인을 리로드한다.
//   - dashboard 갱신 직후: publish(dashboard:)  (이른 표시, schedules 는 그 시점 store 값)
//   - warmup / 강의계획서 파싱 완료 후: publishFromStore()  (dashboard + 전체 일정 모두 반영)
//   - 로그인/토큰갱신 시 publishAuth(...), 로그아웃 시 clearAuth().
//

import Foundation
import WidgetKit

enum GwaTopWidgetBridge {

    /// 대시보드를 받은 직후 호출. 다가오는 일정은 그 시점의 store.allSchedules 를 함께 반영.
    @MainActor
    static func publish(dashboard: GwaTopHomeDashboardDTO) {
        writeSnapshot(dashboard: dashboard, schedules: GwaTopAppDataStore.shared.allSchedules)
    }

    /// 모든 prefetch 가 끝난 뒤 호출 — dashboard + 전체 일정을 함께 반영한 완전한 스냅샷.
    @MainActor
    static func publishFromStore() {
        let store = GwaTopAppDataStore.shared
        guard let dash = store.dashboard else { return }   // 대시보드 없으면 다음 기회에.
        writeSnapshot(dashboard: dash, schedules: store.allSchedules)
    }

    @MainActor
    private static func writeSnapshot(dashboard: GwaTopHomeDashboardDTO, schedules: [GwaTopScheduleDTO]) {
        // baseURL 은 위젯 직접 fetch(B)에서 쓰므로 함께 최신화.
        GwaTopWidgetStore.saveBaseURL(GwaTopAPI.baseURL)
        let snapshot = makeSnapshot(from: dashboard, schedules: schedules)
        GwaTopWidgetStore.saveSnapshot(snapshot)
        reload()
    }

    /// 로그인 / 토큰 갱신 시 — 위젯이 직접 fetch 할 수 있도록 access token 미러링.
    static func publishAuth(accessToken: String?) {
        GwaTopWidgetStore.saveAccessToken(accessToken)
        GwaTopWidgetStore.saveBaseURL(GwaTopAPI.baseURL)
    }

    /// 로그아웃 시 — 스냅샷/토큰 제거 후 위젯을 빈 상태로 리로드.
    static func clearAuth() {
        GwaTopWidgetStore.clearAll()
        reload()
    }

    private static func reload() {
        // 위젯 종류가 둘(오늘의 과탑 / 과탑 캘린더)이라 전체 리로드.
        WidgetCenter.shared.reloadAllTimelines()
    }

    // MARK: - DTO → 위젯 스냅샷 매핑

    private static func makeSnapshot(from dash: GwaTopHomeDashboardDTO,
                                     schedules: [GwaTopScheduleDTO]) -> GwaTopWidgetSnapshot {
        let todaySchedules = dash.todaySchedules.map { scheduleItem($0) }

        let todos = dash.upcomingTodos.map { t in
            GwaTopWidgetItem(
                id: t.id,
                kind: .todo,
                title: t.title,
                courseName: t.courseName,
                courseColorHex: t.courseColor,
                // hasDueDate=false 면 .distantFuture 로 들어오므로 nil(날짜 미정) 로 표시.
                dueDate: t.hasDueDate ? t.dueDate : nil,
                typeOrPriority: t.priority,
                isDone: t.isDone
            )
        }

        // 오늘 0시 이후의 일정만, 가까운 순으로 최대 15개 — 캘린더 위젯 agenda.
        let cal = Calendar(identifier: .gregorian)
        let startOfToday = cal.startOfDay(for: Date())
        let upcomingSchedules = schedules
            .filter { $0.dueDate >= startOfToday }
            .sorted { $0.dueDate < $1.dueDate }
            .prefix(15)
            .map { scheduleItem($0) }

        return GwaTopWidgetSnapshot(
            generatedAt: Date(),
            todaySchedules: todaySchedules,
            upcomingTodos: todos,
            upcomingSchedules: Array(upcomingSchedules),
            weekTotal: dash.thisWeekSummary.total,
            weekDone: dash.thisWeekSummary.done,
            nextEventTitle: dash.nextEvent?.title,
            nextEventDueDate: dash.nextEvent?.dueDate,
            nextEventCourseName: dash.nextEvent?.courseName,
            nextEventColorHex: dash.nextEvent?.courseColor
        )
    }

    private static func scheduleItem(_ s: GwaTopScheduleDTO) -> GwaTopWidgetItem {
        // 외부(Apple) 일정은 과목명이 없으므로 "Apple 캘린더" 로 표시.
        let courseLabel = s.courseName ?? (s.source == "apple_calendar" ? "Apple 캘린더" : "")
        return GwaTopWidgetItem(
            id: s.id,
            kind: .schedule,
            title: s.title,
            courseName: courseLabel,
            courseColorHex: s.courseColor,
            dueDate: s.dueDate,
            typeOrPriority: s.type,
            isDone: false
        )
    }
}
