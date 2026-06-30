//
//  GwaTopCalendarWidget.swift
//  GwaTopWidgetExtension (위젯 타겟 전용)
//
//  구글 캘린더 스타일 위젯 — 좌측 월간 달력(오늘 강조 + 일정 있는 날 점) / 우측 다가오는 일정 agenda.
//   - 데이터/프로바이더(GwaTopWidgetProvider, GwaTopWidgetEntry)는 기존 위젯과 공유.
//   - 우측은 오늘만이 아니라 "다가오는 일정"을 가까운 순으로 카드로 보여준다.
//   - 달력은 주(week) 행이 가용 높이를 균등 분할 → 어떤 달(5/6주)이든 안 잘림.
//   - Medium / Large 지원.
//

import WidgetKit
import SwiftUI

// MARK: - Widget

struct GwaTopCalendarWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: GwaTopWidgetConstants.calendarWidgetKind,
                            provider: GwaTopWidgetProvider()) { entry in
            GwaTopCalendarWidgetView(entry: entry)
                .containerBackground(for: .widget) { GwaTopWidgetPalette.background }
        }
        .configurationDisplayName("과탑 캘린더")
        .description("이번 달 달력과 다가오는 일정을 한눈에.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

// MARK: - 루트 뷰 (좌우 분할)

struct GwaTopCalendarWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: GwaTopWidgetEntry

    private var isLarge: Bool { family == .systemLarge }

    var body: some View {
        HStack(spacing: 12) {
            GwaTopMonthGridView(large: isLarge, eventDays: eventDays)
                .frame(maxWidth: .infinity)

            eventsColumn
                .frame(maxWidth: .infinity)
        }
        .padding(.vertical, 12)
    }

    /// 지금(엔트리 시각) 기준 가장 가까운 일정 3건만. 날짜 미정 항목은 제외.
    private var visibleEvents: [GwaTopWidgetItem] {
        let now = entry.date
        return entry.snapshot.upcomingSchedules
            .compactMap { item -> (GwaTopWidgetItem, Date)? in
                guard let due = item.dueDate, due >= now else { return nil }
                return (item, due)
            }
            .sorted { $0.1 < $1.1 }
            .prefix(3)
            .map { $0.0 }
    }

    /// 일정이 있는 날(자정 기준) — 달력 점 표시용.
    private var eventDays: Set<Date> {
        let cal = Calendar(identifier: .gregorian)
        var set = Set<Date>()
        for item in entry.snapshot.upcomingSchedules + entry.snapshot.todaySchedules {
            if let due = item.dueDate { set.insert(cal.startOfDay(for: due)) }
        }
        return set
    }

    @ViewBuilder
    private var eventsColumn: some View {
        let items = visibleEvents
        if items.isEmpty {
            VStack(spacing: 6) {
                Spacer()
                Text("예정된 일정 없음")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(GwaTopWidgetPalette.tertiaryText)
                Spacer()
            }
        } else {
            VStack(spacing: 8) {
                ForEach(items) { item in
                    GwaTopEventCard(item: item)
                }
                Spacer(minLength: 0)
            }
        }
    }
}

// MARK: - 월간 달력 (주 행이 높이를 균등 분할, 일정 있는 날 점)

struct GwaTopMonthGridView: View {
    let large: Bool
    var eventDays: Set<Date> = []

    private let cal = Calendar(identifier: .gregorian)
    private let weekdaySymbols = ["일", "월", "화", "수", "목", "금", "토"]

    private var dayFont: CGFloat { large ? 13 : 11 }
    private var circleSize: CGFloat { large ? 28 : 23 }

    var body: some View {
        VStack(alignment: .leading, spacing: large ? 6 : 4) {
            Text(GwaTopWidgetFmt.monthName.string(from: Date()))
                .font(.system(size: large ? 16 : 14, weight: .bold))
                .foregroundStyle(GwaTopWidgetPalette.primaryText)

            HStack(spacing: 0) {
                ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { idx, sym in
                    Text(sym)
                        .font(.system(size: large ? 10 : 9, weight: .medium))
                        .foregroundStyle(idx == 0 ? Color.red.opacity(0.5)
                                                  : GwaTopWidgetPalette.tertiaryText)
                        .frame(maxWidth: .infinity)
                }
            }

            ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                HStack(spacing: 0) {
                    ForEach(Array(week.enumerated()), id: \.offset) { _, date in
                        dayCell(date)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder
    private func dayCell(_ date: Date) -> some View {
        let isToday = cal.isDateInToday(date)
        let inMonth = cal.isDate(date, equalTo: Date(), toGranularity: .month)
        let hasEvent = inMonth && eventDays.contains(cal.startOfDay(for: date))
        let day = cal.component(.day, from: date)

        VStack(spacing: 1.5) {
            ZStack {
                if isToday {
                    Circle()
                        .fill(GwaTopWidgetPalette.accent)
                        .frame(width: circleSize, height: circleSize)
                }
                Text("\(day)")
                    .font(.system(size: dayFont, weight: isToday ? .semibold : .regular, design: .rounded))
                    .foregroundStyle(
                        isToday ? Color.white
                                : (inMonth ? GwaTopWidgetPalette.primaryText
                                           : GwaTopWidgetPalette.tertiaryText.opacity(0.45))
                    )
            }
            Circle()
                .fill(hasEvent ? GwaTopWidgetPalette.accent : Color.clear)
                .frame(width: 3.5, height: 3.5)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var weeks: [[Date]] {
        guard let monthInterval = cal.dateInterval(of: .month, for: Date()) else { return [] }
        let firstOfMonth = monthInterval.start
        let leading = cal.component(.weekday, from: firstOfMonth) - 1   // 1 = 일요일
        let daysInMonth = cal.range(of: .day, in: .month, for: Date())?.count ?? 30
        let total = leading + daysInMonth
        let rows = Int((Double(total) / 7.0).rounded(.up))
        guard let gridStart = cal.date(byAdding: .day, value: -leading, to: firstOfMonth) else { return [] }
        let all = (0..<(rows * 7)).compactMap { cal.date(byAdding: .day, value: $0, to: gridStart) }
        return stride(from: 0, to: all.count, by: 7).map { Array(all[$0..<min($0 + 7, all.count)]) }
    }
}

// MARK: - 일정 카드 (과목 색 채움, 플랫/매트)

struct GwaTopEventCard: View {
    let item: GwaTopWidgetItem

    /// "오늘 14:00" / "내일 09:00" / "7.2 14:00" / "날짜 미정"
    private var whenText: String {
        guard let due = item.dueDate else { return "날짜 미정" }
        let cal = Calendar.current
        let time = GwaTopWidgetFmt.timeShort.string(from: due)
        if cal.isDateInToday(due) { return "오늘 \(time)" }
        if cal.isDateInTomorrow(due) { return "내일 \(time)" }
        return "\(GwaTopWidgetFmt.monthDay.string(from: due)) \(time)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(item.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.black.opacity(0.8))
                .lineLimit(1)
            Text(whenText)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.black.opacity(0.55))
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(gwaTopHex: item.courseColorHex))
        )
    }
}

// MARK: - Preview

#Preview("Calendar Medium", as: .systemMedium) {
    GwaTopCalendarWidget()
} timeline: {
    GwaTopWidgetEntry(date: .now, snapshot: .sample)
}

#Preview("Calendar Large", as: .systemLarge) {
    GwaTopCalendarWidget()
} timeline: {
    GwaTopWidgetEntry(date: .now, snapshot: .sample)
}
