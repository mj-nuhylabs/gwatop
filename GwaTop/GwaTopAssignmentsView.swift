import SwiftUI

// MARK: - GwaTop Assignments View
// H-2 주간 할 일(ToDo)을 별도 과제 탭으로 확장한 화면입니다.

struct GwaTopAssignmentsView: View {
    @State private var assignments: [GwaTopAssignment] = GwaTopAssignment.sampleData
    @State private var selectedFilter: GwaTopAssignmentFilter = .all

    private var filteredAssignments: [GwaTopAssignment] {
        switch selectedFilter {
        case .all:
            return assignments.sorted { $0.dueDate < $1.dueDate }
        case .active:
            return assignments.filter { !$0.isCompleted }.sorted { $0.dueDate < $1.dueDate }
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
                    .padding(.horizontal, 20)
                    .padding(.bottom, 30)
                }
            }
            .navigationTitle("과제")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        // 추후 C-3 일정/과제 추가 화면 또는 API 생성 화면으로 연결합니다.
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
        guard let index = assignments.firstIndex(where: { $0.id == assignment.id }) else { return }
        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
            assignments[index].status = assignments[index].isCompleted ? .inProgress : .completed
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

                    Text(assignment.description)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(GwaTopHomeTheme.textSecondary)
                        .lineSpacing(3)
                        .lineLimit(2)
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
                Label("예상 \(assignment.estimatedMinutes)분", systemImage: "timer")
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(GwaTopHomeTheme.textSecondary)

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
        .padding(16)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: .black.opacity(0.045), radius: 14, x: 0, y: 7)
    }
}

#Preview {
    GwaTopAssignmentsView()
}
