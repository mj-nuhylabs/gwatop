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
    // "빈 달이면 가장 가까운 일정으로 점프" 자동 동작을 뷰 생애 최초 1회로 제한하기 위한 플래그.
    // (didInitialLoad 는 reload 호출 전에 이미 true 라 구분 불가 → 별도 플래그)
    @State private var didAutoJumpOnLoad: Bool = false
    @State private var showingCreateSheet: Bool = false
    @State private var editingEvent: GwaTopCalendarEvent? = nil
    @State private var selectedTopTab: TopTab = .calendar
    // 시간표에서 보고 있는 학기. nil 이면 활성 학기(없으면 첫 학기) 자동 선택.
    @State private var timetableSemesterId: String? = nil
    // 시간표 시트 상태 — 탭 시 선택된 과목, + 버튼 시 추가 시트 노출.
    @State private var timetableEditingCourse: GwaTopCourseDTO? = nil
    @State private var showingTimetableAddSheet: Bool = false
    // 캘린더 탭 FAB(+) 스피드다이얼 펼침 상태 — 구글 캘린더식 "강의계획서 업로드 / 일정 추가".
    @State private var isFabExpanded: Bool = false

    /// 강의계획서 파싱 진행 상태 — 배너 표시 + 완료 시 자동 reload 용.
    @ObservedObject private var syllabusWatcher = GwaTopSyllabusWatcher.shared

    // MARK: - Apple 캘린더 통합
    /// 사용자 설정 — 처음엔 false. 토글 켤 때 권한 요청.
    @AppStorage(UserDefaults.gwaTopAppleCalendarEnabledKey) private var appleCalendarEnabled: Bool = false
    /// Apple 캘린더에서 가져온 이벤트 — 서버 events 와는 별도 상태로 두고 표시 시점에 머지.
    @State private var appleEvents: [GwaTopCalendarEvent] = []
    @ObservedObject private var appleCalSvc = GwaTopAppleCalendarService.shared

    /// 서버 일정 + Apple 일정 합본. 모든 monthGrid/eventsForDate 등이 이걸 본다.
    private var mergedEvents: [GwaTopCalendarEvent] {
        appleCalendarEnabled ? events + appleEvents : events
    }

    private let calendar = Calendar.current
    private let weekdaySymbols = ["일", "월", "화", "수", "목", "금", "토"]

    private var monthTitle: String {
        GwaTopDateFormatters.koYearMonth.string(from: displayedMonth)
    }

    /// 상단 헤더 타이틀 — 캘린더 탭은 표시 중인 월("2026년 6월"), 시간표 탭은 "시간표".
    private var headerTitle: String {
        selectedTopTab == .calendar ? monthTitle : selectedTopTab.label
    }

    private var monthDays: [GwaTopCalendarDay] {
        makeMonthDays(for: displayedMonth)
    }

    private var selectedDateEvents: [GwaTopCalendarEvent] {
        mergedEvents
            .filter { calendar.isDate($0.startDate, inSameDayAs: selectedDate) }
            .sorted { $0.startDate < $1.startDate }
    }

    private var nearestUpcomingEvent: GwaTopCalendarEvent? {
        let start = calendar.startOfDay(for: selectedDate)
        return mergedEvents
            .filter { $0.startDate >= start }
            .min(by: { $0.startDate < $1.startDate })
            ?? mergedEvents.min(by: { $0.startDate < $1.startDate })
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

                VStack(spacing: 0) {
                    // 헤더에 캘린더/시간표 미니멀 아이콘 토글 동거 — 별도 줄 제거.
                    // 캘린더 탭: 타이틀이 월 표시("2026년 6월") + 월 이동 화살표.
                    // 시간표 탭: "시간표" 옆에 학기 드롭다운(업로드한 학기만).
                    headerBar

                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 16) {
                            if selectedTopTab == .calendar {
                                calendarTabContent
                            } else {
                                timetableTabContent
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 96)   // FAB 가림 방지 여유
                    }
                }

                // 펼쳐졌을 때 바깥을 탭하면 닫히도록 투명 레이어 — 화면은 어둡게 하지 않음.
                if isFabExpanded {
                    Color.clear
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture { collapseFab() }
                }

                // FAB(+) — 구글 캘린더식 스피드다이얼.
                // - 캘린더: 탭하면 "강의계획서 업로드 / 일정 추가" 가 펼쳐짐 (+ → ×)
                // - 시간표: 탭하면 곧장 시간표 추가 시트 (펼침 없음)
                VStack(alignment: .trailing, spacing: 14) {
                    if isFabExpanded {
                        fabActionPill(icon: "doc.badge.arrow.up.fill", label: "강의계획서 업로드") {
                            collapseFab()
                            showUploadPreview = true
                        }
                        fabActionPill(icon: "calendar.badge.plus", label: "일정 추가") {
                            collapseFab()
                            showingCreateSheet = true
                        }
                    }

                    Button {
                        if selectedTopTab == .timetable {
                            showingTimetableAddSheet = true
                        } else {
                            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                                isFabExpanded.toggle()
                            }
                        }
                    } label: {
                        Image(systemName: "plus")
                            .font(.gwaTopSystem(size: 22, weight: .heavy))
                            .foregroundStyle(.white)
                            .rotationEffect(.degrees(isFabExpanded ? 45 : 0))
                            .frame(width: 56, height: 56)
                            .background(GwaTopHomeTheme.primary)
                            .clipShape(Circle())
                            .shadow(color: GwaTopHomeTheme.primary.opacity(0.30), radius: 14, x: 0, y: 6)
                    }
                    .accessibilityLabel(isFabExpanded ? "닫기" : "추가")
                }
                .padding(.trailing, 22)
                .padding(.bottom, 22)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
            .toolbar(.hidden, for: .navigationBar)
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
            // 시간표 블록 탭 → 과목 정보/수정 시트
            .sheet(item: $timetableEditingCourse) { course in
                GwaTopTimetableCourseSheet(
                    course: course,
                    onSaved: { _ in
                        GwaTopAppDataStore.shared.refreshCoursesInBackground()
                        Task { await loadCoursesIfNeeded(force: true) }
                    },
                    onDeleted: { _ in
                        GwaTopAppDataStore.shared.refreshCoursesInBackground()
                        Task {
                            await loadCoursesIfNeeded(force: true)
                            await reload()
                        }
                    }
                )
                .presentationDetents([.large])
            }
            // 시간표 + 버튼 → 새 슬롯 추가 시트
            .sheet(isPresented: $showingTimetableAddSheet) {
                GwaTopTimetableAddSheet(
                    existingCourses: courses,
                    activeSemesterId: GwaTopAppDataStore.shared.semesters.first(where: { $0.isActive })?.id
                        ?? GwaTopAppDataStore.shared.semesters.first?.id,
                    onSaved: {
                        GwaTopAppDataStore.shared.refreshCoursesInBackground()
                        Task { await loadCoursesIfNeeded(force: true) }
                    }
                )
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
                // Apple 캘린더 통합이 켜져 있고 권한도 있으면 진입 시 한 번 fetch.
                await loadAppleEvents()
            }
            .refreshable {
                await reload()
                await loadCoursesIfNeeded(force: true)
                await loadAppleEvents()
            }
            // 표시 월이 바뀌면 Apple 일정 새 윈도우로 다시 fetch.
            .onChange(of: displayedMonth) { _, _ in
                Task { await loadAppleEvents() }
            }
            // 시간표 탭으로 전환하면 펼쳐둔 FAB 메뉴는 닫는다 (시간표 FAB 는 단일 동작).
            .onChange(of: selectedTopTab) { _, _ in
                isFabExpanded = false
            }
            // 사용자가 Apple 캘린더 앱에서 일정 추가/수정/삭제하면 EventKit 이 알림 → 자동 재로드.
            .onChange(of: appleCalSvc.changeCounter) { _, _ in
                Task { await loadAppleEvents() }
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

    // MARK: - 상단 헤더 트레일링 (월 이동 + 탭 전환)

    /// 캘린더 탭이면 월 이동 화살표를 같이 노출, 시간표 탭이면 탭 스위처만.
    @ViewBuilder
    /// 상단 헤더 한 줄. 캘린더 탭은 월 타이틀, 시간표 탭은 "시간표 + 학기 드롭다운".
    private var headerBar: some View {
        HStack(alignment: .center) {
            if selectedTopTab == .timetable {
                HStack(spacing: 8) {
                    Text("시간표")
                        .font(.gwaTopSystem(size: 26, weight: .heavy))
                        .foregroundStyle(GwaTopHomeTheme.textPrimary)
                    timetableSemesterMenu
                }
            } else {
                Text(headerTitle)
                    .font(.gwaTopSystem(size: 26, weight: .heavy))
                    .foregroundStyle(GwaTopHomeTheme.textPrimary)
            }
            Spacer()
            headerTrailing
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    /// "시간표" 옆 작은 학기 드롭다운 — 시간표 데이터(스케줄)가 있는 학기만 노출.
    @ViewBuilder
    private var timetableSemesterMenu: some View {
        let sems = timetableSemesters
        if !sems.isEmpty {
            let currentName = sems.first(where: { $0.id == effectiveTimetableSemesterId })?.name
                ?? sems.first?.name ?? "학기"
            Menu {
                ForEach(sems) { s in
                    Button {
                        timetableSemesterId = s.id
                    } label: {
                        if s.id == effectiveTimetableSemesterId {
                            Label(s.name, systemImage: "checkmark")
                        } else {
                            Text(s.name)
                        }
                    }
                }
            } label: {
                HStack(spacing: 3) {
                    Text(currentName)
                        .font(.gwaTopSystem(size: 13, weight: .bold))
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.gwaTopSystem(size: 9, weight: .bold))
                }
                .foregroundStyle(GwaTopHomeTheme.primary)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(GwaTopHomeTheme.primary.opacity(0.10))
                .clipShape(Capsule())
            }
        }
    }

    private var headerTrailing: some View {
        HStack(spacing: 6) {
            if selectedTopTab == .calendar {
                monthNavButtons
            }
            topTabSwitcher
        }
    }

    /// 월 이전/다음 이동 화살표.
    private var monthNavButtons: some View {
        HStack(spacing: 2) {
            Button {
                moveMonth(by: -1)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.gwaTopSystem(size: 14, weight: .bold))
                    .foregroundStyle(GwaTopHomeTheme.textSecondary)
                    .frame(width: 30, height: 30)
            }
            Button {
                moveMonth(by: 1)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.gwaTopSystem(size: 14, weight: .bold))
                    .foregroundStyle(GwaTopHomeTheme.textSecondary)
                    .frame(width: 30, height: 30)
            }
        }
    }

    // MARK: - 상단 탭 전환

    private var topTabSwitcher: some View {
        // 미니멀 아이콘 토글 — 헤더 우측, 캘린더 텍스트와 같은 높이.
        // 선택: primary 코랄 fill / 비선택: 배경 없음, 아이콘만.
        HStack(spacing: 4) {
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
                    Image(systemName: tab.icon)
                        .font(.gwaTopSystem(size: 15, weight: .bold))
                        .foregroundStyle(isSelected ? .white : GwaTopHomeTheme.textSecondary)
                        .frame(width: 34, height: 34)
                        .background(isSelected ? GwaTopHomeTheme.primary : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.label)
            }
        }
        .padding(4)
        .background(GwaTopHomeTheme.surface.opacity(0.45))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var calendarTabContent: some View {
        VStack(spacing: 18) {
            // 업로드/파싱 진행 상황은 GwaTopUploadProgressBanner 한 곳에서 통합 표시.
            // 이전엔 syllabusInFlightBanner 가 별도로 떠서 알림이 2 개 겹쳐 보였음.
            GwaTopUploadProgressBanner()

            if isLoading {
                loadingBanner
            } else if let msg = loadErrorMessage {
                errorBanner(message: msg)
            }

            // Apple 캘린더 연동 토글은 설정 화면으로 이동. (최초 로그인/회원가입 시 1회 안내)
            monthGrid
            // selectedDaySection 제거 — 일정은 셀 안 pill 로 직접 노출. tap 시 detail sheet.
            // 강의계획서 업로드 / 일정 추가 진입은 우하단 FAB(+) 스피드다이얼로 이동.
        }
    }

    // MARK: - FAB 스피드다이얼

    /// 펼침 메뉴를 애니메이션과 함께 접는다.
    private func collapseFab() {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
            isFabExpanded = false
        }
    }

    /// 스피드다이얼 액션 한 개 — 아이콘 + 라벨 캡슐. 딤 배경 위에 떠 보이도록 그림자 포함.
    private func fabActionPill(
        icon: String, label: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.gwaTopSystem(size: 16, weight: .bold))
                    .foregroundStyle(GwaTopHomeTheme.primary)
                    .frame(width: 22)
                Text(label)
                    .font(.gwaTopSystem(size: 15, weight: .bold))
                    .foregroundStyle(GwaTopHomeTheme.textPrimary)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(GwaTopHomeTheme.surface)
            .clipShape(Capsule())
            .shadow(color: .black.opacity(0.16), radius: 10, x: 0, y: 4)
        }
        .buttonStyle(.plain)
        .transition(.scale(scale: 0.85, anchor: .bottomTrailing).combined(with: .opacity))
    }

    /// 현재 표시 월 ±2개월 범위의 Apple 일정 fetch.
    /// 사용자가 월 넘길 때마다 호출돼서 새 윈도우 채움.
    @MainActor
    private func loadAppleEvents() async {
        guard appleCalendarEnabled, appleCalSvc.hasAccess else {
            appleEvents = []
            return
        }
        let cal = Calendar.current
        let start = cal.date(byAdding: .month, value: -2, to: displayedMonth) ?? displayedMonth
        let end = cal.date(byAdding: .month, value: 2, to: displayedMonth) ?? displayedMonth
        appleEvents = appleCalSvc.fetchEvents(from: start, to: end)
    }

    /// 백그라운드에서 파싱 중인 강의계획서가 있을 때 보여주는 카드.
    private var syllabusInFlightBanner: some View {
        let count = syllabusWatcher.inFlightFileIds.count
        return HStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.gwaTopSystem(size: 18, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(GwaTopHomeTheme.primary)
                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(count == 1
                     ? "강의계획서 분석 중"
                     : "강의계획서 \(count)개 분석 중")
                    .font(.gwaTopSystem(size: 14, weight: .heavy))
                    .foregroundStyle(GwaTopHomeTheme.textPrimary)
                Text("끝나면 자동으로 일정이 추가돼요")
                    .font(.gwaTopSystem(size: 12, weight: .medium))
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
        .background(GwaTopHomeTheme.surface)
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

            GwaTopTimetableView(
                courses: timetableFilteredCourses,
                onSelectCourse: { course in
                    timetableEditingCourse = course
                },
                onResolveConflict: { keep, removeFrom, day, slotStart, slotEnd in
                    resolveTimetableConflict(
                        keep: keep, removeFrom: removeFrom,
                        day: day, slotStartMin: slotStart, slotEndMin: slotEnd
                    )
                }
            )
        }
    }

    /// 시간표 드롭다운에 노출할 학기 — **시간표 데이터(스케줄)가 있는 학기만**.
    /// 즉 사용자가 강의계획서를 올려 수업 시간이 생긴 학기들만. 최신(시작일) 순.
    private var timetableSemesters: [GwaTopSemesterDTO] {
        let semIdsWithSchedule = Set(
            courses.filter { !($0.schedule ?? []).isEmpty }.map(\.semesterId)
        )
        return GwaTopAppDataStore.shared.semesters
            .filter { semIdsWithSchedule.contains($0.id) }
            .sorted { $0.startDate > $1.startDate }
    }

    /// 실제로 보여줄 학기 id — 사용자가 고른 것 > 활성(업로드된 것 중) > 첫 번째.
    private var effectiveTimetableSemesterId: String? {
        let sems = timetableSemesters
        if let chosen = timetableSemesterId, sems.contains(where: { $0.id == chosen }) {
            return chosen
        }
        return sems.first(where: { $0.isActive })?.id ?? sems.first?.id
    }

    /// 선택 학기의 과목만. 시간표 데이터가 있는 학기가 하나도 없으면 전체 표시 (폴백).
    private var timetableFilteredCourses: [GwaTopCourseDTO] {
        guard let sid = effectiveTimetableSemesterId else { return courses }
        return courses.filter { $0.semesterId == sid }
    }

    /// 겹침 해소 — keep 수업은 그대로 두고, removeFrom 수업의 충돌 슬롯만 제거 후 서버 반영.
    private func resolveTimetableConflict(
        keep: GwaTopCourseDTO,
        removeFrom: GwaTopCourseDTO,
        day: String,
        slotStartMin: Int,
        slotEndMin: Int
    ) {
        let startHHMM = String(format: "%02d:%02d", slotStartMin / 60, slotStartMin % 60)
        let endHHMM = String(format: "%02d:%02d", slotEndMin / 60, slotEndMin % 60)
        // removeFrom 의 schedule 에서 (요일 + 시작/종료가 일치하는) 충돌 슬롯만 뺀다.
        let newSchedule = (removeFrom.schedule ?? []).filter { ct in
            !(ct.day.uppercased() == day.uppercased()
              && ct.startTime == startHHMM
              && ct.endTime == endHHMM)
        }
        Task {
            do {
                _ = try await GwaTopCourseService.shared.update(
                    id: removeFrom.id, schedule: newSchedule
                )
                GwaTopAppDataStore.shared.refreshCoursesInBackground()
                await loadCoursesIfNeeded(force: true)
            } catch {
                await MainActor.run {
                    loadErrorMessage = (error as? LocalizedError)?.errorDescription
                        ?? error.localizedDescription
                }
            }
        }
    }

    @MainActor
    private func loadCoursesIfNeeded(force: Bool = false) async {
        if !force, !courses.isEmpty { return }
        // 스플래시 캐시 hydrate.
        let store = GwaTopAppDataStore.shared
        if !force, !store.courses.isEmpty {
            courses = store.courses
            if store.isCacheFresh { return }
        }
        do {
            courses = try await GwaTopCourseService.shared.fetchAll()
        } catch {
            if isCancellation(error) { return }
            loadErrorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    @MainActor
    private func reload(jumpToLatest: Bool = false) async {
        // 0) 스플래시 prefetch 캐시 hydrate — 깜빡임 제거. fresh 면 네트워크 호출 스킵.
        let store = GwaTopAppDataStore.shared
        if !store.allSchedules.isEmpty {
            events = store.allSchedules.map { GwaTopCalendarEvent(dto: $0) }
            if jumpToLatest {
                didAutoJumpOnLoad = true
                jumpToFirstUpcomingOrAuto()
            } else if !didAutoJumpOnLoad && !events.isEmpty && eventsInDisplayedMonth.isEmpty {
                // 빈 달을 보던 사용자가 새로고침/탭 재진입 때마다 끌려가지 않도록, 이
                // 자동 점프는 뷰 생애 최초 1회만 한다 (명시적 jumpToLatest 는 항상 점프).
                didAutoJumpOnLoad = true
                jumpToFirstUpcomingOrAuto()
            }
            if store.isCacheFresh && !jumpToLatest {
                isLoading = false
                loadErrorMessage = nil
                return
            }
        }

        // 캐시가 있으면 spinner 안 보여줌 — 이미 데이터가 차 있으니 백그라운드 갱신만.
        if events.isEmpty { isLoading = true }
        loadErrorMessage = nil
        do {
            let dtos = try await GwaTopScheduleService.shared.fetchAll()
            events = dtos.map { GwaTopCalendarEvent(dto: $0) }

            // 자동 점프 조건:
            //  1) 업로드 직후 (jumpToLatest=true) — 가장 가까운 자동 일정으로
            //  2) 일반 로드인데 현재 displayedMonth에 일정이 0이면서 어딘가에 일정이 있을 때
            //     → 사용자가 빈 달을 보고 "데이터가 사라졌다"고 오해하는 것 방지
            if jumpToLatest {
                didAutoJumpOnLoad = true
                jumpToFirstUpcomingOrAuto()
            } else if !didAutoJumpOnLoad && !events.isEmpty && eventsInDisplayedMonth.isEmpty {
                // 빈 달을 보던 사용자가 새로고침/탭 재진입 때마다 끌려가지 않도록, 이
                // 자동 점프는 뷰 생애 최초 1회만 한다 (명시적 jumpToLatest 는 항상 점프).
                didAutoJumpOnLoad = true
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
        mergedEvents.filter { calendar.isDate($0.startDate, equalTo: displayedMonth, toGranularity: .month) }
    }

    private var monthGrid: some View {
        // 셀마다 mergedEvents 를 선형 스캔(O 일수×이벤트)하지 않도록, 날짜(자정)별로 한 번만 그룹핑.
        let eventsByDay = Dictionary(grouping: mergedEvents) { calendar.startOfDay(for: $0.startDate) }
        return VStack(spacing: 0) {
            // 월 표시("2026년 6월")와 이동 화살표는 상단 헤더로 이동했다.
            // 요일 헤더
            HStack(spacing: 0) {
                ForEach(weekdaySymbols, id: \.self) { symbol in
                    Text(symbol)
                        .font(.gwaTopSystem(size: 11, weight: .bold))
                        .foregroundStyle(symbol == "일" ? GwaTopHomeTheme.danger.opacity(0.75) : GwaTopHomeTheme.textSecondary)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, 6)

            sectionDivider.opacity(0.5)

            // 주 단위 행 + hairline divider
            ForEach(Array(monthDaysByWeek.enumerated()), id: \.offset) { idx, week in
                HStack(alignment: .top, spacing: 0) {
                    ForEach(week) { day in
                        GwaTopCalendarDayCell(
                            day: day,
                            isToday: calendar.isDateInToday(day.date),
                            events: eventsByDay[calendar.startOfDay(for: day.date)] ?? [],
                            onEventTap: { event in
                                selectedEvent = event
                            },
                            onCellTap: {
                                withAnimation(.spring(response: 0.25, dampingFraction: 0.86)) {
                                    selectedDate = day.date
                                    if !calendar.isDate(day.date, equalTo: displayedMonth, toGranularity: .month) {
                                        displayedMonth = day.date
                                    }
                                }
                            }
                        )
                    }
                }
                if idx < monthDaysByWeek.count - 1 {
                    sectionDivider.opacity(0.5)
                }
            }
        }
    }

    /// 42개 monthDays 를 7개씩 묶어 6주.
    private var monthDaysByWeek: [[GwaTopCalendarDay]] {
        stride(from: 0, to: monthDays.count, by: 7).map {
            Array(monthDays[$0..<min($0 + 7, monthDays.count)])
        }
    }

    private var sectionDivider: some View {
        Rectangle()
            .fill(GwaTopHomeTheme.line)
            .frame(height: 1)
    }

    private var selectedDaySection: some View {
        VStack(alignment: .leading, spacing: 14) {
            // 헤더: 부제목("선택한 날짜의 일정") + 개수 캡슐 제거 — 날짜 타이틀만 노출
            Text(selectedDateTitle)
                .font(.gwaTopSystem(size: 21, weight: .bold))
                .foregroundStyle(GwaTopHomeTheme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)

            if selectedDateEvents.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "calendar.badge.checkmark")
                        .font(.gwaTopSystem(size: 32, weight: .bold))
                        .foregroundStyle(GwaTopHomeTheme.primary)
                    Text("이 날짜엔 일정이 없어요")
                        .font(.gwaTopSystem(size: 16, weight: .bold))
                        .foregroundStyle(GwaTopHomeTheme.textPrimary)
                    if let nearest = nearestUpcomingEvent {
                        Button {
                            withAnimation { jumpTo(event: nearest) }
                        } label: {
                            Text("→ \(nearest.dateText)에 \(nearest.title)")
                                .font(.gwaTopSystem(size: 13, weight: .heavy))
                                .foregroundStyle(GwaTopHomeTheme.primary)
                        }
                    } else if events.isEmpty {
                        Text("오른쪽 위 + 버튼으로 직접 일정을 추가하거나 강의계획서를 업로드해보세요.")
                            .font(.gwaTopSystem(size: 13, weight: .medium))
                            .foregroundStyle(GwaTopHomeTheme.textSecondary)
                            .multilineTextAlignment(.center)
                            .lineSpacing(3)
                    }
                }
                .padding(22)
                .frame(maxWidth: .infinity)
                .background(GwaTopHomeTheme.surface)
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
                .font(.gwaTopSystem(size: 13, weight: .medium))
                .foregroundStyle(GwaTopHomeTheme.textSecondary)
            Spacer()
        }
        .padding(14)
        .background(GwaTopHomeTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func errorBanner(message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(GwaTopHomeTheme.warning)
            VStack(alignment: .leading, spacing: 4) {
                Text("일정을 불러오지 못했어요")
                    .font(.gwaTopSystem(size: 13, weight: .heavy))
                    .foregroundStyle(GwaTopHomeTheme.textPrimary)
                Text(message)
                    .font(.gwaTopSystem(size: 12, weight: .medium))
                    .foregroundStyle(GwaTopHomeTheme.textSecondary)
                    .lineLimit(3)
            }
            Spacer()
        }
        .padding(14)
        .background(GwaTopHomeTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var selectedDateTitle: String {
        GwaTopDateFormatters.koMonthDayWeekday.string(from: selectedDate)
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
    let isToday: Bool
    let events: [GwaTopCalendarEvent]
    let onEventTap: (GwaTopCalendarEvent) -> Void
    let onCellTap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            // 날짜 — 오늘이면 검은 원 + 흰 글자, 일요일은 빨강, 다른 달은 흐리게
            HStack {
                Group {
                    if isToday {
                        Text(day.dayNumber)
                            .font(.gwaTopSystem(size: 12, weight: .heavy))
                            .foregroundStyle(GwaTopHomeTheme.background)
                            .frame(width: 22, height: 22)
                            .background(GwaTopHomeTheme.textPrimary)
                            .clipShape(Circle())
                    } else {
                        Text(day.dayNumber)
                            .font(.gwaTopSystem(size: 12, weight: .semibold))
                            .foregroundStyle(dateColor)
                            .frame(width: 22, height: 22)
                    }
                }
                Spacer(minLength: 0)
            }

            // 이벤트 pill (최대 2개) + 초과 시 +N
            VStack(spacing: 2) {
                ForEach(events.prefix(2)) { event in
                    Button {
                        onEventTap(event)
                    } label: {
                        Text(event.title)
                            .font(.gwaTopSystem(size: 9, weight: .semibold))
                            .foregroundStyle(event.course.color)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(event.course.color.opacity(0.18))
                            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
                if events.count > 2 {
                    Text("+\(events.count - 2)")
                        .font(.gwaTopSystem(size: 9, weight: .semibold))
                        .foregroundStyle(GwaTopHomeTheme.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 4)
                }
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 78, alignment: .topLeading)
        .padding(.horizontal, 3)
        .padding(.vertical, 4)
        .opacity(day.isCurrentMonth ? 1.0 : 0.38)
        .contentShape(Rectangle())
        .onTapGesture { onCellTap() }
    }

    /// 날짜 색: 다른 달 → tertiary, 일요일 → danger, 그 외 → textPrimary
    private var dateColor: Color {
        if !day.isCurrentMonth { return GwaTopHomeTheme.textTertiary }
        if Calendar.current.component(.weekday, from: day.date) == 1 {
            return GwaTopHomeTheme.danger
        }
        return GwaTopHomeTheme.textPrimary
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
                    .font(.gwaTopSystem(size: 11, weight: .bold))
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
                        .font(.gwaTopSystem(size: 12, weight: .bold))
                        .foregroundStyle(event.course.color)
                    Text(event.eventType.displayTitle)
                        .font(.gwaTopSystem(size: 12, weight: .bold))
                        .foregroundStyle(event.course.color)
                }

                Text(event.title)
                    .font(.gwaTopSystem(size: 16, weight: .heavy))
                    .foregroundStyle(GwaTopHomeTheme.textPrimary)
                    .lineLimit(1)

                Text("\(event.course.name) · \(event.location)")
                    .font(.gwaTopSystem(size: 12, weight: .medium))
                    .foregroundStyle(GwaTopHomeTheme.textSecondary)
                    .lineLimit(1)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.gwaTopSystem(size: 12, weight: .bold))
                .foregroundStyle(GwaTopHomeTheme.textSecondary)
        }
        .padding(14)
        .gwaTopCard(radius: 22)
    }
}

private struct GwaTopCalendarEventDetailSheet: View {
    let event: GwaTopCalendarEvent
    var onEdit: () -> Void
    var onDelete: () -> Void

    @State private var showDeleteConfirm: Bool = false
    @Environment(\.dismiss) private var dismiss

    /// Apple 캘린더에서 가져온 이벤트는 우리 서버 소유가 아니므로 수정/삭제 불가.
    private var isAppleEvent: Bool {
        event.source == "apple_calendar"
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 14) {
                        Image(systemName: isAppleEvent ? "applelogo" : event.eventType.iconName)
                            .font(.gwaTopSystem(size: 24, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 64, height: 64)
                            .background(event.course.color)
                            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))

                        VStack(alignment: .leading, spacing: 6) {
                            Text(isAppleEvent ? "Apple 캘린더" : event.eventType.displayTitle)
                                .font(.gwaTopSystem(size: 13, weight: .bold))
                                .foregroundStyle(event.course.color)
                            Text(event.title)
                                .font(.system(size: 23, weight: .heavy, design: .rounded))
                                .foregroundStyle(GwaTopHomeTheme.textPrimary)
                        }
                    }

                    VStack(spacing: 12) {
                        GwaTopEventDetailRow(iconName: "calendar", title: "날짜", value: event.dateText)
                        GwaTopEventDetailRow(iconName: "clock.fill", title: "시간", value: event.timeText)
                        GwaTopEventDetailRow(
                            iconName: isAppleEvent ? "calendar" : "book.closed.fill",
                            title: isAppleEvent ? "캘린더" : "과목",
                            value: event.course.name
                        )
                        GwaTopEventDetailRow(iconName: "mappin.and.ellipse", title: "장소", value: event.location)
                        GwaTopEventDetailRow(iconName: "sparkles", title: "등록 출처", value: event.source)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("메모")
                            .font(.gwaTopSystem(size: 18, weight: .heavy))
                            .foregroundStyle(GwaTopHomeTheme.textPrimary)
                        Text(event.memo.isEmpty ? "메모가 없습니다." : event.memo)
                            .font(.gwaTopSystem(size: 15, weight: .medium))
                            .foregroundStyle(GwaTopHomeTheme.textSecondary)
                            .lineSpacing(4)
                    }
                    .padding(16)
                    .background(GwaTopHomeTheme.background)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

                    if isAppleEvent {
                        // Apple 일정은 서버 소유가 아니므로 우리 앱에서 수정/삭제 못 함.
                        // 사용자가 Apple 캘린더 앱에서 직접 관리해야 한다는 점만 안내.
                        HStack(spacing: 10) {
                            Image(systemName: "info.circle.fill")
                                .foregroundStyle(GwaTopHomeTheme.textSecondary)
                            Text("Apple 캘린더의 일정이에요. 수정·삭제는 Apple 캘린더 앱에서 가능합니다.")
                                .font(.gwaTopSystem(size: 13, weight: .semibold))
                                .foregroundStyle(GwaTopHomeTheme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(GwaTopHomeTheme.background)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    } else {
                        HStack(spacing: 12) {
                            Button(action: onEdit) {
                                HStack {
                                    Image(systemName: "pencil")
                                    Text("수정")
                                }
                                .font(.gwaTopSystem(size: 15, weight: .heavy))
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
                                .font(.gwaTopSystem(size: 15, weight: .heavy))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 13)
                                .background(GwaTopHomeTheme.danger.opacity(0.1))
                                .foregroundStyle(GwaTopHomeTheme.danger)
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                            }
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
                .font(.gwaTopSystem(size: 15, weight: .bold))
                .foregroundStyle(GwaTopHomeTheme.primary)
                .frame(width: 34, height: 34)
                .background(GwaTopHomeTheme.primary.opacity(0.10))
                .clipShape(Circle())

            Text(title)
                .font(.gwaTopSystem(size: 14, weight: .bold))
                .foregroundStyle(GwaTopHomeTheme.textPrimary)

            Spacer()

            Text(value)
                .font(.gwaTopSystem(size: 14, weight: .medium))
                .foregroundStyle(GwaTopHomeTheme.textSecondary)
                .multilineTextAlignment(.trailing)
        }
        .padding(14)
        .background(GwaTopHomeTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

// 실제 업로드 시트는 GwaTopSyllabusUploadSheet.swift 참고.

#Preview {
    GwaTopCalendarView()
}
