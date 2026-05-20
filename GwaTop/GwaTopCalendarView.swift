import SwiftUI

// MARK: - GwaTop Calendar View
// C-1 월간 캘린더, C-2 일정 상세, C-3 일정 추가/편집 진입 버튼, C-4 강의계획서 업로드 진입 버튼을 포함합니다.

struct GwaTopCalendarView: View {
    @State private var events: [GwaTopCalendarEvent] = []
    @State private var displayedMonth: Date = Date()
    @State private var selectedDate: Date = Date()
    @State private var selectedEvent: GwaTopCalendarEvent? = nil
    @State private var showUploadPreview: Bool = false
    @State private var isLoading: Bool = false
    @State private var loadErrorMessage: String? = nil
    @State private var didInitialLoad: Bool = false

    private let calendar = Calendar.current
    private let weekdaySymbols = ["일", "월", "화", "수", "목", "금", "토"]

    private var monthTitle: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = "yyyy년 M월"
        return formatter.string(from: displayedMonth)
    }

    private var monthDays: [GwaTopCalendarDay] {
        makeMonthDays(for: displayedMonth)
    }

    private var selectedDateEvents: [GwaTopCalendarEvent] {
        events
            .filter { calendar.isDate($0.startDate, inSameDayAs: selectedDate) }
            .sorted { $0.startDate < $1.startDate }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                GwaTopHomeTheme.background
                    .ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 18) {
                        calendarHeader
                            .padding(.top, 14)

                        if isLoading {
                            loadingBanner
                        } else if let msg = loadErrorMessage {
                            errorBanner(message: msg)
                        }

                        monthGrid
                        selectedDaySection
                        syllabusUploadCard
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 32)
                }
            }
            .navigationTitle("캘린더")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        // 추후 C-3 일정 추가/편집 화면으로 연결합니다.
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 38, height: 38)
                            .background(GwaTopHomeTheme.primary)
                            .clipShape(Circle())
                    }
                }
            }
            .sheet(item: $selectedEvent) { event in
                GwaTopCalendarEventDetailSheet(event: event)
                    .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $showUploadPreview) {
                GwaTopSyllabusUploadSheet(onUploadCompleted: {
                    Task { await reload() }
                })
                .presentationDetents([.large])
            }
            .task {
                if !didInitialLoad {
                    didInitialLoad = true
                    await reload()
                }
            }
            .refreshable {
                await reload()
            }
        }
    }

    @MainActor
    private func reload() async {
        isLoading = true
        loadErrorMessage = nil
        do {
            let dtos = try await GwaTopScheduleService.shared.fetchAll()
            events = dtos.map { GwaTopCalendarEvent(dto: $0) }
        } catch {
            if events.isEmpty {
                events = GwaTopCalendarEvent.sampleData   // 첫 로드 실패 시만 샘플 폴백
            }
            loadErrorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        isLoading = false
    }

    private var calendarHeader: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("월간 일정")
                        .font(.system(size: 24, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)

                    Text("시험, 과제, 강의 일정을 과목 색상으로 확인하세요")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.84))
                }

                Spacer()

                Image(systemName: "calendar")
                    .font(.system(size: 25, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 58, height: 58)
                    .background(.white.opacity(0.16))
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            }

            HStack(spacing: 10) {
                GwaTopCalendarHeaderMetric(title: "이번 달", value: "\(eventsInDisplayedMonth.count)", unit: "개")
                GwaTopCalendarHeaderMetric(title: "과제", value: "\(eventsInDisplayedMonth.filter { $0.eventType == .assignment }.count)", unit: "개")
                GwaTopCalendarHeaderMetric(title: "시험", value: "\(eventsInDisplayedMonth.filter { $0.eventType == .exam }.count)", unit: "개")
            }
        }
        .padding(20)
        .background(GwaTopHomeTheme.primaryGradient)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .shadow(color: GwaTopHomeTheme.primary.opacity(0.22), radius: 18, x: 0, y: 12)
    }

    private var eventsInDisplayedMonth: [GwaTopCalendarEvent] {
        events.filter { calendar.isDate($0.startDate, equalTo: displayedMonth, toGranularity: .month) }
    }

    private var monthGrid: some View {
        VStack(spacing: 14) {
            HStack {
                Button {
                    moveMonth(by: -1)
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(GwaTopHomeTheme.primary)
                        .frame(width: 36, height: 36)
                        .background(GwaTopHomeTheme.primary.opacity(0.09))
                        .clipShape(Circle())
                }

                Spacer()

                Text(monthTitle)
                    .font(.system(size: 20, weight: .heavy, design: .rounded))
                    .foregroundStyle(GwaTopHomeTheme.textPrimary)

                Spacer()

                Button {
                    moveMonth(by: 1)
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(GwaTopHomeTheme.primary)
                        .frame(width: 36, height: 36)
                        .background(GwaTopHomeTheme.primary.opacity(0.09))
                        .clipShape(Circle())
                }
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 7), count: 7), spacing: 8) {
                ForEach(weekdaySymbols, id: \.self) { symbol in
                    Text(symbol)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(symbol == "일" ? .red.opacity(0.75) : GwaTopHomeTheme.textSecondary)
                        .frame(maxWidth: .infinity)
                }

                ForEach(monthDays) { day in
                    GwaTopCalendarDayCell(
                        day: day,
                        isSelected: calendar.isDate(day.date, inSameDayAs: selectedDate),
                        isToday: calendar.isDateInToday(day.date),
                        events: eventsForDate(day.date)
                    )
                    .onTapGesture {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.86)) {
                            selectedDate = day.date
                            if !calendar.isDate(day.date, equalTo: displayedMonth, toGranularity: .month) {
                                displayedMonth = day.date
                            }
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: .black.opacity(0.045), radius: 14, x: 0, y: 7)
    }

    private var selectedDaySection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(selectedDateTitle)
                        .font(.system(size: 21, weight: .bold))
                        .foregroundStyle(GwaTopHomeTheme.textPrimary)
                    Text("선택한 날짜의 일정")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(GwaTopHomeTheme.textSecondary)
                }

                Spacer()

                Text("\(selectedDateEvents.count)개")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(GwaTopHomeTheme.primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(GwaTopHomeTheme.primary.opacity(0.10))
                    .clipShape(Capsule())
            }

            if selectedDateEvents.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "calendar.badge.checkmark")
                        .font(.system(size: 32, weight: .bold))
                        .foregroundStyle(GwaTopHomeTheme.primary)
                    Text("등록된 일정이 없어요")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(GwaTopHomeTheme.textPrimary)
                    Text("오른쪽 위 + 버튼으로 직접 일정을 추가하거나 강의계획서를 업로드해보세요.")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(GwaTopHomeTheme.textSecondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(3)
                }
                .padding(22)
                .frame(maxWidth: .infinity)
                .background(.white)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            } else {
                VStack(spacing: 11) {
                    ForEach(selectedDateEvents) { event in
                        Button {
                            selectedEvent = event
                        } label: {
                            GwaTopCalendarEventRow(event: event)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var loadingBanner: some View {
        HStack(spacing: 10) {
            ProgressView().tint(GwaTopHomeTheme.primary)
            Text("일정을 불러오는 중…")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(GwaTopHomeTheme.textSecondary)
            Spacer()
        }
        .padding(14)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func errorBanner(message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("연동 오류 — 샘플 데이터 표시 중")
                    .font(.system(size: 13, weight: .heavy))
                    .foregroundStyle(GwaTopHomeTheme.textPrimary)
                Text(message)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(GwaTopHomeTheme.textSecondary)
                    .lineLimit(3)
            }
            Spacer()
        }
        .padding(14)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var syllabusUploadCard: some View {
        Button {
            showUploadPreview = true
        } label: {
            HStack(spacing: 13) {
                Image(systemName: "doc.badge.arrow.up.fill")
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(GwaTopHomeTheme.primary)
                    .frame(width: 46, height: 46)
                    .background(GwaTopHomeTheme.primary.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                VStack(alignment: .leading, spacing: 5) {
                    Text("강의계획서 업로드")
                        .font(.system(size: 17, weight: .heavy))
                        .foregroundStyle(GwaTopHomeTheme.textPrimary)

                    Text("PDF/이미지를 AI가 분석해 일정을 자동 등록하는 흐름입니다")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(GwaTopHomeTheme.textSecondary)
                        .lineLimit(2)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(GwaTopHomeTheme.textSecondary)
            }
            .padding(16)
            .background(.white)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .shadow(color: .black.opacity(0.045), radius: 14, x: 0, y: 7)
        }
        .buttonStyle(.plain)
    }

    private var selectedDateTitle: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = "M월 d일 EEEE"
        return formatter.string(from: selectedDate)
    }

    private func eventsForDate(_ date: Date) -> [GwaTopCalendarEvent] {
        events.filter { calendar.isDate($0.startDate, inSameDayAs: date) }
    }

    private func moveMonth(by value: Int) {
        guard let newMonth = calendar.date(byAdding: .month, value: value, to: displayedMonth) else { return }
        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
            displayedMonth = newMonth
            selectedDate = newMonth
        }
    }

    private func makeMonthDays(for date: Date) -> [GwaTopCalendarDay] {
        guard let monthInterval = calendar.dateInterval(of: .month, for: date),
              let firstWeek = calendar.dateInterval(of: .weekOfMonth, for: monthInterval.start),
              let lastWeek = calendar.dateInterval(of: .weekOfMonth, for: monthInterval.end.addingTimeInterval(-1)) else {
            return []
        }

        var days: [GwaTopCalendarDay] = []
        var current = firstWeek.start

        while current < lastWeek.end {
            days.append(
                GwaTopCalendarDay(
                    id: current.timeIntervalSince1970,
                    date: current,
                    isCurrentMonth: calendar.isDate(current, equalTo: date, toGranularity: .month)
                )
            )
            guard let next = calendar.date(byAdding: .day, value: 1, to: current) else { break }
            current = next
        }

        return days
    }
}

private struct GwaTopCalendarDay: Identifiable, Equatable {
    let id: TimeInterval
    let date: Date
    let isCurrentMonth: Bool

    var dayNumber: String {
        String(Calendar.current.component(.day, from: date))
    }
}

private struct GwaTopCalendarHeaderMetric: View {
    let title: String
    let value: String
    let unit: String

    var body: some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white.opacity(0.72))

            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: 18, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                Text(unit)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.84))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(.white.opacity(0.14))
        .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
    }
}

private struct GwaTopCalendarDayCell: View {
    let day: GwaTopCalendarDay
    let isSelected: Bool
    let isToday: Bool
    let events: [GwaTopCalendarEvent]

    var body: some View {
        VStack(spacing: 5) {
            Text(day.dayNumber)
                .font(.system(size: 14, weight: isSelected || isToday ? .heavy : .bold))
                .foregroundStyle(foregroundColor)
                .frame(width: 30, height: 30)
                .background(circleBackground)
                .clipShape(Circle())

            HStack(spacing: 3) {
                ForEach(events.prefix(3)) { event in
                    Circle()
                        .fill(event.course.color)
                        .frame(width: 5, height: 5)
                }
            }
            .frame(height: 6)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 48)
        .background(isSelected ? GwaTopHomeTheme.primary.opacity(0.08) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .opacity(day.isCurrentMonth ? 1.0 : 0.35)
    }

    private var foregroundColor: Color {
        if isSelected { return .white }
        if isToday { return GwaTopHomeTheme.primary }
        return GwaTopHomeTheme.textPrimary
    }

    private var circleBackground: Color {
        if isSelected { return GwaTopHomeTheme.primary }
        return .clear
    }
}

private struct GwaTopCalendarEventRow: View {
    let event: GwaTopCalendarEvent

    var body: some View {
        HStack(spacing: 13) {
            VStack(spacing: 4) {
                Text(event.timeText)
                    .font(.system(size: 13, weight: .heavy, design: .rounded))
                    .foregroundStyle(event.course.color)
                Text(event.dDayText)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(GwaTopHomeTheme.textSecondary)
            }
            .frame(width: 54)

            Rectangle()
                .fill(event.course.color)
                .frame(width: 4)
                .clipShape(Capsule())

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Image(systemName: event.eventType.iconName)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(event.course.color)
                    Text(event.eventType.displayTitle)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(event.course.color)
                }

                Text(event.title)
                    .font(.system(size: 16, weight: .heavy))
                    .foregroundStyle(GwaTopHomeTheme.textPrimary)
                    .lineLimit(1)

                Text("\(event.course.name) · \(event.location)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(GwaTopHomeTheme.textSecondary)
                    .lineLimit(1)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(GwaTopHomeTheme.textSecondary)
        }
        .padding(14)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: .black.opacity(0.045), radius: 14, x: 0, y: 7)
    }
}

private struct GwaTopCalendarEventDetailSheet: View {
    let event: GwaTopCalendarEvent

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 14) {
                        Image(systemName: event.eventType.iconName)
                            .font(.system(size: 24, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 64, height: 64)
                            .background(event.course.color)
                            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))

                        VStack(alignment: .leading, spacing: 6) {
                            Text(event.eventType.displayTitle)
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(event.course.color)
                            Text(event.title)
                                .font(.system(size: 23, weight: .heavy, design: .rounded))
                                .foregroundStyle(GwaTopHomeTheme.textPrimary)
                        }
                    }

                    VStack(spacing: 12) {
                        GwaTopEventDetailRow(iconName: "calendar", title: "날짜", value: event.dateText)
                        GwaTopEventDetailRow(iconName: "clock.fill", title: "시간", value: event.timeText)
                        GwaTopEventDetailRow(iconName: "book.closed.fill", title: "과목", value: event.course.name)
                        GwaTopEventDetailRow(iconName: "mappin.and.ellipse", title: "장소", value: event.location)
                        GwaTopEventDetailRow(iconName: "sparkles", title: "등록 출처", value: event.source)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("메모")
                            .font(.system(size: 18, weight: .heavy))
                            .foregroundStyle(GwaTopHomeTheme.textPrimary)
                        Text(event.memo)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(GwaTopHomeTheme.textSecondary)
                            .lineSpacing(4)
                    }
                    .padding(16)
                    .background(GwaTopHomeTheme.background)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                }
                .padding(20)
            }
            .navigationTitle("일정 상세")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private struct GwaTopEventDetailRow: View {
    let iconName: String
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(GwaTopHomeTheme.primary)
                .frame(width: 34, height: 34)
                .background(GwaTopHomeTheme.primary.opacity(0.10))
                .clipShape(Circle())

            Text(title)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(GwaTopHomeTheme.textPrimary)

            Spacer()

            Text(value)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(GwaTopHomeTheme.textSecondary)
                .multilineTextAlignment(.trailing)
        }
        .padding(14)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

// 실제 업로드 시트는 GwaTopSyllabusUploadSheet.swift 참고.

#Preview {
    GwaTopCalendarView()
}
