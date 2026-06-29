import SwiftUI

// MARK: - GwaTop Todo View (레퍼런스 PM 앱 스타일로 재구성)
// 레이아웃: 주간 날짜 스트립 → 과목 진행도 카드 그리드 → 선택한 날짜의 할 일 카드 리스트.
// 과목 카드 탭 → 과목별 과제 상세(요약 카드 + 번호 매긴 표). 백엔드 dashboard.upcoming_todos 와 연동.

struct GwaTopAssignmentsView: View {
    @State private var assignments: [GwaTopAssignment] = []
    /// 주간 스트립에서 선택된 날짜 — 이 날 마감인 과제만 리스트에 표시.
    @State private var selectedDate: Date = Date()
    @State private var isLoading = false
    @State private var loadError: String? = nil
    /// 빠른 더블탭으로 토글이 중복 실행되는 걸 막는 진행중 id 집합.
    @State private var togglingIds: Set<String> = []
    /// 길게 눌러 드래그하는 동안의 과목 id — 드롭 대상 카드 강조용.
    @State private var draggingCourseId: String? = nil
    /// 과목 순서 편집 모드 — iOS 홈 화면처럼 카드를 길게 누르면 켜지고 "완료"로 끈다.
    @State private var isEditingCourses = false

    /// 사용자가 직접 정한 과목 순서(학습/Todo 공유) — 길게 눌러 드래그로 재정렬.
    @ObservedObject private var orderStore = GwaTopCourseOrderStore.shared

    /// 카드를 길게 눌렀을 때 — 햅틱과 함께 과목 순서 편집 모드로 진입.
    private func enterCourseEditMode() {
        guard !isEditingCourses else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        withAnimation(.easeOut(duration: 0.18)) { isEditingCourses = true }
    }

    private let calendar = Calendar.current
    private let weekdaySymbols = ["월", "화", "수", "목", "금", "토", "일"]

    // MARK: - 파생 데이터

    private static func priorityWeight(_ p: GwaTopAssignmentPriority) -> Int {
        switch p {
        case .high: return 0
        case .medium: return 1
        case .low: return 2
        }
    }

    private func sortedByPriorityThenDate(_ list: [GwaTopAssignment]) -> [GwaTopAssignment] {
        list.sorted { lhs, rhs in
            let lw = Self.priorityWeight(lhs.priority)
            let rw = Self.priorityWeight(rhs.priority)
            if lw != rw { return lw < rw }
            return lhs.dueDate < rhs.dueDate
        }
    }

    /// 선택된 날짜가 속한 주(월~일) 7일.
    private var weekDays: [Date] {
        let weekday = calendar.component(.weekday, from: selectedDate) // 1=일 ... 7=토
        let daysFromMonday = (weekday + 5) % 7
        let start = calendar.startOfDay(for: selectedDate)
        guard let monday = calendar.date(byAdding: .day, value: -daysFromMonday, to: start) else { return [] }
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: monday) }
    }

    /// 과목별 진행도 카드 데이터 — 로드된 전체 todo 기준 (완료/전체, 다음 마감).
    private var courseProgressList: [GwaTopTodoCourseProgress] {
        let groups = Dictionary(grouping: assignments, by: { $0.course.id })
        return groups.compactMap { _, items -> GwaTopTodoCourseProgress? in
            guard let first = items.first else { return nil }
            let total = items.count
            let done = items.filter(\.isCompleted).count
            let nextDue = items.filter { !$0.isCompleted }.map(\.dueDate).min()
            return GwaTopTodoCourseProgress(course: first.course, total: total, done: done, nextDue: nextDue)
        }
        .sorted { lhs, rhs in
            // 마감 임박한 과목 우선, 동률이면 이름순.
            let l = lhs.nextDue ?? .distantFuture
            let r = rhs.nextDue ?? .distantFuture
            if l != r { return l < r }
            return lhs.course.name < rhs.course.name
        }
    }

    /// 사용자가 직접 정한 순서를 우선 적용한 과목 진행도 카드 목록.
    /// 아직 손대지 않은 과목은 기본 정렬(마감 임박순)을 그대로 따른다.
    private var orderedCourseProgressList: [GwaTopTodoCourseProgress] {
        orderStore.ordered(courseProgressList) { $0.course.id }
    }

    /// 선택된 날짜에 마감인 과제 — 미완(우선순위·마감순) 먼저, 완료는 맨 아래로.
    private var dayAssignments: [GwaTopAssignment] {
        let base = assignments.filter { calendar.isDate($0.dueDate, inSameDayAs: selectedDate) }
        let active = sortedByPriorityThenDate(base.filter { !$0.isCompleted })
        let done = base.filter { $0.isCompleted }.sorted { $0.dueDate < $1.dueDate }
        return active + done
    }

    /// 특정 과목의 과제 — 미완(마감 빠른 순) 먼저, 완료는 뒤로. 상세 표용.
    private func assignmentsForCourse(_ id: String) -> [GwaTopAssignment] {
        assignments
            .filter { $0.course.id == id }
            .sorted { a, b in
                if a.isCompleted != b.isCompleted { return !a.isCompleted }
                return a.dueDate < b.dueDate
            }
    }

    private func relativeDayLabel(_ date: Date) -> String {
        if calendar.isDateInToday(date) { return "오늘" }
        if calendar.isDateInTomorrow(date) { return "내일" }
        if calendar.isDateInYesterday(date) { return "어제" }
        return GwaTopDateFormatters.koMonthDayShortWeekday.string(from: date)
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ZStack {
                GwaTopHomeTheme.background
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    GwaTopScreenHeader(title: "Todo") {
                        if isEditingCourses {
                            // 편집 모드 — iOS 홈 화면처럼 "완료" 로 빠져나간다.
                            Button {
                                withAnimation(.easeOut(duration: 0.18)) { isEditingCourses = false }
                            } label: {
                                Text("완료")
                                    .font(.gwaTopSystem(size: 14, weight: .bold))
                                    .foregroundStyle(GwaTopHomeTheme.primary)
                                    .padding(.horizontal, 14)
                                    .frame(height: 32)
                                    .background(GwaTopHomeTheme.surfaceMute)
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        } else {
                            // 레퍼런스의 "July, 2025 ⌄" 위치 — 제목 줄 오른쪽. 탭하면 오늘로 복귀.
                            Button {
                                goToToday()
                            } label: {
                                HStack(spacing: 4) {
                                    Text(GwaTopDateFormatters.koYearMonth.string(from: selectedDate))
                                        .font(.gwaTopSystem(size: 14, weight: .bold))
                                        .foregroundStyle(GwaTopHomeTheme.textSecondary)
                                    Image(systemName: "chevron.down")
                                        .font(.gwaTopSystem(size: 10, weight: .bold))
                                        .foregroundStyle(GwaTopHomeTheme.textTertiary)
                                }
                                .padding(.horizontal, 12)
                                .frame(height: 32)
                                .background(GwaTopHomeTheme.surfaceMute)
                                .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 20) {
                            if let err = loadError {
                                errorState(err)
                            } else if isLoading && assignments.isEmpty {
                                loadingState
                            } else {
                                weekStripView

                                if assignments.isEmpty {
                                    bigEmptyState
                                } else {
                                    if !courseProgressList.isEmpty {
                                        courseCardsSection
                                    }
                                    taskSection
                                }
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 6)
                        .padding(.bottom, 30)
                    }
                    .refreshable { await load() }
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: String.self) { courseId in
                if let item = courseProgressList.first(where: { $0.course.id == courseId }) {
                    GwaTopCourseTodoDetailView(
                        course: item.course,
                        progress: item,
                        assignments: assignmentsForCourse(courseId),
                        onToggle: { toggleAssignment($0) }
                    )
                }
            }
            .task { if assignments.isEmpty { await load() } }
            // 강의계획서 파싱 완료 → 자동 생성 과제가 즉시 목록에 반영되도록 강제 새로고침.
            .onReceive(NotificationCenter.default.publisher(for: .syllabusParseCompleted)) { _ in
                Task { await load(force: true) }
            }
        }
    }

    // MARK: - 주간 날짜 스트립 (레퍼런스 상단 week strip)

    private var weekStripView: some View {
        // 월 표시는 헤더로 올림. 카드 없이 투명 배경의 ‹ 요일행 › 한 줄 — 위아래 폭 최소화.
        HStack(spacing: 2) {
            weekArrow("chevron.left") { shiftWeek(-1) }

            HStack(spacing: 4) {
                ForEach(Array(weekDays.enumerated()), id: \.element) { idx, day in
                    dayCell(day, label: weekdaySymbols[idx])
                }
            }

            weekArrow("chevron.right") { shiftWeek(1) }
        }
        .padding(.vertical, 2)
    }

    private func weekArrow(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.gwaTopSystem(size: 13, weight: .bold))
                .foregroundStyle(GwaTopHomeTheme.textSecondary)
                .frame(width: 26, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func shiftWeek(_ direction: Int) {
        if let d = calendar.date(byAdding: .day, value: 7 * direction, to: selectedDate) {
            withAnimation(.easeInOut(duration: 0.2)) { selectedDate = d }
        }
    }

    private func goToToday() {
        withAnimation(.easeInOut(duration: 0.2)) { selectedDate = Date() }
    }

    private func dayCell(_ day: Date, label: String) -> some View {
        let isSelected = calendar.isDate(day, inSameDayAs: selectedDate)
        let isToday = calendar.isDateInToday(day)
        let hasTasks = assignments.contains { calendar.isDate($0.dueDate, inSameDayAs: day) }
        let dayNum = calendar.component(.day, from: day)
        return Button {
            withAnimation(.easeInOut(duration: 0.18)) { selectedDate = day }
        } label: {
            VStack(spacing: 3) {
                Text(label)
                    .font(.gwaTopSystem(size: 10, weight: .bold))
                    .foregroundStyle(isSelected ? Color.white.opacity(0.9) : GwaTopHomeTheme.textSecondary)
                Text("\(dayNum)")
                    .font(.system(size: 14, weight: .heavy, design: .rounded))
                    .foregroundStyle(isSelected ? .white : (isToday ? GwaTopHomeTheme.primary : GwaTopHomeTheme.textPrimary))
                Circle()
                    .fill(isSelected ? Color.white : GwaTopHomeTheme.primary)
                    .frame(width: 4, height: 4)
                    .opacity(hasTasks ? 1 : 0)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(isSelected ? GwaTopHomeTheme.primary : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - 과목 진행도 카드 (레퍼런스 Pinned Project 그리드)

    private var courseCardsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("내 과목")
                .font(.gwaTopSystem(size: 18, weight: .bold))
                .foregroundStyle(GwaTopHomeTheme.textPrimary)

            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                spacing: 12
            ) {
                ForEach(Array(orderedCourseProgressList.enumerated()), id: \.element.id) { idx, item in
                    NavigationLink(value: item.course.id) {
                        GwaTopTodoCourseCard(item: item)
                    }
                    .buttonStyle(.plain)
                    .modifier(GwaTopCourseReorderModifier(
                        courseId: item.course.id,
                        index: idx,
                        isEditing: isEditingCourses,
                        enabled: true,
                        draggingId: $draggingCourseId,
                        onEnterEdit: { enterCourseEditMode() },
                        onMove: { dragged in
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
                                orderStore.move(dragged, before: item.course.id,
                                                in: orderedCourseProgressList.map(\.course.id))
                            }
                        }
                    ))
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.86), value: orderStore.order)
        }
    }

    // MARK: - 할 일 리스트 (레퍼런스 Task 카드)

    private var taskSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("할 일")
                    .font(.gwaTopSystem(size: 18, weight: .bold))
                    .foregroundStyle(GwaTopHomeTheme.textPrimary)
                Text("\(dayAssignments.count)")
                    .font(.system(size: 14, weight: .heavy, design: .rounded))
                    .foregroundStyle(GwaTopHomeTheme.textSecondary)
                Spacer()
                Text(relativeDayLabel(selectedDate))
                    .font(.gwaTopSystem(size: 13, weight: .semibold))
                    .foregroundStyle(GwaTopHomeTheme.textSecondary)
            }

            if dayAssignments.isEmpty {
                emptyDayState
            } else {
                VStack(spacing: 12) {
                    ForEach(dayAssignments) { assignment in
                        GwaTopTodoTaskCard(
                            assignment: assignment,
                            onToggle: { toggleAssignment(assignment) }
                        )
                    }
                }
            }
        }
    }

    // MARK: - 상태 뷰

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("불러오는 중...")
                .font(.gwaTopSystem(size: 13, weight: .medium))
                .foregroundStyle(GwaTopHomeTheme.textSecondary)
        }
        .padding(40)
        .frame(maxWidth: .infinity)
        .gwaTopCard(radius: 24)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.gwaTopSystem(size: 32))
                .foregroundStyle(GwaTopHomeTheme.warning)
            Text("불러오기 실패")
                .font(.gwaTopSystem(size: 17, weight: .bold))
                .foregroundStyle(GwaTopHomeTheme.textPrimary)
            Text(message)
                .font(.gwaTopSystem(size: 13, weight: .medium))
                .foregroundStyle(GwaTopHomeTheme.textSecondary)
                .multilineTextAlignment(.center)
            Button("다시 시도") {
                Task { await load() }
            }
            .font(.gwaTopSystem(size: 14, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(GwaTopHomeTheme.primary)
            .clipShape(Capsule())
        }
        .padding(28)
        .frame(maxWidth: .infinity)
        .gwaTopCard(radius: 24)
    }

    /// 등록된 todo 자체가 하나도 없을 때.
    private var bigEmptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
                .font(.gwaTopSystem(size: 42, weight: .bold))
                .foregroundStyle(GwaTopHomeTheme.success)
            Text("아직 할 일이 없어요")
                .font(.gwaTopSystem(size: 19, weight: .bold))
                .foregroundStyle(GwaTopHomeTheme.textPrimary)
            Text("강의계획서를 업로드하면 과제와 일정이 자동으로 채워져요.")
                .font(.gwaTopSystem(size: 14, weight: .medium))
                .foregroundStyle(GwaTopHomeTheme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(30)
        .frame(maxWidth: .infinity)
        .gwaTopCard(radius: 24)
    }

    /// 선택한 날짜에만 할 일이 없을 때 (다른 날엔 있음).
    private var emptyDayState: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.circle")
                .font(.gwaTopSystem(size: 30, weight: .semibold))
                .foregroundStyle(GwaTopHomeTheme.textTertiary)
            Text("이 날은 할 일이 없어요")
                .font(.gwaTopSystem(size: 14, weight: .semibold))
                .foregroundStyle(GwaTopHomeTheme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
    }

    // MARK: - 데이터 로드 / 토글

    @MainActor
    private func load(force: Bool = false) async {
        // 홈 ToDo 와 동일한 항목을 보여주려고 소스를 dashboard.upcoming_todos 로 통일.
        // (과제탭은 풀 리스트이므로 limit 을 넉넉히 줘 홈 항목을 모두 포함한다.)
        let store = GwaTopAppDataStore.shared

        // 0) 스플래시 prefetch 캐시 hydrate — 깜빡임 제거.
        if let cachedTodos = store.dashboard?.upcomingTodos, !cachedTodos.isEmpty {
            assignments = cachedTodos.map(GwaTopAssignment.init(dto:))
            if !force && store.isCacheFresh {
                isLoading = false
                loadError = nil
                return
            }
        }

        if assignments.isEmpty { isLoading = true }
        loadError = nil
        defer { isLoading = false }

        do {
            let dash = try await GwaTopHomeService.shared.fetchDashboard(upcomingLimit: 100)
            assignments = dash.upcomingTodos.map(GwaTopAssignment.init(dto:))
        } catch {
            if isCancellation(error) { return }
            loadError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    @MainActor
    private func applyOptimisticToggle(_ assignment: GwaTopAssignment) {
        guard let index = assignments.firstIndex(where: { $0.id == assignment.id }) else { return }
        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
            assignments[index].status = assignments[index].isCompleted ? .pending : .completed
        }
    }

    /// 원래 status로 명시 복원 — 외부 reload 등으로 상태가 바뀌어도 toggle 누적 오차 없음.
    @MainActor
    private func restoreStatus(id: String, status: GwaTopAssignmentStatus) {
        guard let index = assignments.firstIndex(where: { $0.id == id }) else { return }
        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
            assignments[index].status = status
        }
    }

    private func toggleAssignment(_ assignment: GwaTopAssignment) {
        // 진행 중이면 무시 (빠른 더블탭 race 방지)
        guard !togglingIds.contains(assignment.id) else { return }
        togglingIds.insert(assignment.id)

        // optimistic update — 실패 시 원래 status로 복원.
        let originalStatus = assignment.status
        applyOptimisticToggle(assignment)
        Task {
            defer { Task { @MainActor in togglingIds.remove(assignment.id) } }
            do {
                let newIsDone = !assignment.isCompleted
                let dto = try await GwaTopTodoService.shared.toggleDone(
                    id: assignment.id,
                    isDone: newIsDone
                )
                await MainActor.run {
                    if let idx = assignments.firstIndex(where: { $0.id == dto.id }) {
                        assignments[idx] = GwaTopAssignment(dto: dto)
                    }
                }
            } catch {
                await MainActor.run {
                    if isCancellation(error) { return }
                    restoreStatus(id: assignment.id, status: originalStatus)
                    loadError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
            }
        }
    }
}

// MARK: - 과목 진행도 모델

private struct GwaTopTodoCourseProgress: Identifiable {
    let course: GwaTopCourseSummary
    let total: Int
    let done: Int
    let nextDue: Date?

    var id: String { course.id }
    var progress: Double { total > 0 ? Double(done) / Double(total) : 0 }
    var remaining: Int { max(0, total - done) }
}

// MARK: - 공통 작은 컴포넌트

/// 얇은 진행바 — 홈 과목 카드와 동일 톤.
private struct GwaTopThinProgressBar: View {
    let progress: Double
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(GwaTopHomeTheme.line)
                Capsule()
                    .fill(color)
                    .frame(width: max(0, proxy.size.width * CGFloat(min(max(progress, 0), 1))))
            }
        }
        .frame(height: 7)
    }
}

/// 둥근 체크박스 — 미완: 과목색 얇은 링 / 완료: success 채움 + 흰 체크.
/// (홈 "오늘 마감" 스트립에서도 재사용 — internal)
struct GwaTopTodoCheckbox: View {
    let isCompleted: Bool
    let color: Color

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(color.opacity(0.5), lineWidth: 1.6)
                .opacity(isCompleted ? 0 : 1)
            Circle()
                .fill(GwaTopHomeTheme.success)
                .opacity(isCompleted ? 1 : 0)
            Image(systemName: "checkmark")
                .font(.gwaTopSystem(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .opacity(isCompleted ? 1 : 0)
        }
        .frame(width: 24, height: 24)
        .frame(width: 34, height: 34)        // 넉넉한 탭 영역
        .contentShape(Circle())
    }
}

// MARK: - 과목 진행도 카드 (그리드 셀)

private struct GwaTopTodoCourseCard: View {
    let item: GwaTopTodoCourseProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                ZStack {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(item.course.color.opacity(0.13))
                        .frame(width: 42, height: 42)
                    Image(systemName: "folder.fill")
                        .font(.gwaTopSystem(size: 17, weight: .bold))
                        .foregroundStyle(item.course.color)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.gwaTopSystem(size: 12, weight: .semibold))
                    .foregroundStyle(GwaTopHomeTheme.textTertiary)
            }

            Spacer(minLength: 14)

            Text(item.course.name)
                .font(.gwaTopSystem(size: 15, weight: .bold))
                .foregroundStyle(GwaTopHomeTheme.textPrimary)
                .lineLimit(1)

            HStack(spacing: 6) {
                Circle()
                    .fill(item.course.color)
                    .frame(width: 7, height: 7)
                Text("\(item.done)/\(item.total) 완료")
                    .font(.gwaTopSystem(size: 12, weight: .semibold))
                    .foregroundStyle(GwaTopHomeTheme.textSecondary)
            }
            .padding(.top, 6)

            GwaTopThinProgressBar(progress: item.progress, color: item.course.color)
                .padding(.top, 8)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 148, alignment: .topLeading)
        .gwaTopCard(radius: 20)
    }
}

// MARK: - 할 일 카드 (리스트 셀)

private struct GwaTopTodoTaskCard: View {
    let assignment: GwaTopAssignment
    let onToggle: () -> Void

    private var isCompleted: Bool { assignment.isCompleted }
    /// 마감이 오늘이거나 지났는데 아직 미완 → "진행 중"(긴급) 으로 강조.
    private var isUrgent: Bool { !isCompleted && Date.gwaTopDDayFromToday(to: assignment.dueDate) <= 0 }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                // 과목 라벨 (레퍼런스의 회색 카테고리 라벨 → 과목색으로)
                Text(assignment.course.name)
                    .font(.gwaTopSystem(size: 12, weight: .bold))
                    .foregroundStyle(assignment.course.color)
                    .lineLimit(1)

                Text(assignment.title)
                    .font(.gwaTopSystem(size: 16, weight: .bold))
                    .foregroundStyle(GwaTopHomeTheme.textPrimary)
                    .strikethrough(isCompleted, color: GwaTopHomeTheme.textSecondary)
                    .opacity(isCompleted ? 0.55 : 1)
                    .lineLimit(2)

                // 설명이 있으면(수동 등록 todo) 표시, 없으면 생략.
                if !assignment.description.isEmpty {
                    Text(assignment.description)
                        .font(.gwaTopSystem(size: 13, weight: .medium))
                        .foregroundStyle(GwaTopHomeTheme.textSecondary)
                        .lineLimit(2)
                }

                // 메타 행: 과목색 점 + 마감 시각 + D-Day (날짜 미지정 todo 는 "날짜 미정"만 표시)
                HStack(spacing: 7) {
                    Circle()
                        .fill(isCompleted ? GwaTopHomeTheme.controlDisabled : assignment.course.color)
                        .frame(width: 7, height: 7)
                    if assignment.hasDueDate {
                        Text(GwaTopDateFormatters.koMonthDayTime.string(from: assignment.dueDate))
                            .font(.gwaTopSystem(size: 12, weight: .medium))
                            .foregroundStyle(GwaTopHomeTheme.textSecondary)
                        Text("·")
                            .font(.gwaTopSystem(size: 12, weight: .medium))
                            .foregroundStyle(GwaTopHomeTheme.textTertiary)
                        Text(assignment.dDayText)
                            .font(.gwaTopSystem(size: 12, weight: .heavy))
                            .foregroundStyle(isCompleted
                                             ? GwaTopHomeTheme.success
                                             : (isUrgent ? GwaTopHomeTheme.primary : GwaTopHomeTheme.textSecondary))
                    } else {
                        Text("날짜 미정")
                            .font(.gwaTopSystem(size: 12, weight: .medium))
                            .foregroundStyle(GwaTopHomeTheme.textSecondary)
                    }
                }
                .padding(.top, 2)
            }

            Spacer(minLength: 4)

            Button(action: onToggle) {
                GwaTopTodoCheckbox(isCompleted: isCompleted, color: assignment.course.color)
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .gwaTopCard(radius: 20)
    }
}

// MARK: - 과목별 과제 상세 (레퍼런스 Project 상세 화면)
// 요약 카드(다음 마감·진행률·완료 진행바) + 번호 매긴 과제 표(진행 중/완료 상태 표시).

private struct GwaTopCourseTodoDetailView: View {
    let course: GwaTopCourseSummary
    let progress: GwaTopTodoCourseProgress
    let assignments: [GwaTopAssignment]
    let onToggle: (GwaTopAssignment) -> Void

    private var nextDueText: String {
        guard let d = progress.nextDue else { return "없음" }
        return GwaTopDateFormatters.koMonthDayTime.string(from: d)
    }

    var body: some View {
        ZStack {
            GwaTopHomeTheme.background
                .ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    summaryCard
                    tableSection
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 30)
            }
        }
        .navigationTitle(course.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var summaryCard: some View {
        VStack(spacing: 16) {
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("다음 마감")
                        .font(.gwaTopSystem(size: 12, weight: .semibold))
                        .foregroundStyle(GwaTopHomeTheme.textSecondary)
                    Text(nextDueText)
                        .font(.gwaTopSystem(size: 16, weight: .bold))
                        .foregroundStyle(GwaTopHomeTheme.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Rectangle()
                    .fill(GwaTopHomeTheme.line)
                    .frame(width: 1, height: 36)

                VStack(alignment: .leading, spacing: 5) {
                    Text("진행률")
                        .font(.gwaTopSystem(size: 12, weight: .semibold))
                        .foregroundStyle(GwaTopHomeTheme.textSecondary)
                    Text("\(Int(progress.progress * 100))%")
                        .font(.system(size: 16, weight: .heavy, design: .rounded))
                        .foregroundStyle(course.color)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Rectangle()
                .fill(GwaTopHomeTheme.line)
                .frame(height: 1)

            VStack(spacing: 8) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(course.color)
                        .frame(width: 7, height: 7)
                    Text("\(progress.done)/\(progress.total) 완료")
                        .font(.gwaTopSystem(size: 13, weight: .semibold))
                        .foregroundStyle(GwaTopHomeTheme.textSecondary)
                    Spacer()
                }
                GwaTopThinProgressBar(progress: progress.progress, color: course.color)
            }
        }
        .padding(18)
        .gwaTopCard(radius: 22)
    }

    private var tableSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("과제 \(assignments.count)")
                    .font(.gwaTopSystem(size: 18, weight: .heavy))
                    .foregroundStyle(GwaTopHomeTheme.textPrimary)
                Spacer()
                Text("상태")
                    .font(.gwaTopSystem(size: 12, weight: .semibold))
                    .foregroundStyle(GwaTopHomeTheme.textSecondary)
            }
            .padding(.horizontal, 4)

            if assignments.isEmpty {
                Text("등록된 과제가 없어요.")
                    .font(.gwaTopSystem(size: 14, weight: .medium))
                    .foregroundStyle(GwaTopHomeTheme.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
                    .gwaTopCard(radius: 20)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(assignments.enumerated()), id: \.element.id) { idx, assignment in
                        GwaTopCourseTodoRow(
                            index: idx + 1,
                            assignment: assignment,
                            courseColor: course.color,
                            onToggle: { onToggle(assignment) }
                        )
                        if idx < assignments.count - 1 {
                            Divider()
                                .background(GwaTopHomeTheme.line)
                                .padding(.leading, 60)
                        }
                    }
                }
                .gwaTopCard(radius: 20)
            }
        }
    }
}

/// 상세 표의 한 줄 — 번호 원(완료=체크/진행중=채움/대기=옅은) + 제목 + 상태 보조줄 + 체크박스.
private struct GwaTopCourseTodoRow: View {
    let index: Int
    let assignment: GwaTopAssignment
    let courseColor: Color
    let onToggle: () -> Void

    private var isCompleted: Bool { assignment.isCompleted }
    private var isOngoing: Bool { !isCompleted && Date.gwaTopDDayFromToday(to: assignment.dueDate) <= 0 }

    private var numberFill: Color {
        if isCompleted { return GwaTopHomeTheme.success }
        if isOngoing { return courseColor }
        return courseColor.opacity(0.12)
    }

    private var secondaryText: String {
        if isCompleted { return "완료됨" }
        if isOngoing { return "진행 중 · \(assignment.dDayText)" }
        if !assignment.hasDueDate { return "날짜 미정" }
        if !assignment.description.isEmpty { return assignment.description }
        return "\(GwaTopDateFormatters.koMonthDayTime.string(from: assignment.dueDate)) · \(assignment.dDayText)"
    }

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(numberFill)
                    .frame(width: 30, height: 30)
                if isCompleted {
                    Image(systemName: "checkmark")
                        .font(.gwaTopSystem(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                } else {
                    Text("\(index)")
                        .font(.system(size: 14, weight: .heavy, design: .rounded))
                        .foregroundStyle(isOngoing ? .white : courseColor)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(assignment.title)
                    .font(.gwaTopSystem(size: 15, weight: .semibold))
                    .foregroundStyle(GwaTopHomeTheme.textPrimary)
                    .strikethrough(isCompleted, color: GwaTopHomeTheme.textSecondary)
                    .opacity(isCompleted ? 0.55 : 1)
                    .lineLimit(2)

                Text(secondaryText)
                    .font(.gwaTopSystem(size: 12, weight: isOngoing ? .bold : .medium))
                    .foregroundStyle(isOngoing ? courseColor : GwaTopHomeTheme.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button(action: onToggle) {
                GwaTopTodoCheckbox(isCompleted: isCompleted, color: courseColor)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .contentShape(Rectangle())
    }
}

#Preview {
    GwaTopAssignmentsView()
}
