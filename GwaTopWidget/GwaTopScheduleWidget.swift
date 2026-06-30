//
//  GwaTopScheduleWidget.swift
//  GwaTopWidgetExtension (위젯 타겟 전용)
//
//  오늘 일정 / 임박 할 일을 보여주는 홈 화면 위젯. Small / Medium / Large 지원.
//   - 하이브리드 데이터: 저장된 스냅샷(A)으로 즉시 그린 뒤, 가능하면 직접 fetch(B)로 최신화.
//   - 타임라인은 30분마다 갱신(.after) — 앱이 포그라운드에서 갱신하면 즉시 reload 도 받음.
//

import WidgetKit
import SwiftUI

// MARK: - Timeline Entry

struct GwaTopWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: GwaTopWidgetSnapshot
    /// 미리보기/플레이스홀더(샘플 데이터) 여부 — redaction 처리에 사용.
    var isPlaceholder: Bool = false
}

// MARK: - Provider

struct GwaTopWidgetProvider: TimelineProvider {

    func placeholder(in context: Context) -> GwaTopWidgetEntry {
        GwaTopWidgetEntry(date: Date(), snapshot: .sample, isPlaceholder: true)
    }

    /// 위젯 갤러리 미리보기 / 빠른 스냅샷. 저장된 데이터가 있으면 그걸, 없으면 샘플.
    func getSnapshot(in context: Context, completion: @escaping (GwaTopWidgetEntry) -> Void) {
        let stored = GwaTopWidgetStore.loadSnapshot()
        if let stored, !stored.isEmpty {
            completion(GwaTopWidgetEntry(date: Date(), snapshot: stored))
        } else {
            completion(GwaTopWidgetEntry(date: Date(), snapshot: .sample, isPlaceholder: context.isPreview))
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<GwaTopWidgetEntry>) -> Void) {
        Task {
            // A. 저장된 스냅샷 — 항상 즉시 사용 가능한 폴백.
            let stored = GwaTopWidgetStore.loadSnapshot() ?? .empty

            // B. 가능하면 직접 fetch 로 최신화. 실패하면 저장본 유지.
            let fresh = await GwaTopWidgetAPI.fetchSnapshot()
            let snapshot: GwaTopWidgetSnapshot
            if let fresh {
                GwaTopWidgetStore.saveSnapshot(fresh)   // 다음 reload 의 폴백도 최신화
                snapshot = fresh
            } else {
                snapshot = stored
            }

            let now = Date()
            let entry = GwaTopWidgetEntry(date: now, snapshot: snapshot)
            // 30분 뒤 자동 갱신. 자정이 더 가까우면 자정(날짜/today 경계)에 맞춰 갱신.
            let nextRefresh = Self.nextRefreshDate(from: now)
            completion(Timeline(entries: [entry], policy: .after(nextRefresh)))
        }
    }

    /// 30분 후 또는 다음 자정 중 빠른 쪽. 자정 갱신으로 "오늘" 경계를 넘겨도 데이터가 신선하게 유지.
    private static func nextRefreshDate(from now: Date) -> Date {
        let cal = Calendar.current
        let in30 = now.addingTimeInterval(30 * 60)
        if let midnight = cal.nextDate(after: now, matching: DateComponents(hour: 0, minute: 0),
                                       matchingPolicy: .nextTime) {
            return min(in30, midnight)
        }
        return in30
    }
}

// MARK: - Widget

struct GwaTopScheduleWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: GwaTopWidgetConstants.widgetKind, provider: GwaTopWidgetProvider()) { entry in
            GwaTopWidgetView(entry: entry)
                .containerBackground(for: .widget) { GwaTopWidgetPalette.background }
        }
        .configurationDisplayName("오늘의 과탑")
        .description("오늘 일정과 임박한 할 일을 한눈에.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

// MARK: - 샘플 데이터 (갤러리 미리보기 / 플레이스홀더)

extension GwaTopWidgetSnapshot {
    static let sample: GwaTopWidgetSnapshot = {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        func at(_ h: Int, _ m: Int) -> Date {
            cal.date(bySettingHour: h, minute: m, second: 0, of: today) ?? today
        }
        return GwaTopWidgetSnapshot(
            generatedAt: Date(),
            todaySchedules: [
                GwaTopWidgetItem(id: "s1", kind: .schedule, title: "자료구조 중간고사",
                                 courseName: "자료구조", courseColorHex: "#8AB6F0",
                                 dueDate: at(10, 30), typeOrPriority: "exam", isDone: false),
                GwaTopWidgetItem(id: "s2", kind: .schedule, title: "팀플 회의",
                                 courseName: "소프트웨어공학", courseColorHex: "#F0B8C8",
                                 dueDate: at(15, 0), typeOrPriority: "meeting", isDone: false),
            ],
            upcomingTodos: [
                GwaTopWidgetItem(id: "t1", kind: .todo, title: "알고리즘 과제 3 제출",
                                 courseName: "알고리즘", courseColorHex: "#A8D8B0",
                                 dueDate: at(23, 59), typeOrPriority: "high", isDone: false),
                GwaTopWidgetItem(id: "t2", kind: .todo, title: "영어 단어 시험 대비",
                                 courseName: "대학영어", courseColorHex: "#F0D8A0",
                                 dueDate: cal.date(byAdding: .day, value: 1, to: at(9, 0)),
                                 typeOrPriority: "medium", isDone: false),
            ],
            upcomingSchedules: [
                GwaTopWidgetItem(id: "u1", kind: .schedule, title: "자료구조 중간고사",
                                 courseName: "자료구조", courseColorHex: "#8AB6F0",
                                 dueDate: at(10, 30), typeOrPriority: "exam", isDone: false),
                GwaTopWidgetItem(id: "u2", kind: .schedule, title: "알고리즘 과제 4 제출",
                                 courseName: "알고리즘", courseColorHex: "#A8D8B0",
                                 dueDate: cal.date(byAdding: .day, value: 2, to: at(23, 59)),
                                 typeOrPriority: "assignment", isDone: false),
                GwaTopWidgetItem(id: "u3", kind: .schedule, title: "소프트웨어공학 팀 발표",
                                 courseName: "소프트웨어공학", courseColorHex: "#F0B8C8",
                                 dueDate: cal.date(byAdding: .day, value: 5, to: at(14, 0)),
                                 typeOrPriority: "meeting", isDone: false),
            ],
            weekTotal: 8, weekDone: 3,
            nextEventTitle: "자료구조 중간고사",
            nextEventDueDate: at(10, 30),
            nextEventCourseName: "자료구조",
            nextEventColorHex: "#8AB6F0"
        )
    }()
}

// MARK: - Preview

#Preview("Small", as: .systemSmall) {
    GwaTopScheduleWidget()
} timeline: {
    GwaTopWidgetEntry(date: .now, snapshot: .sample)
}

#Preview("Medium", as: .systemMedium) {
    GwaTopScheduleWidget()
} timeline: {
    GwaTopWidgetEntry(date: .now, snapshot: .sample)
}

#Preview("Large", as: .systemLarge) {
    GwaTopScheduleWidget()
} timeline: {
    GwaTopWidgetEntry(date: .now, snapshot: .sample)
}
