import SwiftUI

// MARK: - GwaTop 홈 화면
// Google 로그인 후 전달받은 사용자 정보를 홈 화면과 설정 화면에서 사용합니다.

struct GwaTopHomeRootView: View {
    let user: GwaTopSignedInUser
    var onLogout: (() -> Void)? = nil

    @State private var selectedTab: GwaTopTab = .home

    var body: some View {
        TabView(selection: $selectedTab) {
            GwaTopHomeView(user: user)
                .tabItem {
                    Image(systemName: "house.fill")
                    Text("홈")
                }
                .tag(GwaTopTab.home)

            GwaTopAssignmentsView()
                .tabItem {
                    Image(systemName: "checklist")
                    Text("과제")
                }
                .tag(GwaTopTab.tasks)

            GwaTopPlaceholderTabView(
                title: "AI 플래너",
                subtitle: "학습 패턴 분석과 추천 기능은 추후 백엔드 연결 후 구현합니다.",
                iconName: "sparkles"
            )
            .tabItem {
                Image(systemName: "sparkles")
                Text("AI")
            }
            .tag(GwaTopTab.ai)

            GwaTopPlaceholderTabView(
                title: "캘린더",
                subtitle: "시험, 과제, 수업 일정을 월간 캘린더로 보여줄 예정입니다.",
                iconName: "calendar"
            )
            .tabItem {
                Image(systemName: "calendar")
                Text("캘린더")
            }
            .tag(GwaTopTab.calendar)

            GwaTopSettingsView(user: user, onLogout: onLogout)
                .tabItem {
                    Image(systemName: "gearshape.fill")
                    Text("설정")
                }
                .tag(GwaTopTab.settings)
        }
        .tint(GwaTopHomeTheme.primary)
    }
}

struct GwaTopHomeView: View {
    let user: GwaTopSignedInUser

    // 과목 진행률은 백엔드에 별도 컬럼이 아직 없어서 mock 유지 (Day 5 이후 교체 예정).
    private let subjects: [GwaTopSubject] = GwaTopSubject.mockData

    @State private var dashboard: GwaTopHomeDashboardDTO? = nil
    @State private var isLoading = false
    @State private var loadError: String? = nil

    var body: some View {
        NavigationStack {
            ZStack {
                GwaTopHomeTheme.background
                    .ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 22) {
                        topGreetingSection
                            .padding(.top, 18)

                        todaySummarySection
                        aiRecommendationCard
                        todayTaskSection
                        subjectProgressSection
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 30)
                }
                .refreshable { await load() }
            }
            .navigationBarTitleDisplayMode(.inline)
            .task { if dashboard == nil { await load() } }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        // 추후 알림 화면으로 연결
                    } label: {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: "bell.fill")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundStyle(GwaTopHomeTheme.textPrimary)
                                .frame(width: 42, height: 42)
                                .background(.white)
                                .clipShape(Circle())
                                .shadow(color: .black.opacity(0.06), radius: 10, x: 0, y: 6)

                            Circle()
                                .fill(.red)
                                .frame(width: 9, height: 9)
                                .offset(x: -5, y: 6)
                        }
                    }
                }
            }
        }
    }

    @MainActor
    private func load() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            dashboard = try await GwaTopHomeService.shared.fetchDashboard(upcomingLimit: 5)
        } catch {
            loadError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private var topGreetingSection: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(currentDateText)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(GwaTopHomeTheme.textSecondary)

                Text("안녕하세요, \(user.firstDisplayName)님")
                    .font(.system(size: 28, weight: .heavy, design: .rounded))
                    .foregroundStyle(GwaTopHomeTheme.textPrimary)

                Text(user.email.isEmpty ? "오늘도 학점을 향해 한 걸음 더 가볼까요?" : user.email)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(GwaTopHomeTheme.textSecondary)
                    .lineLimit(1)
            }

            Spacer()

            GwaTopUserAvatar(user: user)
        }
    }

    private var todaySummarySection: some View {
        let summary = dashboard?.thisWeekSummary
        let total = summary?.total ?? 0
        let done = summary?.done ?? 0
        let remaining = max(0, total - done)
        let rate = summary?.rate ?? 0
        let percent = Int((rate * 100).rounded())
        let examCount = (dashboard?.todaySchedules ?? []).filter { $0.type == "exam" }.count

        return VStack(spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("이번 주 학습 현황")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(.white)

                    Text("이번 주 할 일 \(total)개 중 \(done)개 완료")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.82))
                }

                Spacer()

                ZStack {
                    Circle()
                        .stroke(.white.opacity(0.22), lineWidth: 8)
                        .frame(width: 70, height: 70)

                    Circle()
                        .trim(from: 0, to: rate)
                        .stroke(.white, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                        .frame(width: 70, height: 70)
                        .rotationEffect(.degrees(-90))
                        .animation(.spring(response: 0.5), value: rate)

                    Text("\(percent)%")
                        .font(.system(size: 15, weight: .heavy))
                        .foregroundStyle(.white)
                }
            }

            HStack(spacing: 10) {
                GwaTopStatCard(title: "남은 할 일", value: "\(remaining)", unit: "개")
                GwaTopStatCard(title: "오늘 시험", value: "\(examCount)", unit: "개")
                GwaTopStatCard(title: "완료율", value: "\(percent)", unit: "%")
            }
        }
        .padding(20)
        .background(GwaTopHomeTheme.primaryGradient)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .shadow(color: GwaTopHomeTheme.primary.opacity(0.22), radius: 18, x: 0, y: 12)
    }

    private var aiRecommendationCard: some View {
        let event = dashboard?.nextEvent
        let labelText: String
        let bodyText: String
        if let event {
            let typeName: String
            switch event.type {
            case "exam":       typeName = "시험"
            case "assignment": typeName = "과제"
            case "lecture":    typeName = "강의"
            default:           typeName = "일정"
            }
            let dDay = event.dDay
            let dDayLabel = dDay == 0 ? "D-Day" : (dDay > 0 ? "D-\(dDay)" : "D+\(abs(dDay))")
            labelText = "다음 \(typeName) · \(dDayLabel)"
            bodyText = "\(event.courseName) — \(event.title)"
        } else {
            labelText = "다음 일정"
            bodyText = "예정된 일정이 없어요. 새 강의계획서를 업로드하면 자동으로 채워집니다."
        }

        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(GwaTopHomeTheme.primary.opacity(0.12))
                        .frame(width: 44, height: 44)

                    Image(systemName: "sparkles")
                        .font(.system(size: 19, weight: .bold))
                        .foregroundStyle(GwaTopHomeTheme.primary)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(labelText)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(GwaTopHomeTheme.textPrimary)

                    Text("\(user.firstDisplayName)님이 확인할 임박 일정")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(GwaTopHomeTheme.textSecondary)
                }

                Spacer()
            }

            Text(bodyText)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(GwaTopHomeTheme.textPrimary)
                .lineSpacing(4)
        }
        .padding(18)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: .black.opacity(0.06), radius: 16, x: 0, y: 8)
    }

    private var todayTaskSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader(title: "급한 할 일", subtitle: "우선순위 높은 순서로 정리했어요")

            VStack(spacing: 10) {
                if let todos = dashboard?.upcomingTodos, !todos.isEmpty {
                    ForEach(todos) { todo in
                        GwaTopTodayTaskRow(task: GwaTopTodayTask(todo: todo))
                    }
                } else if isLoading {
                    HStack {
                        ProgressView()
                        Text("불러오는 중...")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(GwaTopHomeTheme.textSecondary)
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                } else {
                    Text("표시할 할 일이 없어요.")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(GwaTopHomeTheme.textSecondary)
                        .padding(20)
                        .frame(maxWidth: .infinity)
                        .background(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
        }
    }

    private var subjectProgressSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader(title: "내 과목", subtitle: "이번 학기 과목별 진행률")

            VStack(spacing: 12) {
                ForEach(subjects) { subject in
                    GwaTopSubjectProgressCard(subject: subject)
                }
            }
        }
    }

    private func sectionHeader(title: String, subtitle: String) -> some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 21, weight: .bold))
                    .foregroundStyle(GwaTopHomeTheme.textPrimary)

                Text(subtitle)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(GwaTopHomeTheme.textSecondary)
            }

            Spacer()

            Button("전체보기") {
                // 추후 목록 화면으로 이동
            }
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(GwaTopHomeTheme.primary)
        }
    }

    private var currentDateText: String {
        GwaTopDateFormatters.koMonthDayWeekday.string(from: Date())
    }
}

struct GwaTopSettingsView: View {
    let user: GwaTopSignedInUser
    var onLogout: (() -> Void)?

    var body: some View {
        NavigationStack {
            ZStack {
                GwaTopHomeTheme.background
                    .ignoresSafeArea()

                VStack(spacing: 20) {
                    GwaTopUserAvatar(user: user, size: 76)
                        .padding(.top, 28)

                    VStack(spacing: 8) {
                        Text(user.displayName)
                            .font(.system(size: 25, weight: .heavy, design: .rounded))
                            .foregroundStyle(GwaTopHomeTheme.textPrimary)

                        Text(user.email)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(GwaTopHomeTheme.textSecondary)

                        Text("로그인 방식: \(user.loginProvider)")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(GwaTopHomeTheme.primary)
                            .padding(.top, 2)
                    }

                    VStack(spacing: 12) {
                        NavigationLink {
                            GwaTopAcademicManagementView()
                        } label: {
                            GwaTopSettingsRow(
                                iconName: "book.closed.fill",
                                title: "학기 / 과목 관리",
                                value: "추가, 수정, 삭제"
                            )
                        }
                        .buttonStyle(.plain)

                        GwaTopSettingsRow(iconName: "person.fill", title: "프로필 정보", value: user.displayName)
                        GwaTopSettingsRow(iconName: "envelope.fill", title: "이메일", value: user.email)
                        GwaTopSettingsRow(iconName: "key.fill", title: "인증 제공자", value: user.loginProvider)
                    }
                    .padding(.top, 12)

                    Button {
                        onLogout?()
                    } label: {
                        Text("로그아웃")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 54)
                            .background(Color.red)
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                    .padding(.top, 10)

                    Spacer()
                }
                .padding(.horizontal, 22)
            }
            .navigationTitle("설정")
        }
    }
}

struct GwaTopSettingsRow: View {
    let iconName: String
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(GwaTopHomeTheme.primary)
                .frame(width: 36, height: 36)
                .background(GwaTopHomeTheme.primary.opacity(0.10))
                .clipShape(Circle())

            Text(title)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(GwaTopHomeTheme.textPrimary)

            Spacer()

            Text(value.isEmpty ? "-" : value)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(GwaTopHomeTheme.textSecondary)
                .lineLimit(1)
        }
        .padding(14)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

struct GwaTopUserAvatar: View {
    let user: GwaTopSignedInUser
    var size: CGFloat = 58

    var body: some View {
        ZStack {
            Circle()
                .fill(GwaTopHomeTheme.primary.opacity(0.13))
                .frame(width: size, height: size)

            Text(user.initials)
                .font(.system(size: size * 0.31, weight: .heavy, design: .rounded))
                .foregroundStyle(GwaTopHomeTheme.primary)
        }
    }
}

struct GwaTopStatCard: View {
    let title: String
    let value: String
    let unit: String

    var body: some View {
        VStack(spacing: 5) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.76))

            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: 20, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)

                Text(unit)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.86))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 13)
        .background(.white.opacity(0.14))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

struct GwaTopTodayTaskRow: View {
    let task: GwaTopTodayTask

    var body: some View {
        HStack(spacing: 13) {
            ZStack {
                Circle()
                    .fill(task.isDone ? GwaTopHomeTheme.success.opacity(0.14) : task.color.opacity(0.13))
                    .frame(width: 44, height: 44)

                Image(systemName: task.isDone ? "checkmark" : task.iconName)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(task.isDone ? GwaTopHomeTheme.success : task.color)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(task.title)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(GwaTopHomeTheme.textPrimary)
                    .strikethrough(task.isDone, color: GwaTopHomeTheme.textSecondary)

                Text("\(task.subject) · \(task.dueText)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(GwaTopHomeTheme.textSecondary)
            }

            Spacer()

            Text(task.priorityText)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(task.color)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(task.color.opacity(0.10))
                .clipShape(Capsule())
        }
        .padding(14)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.04), radius: 10, x: 0, y: 5)
    }
}

struct GwaTopSubjectProgressCard: View {
    let subject: GwaTopSubject

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(subject.color.opacity(0.13))
                        .frame(width: 48, height: 48)

                    Image(systemName: subject.iconName)
                        .font(.system(size: 19, weight: .bold))
                        .foregroundStyle(subject.color)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(subject.name)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(GwaTopHomeTheme.textPrimary)

                    Text("다음 일정: \(subject.nextSchedule)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(GwaTopHomeTheme.textSecondary)
                }

                Spacer()

                Text("\(Int(subject.progress * 100))%")
                    .font(.system(size: 15, weight: .heavy, design: .rounded))
                    .foregroundStyle(subject.color)
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(GwaTopHomeTheme.line)

                    Capsule()
                        .fill(subject.color)
                        .frame(width: max(0, proxy.size.width * subject.progress))
                }
            }
            .frame(height: 8)
        }
        .padding(16)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: .black.opacity(0.04), radius: 12, x: 0, y: 6)
    }
}

struct GwaTopPlaceholderTabView: View {
    let title: String
    let subtitle: String
    let iconName: String

    var body: some View {
        NavigationStack {
            ZStack {
                GwaTopHomeTheme.background
                    .ignoresSafeArea()

                VStack(spacing: 14) {
                    Image(systemName: iconName)
                        .font(.system(size: 44, weight: .bold))
                        .foregroundStyle(GwaTopHomeTheme.primary)

                    Text(title)
                        .font(.system(size: 28, weight: .heavy, design: .rounded))
                        .foregroundStyle(GwaTopHomeTheme.textPrimary)

                    Text(subtitle)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(GwaTopHomeTheme.textSecondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(4)
                        .padding(.horizontal, 34)
                }
            }
        }
    }
}

enum GwaTopTab {
    case home
    case tasks
    case ai
    case calendar
    case settings
}

struct GwaTopTodayTask: Identifiable {
    let id: String
    let title: String
    let subject: String
    let dueText: String
    let priorityText: String
    let iconName: String
    let color: Color
    let isDone: Bool

    init(id: String = UUID().uuidString,
         title: String, subject: String, dueText: String,
         priorityText: String, iconName: String, color: Color, isDone: Bool) {
        self.id = id
        self.title = title
        self.subject = subject
        self.dueText = dueText
        self.priorityText = priorityText
        self.iconName = iconName
        self.color = color
        self.isDone = isDone
    }

    /// 백엔드 TodoDTO를 홈 화면용 row 모델로 변환.
    init(todo: GwaTopTodoDTO) {
        let (priorityText, icon, color): (String, String, Color) = {
            switch todo.priority {
            case "high":   return ("긴급", "exclamationmark", .red)
            case "medium": return ("중요", "flag.fill", .orange)
            default:       return ("일반", "circle", .gray)
            }
        }()
        self.id = todo.id
        self.title = todo.title
        self.subject = todo.courseName
        self.dueText = GwaTopDateFormatters.koMonthDayTime.string(from: todo.dueDate)
        self.priorityText = todo.isDone ? "완료" : priorityText
        self.iconName = todo.isDone ? "checkmark" : icon
        self.color = todo.isDone ? .green : (todo.courseColor.map(Color.gwaTopHex) ?? color)
        self.isDone = todo.isDone
    }

    static let mockData: [GwaTopTodayTask] = [
        GwaTopTodayTask(title: "데이터베이스 과제 ERD 초안", subject: "데이터베이스", dueText: "오늘 23:59", priorityText: "긴급", iconName: "exclamationmark", color: .red, isDone: false),
        GwaTopTodayTask(title: "자료구조 3주차 복습", subject: "자료구조", dueText: "오늘 18:00", priorityText: "중요", iconName: "book.fill", color: .orange, isDone: false),
        GwaTopTodayTask(title: "캡스톤 회의록 정리", subject: "캡스톤", dueText: "완료", priorityText: "완료", iconName: "checkmark", color: .green, isDone: true)
    ]
}

struct GwaTopSubject: Identifiable {
    let id = UUID()
    let name: String
    let progress: CGFloat
    let nextSchedule: String
    let iconName: String
    let color: Color

    static let mockData: [GwaTopSubject] = [
        GwaTopSubject(name: "데이터베이스", progress: 0.72, nextSchedule: "과제 마감 D-1", iconName: "server.rack", color: .blue),
        GwaTopSubject(name: "자료구조", progress: 0.58, nextSchedule: "퀴즈 D-3", iconName: "point.3.connected.trianglepath.dotted", color: .purple),
        GwaTopSubject(name: "캡스톤디자인", progress: 0.41, nextSchedule: "회의 내일", iconName: "lightbulb.fill", color: .orange)
    ]
}

struct GwaTopHomeTheme {
    static let primary = Color(red: 0.25, green: 0.38, blue: 0.95)
    static let secondary = Color(red: 0.43, green: 0.68, blue: 1.00)
    static let success = Color(red: 0.11, green: 0.68, blue: 0.39)
    static let background = Color(red: 0.96, green: 0.97, blue: 1.0)
    static let textPrimary = Color(red: 0.10, green: 0.12, blue: 0.20)
    static let textSecondary = Color(red: 0.45, green: 0.48, blue: 0.58)
    static let line = Color(red: 0.88, green: 0.90, blue: 0.95)

    static let primaryGradient = LinearGradient(
        colors: [primary, secondary],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

#Preview {
    GwaTopHomeRootView(user: .guest)
}
