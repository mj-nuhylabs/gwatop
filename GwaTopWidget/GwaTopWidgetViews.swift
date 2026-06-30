//
//  GwaTopWidgetViews.swift
//  GwaTopWidgetExtension (위젯 타겟 전용)
//
//  Small / Medium / Large 위젯 UI.
//   - Small  : 오늘 요약(남은 할 일 수) + 다음 일정 한 건.
//   - Medium : 구글 캘린더식 좌우 분할 — 좌측 날짜 카드 / 우측 오늘 일정·할 일 목록.
//   - Large  : 하루 전체 브리핑 — 미니 월간 캘린더 + 오늘 목록 + 다가오는 할 일 + 주간 진척.
//

import WidgetKit
import SwiftUI

// MARK: - 팔레트 / 공통 색

enum GwaTopWidgetPalette {
    static let background = Color(.systemBackground)
    static let secondaryBG = Color(.secondarySystemBackground)
    static let primaryText = Color(.label)
    static let secondaryText = Color(.secondaryLabel)
    static let tertiaryText = Color(.tertiaryLabel)
    static let accent = Color(red: 138/255, green: 182/255, blue: 240/255)   // pastel sky #8AB6F0
    static let separator = Color(.separator)
}

extension Color {
    /// "#8AB6F0" / "8AB6F0" → Color. 실패 시 기본 파스텔.
    init(gwaTopHex hex: String?) {
        guard let hex else { self = GwaTopWidgetPalette.accent; return }
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&int)
        guard cleaned.count == 6 else { self = GwaTopWidgetPalette.accent; return }
        self = Color(
            red: Double((int >> 16) & 0xFF) / 255,
            green: Double((int >> 8) & 0xFF) / 255,
            blue: Double(int & 0xFF) / 255
        )
    }
}

// MARK: - 포맷터 / 라벨 헬퍼

enum GwaTopWidgetFmt {
    static let time: DateFormatter = make("a h:mm")          // "오전 10:30"
    static let timeShort: DateFormatter = make("HH:mm")      // "10:30"
    static let weekday: DateFormatter = make("EEEE")         // "목요일"
    static let weekdayShort: DateFormatter = make("E")       // "목"
    static let monthName: DateFormatter = make("M월")        // "6월"
    static let monthDay: DateFormatter = make("M.d")         // "7.2"
    static let dayNum: DateFormatter = make("d")             // "29"

    private static func make(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = format
        return f
    }

    /// schedule type / todo priority → 짧은 한글 라벨.
    static func typeLabel(for item: GwaTopWidgetItem) -> String {
        switch item.kind {
        case .schedule:
            switch item.typeOrPriority {
            case "exam":       return "시험"
            case "assignment": return "과제"
            case "lecture":    return "수업"
            case "meeting":    return "회의"
            case "upload":     return "자료"
            default:           return "일정"
            }
        case .todo:
            return "할 일"
        }
    }

    /// 오늘 자정 기준 D-Day. 0=오늘.
    static func dDay(to target: Date) -> Int {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let t = cal.startOfDay(for: target)
        return cal.dateComponents([.day], from: today, to: t).day ?? 0
    }

    static func dDayText(to target: Date) -> String {
        let d = dDay(to: target)
        if d == 0 { return "오늘" }
        if d == 1 { return "내일" }
        if d > 0  { return "D-\(d)" }
        return "D+\(-d)"
    }
}

// MARK: - 스냅샷 파생 데이터

extension GwaTopWidgetSnapshot {
    /// 오늘 보여줄 항목: 오늘 일정 + 오늘 마감 할 일, 시간순 정렬.
    var todayItems: [GwaTopWidgetItem] {
        let cal = Calendar.current
        let todayTodos = upcomingTodos.filter { item in
            guard !item.isDone, let due = item.dueDate else { return false }
            return cal.isDateInToday(due)
        }
        let merged = todaySchedules + todayTodos
        return merged.sorted { a, b in
            (a.dueDate ?? .distantFuture) < (b.dueDate ?? .distantFuture)
        }
    }

    /// 아직 안 끝난 다가오는 할 일(오늘 제외하지 않음), 마감순.
    var openTodos: [GwaTopWidgetItem] {
        upcomingTodos
            .filter { !$0.isDone }
            .sorted { ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture) }
    }

    /// 오늘 남은 할 일 수(완료 제외, 오늘 마감).
    var todayRemainingCount: Int {
        let cal = Calendar.current
        return upcomingTodos.filter { item in
            guard !item.isDone, let due = item.dueDate else { return false }
            return cal.isDateInToday(due)
        }.count
    }
}

// MARK: - 루트 뷰

struct GwaTopWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: GwaTopWidgetEntry

    var body: some View {
        switch family {
        case .systemSmall:  GwaTopSmallWidget(snapshot: entry.snapshot)
        case .systemMedium: GwaTopMediumWidget(snapshot: entry.snapshot)
        case .systemLarge:  GwaTopLargeWidget(snapshot: entry.snapshot)
        default:            GwaTopMediumWidget(snapshot: entry.snapshot)
        }
    }
}

// MARK: - Small

struct GwaTopSmallWidget: View {
    let snapshot: GwaTopWidgetSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 헤더: 오늘 날짜 + 남은 할 일 배지
            HStack(alignment: .firstTextBaseline) {
                Text(GwaTopWidgetFmt.dayNum.string(from: Date()))
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(GwaTopWidgetPalette.primaryText)
                Text(GwaTopWidgetFmt.weekday.string(from: Date()))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(GwaTopWidgetPalette.secondaryText)
                Spacer()
                if snapshot.todayRemainingCount > 0 {
                    Text("\(snapshot.todayRemainingCount)")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Capsule().fill(GwaTopWidgetPalette.accent))
                }
            }

            Spacer(minLength: 6)

            // 다음 일정
            if let title = snapshot.nextEventTitle {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(Color(gwaTopHex: snapshot.nextEventColorHex))
                            .frame(width: 7, height: 7)
                        if let due = snapshot.nextEventDueDate {
                            Text(GwaTopWidgetFmt.dDayText(to: due))
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(Color(gwaTopHex: snapshot.nextEventColorHex))
                        }
                        Spacer()
                    }
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(GwaTopWidgetPalette.primaryText)
                        .lineLimit(2)
                    if let due = snapshot.nextEventDueDate {
                        Text(GwaTopWidgetFmt.time.string(from: due))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(GwaTopWidgetPalette.secondaryText)
                    }
                    if let course = snapshot.nextEventCourseName {
                        Text(course)
                            .font(.system(size: 11))
                            .foregroundStyle(GwaTopWidgetPalette.tertiaryText)
                            .lineLimit(1)
                    }
                }
            } else {
                Spacer()
                Text("예정된 일정이 없어요 🎉")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(GwaTopWidgetPalette.secondaryText)
                Spacer()
            }
        }
    }
}

// MARK: - Medium (구글 캘린더식 좌우 분할)

struct GwaTopMediumWidget: View {
    let snapshot: GwaTopWidgetSnapshot

    var body: some View {
        HStack(spacing: 12) {
            GwaTopDateCard()
                .frame(width: 96)

            Rectangle()
                .fill(GwaTopWidgetPalette.separator)
                .frame(width: 1)

            // 우측: 오늘 일정 + 할 일 목록
            VStack(alignment: .leading, spacing: 0) {
                Text("오늘 일정")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(GwaTopWidgetPalette.secondaryText)
                    .padding(.bottom, 4)

                let items = snapshot.todayItems
                if items.isEmpty {
                    Spacer()
                    Text("오늘 일정이 없어요 🎉")
                        .font(.system(size: 13))
                        .foregroundStyle(GwaTopWidgetPalette.secondaryText)
                    Spacer()
                } else {
                    ForEach(items.prefix(4)) { item in
                        GwaTopItemRow(item: item)
                    }
                    if items.count > 4 {
                        Text("+\(items.count - 4)건 더")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(GwaTopWidgetPalette.tertiaryText)
                            .padding(.top, 2)
                    }
                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Large (하루 전체 브리핑)

struct GwaTopLargeWidget: View {
    let snapshot: GwaTopWidgetSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 헤더: 오늘 날짜 + 주간 진척
            HStack(alignment: .firstTextBaseline) {
                Text(GwaTopWidgetFmt.dayNum.string(from: Date()))
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(GwaTopWidgetPalette.primaryText)
                Text(GwaTopWidgetFmt.weekday.string(from: Date()))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(GwaTopWidgetPalette.secondaryText)
                Spacer()
                GwaTopWeekProgressPill(done: snapshot.weekDone, total: snapshot.weekTotal)
            }

            HStack(alignment: .top, spacing: 12) {
                GwaTopMiniMonth(snapshot: snapshot)
                    .frame(width: 150)

                Rectangle().fill(GwaTopWidgetPalette.separator).frame(width: 1)

                VStack(alignment: .leading, spacing: 5) {
                    Text("오늘 일정")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(GwaTopWidgetPalette.secondaryText)
                    let items = snapshot.todayItems
                    if items.isEmpty {
                        Text("오늘 일정이 없어요 🎉")
                            .font(.system(size: 13))
                            .foregroundStyle(GwaTopWidgetPalette.secondaryText)
                            .padding(.top, 2)
                    } else {
                        ForEach(items.prefix(4)) { item in
                            GwaTopItemRow(item: item)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Rectangle().fill(GwaTopWidgetPalette.separator).frame(height: 1)

            // 다가오는 할 일
            VStack(alignment: .leading, spacing: 5) {
                Text("다가오는 할 일")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(GwaTopWidgetPalette.secondaryText)
                let upcoming = snapshot.openTodos.filter { item in
                    guard let due = item.dueDate else { return true }
                    return !Calendar.current.isDateInToday(due)
                }
                if upcoming.isEmpty {
                    Text("다가오는 할 일이 없어요")
                        .font(.system(size: 13))
                        .foregroundStyle(GwaTopWidgetPalette.secondaryText)
                } else {
                    ForEach(upcoming.prefix(3)) { item in
                        GwaTopItemRow(item: item, showDDay: true)
                    }
                }
            }

            Spacer(minLength: 0)
        }
    }
}

// MARK: - 재사용 컴포넌트

/// 좌측 날짜 카드 (월 / 큰 일 / 요일).
struct GwaTopDateCard: View {
    var body: some View {
        VStack(spacing: 2) {
            Text(GwaTopWidgetFmt.monthName.string(from: Date()))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(GwaTopWidgetPalette.accent)
            Text(GwaTopWidgetFmt.dayNum.string(from: Date()))
                .font(.system(size: 44, weight: .bold, design: .rounded))
                .foregroundStyle(GwaTopWidgetPalette.primaryText)
            Text(GwaTopWidgetFmt.weekday.string(from: Date()))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(GwaTopWidgetPalette.secondaryText)
        }
        .frame(maxHeight: .infinity)
    }
}

/// 한 줄: 과목 색 바 + 제목 + 시간/유형.
struct GwaTopItemRow: View {
    let item: GwaTopWidgetItem
    var showDDay: Bool = false

    var body: some View {
        HStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color(gwaTopHex: item.courseColorHex))
                .frame(width: 3, height: 26)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(GwaTopWidgetPalette.primaryText)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(GwaTopWidgetFmt.typeLabel(for: item))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color(gwaTopHex: item.courseColorHex))
                    Text(item.courseName)
                        .font(.system(size: 10))
                        .foregroundStyle(GwaTopWidgetPalette.tertiaryText)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 2)

            if let due = item.dueDate {
                Text(showDDay ? GwaTopWidgetFmt.dDayText(to: due)
                              : GwaTopWidgetFmt.timeShort.string(from: due))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(GwaTopWidgetPalette.secondaryText)
            } else {
                Text("미정")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(GwaTopWidgetPalette.tertiaryText)
            }
        }
        .padding(.vertical, 2)
    }
}

/// 주간 진척 pill (done / total).
struct GwaTopWeekProgressPill: View {
    let done: Int
    let total: Int

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(GwaTopWidgetPalette.accent)
            Text("이번 주 \(done)/\(total)")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(GwaTopWidgetPalette.secondaryText)
        }
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(Capsule().fill(GwaTopWidgetPalette.secondaryBG))
    }
}

/// 미니 월간 캘린더. 오늘 강조 + 일정/할 일 있는 날에 점.
struct GwaTopMiniMonth: View {
    let snapshot: GwaTopWidgetSnapshot
    private let cal = Calendar.current
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 7)

    var body: some View {
        VStack(spacing: 4) {
            // 요일 헤더
            HStack(spacing: 2) {
                ForEach(["일","월","화","수","목","금","토"], id: \.self) { d in
                    Text(d)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(GwaTopWidgetPalette.tertiaryText)
                        .frame(maxWidth: .infinity)
                }
            }
            LazyVGrid(columns: columns, spacing: 3) {
                ForEach(Array(monthDays.enumerated()), id: \.offset) { _, day in
                    if let day {
                        dayCell(day)
                    } else {
                        Color.clear.frame(height: 16)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func dayCell(_ date: Date) -> some View {
        let isToday = cal.isDateInToday(date)
        let hasEvent = eventDays.contains(cal.startOfDay(for: date))
        VStack(spacing: 1) {
            Text(GwaTopWidgetFmt.dayNum.string(from: date))
                .font(.system(size: 10, weight: isToday ? .bold : .regular))
                .foregroundStyle(isToday ? Color.white : GwaTopWidgetPalette.primaryText)
                .frame(width: 16, height: 16)
                .background(
                    Circle().fill(isToday ? GwaTopWidgetPalette.accent : Color.clear)
                )
            Circle()
                .fill(hasEvent ? GwaTopWidgetPalette.accent : Color.clear)
                .frame(width: 3, height: 3)
        }
    }

    /// 이번 달 그리드(앞쪽 빈칸 포함).
    private var monthDays: [Date?] {
        guard let interval = cal.dateInterval(of: .month, for: Date()),
              let firstWeekday = cal.dateComponents([.weekday], from: interval.start).weekday
        else { return [] }
        let leading = firstWeekday - 1   // 일요일 시작
        let dayCount = cal.range(of: .day, in: .month, for: Date())?.count ?? 30
        var cells: [Date?] = Array(repeating: nil, count: leading)
        for offset in 0..<dayCount {
            cells.append(cal.date(byAdding: .day, value: offset, to: interval.start))
        }
        return cells
    }

    /// 일정/할 일이 있는 날짜(자정 기준) 집합.
    private var eventDays: Set<Date> {
        var set = Set<Date>()
        for item in snapshot.todaySchedules + snapshot.upcomingTodos {
            if let due = item.dueDate { set.insert(cal.startOfDay(for: due)) }
        }
        return set
    }
}
