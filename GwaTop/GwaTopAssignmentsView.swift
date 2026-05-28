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

    private var completedCount: Int {
        assignments.filter(\.isCompleted).count
    }

    private var completionRate: Double {
        guard !assignments.isEmpty else { return 0 }
        return Double(completedCount) / Double(assignments.count)
    }

    private var urgentCount: Int {
        assignments.filter { !$0.isCompleted && $0.priority == .high }.count
    }

    var body: some View {
        NavigationStack {
            ZStack {
                GwaTopHomeTheme.background
                    .ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 18) {
                        headerCard
                            .padding(.top, 14)

                        filterSegment

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
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Text("과제")
                        .font(.gwaTopSystem(size: 22, weight: .heavy))
                        .foregroundStyle(GwaTopHomeTheme.textPrimary)
                }
            }
            .task {
                if assignments.isEmpty { await load() }
            }
        }
    }

    /// 과목별 그룹 섹션. 헤더 탭 → 접기/펴기 토글.
    @ViewBuilder
    private func courseGroupSection(_ group: GwaTopAssignmentCourseGroup) -> some View {
        let isCollapsed = collapsedCourseIds.contains(group.course.id)
        VStack(spacing: 12) {
            Button {
                // 펴기/접기는 부드러운 ease-in-out — spring은 콘텐츠가 튕기는 느낌을 만든다.
                // 화면 위 바깥에서 슬라이드 끌어오는 .move(edge:.top) 도 제거 — 단순 fade로 충분.
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
                VStack(spacing: 12) {
                    ForEach(group.assignments) { assignment in
                        GwaTopAssignmentCard(
                            assignment: assignment,
                            onToggle: { toggleAssignment(assignment) }
                        )
                    }
                }
                // 슬라이드 in/out 제거 → 자연스러운 fade. 위에서 떨어지는 듯한 튕김 현상 해소.
                .transition(.opacity)
            }
        }
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
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(group.course.color.opacity(0.18), lineWidth: 1)
        )
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
        .background(.white)
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
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    @MainActor
    private func load() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }

        // 기본: "이번 주 + 다음 2주" 까지 (시험 D-14 todo가 포함될 수 있도록)
        let now = Date()
        let cal = Calendar(identifier: .gregorian)
        let start = cal.startOfDay(for: now)
        let end = cal.date(byAdding: .day, value: 21, to: start) ?? start.addingTimeInterval(21 * 86400)

        do {
            let dtos = try await GwaTopTodoService.shared.fetchAll(start: start, end: end)
            assignments = dtos.map(GwaTopAssignment.init(dto:))
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

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("이번 주 할 일")
                        .font(.system(size: 24, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)

                    Text("마감이 가까운 과제부터 차근차근 처리해요")
                        .font(.gwaTopSystem(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.84))
                }

                Spacer()

                VStack(spacing: 2) {
                    Text("\(Int(completionRate * 100))%")
                        .font(.system(size: 22, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                    Text("완료율")
                        .font(.gwaTopSystem(size: 11, weight: .bold))
                        .foregroundStyle(.white.opacity(0.76))
                }
                .frame(width: 72, height: 72)
                .background(.white.opacity(0.16))
                .clipShape(Circle())
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.white.opacity(0.22))

                    Capsule()
                        .fill(.white)
                        .frame(width: max(0, proxy.size.width * completionRate))
                }
            }
            .frame(height: 9)

            HStack(spacing: 10) {
                GwaTopAssignmentHeaderMetric(title: "전체", value: "\(assignments.count)", unit: "개")
                GwaTopAssignmentHeaderMetric(title: "완료", value: "\(completedCount)", unit: "개")
                GwaTopAssignmentHeaderMetric(title: "긴급", value: "\(urgentCount)", unit: "개")
            }
        }
        .padding(20)
        .background(GwaTopHomeTheme.primary)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    private var filterSegment: some View {
        HStack(spacing: 8) {
            ForEach(GwaTopAssignmentFilter.allCases) { filter in
                Button {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.86)) {
                        selectedFilter = filter
                    }
                } label: {
                    Text(filter.title)
                        .font(.gwaTopSystem(size: 14, weight: .bold))
                        .foregroundStyle(selectedFilter == filter ? .white : GwaTopHomeTheme.textSecondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 42)
                        .background(selectedFilter == filter ? GwaTopHomeTheme.primary : .white)
                        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 15, style: .continuous)
                                .strokeBorder(selectedFilter == filter ? .clear : GwaTopHomeTheme.line, lineWidth: 1)
                        )
                }
            }
        }
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
        .background(.white)
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

private struct GwaTopAssignmentHeaderMetric: View {
    let title: String
    let value: String
    let unit: String

    var body: some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.gwaTopSystem(size: 11, weight: .bold))
                .foregroundStyle(.white.opacity(0.72))

            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: 18, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                Text(unit)
                    .font(.gwaTopSystem(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.84))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(.white.opacity(0.14))
        .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
    }
}

private struct GwaTopAssignmentCard: View {
    let assignment: GwaTopAssignment
    let onToggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 13) {
                Button(action: onToggle) {
                    ZStack {
                        Circle()
                            .fill(assignment.isCompleted ? GwaTopHomeTheme.success : assignment.course.color.opacity(0.12))
                            .frame(width: 42, height: 42)

                        Image(systemName: assignment.isCompleted ? "checkmark" : "circle")
                            .font(.gwaTopSystem(size: 16, weight: .bold))
                            .foregroundStyle(assignment.isCompleted ? .white : assignment.course.color)
                    }
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 7) {
                        Text(assignment.course.name)
                            .font(.gwaTopSystem(size: 12, weight: .bold))
                            .foregroundStyle(assignment.course.color)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(assignment.course.color.opacity(0.10))
                            .clipShape(Capsule())

                        Text(assignment.priority.displayTitle)
                            .font(.gwaTopSystem(size: 12, weight: .bold))
                            .foregroundStyle(assignment.priority.color)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(assignment.priority.color.opacity(0.10))
                            .clipShape(Capsule())
                    }

                    Text(assignment.title)
                        .font(.gwaTopSystem(size: 17, weight: .heavy))
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

            Divider()
                .background(GwaTopHomeTheme.line)

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
        .padding(16)
        .gwaTopCard(radius: 24)
    }
}

#Preview {
    GwaTopAssignmentsView()
}
