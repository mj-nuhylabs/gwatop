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
                        } else {
                            VStack(spacing: 12) {
                                ForEach(filteredAssignments) { assignment in
                                    GwaTopAssignmentCard(
                                        assignment: assignment,
                                        onToggle: { toggleAssignment(assignment) }
                                    )
                                }
                            }

                            if filteredAssignments.isEmpty {
                                emptyState
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
            .navigationTitle("과제")
            .task {
                if assignments.isEmpty { await load() }
            }
        }
    }

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("불러오는 중...")
                .font(.system(size: 13, weight: .medium))
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
                .font(.system(size: 32))
                .foregroundStyle(.orange)
            Text("불러오기 실패")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(GwaTopHomeTheme.textPrimary)
            Text(message)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(GwaTopHomeTheme.textSecondary)
                .multilineTextAlignment(.center)
            Button("다시 시도") {
                Task { await load() }
            }
            .font(.system(size: 14, weight: .bold))
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

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("이번 주 할 일")
                        .font(.system(size: 24, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)

                    Text("마감이 가까운 과제부터 차근차근 처리해요")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.84))
                }

                Spacer()

                VStack(spacing: 2) {
                    Text("\(Int(completionRate * 100))%")
                        .font(.system(size: 22, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                    Text("완료율")
                        .font(.system(size: 11, weight: .bold))
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
        .background(GwaTopHomeTheme.primaryGradient)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .shadow(color: GwaTopHomeTheme.primary.opacity(0.22), radius: 18, x: 0, y: 12)
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
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(selectedFilter == filter ? .white : GwaTopHomeTheme.textSecondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 42)
                        .background(selectedFilter == filter ? GwaTopHomeTheme.primary : .white)
                        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                        .shadow(color: selectedFilter == filter ? GwaTopHomeTheme.primary.opacity(0.20) : .clear, radius: 10, x: 0, y: 6)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 42, weight: .bold))
                .foregroundStyle(GwaTopHomeTheme.success)

            Text("표시할 과제가 없어요")
                .font(.system(size: 19, weight: .bold))
                .foregroundStyle(GwaTopHomeTheme.textPrimary)

            Text("필터를 바꾸거나 새 과제를 추가하면 여기에 나타납니다.")
                .font(.system(size: 14, weight: .medium))
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

        // optimistic update — 실패 시 롤백
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
                    applyOptimisticToggle(assignment)  // 롤백
                    loadError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
            }
        }
    }
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
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(assignment.isCompleted ? .white : assignment.course.color)
                    }
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 7) {
                        Text(assignment.course.name)
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(assignment.course.color)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(assignment.course.color.opacity(0.10))
                            .clipShape(Capsule())

                        Text(assignment.priority.displayTitle)
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(assignment.priority.color)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(assignment.priority.color.opacity(0.10))
                            .clipShape(Capsule())
                    }

                    Text(assignment.title)
                        .font(.system(size: 17, weight: .heavy))
                        .foregroundStyle(GwaTopHomeTheme.textPrimary)
                        .strikethrough(assignment.isCompleted, color: GwaTopHomeTheme.textSecondary)

                    if !assignment.description.isEmpty {
                        Text(assignment.description)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(GwaTopHomeTheme.textSecondary)
                            .lineSpacing(3)
                            .lineLimit(2)
                    }
                }

                Spacer(minLength: 6)

                Text(assignment.dDayText)
                    .font(.system(size: 12, weight: .heavy))
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
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(GwaTopHomeTheme.textSecondary)

            if !assignment.recommendedAction.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(GwaTopHomeTheme.primary)
                        .padding(.top, 2)

                    Text(assignment.recommendedAction)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(GwaTopHomeTheme.textPrimary)
                        .lineSpacing(3)
                }
                .padding(12)
                .background(GwaTopHomeTheme.primary.opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
        .padding(16)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: .black.opacity(0.045), radius: 14, x: 0, y: 7)
    }
}

#Preview {
    GwaTopAssignmentsView()
}
