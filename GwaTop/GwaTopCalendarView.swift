import SwiftUI

// MARK: - GwaTop Calendar View
// C-1 월간 캘린더, C-2 일정 상세, C-3 일정 추가/편집 진입 버튼, C-4 강의계획서 업로드 진입 버튼을 포함합니다.

struct GwaTopCalendarView: View {
    enum TopTab: String, CaseIterable, Identifiable {
        case calendar
        case timetable
        var id: String { rawValue }
        var label: String { self == .calendar ? "캘린더" : "시간표" }
        var icon: String { self == .calendar ? "calendar" : "tablecells" }
    }

    @State private var events: [GwaTopCalendarEvent] = []
    @State private var courses: [GwaTopCourseDTO] = []
    @State private var displayedMonth: Date = Date()
    @State private var selectedDate: Date = Date()
    @State private var selectedEvent: GwaTopCalendarEvent? = nil
    @State private var showUploadPreview: Bool = false
    @State private var isLoading: Bool = false
    @State private var loadErrorMessage: String? = nil
    @State private var didInitialLoad: Bool = false
    @State private var showingCreateSheet: Bool = false
    @State private var editingEvent: GwaTopCalendarEvent? = nil
    @State private var selectedTopTab: TopTab = .calendar

    /// 강의계획서 파싱 진행 상태 — 배너 표시 + 완료 시 자동 reload 용.
    @ObservedObject private var syllabusWatcher = GwaTopSyllabusWatcher.shared

    private let calendar = Calendar.current
    private let weekdaySymbols = ["일", "월", "화", "수", "목", "금", "토"]

    private var monthTitle: String {
        GwaTopDateFormatters.koYearMonth.string(from: displayedMonth)
    }

    private var monthDays: [GwaTopCalendarDay] {
        makeMonthDays(for: displayedMonth)
    }

    private var selectedDateEvents: [GwaTopCalendarEvent] {
        events
            .filter { calendar.isDate($0.startDate, inSameDayAs: selectedDate) }
            .sorted { $0.startDate < $1.startDate }
    }

    private var nearestUpcomingEvent: GwaTopCalendarEvent? {
        let start = calendar.startOfDay(for: selectedDate)
        return events
            .filter { $0.startDate >= start }
            .min(by: { $0.startDate < $1.startDate })
            ?? events.min(by: { $0.startDate < $1.startDate })
    }

    private func jumpTo(event: GwaTopCalendarEvent) {
        displayedMonth = event.startDate
        selectedDate = event.startDate
    }

    var body: some View {
        NavigationStack {
            ZStack {
                GwaTopHomeTheme.background
                    .ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 16) {
                        topTabSwitcher
                            .padding(.top, 12)

                        if selectedTopTab == .calendar {
                            calendarTabContent
                        } else {
                            timetableTabContent
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 32)
                }
            }
            .navigationTitle(selectedTopTab.label)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingCreateSheet = true
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
                GwaTopCalendarEventDetailSheet(
                    event: event,
                    onEdit: {
                        selectedEvent = nil
                        editingEvent = event
                    },
                    onDelete: {
                        Task { await deleteEvent(event) }
                    }
                )
                .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $showingCreateSheet) {
                GwaTopScheduleEditSheet(
                    mode: .create,
                    initialDate: selectedDate,
                    onSaved: { Task { await reload(jumpToLatest: true) } }
                )
                .presentationDetents([.large])
            }
            .sheet(item: $editingEvent) { event in
                GwaTopScheduleEditSheet(
                    mode: .edit(event),
                    onSaved: { Task { await reload() } }
                )
                .presentationDetents([.large])
            }
            .sheet(isPresented: $showUploadPreview) {
                GwaTopSyllabusUploadSheet(onUploadCompleted: {
                    Task {
                        await reload(jumpToLatest: true)
                        await loadCoursesIfNeeded(force: true)
                    }
                })
                .presentationDetents([.large])
            }
            .task {
                if !didInitialLoad {
                    didInitialLoad = true
                    await reload()
                }
                // Fail-safe: GwaTopApp 의 .task / .onChange(scenePhase) 가 어떤 이유로든
                // watcher 를 시작 못한 경우를 대비해, 캘린더 진입 시점에도 명시적으로 호출.
                // startWatching 은 idempotent 라 중복 호출 무해.
                print("[Calendar] .task — calling syllabusWatcher.startWatching()")
                syllabusWatcher.startWatching()
            }
            .refreshable {
                await reload()
                await loadCoursesIfNeeded(force: true)
            }
            // 강의계획서 파싱이 끝나면 watcher 가 알림. 사용자가 캘린더에 있던 없던
            // 다음 진입 시점에 최신 데이터가 보이도록 reload + courses 도 새로 로드.
            .onReceive(NotificationCenter.default.publisher(for: .syllabusParseCompleted)) { notif in
                let fid = (notif.userInfo?["file_id"] as? String) ?? "?"
                print("[Calendar] received .syllabusParseCompleted file_id=\(fid) — reloading events + courses")
                Task {
                    await reload(jumpToLatest: true)
                    await loadCoursesIfNeeded(force: true)
                }
            }
        }
    }

    // MARK: - 상단 탭 전환

    private var topTabSwitcher: some View {
        HStack(spacing: 6) {
            ForEach(TopTab.allCases) { tab in
                let isSelected = selectedTopTab == tab
                Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                        selectedTopTab = tab
                    }
                    if tab == .timetable {
                        Task { await loadCoursesIfNeeded() }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 13, weight: .bold))
                        Text(tab.label)
                            .font(.system(size: 14, weight: .bold))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 40)
                    .foregroundStyle(isSelected ? .white : GwaTopHomeTheme.primary)
                    .background(isSelected ? GwaTopHomeTheme.primary : Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(GwaTopHomeTheme.primary.opacity(0.25), lineWidth: isSelected ? 0 : 1)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(Color.white.opacity(0.45))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var calendarTabContent: some View {
        VStack(spacing: 18) {
            if !syllabusWatcher.inFlightFileIds.isEmpty {
                syllabusInFlightBanner
            }

            if isLoading {
                loadingBanner
            } else if let msg = loadErrorMessage {
                errorBanner(message: msg)
            }

            monthGrid
            selectedDaySection
            syllabusUploadCard
        }
    }

    /// 백그라운드에서 파싱 중인 강의계획서가 있을 때 보여주는 카드.
    private var syllabusInFlightBanner: some View {
        let count = syllabusWatcher.inFlightFileIds.count
        return HStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(GwaTopHomeTheme.primary)
                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(count == 1
                     ? "강의계획서 분석 중"
                     : "강의계획서 \(count)개 분석 중")
                    .font(.system(size: 14, weight: .heavy))
                    .foregroundStyle(GwaTopHomeTheme.textPrimary)
                Text("끝나면 자동으로 일정이 추가돼요")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(GwaTopHomeTheme.textSecondary)
                    .lineLimit(1)
            }

            Spacer()

            ProgressView()
                .controlSize(.small)
                .tint(GwaTopHomeTheme.primary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(GwaTopHomeTheme.primary.opacity(0.22), lineWidth: 1)
        )
    }

    private var timetableTabContent: some View {
        VStack(spacing: 16) {
            if let msg = loadErrorMessage {
                errorBanner(message: msg)
            }

            GwaTopTimetableView(courses: courses)
        }
    }

    @MainActor
    private func loadCoursesIfNeeded(force: Bool = false) async {
        if !force, !courses.isEmpty { return }
        do {
            courses = try await GwaTopCourseService.shared.fetchAll()
        } catch {
            if isCancellation(error) { return }
            loadErrorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    @MainActor
    private func reload(jumpToLatest: Bool = false) async {
        isLoading = true
        loadErrorMessage = nil
        do {
            let dtos = try await GwaTopScheduleService.shared.fetchAll()
            events = dtos.map { GwaTopCalendarEvent(dto: $0) }

            // 자동 점프 조건:
            //  1) 업로드 직후 (jumpToLatest=true) — 가장 가까운 자동 일정으로
            //  2) 일반 로드인데 현재 displayedMonth에 일정이 0이면서 어딘가에 일정이 있을 때
            //     → 사용자가 빈 달을 보고 "데이터가 사라졌다"고 오해하는 것 방지
            if jumpToLatest {
                jumpToFirstUpcomingOrAuto()
            } else if !events.isEmpty && eventsInDisplayedMonth.isEmpty {
                jumpToFirstUpcomingOrAuto()
            }
        } catch {
            // SwiftUI 라이프사이클로 인한 task 취소는 정상 동작이므로 무시.
            // 이전에 로드된 events 는 그대로 유지된다.
            if isCancellation(error) {
                isLoading = false
                return
            }
            loadErrorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            print("[Calendar] reload failed: \(error)")
        }
        isLoading = false
    }

    @MainActor
    private func deleteEvent(_ event: GwaTopCalendarEvent) async {
        do {
            try await GwaTopScheduleService.shared.delete(id: event.id)
            await MainActor.run {
                events.removeAll { $0.id == event.id }
                selectedEvent = nil
            }
        } catch {
            await MainActor.run {
                loadErrorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    @MainActor
    private func jumpToFirstUpcomingOrAuto() {
        // 우선순위: (1) is_auto=true 중 가장 가까운 일정, (2) 오늘 이후 가장 가까운 일정
        let autoEvents = events.filter { $0.source == "ai_parsed" }
        let target = autoEvents.min(by: { $0.startDate < $1.startDate })
            ?? events
                .filter { $0.startDate >= calendar.startOfDay(for: Date()) }
                .min(by: { $0.startDate < $1.startDate })
            ?? events.first

        guard let event = target else { return }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) {
            displayedMonth = event.startDate
            selectedDate = event.startDate
        }
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
                    Text("이 날짜엔 일정이 없어요")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(GwaTopHomeTheme.textPrimary)
                    if let nearest = nearestUpcomingEvent {
                        Button {
                            withAnimation { jumpTo(event: nearest) }
                        } label: {
                            Text("→ \(nearest.dateText)에 \(nearest.title)")
                                .font(.system(size: 13, weight: .heavy))
                                .foregroundStyle(GwaTopHomeTheme.primary)
                        }
                    } else if events.isEmpty {
                        Text("오른쪽 위 + 버튼으로 직접 일정을 추가하거나 강의계획서를 업로드해보세요.")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(GwaTopHomeTheme.textSecondary)
                            .multilineTextAlignment(.center)
                            .lineSpacing(3)
                    }
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
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                Task { await deleteEvent(event) }
                            } label: {
                                Label("삭제", systemImage: "trash")
                            }
                            Button {
                                editingEvent = event
                            } label: {
                                Label("수정", systemImage: "pencil")
                            }
                            .tint(GwaTopHomeTheme.primary)
                        }
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
                Text("일정을 불러오지 못했어요")
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
        GwaTopDateFormatters.koMonthDayWeekday.string(from: selectedDate)
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
    var onEdit: () -> Void
    var onDelete: () -> Void

    @State private var showDeleteConfirm: Bool = false
    @Environment(\.dismiss) private var dismiss

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
                        Text(event.memo.isEmpty ? "메모가 없습니다." : event.memo)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(GwaTopHomeTheme.textSecondary)
                            .lineSpacing(4)
                    }
                    .padding(16)
                    .background(GwaTopHomeTheme.background)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

                    HStack(spacing: 12) {
                        Button(action: onEdit) {
                            HStack {
                                Image(systemName: "pencil")
                                Text("수정")
                            }
                            .font(.system(size: 15, weight: .heavy))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                            .background(GwaTopHomeTheme.primary)
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                        }

                        Button {
                            showDeleteConfirm = true
                        } label: {
                            HStack {
                                Image(systemName: "trash")
                                Text("삭제")
                            }
                            .font(.system(size: 15, weight: .heavy))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                            .background(Color.red.opacity(0.1))
                            .foregroundStyle(.red)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                        }
                    }
                }
                .padding(20)
            }
            .navigationTitle("일정 상세")
            .navigationBarTitleDisplayMode(.inline)
            .confirmationDialog(
                "일정을 삭제할까요?",
                isPresented: $showDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button("삭제", role: .destructive) {
                    onDelete()
                    dismiss()
                }
                Button("취소", role: .cancel) {}
            } message: {
                Text("\(event.title) — 되돌릴 수 없습니다.")
            }
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
