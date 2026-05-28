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
                // 추후 알림 기능 구현 시 toolbar 버튼 복구. 동작 없는 종 아이콘 + 가짜 빨간 점은 오해 소지가 있어 제거.
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
            if isCancellation(error) { return }
            loadError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private var topGreetingSection: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(currentDateText)
                    .font(.gwaTopSystem(size: 14, weight: .semibold))
                    .foregroundStyle(GwaTopHomeTheme.textSecondary)

                Text("안녕하세요, \(user.firstDisplayName)님")
                    .font(.system(size: 28, weight: .heavy, design: .rounded))
                    .foregroundStyle(GwaTopHomeTheme.textPrimary)

                Text(user.email.isEmpty ? "오늘도 학점을 향해 한 걸음 더 가볼까요?" : user.email)
                    .font(.gwaTopSystem(size: 15, weight: .medium))
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
                        .font(.gwaTopSystem(size: 20, weight: .bold))
                        .foregroundStyle(GwaTopHomeTheme.textPrimary)

                    Text("이번 주 할 일 \(total)개 중 \(done)개 완료")
                        .font(.gwaTopSystem(size: 14, weight: .medium))
                        .foregroundStyle(GwaTopHomeTheme.textSecondary)
                }

                Spacer()

                ZStack {
                    Circle()
                        .stroke(GwaTopHomeTheme.primary.opacity(0.18), lineWidth: 8)
                        .frame(width: 70, height: 70)

                    Circle()
                        .trim(from: 0, to: rate)
                        .stroke(GwaTopHomeTheme.primary, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                        .frame(width: 70, height: 70)
                        .rotationEffect(.degrees(-90))
                        .animation(.spring(response: 0.5), value: rate)

                    Text("\(percent)%")
                        .font(.gwaTopSystem(size: 15, weight: .heavy))
                        .foregroundStyle(GwaTopHomeTheme.primary)
                }
            }

            HStack(spacing: 10) {
                GwaTopStatCard(title: "남은 할 일", value: "\(remaining)", unit: "개")
                GwaTopStatCard(title: "오늘 시험", value: "\(examCount)", unit: "개")
                GwaTopStatCard(title: "완료율", value: "\(percent)", unit: "%")
            }
        }
        .padding(20)
        // 코랄 단색 → 아주 옅은 코랄 wash. 테두리 없이 부드럽게.
        .background(GwaTopHomeTheme.primary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    private var todayTaskSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(title: "ToDo")

            // 모든 행을 하나의 카드에 모으고 hairline divider로 구분.
            // 카드의 시각적 노이즈를 줄이고 정보 위계를 분명히 한다 (애플 리스트 스타일).
            VStack(spacing: 0) {
                if let todos = dashboard?.upcomingTodos, !todos.isEmpty {
                    ForEach(Array(todos.enumerated()), id: \.element.id) { index, todo in
                        GwaTopTodayTaskRow(task: GwaTopTodayTask(todo: todo))
                        if index < todos.count - 1 {
                            Divider()
                                .padding(.leading, 32)  // priority dot 영역 들여쓰기
                        }
                    }
                } else if isLoading {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("불러오는 중…")
                            .font(.gwaTopSystem(size: 13, weight: .medium))
                            .foregroundStyle(GwaTopHomeTheme.textSecondary)
                    }
                    .padding(.vertical, 22)
                    .frame(maxWidth: .infinity)
                } else {
                    Text("표시할 할 일이 없어요.")
                        .font(.gwaTopSystem(size: 13, weight: .medium))
                        .foregroundStyle(GwaTopHomeTheme.textSecondary)
                        .padding(.vertical, 26)
                        .frame(maxWidth: .infinity)
                }
            }
            .gwaTopCard(radius: 18)
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

    private func sectionHeader(title: String, subtitle: String? = nil) -> some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.gwaTopSystem(size: 21, weight: .bold))
                    .foregroundStyle(GwaTopHomeTheme.textPrimary)

                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.gwaTopSystem(size: 13, weight: .medium))
                        .foregroundStyle(GwaTopHomeTheme.textSecondary)
                }
            }

            Spacer()

            // 전체보기 라우팅이 아직 없어 빈 클로저 버튼이었음 — 동작 추가 전까지 숨김.
        }
    }

    private var currentDateText: String {
        GwaTopDateFormatters.koMonthDayWeekday.string(from: Date())
    }
}

struct GwaTopSettingsView: View {
    let user: GwaTopSignedInUser
    var onLogout: (() -> Void)?

    @AppStorage("gw_appearance") private var appearanceRaw: String = GwaTopAppearance.system.rawValue
    private var appearance: GwaTopAppearance {
        get { GwaTopAppearance(rawValue: appearanceRaw) ?? .system }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                GwaTopHomeTheme.background
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    GwaTopScreenHeader(title: "설정")

                    VStack(spacing: 20) {
                        GwaTopUserAvatar(user: user, size: 76)
                            .padding(.top, 18)

                        VStack(spacing: 8) {
                            Text(user.displayName)
                                .font(.system(size: 25, weight: .heavy, design: .rounded))
                                .foregroundStyle(GwaTopHomeTheme.textPrimary)

                            Text(user.email)
                                .font(.gwaTopSystem(size: 15, weight: .medium))
                                .foregroundStyle(GwaTopHomeTheme.textSecondary)

                            Text("로그인 방식: \(user.loginProvider)")
                                .font(.gwaTopSystem(size: 13, weight: .bold))
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

                            appearanceSelector

                            GwaTopSettingsRow(iconName: "person.fill", title: "프로필 정보", value: user.displayName)
                            GwaTopSettingsRow(iconName: "envelope.fill", title: "이메일", value: user.email)
                            GwaTopSettingsRow(iconName: "key.fill", title: "인증 제공자", value: user.loginProvider)
                        }
                        .padding(.top, 12)

                        Button {
                            onLogout?()
                        } label: {
                            Text("로그아웃")
                                .font(.gwaTopSystem(size: 16, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .frame(height: 54)
                                .background(GwaTopHomeTheme.danger)
                                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        }
                        .padding(.top, 10)

                        Spacer()
                    }
                    .padding(.horizontal, 22)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    /// 외관 (시스템 / 라이트 / 다크) 세그먼트 — 즉시 반영.
    private var appearanceSelector: some View {
        HStack(spacing: 12) {
            Image(systemName: "circle.lefthalf.filled")
                .font(.gwaTopSystem(size: 16, weight: .bold))
                .foregroundStyle(GwaTopHomeTheme.primary)
                .frame(width: 36, height: 36)
                .background(GwaTopHomeTheme.primary.opacity(0.10))
                .clipShape(Circle())

            Text("외관")
                .font(.gwaTopSystem(size: 15, weight: .bold))
                .foregroundStyle(GwaTopHomeTheme.textPrimary)

            Spacer()

            HStack(spacing: 4) {
                ForEach(GwaTopAppearance.allCases) { option in
                    Button {
                        appearanceRaw = option.rawValue
                    } label: {
                        Image(systemName: option.iconName)
                            .font(.gwaTopSystem(size: 13, weight: .bold))
                            .foregroundStyle(
                                appearance == option
                                    ? Color.white
                                    : GwaTopHomeTheme.textSecondary
                            )
                            .frame(width: 32, height: 28)
                            .background(
                                appearance == option
                                    ? GwaTopHomeTheme.primary
                                    : Color.clear
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(option.label)
                }
            }
            .padding(3)
            .background(GwaTopHomeTheme.surfaceMute)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .padding(14)
        .background(GwaTopHomeTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

struct GwaTopSettingsRow: View {
    let iconName: String
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .font(.gwaTopSystem(size: 16, weight: .bold))
                .foregroundStyle(GwaTopHomeTheme.primary)
                .frame(width: 36, height: 36)
                .background(GwaTopHomeTheme.primary.opacity(0.10))
                .clipShape(Circle())

            Text(title)
                .font(.gwaTopSystem(size: 15, weight: .bold))
                .foregroundStyle(GwaTopHomeTheme.textPrimary)

            Spacer()

            Text(value.isEmpty ? "-" : value)
                .font(.gwaTopSystem(size: 13, weight: .medium))
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
                .font(.gwaTopSystem(size: 11, weight: .semibold))
                .foregroundStyle(GwaTopHomeTheme.textSecondary)

            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: 20, weight: .heavy, design: .rounded))
                    .foregroundStyle(GwaTopHomeTheme.primary)

                Text(unit)
                    .font(.gwaTopSystem(size: 11, weight: .bold))
                    .foregroundStyle(GwaTopHomeTheme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 13)
        // 헤더 카드(살짝 코랄) 위 흰 칩 — 대비를 위해 surface 단색.
        .background(GwaTopHomeTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

struct GwaTopTodayTaskRow: View {
    let task: GwaTopTodayTask

    var body: some View {
        HStack(spacing: 14) {
            // 좌측 priority indicator — 작은 컬러 점 하나.
            // 컬러 채도를 카드 전체가 아니라 한 점에만 모아두면 시선이 정리되고
            // 시스템 리스트(Apple Reminders/Mail)와 비슷한 무게감이 된다.
            Circle()
                .fill(task.isDone
                      ? Color.gray.opacity(0.35)
                      : task.color)
                .frame(width: 8, height: 8)
                .padding(.leading, 2)

            VStack(alignment: .leading, spacing: 3) {
                Text(task.title)
                    .font(.gwaTopSystem(size: 15, weight: .semibold))
                    .foregroundStyle(GwaTopHomeTheme.textPrimary)
                    .strikethrough(task.isDone, color: GwaTopHomeTheme.textSecondary)
                    .opacity(task.isDone ? 0.55 : 1)
                    .lineLimit(1)

                Text("\(task.subject) · \(task.dueText)")
                    .font(.gwaTopSystem(size: 12, weight: .regular))
                    .foregroundStyle(GwaTopHomeTheme.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            // 우선순위 라벨 — 컬러 캡슐 대신 단정한 텍스트.
            Text(task.priorityText)
                .font(.gwaTopSystem(size: 11, weight: .medium))
                .foregroundStyle(task.isDone ? GwaTopHomeTheme.textSecondary : task.color)

            Image(systemName: "chevron.right")
                .font(.gwaTopSystem(size: 11, weight: .semibold))
                .foregroundStyle(Color.gray.opacity(0.4))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .contentShape(Rectangle())
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
                        .font(.gwaTopSystem(size: 19, weight: .bold))
                        .foregroundStyle(subject.color)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(subject.name)
                        .font(.gwaTopSystem(size: 16, weight: .bold))
                        .foregroundStyle(GwaTopHomeTheme.textPrimary)

                    Text("다음 일정: \(subject.nextSchedule)")
                        .font(.gwaTopSystem(size: 12, weight: .medium))
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
        .gwaTopCard(radius: 22)
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
                        .font(.gwaTopSystem(size: 44, weight: .bold))
                        .foregroundStyle(GwaTopHomeTheme.primary)

                    Text(title)
                        .font(.system(size: 28, weight: .heavy, design: .rounded))
                        .foregroundStyle(GwaTopHomeTheme.textPrimary)

                    Text(subtitle)
                        .font(.gwaTopSystem(size: 15, weight: .medium))
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
    case admin  // 출시 전 테스트용 임시 탭
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
            case "high":   return ("높음", "exclamationmark", GwaTopHomeTheme.danger)
            case "medium": return ("보통", "flag.fill", GwaTopHomeTheme.warning)
            default:       return ("낮음", "circle", .gray)
            }
        }()
        self.id = todo.id
        self.title = todo.title
        self.subject = todo.courseName
        self.dueText = GwaTopDateFormatters.koMonthDayTime.string(from: todo.dueDate)
        self.priorityText = todo.isDone ? "완료" : priorityText
        self.iconName = todo.isDone ? "checkmark" : icon
        self.color = todo.isDone ? GwaTopHomeTheme.success : (todo.courseColor.map(Color.gwaTopHex) ?? color)
        self.isDone = todo.isDone
    }

    static let mockData: [GwaTopTodayTask] = [
        GwaTopTodayTask(title: "데이터베이스 과제 ERD 초안", subject: "데이터베이스", dueText: "오늘 23:59", priorityText: "높음", iconName: "exclamationmark", color: GwaTopHomeTheme.danger, isDone: false),
        GwaTopTodayTask(title: "자료구조 3주차 복습", subject: "자료구조", dueText: "오늘 18:00", priorityText: "보통", iconName: "book.fill", color: GwaTopHomeTheme.warning, isDone: false),
        GwaTopTodayTask(title: "캡스톤 회의록 정리", subject: "캡스톤", dueText: "완료", priorityText: "완료", iconName: "checkmark", color: GwaTopHomeTheme.success, isDone: true)
    ]
}

struct GwaTopSubject: Identifiable {
    let id = UUID()
    let name: String
    let progress: CGFloat
    let nextSchedule: String
    let iconName: String
    let color: Color

    // 과목 색상 — Claude warm 톤에 맞춘 muted multi-tone (mindmap canvas 와 동일 팔레트).
    // 원색 blue/purple/orange 대신 톤다운된 슬레이트/올리브/플럼으로 구분.
    static let mockData: [GwaTopSubject] = [
        GwaTopSubject(name: "데이터베이스", progress: 0.72, nextSchedule: "과제 마감 D-1", iconName: "server.rack",
                      color: Color(red: 0.40, green: 0.52, blue: 0.66)),   // muted slate
        GwaTopSubject(name: "자료구조", progress: 0.58, nextSchedule: "퀴즈 D-3", iconName: "point.3.connected.trianglepath.dotted",
                      color: Color(red: 0.58, green: 0.54, blue: 0.42)),   // muted olive
        GwaTopSubject(name: "캡스톤디자인", progress: 0.41, nextSchedule: "회의 내일", iconName: "lightbulb.fill",
                      color: Color(red: 0.55, green: 0.45, blue: 0.55))    // muted plum
    ]
}

/// SwiftUI Color 의 light/dark 자동 전환 헬퍼.
/// UIColor 의 dynamic provider 를 감싸서 system colorScheme 변경 시 즉시 반영.
/// gwatop-web 의 `.dark` 클래스 토큰과 1:1 매핑.
private func gwaTopAdaptive(light: Color, dark: Color) -> Color {
    Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light)
    })
}

struct GwaTopHomeTheme {
    // GwaTop Web 과 통일된 디자인 토큰 — Claude.ai light/dark 톤 자동 전환.
    // CSS 변수와 1:1 매핑:
    //   light: --background #faf9f5, --foreground #1f1e1d, --card #fff
    //   dark:  --background #262624, --foreground #faf9f5, --card #2f2e2c
    //   primary 코랄 #cc785c 는 light/dark 공통.

    // Claude coral — light/dark 모두 동일.
    static let primary = Color(red: 0.80, green: 0.47, blue: 0.36)        // #cc785c
    static let secondary = Color(red: 0.88, green: 0.60, blue: 0.46)      // #e09975 (gradient)

    // semantic — light/dark 모두 동일한 muted warm 톤 (대비 충분).
    static let success = Color(red: 0.32, green: 0.55, blue: 0.36)        // muted warm green
    static let warning = Color(red: 0.83, green: 0.55, blue: 0.22)        // muted warm amber
    static let danger  = Color(red: 0.72, green: 0.30, blue: 0.26)        // muted warm red

    // 배경 — light: warm off-white / dark: warm dark.
    static let background = gwaTopAdaptive(
        light: Color(red: 0.980, green: 0.976, blue: 0.961),              // #faf9f5
        dark:  Color(red: 0.149, green: 0.149, blue: 0.141)               // #262624
    )
    static let surface = gwaTopAdaptive(
        light: Color.white,                                                // #ffffff
        dark:  Color(red: 0.184, green: 0.180, blue: 0.173)               // #2f2e2c
    )
    static let surfaceElevated = gwaTopAdaptive(
        light: Color(red: 0.992, green: 0.988, blue: 0.976),              // #fdfcf9
        dark:  Color(red: 0.208, green: 0.204, blue: 0.196)               // #353432
    )
    /// surface 위 살짝 어두운 wash — toolbar/thumbnail/segmented 배경 같은 인레이 용도.
    /// light: black 4% / dark: white 4% — 모드별 contrast 자동 보정.
    static let surfaceMute = gwaTopAdaptive(
        light: Color.black.opacity(0.04),
        dark:  Color.white.opacity(0.04)
    )

    // 텍스트 — light: warm dark / dark: warm light.
    static let textPrimary = gwaTopAdaptive(
        light: Color(red: 0.122, green: 0.118, blue: 0.114),              // #1f1e1d
        dark:  Color(red: 0.980, green: 0.976, blue: 0.961)               // #faf9f5
    )
    static let textSecondary = gwaTopAdaptive(
        light: Color(red: 0.420, green: 0.408, blue: 0.384),              // #6b6862
        dark:  Color(red: 0.659, green: 0.647, blue: 0.620)               // #a8a59e
    )
    static let textTertiary = gwaTopAdaptive(
        light: Color(red: 0.659, green: 0.647, blue: 0.620),
        dark:  Color(red: 0.500, green: 0.486, blue: 0.463)
    )

    // 헤어라인 분리선 — 웹 --border. light: black 8%, dark: white 8%.
    static let line = gwaTopAdaptive(
        light: Color.black.opacity(0.08),
        dark:  Color.white.opacity(0.08)
    )
    static let separator = gwaTopAdaptive(
        light: Color.black.opacity(0.06),
        dark:  Color.white.opacity(0.06)
    )

    // 그림자: 거의 없음 — 웹과 동일한 평면적 깊이감. 다크에서도 검정 미세 그림자.
    static let cardShadow = Color.black.opacity(0.04)

    static let primaryGradient = LinearGradient(
        colors: [primary, secondary],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

#Preview {
    GwaTopHomeRootView(user: .guest)
}
