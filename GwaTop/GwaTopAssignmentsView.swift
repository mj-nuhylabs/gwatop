import SwiftUI

// MARK: - GwaTop Assignments View
// 주간 할 일(ToDo) 화면. 백엔드 /v1/todos 와 연동.

struct GwaTopAssignmentsView: View {
    @State private var assignments: [GwaTopAssignment] = []
    @State private var selectedFilter: GwaTopAssignmentFilter = .all
    @State private var isLoading = false
    @State private var loadError: String? = nil
    /// 동시에 다중 토글이 일어나는 걸 막기 위한 진행중 id 집합. 빠른 더블탭 시
    /// 두 번째 요청은 무시되어 응답 순서가 뒤집혀도 UI가 잘못 고정되지 않는다.
    @State private var togglingIds: Set<String> = []
    /// 접힌 과목 그룹의 course.id 집합. 기본값 비어 있음(모두 펼침).
    @State private var collapsedCourseIds: Set<String> = []
    /// 필터 선택 언더라인 슬라이드 애니메이션용 네임스페이스.
    @Namespace private var filterNamespace

    /// priority 정렬 가중치 (high가 먼저)
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

    private var filteredAssignments: [GwaTopAssignment] {
        switch selectedFilter {
        case .all:
            return sortedByPriorityThenDate(assignments)
        case .active:
            return sortedByPriorityThenDate(assignments.filter { !$0.isCompleted })
        case .completed:
            return assignments.filter { $0.isCompleted }.sorted { $0.dueDate < $1.dueDate }
        }
    }

    /// 필터 적용된 과제를 과목별로 묶어서 정렬한 결과.
    /// 정렬 기준: (1) 활성 항목의 최소 마감일이 빠른 과목 우선, (2) 과목명 알파벳 순.
    private var groupedAssignments: [GwaTopAssignmentCourseGroup] {
        let base = filteredAssignments
        let bucket = Dictionary(grouping: base, by: { $0.course.id })
        return bucket.compactMap { _, items -> GwaTopAssignmentCourseGroup? in
            guard let first = items.first else { return nil }
            return GwaTopAssignmentCourseGroup(course: first.course, assignments: items)
        }
        .sorted { lhs, rhs in
            let lhsKey = lhs.assignments.filter { !$0.isCompleted }.map(\.dueDate).min() ?? .distantFuture
            let rhsKey = rhs.assignments.filter { !$0.isCompleted }.map(\.dueDate).min() ?? .distantFuture
            if lhsKey != rhsKey { return lhsKey < rhsKey }
            return lhs.course.name < rhs.course.name
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                GwaTopHomeTheme.background
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    GwaTopScreenHeader(title: "Todo")

                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 18) {
                            filterSegment
                                .padding(.top, 6)

                            if let err = loadError {
                                errorState(err)
                            } else if isLoading && assignments.isEmpty {
                                loadingState
                            } else if filteredAssignments.isEmpty {
                                emptyState
                            } else {
                                VStack(spacing: 20) {
                                    ForEach(groupedAssignments) { group in
                                        courseGroupSection(group)
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 30)
                    }
                    .refreshable {
                        await load()
                    }
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .task {
                if assignments.isEmpty { await load() }
            }
            // 강의계획서 파싱 완료 → 자동 생성 과제가 즉시 목록에 반영되도록 강제 새로고침.
            .onReceive(NotificationCenter.default.publisher(for: .syllabusParseCompleted)) { _ in
                Task { await load(force: true) }
            }
        }
    }

    /// 과목별 그룹 섹션 — 과목 헤더와 그 과목의 과제들을 "하나의 카드"로 묶는다.
    /// 헤더 탭 → 접기/펴기 토글. 카드 테두리는 과목 색으로 옅게 틴트.
    @ViewBuilder
    private func courseGroupSection(_ group: GwaTopAssignmentCourseGroup) -> some View {
        let isCollapsed = collapsedCourseIds.contains(group.course.id)
        VStack(spacing: 0) {
            Button {
                // 펴기/접기는 부드러운 ease-in-out — spring은 콘텐츠가 튕기는 느낌을 만든다.
                withAnimation(.easeInOut(duration: 0.22)) {
                    if isCollapsed {
                        collapsedCourseIds.remove(group.course.id)
                    } else {
                        collapsedCourseIds.insert(group.course.id)
                    }
                }
            } label: {
                courseGroupHeader(group, isCollapsed: isCollapsed)
            }
            .buttonStyle(.plain)

            if !isCollapsed {
                // 같은 카드 안에서 헤더 → 헤어라인 → 과제 행 순으로 쌓는다.
                // 각 행 앞에 인셋 구분선을 둬 헤더/행, 행/행 사이를 분리.
                VStack(spacing: 0) {
                    ForEach(group.assignments) { assignment in
                        Divider()
                            .background(GwaTopHomeTheme.line)
                            .padding(.horizontal, 16)

                        GwaTopAssignmentRow(
                            assignment: assignment,
                            onToggle: { toggleAssignment(assignment) }
                        )
                        .padding(16)
                    }
                }
                // 슬라이드 in/out 제거 → 자연스러운 fade. 위에서 떨어지는 듯한 튕김 현상 해소.
                .transition(.opacity)
            }
        }
        .gwaTopCard(radius: 24, lineColor: group.course.color.opacity(0.18), lineWidth: 1)
    }

    private func courseGroupHeader(_ group: GwaTopAssignmentCourseGroup, isCollapsed: Bool) -> some View {
        let activeCount = group.assignments.filter { !$0.isCompleted }.count
        let total = group.assignments.count
        return HStack(spacing: 12) {
            Image(systemName: group.course.iconName)
                .font(.gwaTopSystem(size: 16, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(group.course.color)
                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(group.course.name)
                    .font(.gwaTopSystem(size: 16, weight: .heavy))
                    .foregroundStyle(GwaTopHomeTheme.textPrimary)
                Text(activeCount > 0 ? "남은 과제 \(activeCount)개" : "모두 완료 ✓")
                    .font(.gwaTopSystem(size: 12, weight: .semibold))
                    .foregroundStyle(activeCount > 0 ? GwaTopHomeTheme.textSecondary : GwaTopHomeTheme.success)
            }

            Spacer()

            Text("\(total)")
                .font(.system(size: 13, weight: .heavy, design: .rounded))
                .foregroundStyle(group.course.color)
                .frame(minWidth: 26, minHeight: 26)
                .padding(.horizontal, 8)
                .background(group.course.color.opacity(0.12))
                .clipShape(Capsule())

            Image(systemName: "chevron.down")
                .font(.gwaTopSystem(size: 12, weight: .bold))
                .foregroundStyle(GwaTopHomeTheme.textSecondary)
                .rotationEffect(.degrees(isCollapsed ? -90 : 0))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        // Spacer 영역까지 포함해 헤더 전체가 접기/펴기 탭 영역이 되도록.
        .contentShape(Rectangle())
    }

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("불러오는 중...")
                .font(.gwaTopSystem(size: 13, weight: .medium))
                .foregroundStyle(GwaTopHomeTheme.textSecondary)
        }
        .padding(40)
        .frame(maxWidth: .infinity)
        .background(GwaTopHomeTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
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
        .background(GwaTopHomeTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    @MainActor
    private func load(force: Bool = false) async {
        // 과제탭은 홈 ToDo 리스트와 "완전히 동일한" 항목을 보여줘야 한다.
        // 홈은 GET /v1/home/dashboard 의 upcoming_todos 를 렌더하는데, 과제탭이 예전엔
        // GET /v1/todos?start=오늘 을 따로 호출해서 마감 지난(overdue) 과제가 전부 빠졌다.
        // → 소스를 dashboard.upcoming_todos 로 통일해 항상 홈과 같은 항목을 표시한다.
        // (과제탭은 풀 리스트이므로 limit 을 넉넉히 줘 홈의 항목을 모두 포함한다.)
        let store = GwaTopAppDataStore.shared

        // 0) 스플래시 prefetch 캐시 hydrate — 깜빡임 제거. 홈과 같은 dashboard 캐시 사용.
        if let cachedTodos = store.dashboard?.upcomingTodos, !cachedTodos.isEmpty {
            assignments = cachedTodos.map(GwaTopAssignment.init(dto:))
            // force(파싱 완료 알림 등) 일 때는 캐시를 건너뛰고 무조건 네트워크에서 다시 받는다.
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
            // SwiftUI 라이프사이클로 task가 취소된 경우는 무시 (이전 데이터 유지)
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

    /// 원래 status로 명시 복원 — 외부 reload 등으로 중간에 상태가 바뀌어도 toggle 누적 오차 없음.
    @MainActor
    private func restoreStatus(id: String, status: GwaTopAssignmentStatus) {
        guard let index = assignments.firstIndex(where: { $0.id == id }) else { return }
        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
            assignments[index].status = status
        }
    }

    /// 초미니멀 필터 — 알약/테두리/채움 없이 텍스트만, 화면 가로 중앙에 묶어서 배치.
    /// 선택 항목은 굵게 + 아래 얇은 코랄 언더라인. (Spacer 없이 intrinsic 폭 → 부모가 중앙 정렬)
    private var filterSegment: some View {
        HStack(spacing: 32) {
            ForEach(GwaTopAssignmentFilter.allCases) { filter in
                let isSelected = selectedFilter == filter
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        selectedFilter = filter
                    }
                } label: {
                    VStack(spacing: 6) {
                        Text(filter.title)
                            .font(.gwaTopSystem(size: 15, weight: isSelected ? .heavy : .semibold))
                            .foregroundStyle(isSelected ? GwaTopHomeTheme.textPrimary : GwaTopHomeTheme.textTertiary)

                        // 선택 언더라인 — 미선택 칸은 같은 높이의 투명 막대로 자리만 유지(레이아웃 점프 방지).
                        Group {
                            if isSelected {
                                Capsule()
                                    .fill(GwaTopHomeTheme.primary)
                                    .matchedGeometryEffect(id: "filterUnderline", in: filterNamespace)
                            } else {
                                Capsule().fill(.clear)
                            }
                        }
                        .frame(height: 2.5)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
                .font(.gwaTopSystem(size: 42, weight: .bold))
                .foregroundStyle(GwaTopHomeTheme.success)

            Text("표시할 과제가 없어요")
                .font(.gwaTopSystem(size: 19, weight: .bold))
                .foregroundStyle(GwaTopHomeTheme.textPrimary)

            Text("필터를 바꾸거나 새 과제를 추가하면 여기에 나타납니다.")
                .font(.gwaTopSystem(size: 14, weight: .medium))
                .foregroundStyle(GwaTopHomeTheme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(30)
        .frame(maxWidth: .infinity)
        .background(GwaTopHomeTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
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

private struct GwaTopAssignmentCourseGroup: Identifiable {
    let course: GwaTopCourseSummary
    let assignments: [GwaTopAssignment]
    var id: String { course.id }
}

private enum GwaTopAssignmentFilter: String, CaseIterable, Identifiable {
    case all
    case active
    case completed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "전체"
        case .active: return "진행 중"
        case .completed: return "완료"
        }
    }
}

/// 과목 그룹 카드 안에 들어가는 과제 한 줄. 자체 카드 chrome 없이 행(row) 으로만 동작한다.
/// (과목명 배지는 카드 헤더와 중복이라 제거 — 우선순위 배지만 남김.)
private struct GwaTopAssignmentRow: View {
    let assignment: GwaTopAssignment
    let onToggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 13) {
                Button(action: onToggle) {
                    ZStack {
                        Circle()
                            .fill(assignment.isCompleted ? GwaTopHomeTheme.success : assignment.course.color.opacity(0.12))
                            .frame(width: 40, height: 40)

                        Image(systemName: assignment.isCompleted ? "checkmark" : "circle")
                            .font(.gwaTopSystem(size: 15, weight: .bold))
                            .foregroundStyle(assignment.isCompleted ? .white : assignment.course.color)
                    }
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 6) {
                    Text(assignment.priority.displayTitle)
                        .font(.gwaTopSystem(size: 12, weight: .bold))
                        .foregroundStyle(assignment.priority.color)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(assignment.priority.color.opacity(0.10))
                        .clipShape(Capsule())

                    Text(assignment.title)
                        .font(.gwaTopSystem(size: 16, weight: .heavy))
                        .foregroundStyle(GwaTopHomeTheme.textPrimary)
                        .strikethrough(assignment.isCompleted, color: GwaTopHomeTheme.textSecondary)

                    if !assignment.description.isEmpty {
                        Text(assignment.description)
                            .font(.gwaTopSystem(size: 13, weight: .medium))
                            .foregroundStyle(GwaTopHomeTheme.textSecondary)
                            .lineSpacing(3)
                            .lineLimit(2)
                    }
                }

                Spacer(minLength: 6)

                Text(assignment.dDayText)
                    .font(.gwaTopSystem(size: 12, weight: .heavy))
                    .foregroundStyle(assignment.isCompleted ? GwaTopHomeTheme.success : assignment.priority.color)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 7)
                    .background((assignment.isCompleted ? GwaTopHomeTheme.success : assignment.priority.color).opacity(0.10))
                    .clipShape(Capsule())
            }

            HStack(spacing: 12) {
                Label(assignment.dueDateText, systemImage: "clock.fill")
                if assignment.estimatedMinutes > 0 {
                    Label("예상 \(assignment.estimatedMinutes)분", systemImage: "timer")
                }
                if assignment.isAuto {
                    Label("AI 자동", systemImage: "sparkles")
                }
            }
            .font(.gwaTopSystem(size: 12, weight: .semibold))
            .foregroundStyle(GwaTopHomeTheme.textSecondary)

            if !assignment.recommendedAction.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "sparkles")
                        .font(.gwaTopSystem(size: 12, weight: .bold))
                        .foregroundStyle(GwaTopHomeTheme.primary)
                        .padding(.top, 2)

                    Text(assignment.recommendedAction)
                        .font(.gwaTopSystem(size: 13, weight: .medium))
                        .foregroundStyle(GwaTopHomeTheme.textPrimary)
                        .lineSpacing(3)
                }
                .padding(12)
                .background(GwaTopHomeTheme.primary.opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
    }
}

#Preview {
    GwaTopAssignmentsView()
}
