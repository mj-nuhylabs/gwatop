import SwiftUI
import UniformTypeIdentifiers

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

    @State private var dashboard: GwaTopHomeDashboardDTO? = nil
    @State private var courses: [GwaTopCourseDTO] = []
    /// 이번 주 모든 todo — 과목별 완료율(progress) 계산용.
    @State private var weekTodos: [GwaTopTodoDTO] = []
    @State private var isLoading = false
    @State private var loadError: String? = nil
    /// 과목 카드 탭 시 표시할 상세 시트 대상.
    @State private var selectedSubject: GwaTopSubject? = nil
    /// 무차별 업로드 — Files 앱 파일 선택기 표시 여부.
    @State private var showingUploadImporter = false
    /// 파일 읽기/선택 실패 메시지 (업로드 버튼 아래 표시).
    @State private var uploadImportError: String? = nil

    /// 실 데이터 기반 과목 카드. 백엔드에 progress 컬럼이 없어서 이번 주 todo
    /// 완료율로 derive. 다음 일정은 upcomingTodos / nextEvent 에서 가장 빠른 것.
    private var subjects: [GwaTopSubject] {
        courses.map { course in
            let courseTodos = weekTodos.filter { $0.courseId == course.id }
            let total = courseTodos.count
            let done = courseTodos.filter(\.isDone).count
            let progress: CGFloat = total > 0 ? CGFloat(done) / CGFloat(total) : 0

            let upcoming = (dashboard?.upcomingTodos ?? [])
                .filter { $0.courseId == course.id && !$0.isDone }
                .sorted { $0.dueDate < $1.dueDate }
                .first
            let nextSchedule: String
            if let u = upcoming {
                let dDay = Calendar.current.dateComponents(
                    [.day], from: Calendar.current.startOfDay(for: Date()),
                    to: Calendar.current.startOfDay(for: u.dueDate)
                ).day ?? 0
                let dLabel = dDay == 0 ? "오늘" : (dDay > 0 ? "D-\(dDay)" : "D+\(abs(dDay))")
                nextSchedule = "\(u.title) · \(dLabel)"
            } else {
                nextSchedule = "예정된 일정 없음"
            }

            return GwaTopSubject(
                courseId: course.id,
                name: course.name.isEmpty ? "이름 없는 과목" : course.name,
                professor: course.professor,
                location: course.location,
                classTimes: course.schedule ?? [],
                progress: progress,
                nextSchedule: nextSchedule,
                iconName: "book.closed.fill",
                color: course.color.map(Color.gwaTopHex) ?? GwaTopHomeTheme.primary
            )
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                GwaTopHomeTheme.background
                    .ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 22) {
                        topGreetingSection
                            .padding(.top, 18)

                        uploadSection
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
            // 강의계획서 파싱 완료 → 자동 생성 과제/일정이 즉시 반영되도록 강제 새로고침.
            .onReceive(NotificationCenter.default.publisher(for: .syllabusParseCompleted)) { _ in
                Task { await load(force: true) }
            }
            .toolbar {
                // 추후 알림 기능 구현 시 toolbar 버튼 복구. 동작 없는 종 아이콘 + 가짜 빨간 점은 오해 소지가 있어 제거.
            }
            .sheet(item: $selectedSubject) { subject in
                GwaTopSubjectDetailSheet(
                    subject: subject,
                    upcoming: (dashboard?.upcomingTodos ?? [])
                        .filter { $0.courseId == subject.courseId }
                        .sorted { $0.dueDate < $1.dueDate },
                    onSaved: { Task { await load(force: true) } }
                )
                .presentationDetents([.medium, .large])
            }
            // 무차별 업로드 — 종류(강의계획서/강의자료)를 미리 묻지 않으므로 버튼 탭 시
            // 곧장 파일 선택기를 띄운다. 선택 즉시 백그라운드 업로드가 시작되고 분류는 백엔드가.
            .fileImporter(
                isPresented: $showingUploadImporter,
                allowedContentTypes: Self.uploadContentTypes,
                allowsMultipleSelection: false
            ) { result in
                handleAutoFilePick(result)
            }
        }
    }

    @MainActor
    private func load(force: Bool = false) async {
        // 1) 스플래시 prefetch 결과를 우선 그대로 표시 — 깜빡임 제거.
        let store = GwaTopAppDataStore.shared
        if let cachedDash = store.dashboard {
            dashboard = cachedDash
        }
        if !store.courses.isEmpty {
            courses = store.courses
        }
        // weekTodos 는 store.upcomingTodos (3주) 중 이번 주만 필터.
        if !store.upcomingTodos.isEmpty {
            let cal = Calendar.current
            let now = Date()
            let weekStart = cal.dateInterval(of: .weekOfYear, for: now)?.start ?? now
            let weekEnd = cal.date(byAdding: .day, value: 7, to: weekStart) ?? now
            weekTodos = store.upcomingTodos.filter { $0.dueDate >= weekStart && $0.dueDate < weekEnd }
        }
        // 캐시가 신선하면 네트워크 호출 자체를 건너뜀 (탭 전환 시 깜빡임 방지).
        // force(파싱 완료 알림 등) 일 때는 무조건 네트워크에서 다시 받는다.
        if !force && store.isCacheFresh && dashboard != nil {
            isLoading = false
            loadError = nil
            return
        }

        // 2) 캐시가 없거나 stale 일 때만 백그라운드 fetch.
        if dashboard == nil { isLoading = true }
        loadError = nil
        defer { isLoading = false }
        async let dashTask = try? GwaTopHomeService.shared.fetchDashboard(upcomingLimit: 5)
        async let coursesTask = try? GwaTopCourseService.shared.fetchAll()
        async let todosTask: [GwaTopTodoDTO]? = {
            let cal = Calendar.current
            let now = Date()
            let weekStart = cal.dateInterval(of: .weekOfYear, for: now)?.start ?? now
            let weekEnd = cal.date(byAdding: .day, value: 7, to: weekStart) ?? now
            return try? await GwaTopTodoService.shared.fetchAll(start: weekStart, end: weekEnd)
        }()

        let (dash, list, todos) = await (dashTask, coursesTask, todosTask)
        if let dash { dashboard = dash }
        if let list { courses = list }
        if let todos { weekTodos = todos }

        if dash == nil && list == nil && todos == nil && self.dashboard == nil {
            loadError = "데이터를 불러오지 못했어요. 잠시 후 다시 시도해주세요."
        }
    }

    private var topGreetingSection: some View {
        // 오늘 할 일 = upcomingTodos 중 오늘 마감인 것. done/total 모두 카운트.
        let todayTodos = (dashboard?.upcomingTodos ?? []).filter {
            Calendar.current.isDateInToday($0.dueDate)
        }
        let todayTotal = todayTodos.count
        let todayDone = todayTodos.filter(\.isDone).count
        let todayRemaining = max(0, todayTotal - todayDone)
        let todayRate = todayTotal == 0 ? 0 : Double(todayDone) / Double(todayTotal)
        let todayPercent = Int((todayRate * 100).rounded())

        return VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(currentDateText)
                    .font(.gwaTopSystem(size: 14, weight: .semibold))
                    .foregroundStyle(GwaTopHomeTheme.textSecondary)

                Text("안녕하세요,\n\(user.firstDisplayName)님")
                    .font(.system(size: 28, weight: .heavy, design: .rounded))
                    .foregroundStyle(GwaTopHomeTheme.textPrimary)
                    .lineSpacing(2)
            }

            // 오늘 할 일 요약 — 카드 없이 플랫. 좌측 텍스트 + 우측 퍼센트 + 하단 thin progress.
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    (
                        Text("오늘 할 일 ")
                            .foregroundStyle(GwaTopHomeTheme.textSecondary)
                        + Text("\(todayRemaining)")
                            .foregroundStyle(GwaTopHomeTheme.textPrimary)
                            .fontWeight(.heavy)
                        + Text("개 남았어요")
                            .foregroundStyle(GwaTopHomeTheme.textSecondary)
                    )
                    .font(.gwaTopSystem(size: 15, weight: .semibold))

                    Spacer(minLength: 8)

                    Text("\(todayPercent)%")
                        .font(.gwaTopSystem(size: 15, weight: .heavy).monospacedDigit())
                        .foregroundStyle(GwaTopHomeTheme.textPrimary)
                }

                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(GwaTopHomeTheme.surfaceMute)
                        Capsule()
                            .fill(GwaTopHomeTheme.primary)
                            .frame(width: max(0, proxy.size.width * todayRate))
                            .animation(.easeOut(duration: 0.35), value: todayRate)
                    }
                }
                .frame(height: 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
            sectionHeader(title: "내 과목")

            if subjects.isEmpty {
                Text("등록된 과목이 없어요.\n설정 → 학기/과목 관리에서 추가해 주세요.")
                    .font(.gwaTopSystem(size: 13, weight: .medium))
                    .foregroundStyle(GwaTopHomeTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
                    .gwaTopCard(radius: 18)
            } else {
                // 모든 과목을 하나의 카드 안에 모으고 hairline divider 로 구분.
                // 각 행은 Button 으로 감싸 탭하면 상세 시트 노출 (feat/hyunnow).
                VStack(spacing: 0) {
                    ForEach(Array(subjects.enumerated()), id: \.element.id) { index, subject in
                        Button {
                            selectedSubject = subject
                        } label: {
                            GwaTopSubjectProgressCard(subject: subject)
                        }
                        .buttonStyle(.plain)
                        if index < subjects.count - 1 {
                            Divider()
                                .padding(.leading, 76)   // 아이콘 영역 들여쓰기
                        }
                    }
                }
                .gwaTopCard(radius: 22)
            }
        }
    }

    // MARK: - 무차별 파일 업로드 (강의계획서/강의자료 자동 구분)

    /// 허용 파일 타입 — PDF / PPTX / DOCX. 강의계획서·강의자료 모두 이 형식이라
    /// 한 진입점에서 받고, 종류 판정은 백엔드(_auto_dispatch)에 맡긴다.
    private static let uploadContentTypes: [UTType] = {
        var types: [UTType] = [.pdf]
        if let pptx = UTType(filenameExtension: "pptx") { types.append(pptx) }
        if let docx = UTType(filenameExtension: "docx") { types.append(docx) }
        return types
    }()

    /// ToDo 위에 놓이는 업로드 진입점. 탭하면 파일 선택기를 띄우고, 진행 중 업로드가
    /// 있으면 바로 아래에 진행 카드(GwaTopUploadProgressBanner)를 함께 보여준다.
    private var uploadSection: some View {
        VStack(spacing: 10) {
            Button {
                uploadImportError = nil
                showingUploadImporter = true
            } label: {
                HStack(spacing: 14) {
                    ZStack {
                        Circle()
                            .fill(Color.white.opacity(0.18))
                            .frame(width: 46, height: 46)
                        Image(systemName: "arrow.up.doc.fill")
                            .font(.gwaTopSystem(size: 20, weight: .bold))
                            .foregroundStyle(.white)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text("파일 업로드")
                            .font(.gwaTopSystem(size: 16, weight: .heavy))
                            .foregroundStyle(.white)
                        Text("강의계획서·강의자료 아무거나 올리면 AI가 자동으로 분류해요")
                            .font(.gwaTopSystem(size: 12, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.92))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 8)

                    Image(systemName: "plus")
                        .font(.gwaTopSystem(size: 15, weight: .heavy))
                        .foregroundStyle(GwaTopHomeTheme.primary)
                        .frame(width: 30, height: 30)
                        .background(Color.white)
                        .clipShape(Circle())
                }
                .padding(16)
                .background(GwaTopHomeTheme.primaryGradient)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
            .buttonStyle(.plain)

            // 진행 중 업로드가 있으면 버튼 바로 아래에 진행 상태 카드 표시.
            GwaTopUploadProgressBanner()

            if let uploadImportError {
                Text(uploadImportError)
                    .font(.gwaTopSystem(size: 12, weight: .semibold))
                    .foregroundStyle(GwaTopHomeTheme.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// 파일 선택 결과 처리 — 보안 스코프 진입 후 Data 로 읽어 전역 업로드 매니저에 위임.
    private func handleAutoFilePick(_ result: Result<[URL], Error>) {
        uploadImportError = nil
        switch result {
        case .failure(let error):
            uploadImportError = "파일 선택에 실패했어요: \(error.localizedDescription)"
        case .success(let urls):
            guard let url = urls.first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }

            let filename = url.lastPathComponent
            let fileType = Self.inferUploadFileType(from: url)
            do {
                let data = try Data(contentsOf: url)
                // 시트 없이 즉시 백그라운드 업로드 시작. 종류 구분은 백엔드가 한다.
                GwaTopUploadProgress.shared.startAutoUpload(
                    filename: filename, data: data, fileType: fileType,
                )
            } catch {
                uploadImportError = "파일을 읽지 못했어요: \(error.localizedDescription)"
            }
        }
    }

    /// 확장자 → 백엔드 file_type. 선택기가 PDF/PPTX/DOCX 로 제한하므로 그 외는 없음.
    private static func inferUploadFileType(from url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "pdf":  return "pdf"
        case "pptx": return "pptx"
        case "docx": return "docx"
        default:     return "other"
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
    /// 관리자 여부 — true 면 설정에 "관리자" 링크 노출. (별도 탭 대신 여기로 옮겨 More 래퍼 방지)
    var isAdmin: Bool = false

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

                    // 내용이 길어 화면을 넘칠 수 있으므로 ScrollView 로 감싼다.
                    // 하단 패딩으로 로그아웃 버튼이 탭바에 가려지지 않게 충분히 띄운다.
                    ScrollView(showsIndicators: false) {
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
                                    GwaTopMyDataManagementView()
                                } label: {
                                    GwaTopSettingsRow(
                                        iconName: "folder.fill",
                                        title: "내 자료 관리",
                                        value: "학기·과목, 업로드 자료"
                                    )
                                }
                                .buttonStyle(.plain)

                                appearanceSelector

                                GwaTopAppleCalendarSettingsRow()

                                GwaTopSettingsRow(iconName: "person.fill", title: "프로필 정보", value: user.displayName)
                                GwaTopSettingsRow(iconName: "envelope.fill", title: "이메일", value: user.email)
                                GwaTopSettingsRow(iconName: "key.fill", title: "인증 제공자", value: user.loginProvider)

                                if isAdmin {
                                    NavigationLink {
                                        GwaTopAdminView()
                                    } label: {
                                        GwaTopSettingsRow(
                                            iconName: "lock.shield.fill",
                                            title: "관리자",
                                            value: "테스트 도구"
                                        )
                                    }
                                    .buttonStyle(.plain)
                                }
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
                        }
                        .padding(.horizontal, 22)
                        .padding(.bottom, 120)   // 하단 탭바 가림 방지 여유
                    }
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
        .background(GwaTopHomeTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

/// 설정 화면의 Apple 캘린더 연동 토글 행.
/// 켜면 권한을 요청하고, 거부 상태면 시스템 설정으로 보내는 안내 alert 를 띄운다.
struct GwaTopAppleCalendarSettingsRow: View {
    @AppStorage(UserDefaults.gwaTopAppleCalendarEnabledKey) private var enabled: Bool = false
    @ObservedObject private var svc = GwaTopAppleCalendarService.shared
    @State private var showDeniedAlert = false

    /// 실제로 "켜짐"으로 보이는 조건 — 사용자 토글 + 권한 보유 둘 다.
    private var isOn: Bool { enabled && svc.hasAccess }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "calendar")
                .font(.gwaTopSystem(size: 16, weight: .bold))
                .foregroundStyle(GwaTopHomeTheme.primary)
                .frame(width: 36, height: 36)
                .background(GwaTopHomeTheme.primary.opacity(0.10))
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text("Apple 캘린더 연동")
                    .font(.gwaTopSystem(size: 15, weight: .bold))
                    .foregroundStyle(GwaTopHomeTheme.textPrimary)
                Text(isOn ? "Apple 캘린더 일정을 함께 표시 중" : "기기의 Apple 캘린더 일정을 함께 표시")
                    .font(.gwaTopSystem(size: 12, weight: .medium))
                    .foregroundStyle(GwaTopHomeTheme.textSecondary)
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { isOn },
                set: { newValue in
                    if newValue {
                        Task { await turnOn() }
                    } else {
                        enabled = false
                    }
                }
            ))
            .labelsHidden()
            .tint(GwaTopHomeTheme.primary)
        }
        .padding(14)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .alert("캘린더 접근 권한이 필요해요", isPresented: $showDeniedAlert) {
            Button("설정으로 이동") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text("설정 > 과탑 > 캘린더 에서 권한을 허용해주세요.")
        }
    }

    @MainActor
    private func turnOn() async {
        if svc.isDenied {
            showDeniedAlert = true
            return
        }
        if !svc.hasAccess {
            let granted = await svc.requestAccess()
            if !granted {
                showDeniedAlert = svc.isDenied
                return
            }
        }
        enabled = true
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

struct GwaTopTodayTaskRow: View {
    let task: GwaTopTodayTask

    var body: some View {
        HStack(spacing: 14) {
            // 좌측 priority indicator — 작은 컬러 점 하나.
            // 컬러 채도를 카드 전체가 아니라 한 점에만 모아두면 시선이 정리되고
            // 시스템 리스트(Apple Reminders/Mail)와 비슷한 무게감이 된다.
            Circle()
                .fill(task.isDone
                      ? GwaTopHomeTheme.controlDisabled
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
                .foregroundStyle(GwaTopHomeTheme.textTertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .contentShape(Rectangle())
    }
}

struct GwaTopSubjectProgressCard: View {
    let subject: GwaTopSubject

    /// row 단독 카드가 아니라 상위 카드 안의 한 row 로 동작 — padding 만 적용하고
    /// 배경/clipShape 는 상위(subjectProgressSection)가 책임진다.
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
    }
}

// MARK: - 과목 상세 시트
// 홈 "내 과목" 카드 탭 시 표시. 실라버스에서 파싱된 과목 정보(교수·수업 시간)와
// 해당 과목의 다가오는 일정을 요약해 보여준다.
struct GwaTopSubjectDetailSheet: View {
    let subject: GwaTopSubject
    let upcoming: [GwaTopTodoDTO]
    /// 저장 성공 후 호출 — 홈이 과목/일정을 다시 불러와 변경된 강의실을 반영.
    var onSaved: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss

    /// 편집 중인 수업 시간(요일·시간·강의실). 저장 전까지 로컬에서만 변경.
    @State private var editableTimes: [GwaTopClassTimeDTO]
    @State private var isEditing = false
    @State private var isSaving = false
    @State private var saveError: String? = nil

    init(subject: GwaTopSubject, upcoming: [GwaTopTodoDTO], onSaved: (() -> Void)? = nil) {
        self.subject = subject
        self.upcoming = upcoming
        self.onSaved = onSaved
        _editableTimes = State(initialValue: subject.classTimes)
    }

    private static let dayOrder = ["MON", "TUE", "WED", "THU", "FRI", "SAT", "SUN"]
    private static let dayLabels: [String: String] = [
        "MON": "월", "TUE": "화", "WED": "수", "THU": "목",
        "FRI": "금", "SAT": "토", "SUN": "일",
    ]

    private var sortedTimes: [GwaTopClassTimeDTO] {
        editableTimes.sorted {
            let a = Self.dayOrder.firstIndex(of: $0.day) ?? 99
            let b = Self.dayOrder.firstIndex(of: $1.day) ?? 99
            return a != b ? a < b : $0.startTime < $1.startTime
        }
    }

    private func timeText(_ t: GwaTopClassTimeDTO) -> String {
        "\(Self.dayLabels[t.day] ?? t.day) \(t.startTime)–\(t.endTime)"
    }

    /// 해당 요일(슬롯)의 강의실. 슬롯 강의실이 비어 있으면 과목 전체 강의실로 폴백.
    private func roomText(_ t: GwaTopClassTimeDTO) -> String? {
        if let slot = t.location?.trimmingCharacters(in: .whitespacesAndNewlines), !slot.isEmpty {
            return slot
        }
        if let course = subject.location?.trimmingCharacters(in: .whitespacesAndNewlines), !course.isEmpty {
            return course
        }
        return nil
    }

    private func dDayText(_ date: Date) -> String {
        let cal = Calendar.current
        let d = cal.dateComponents(
            [.day], from: cal.startOfDay(for: Date()), to: cal.startOfDay(for: date)
        ).day ?? 0
        if d == 0 { return "오늘" }
        return d > 0 ? "D-\(d)" : "D+\(abs(d))"
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    headerSection
                    infoRowsSection
                    classTimeSection
                    upcomingSection
                }
                .padding(20)
            }
            .navigationTitle("과목 정보")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("닫기") { dismiss() }
                        .font(.gwaTopSystem(size: 15, weight: .bold))
                }
            }
        }
    }

    private var headerSection: some View {
        HStack(spacing: 14) {
            Image(systemName: subject.iconName)
                .font(.gwaTopSystem(size: 24, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 64, height: 64)
                .background(subject.color)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))

            VStack(alignment: .leading, spacing: 6) {
                Text("내 과목")
                    .font(.gwaTopSystem(size: 13, weight: .bold))
                    .foregroundStyle(subject.color)
                Text(subject.name)
                    .font(.system(size: 23, weight: .heavy, design: .rounded))
                    .foregroundStyle(GwaTopHomeTheme.textPrimary)
            }
        }
    }

    private var infoRowsSection: some View {
        VStack(spacing: 12) {
            GwaTopSubjectDetailRow(
                iconName: "person.fill",
                title: "교수",
                value: (subject.professor?.isEmpty == false) ? subject.professor! : "정보 없음",
                tint: subject.color
            )
            GwaTopSubjectDetailRow(
                iconName: "chart.bar.fill",
                title: "이번 학기 진행률",
                value: "\(Int(subject.progress * 100))%",
                tint: subject.color
            )
        }
    }

    private var classTimeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("수업 시간 · 강의실")
                    .font(.gwaTopSystem(size: 18, weight: .heavy))
                    .foregroundStyle(GwaTopHomeTheme.textPrimary)
                Spacer()
                if isEditing {
                    Button("취소") {
                        // 변경 폐기 후 원래 값으로 복원.
                        editableTimes = subject.classTimes
                        saveError = nil
                        isEditing = false
                    }
                    .font(.gwaTopSystem(size: 14, weight: .bold))
                    .foregroundStyle(GwaTopHomeTheme.textSecondary)
                } else {
                    Button {
                        isEditing = true
                    } label: {
                        Label("편집", systemImage: "pencil")
                            .font(.gwaTopSystem(size: 14, weight: .bold))
                            .foregroundStyle(subject.color)
                    }
                }
            }

            if isEditing {
                classTimeEditor
            } else {
                classTimeReadOnly
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .gwaTopCard(radius: 20)
    }

    @ViewBuilder
    private var classTimeReadOnly: some View {
        if sortedTimes.isEmpty {
            Text("등록된 수업 시간이 없어요. '편집'으로 추가해보세요.")
                .font(.gwaTopSystem(size: 14, weight: .medium))
                .foregroundStyle(GwaTopHomeTheme.textSecondary)
        } else {
            ForEach(sortedTimes, id: \.self) { t in
                HStack(spacing: 12) {
                    Image(systemName: "clock.fill")
                        .font(.gwaTopSystem(size: 14, weight: .bold))
                        .foregroundStyle(subject.color)
                        .frame(width: 30, height: 30)
                        .background(subject.color.opacity(0.12))
                        .clipShape(Circle())
                    VStack(alignment: .leading, spacing: 3) {
                        Text(timeText(t))
                            .font(.gwaTopSystem(size: 15, weight: .semibold))
                            .foregroundStyle(GwaTopHomeTheme.textPrimary)
                        // 요일별 강의실 — 있으면 표시 (슬롯 → 과목 location 폴백).
                        if let room = roomText(t) {
                            HStack(spacing: 4) {
                                Image(systemName: "mappin.and.ellipse")
                                    .font(.gwaTopSystem(size: 12, weight: .semibold))
                                Text(room)
                                    .font(.gwaTopSystem(size: 13, weight: .medium))
                            }
                            .foregroundStyle(GwaTopHomeTheme.textSecondary)
                        }
                    }
                    Spacer()
                }
            }
        }
    }

    @ViewBuilder
    private var classTimeEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 요일마다 한 줄 — 요일/시간/강의실을 각각 수정. 같은 과목도 요일별 강의실 분리 가능.
            ForEach(Array(editableTimes.enumerated()), id: \.offset) { idx, _ in
                GwaTopClassTimeRow(
                    time: $editableTimes[idx],
                    onDelete: { editableTimes.remove(at: idx) }
                )
            }

            Button {
                editableTimes.append(
                    GwaTopClassTimeDTO(day: "MON", startTime: "09:00", endTime: "10:30")
                )
            } label: {
                Label("요일 추가", systemImage: "plus.circle.fill")
                    .font(.gwaTopSystem(size: 14, weight: .bold))
                    .foregroundStyle(subject.color)
            }
            .padding(.top, 2)

            if let saveError {
                Text(saveError)
                    .font(.gwaTopSystem(size: 13, weight: .semibold))
                    .foregroundStyle(GwaTopHomeTheme.danger)
            }

            Button {
                Task { await saveTimes() }
            } label: {
                HStack(spacing: 6) {
                    if isSaving { ProgressView().tint(.white) }
                    Text(isSaving ? "저장 중…" : "저장")
                        .font(.gwaTopSystem(size: 16, weight: .heavy))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(subject.color)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .disabled(isSaving)
            .padding(.top, 4)
        }
    }

    @MainActor
    private func saveTimes() async {
        isSaving = true
        saveError = nil
        defer { isSaving = false }
        do {
            _ = try await GwaTopCourseService.shared.update(
                id: subject.courseId,
                schedule: editableTimes
            )
            // 캐시 무효화 + 과목 재조회 → 시간표 등 다른 화면도 갱신.
            GwaTopAppDataStore.shared.invalidate()
            GwaTopAppDataStore.shared.refreshCoursesInBackground()
            onSaved?()
            isEditing = false
        } catch {
            saveError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private var upcomingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("다가오는 일정")
                .font(.gwaTopSystem(size: 18, weight: .heavy))
                .foregroundStyle(GwaTopHomeTheme.textPrimary)

            if upcoming.isEmpty {
                Text("예정된 일정이 없어요.")
                    .font(.gwaTopSystem(size: 14, weight: .medium))
                    .foregroundStyle(GwaTopHomeTheme.textSecondary)
            } else {
                ForEach(upcoming) { todo in
                    HStack(spacing: 12) {
                        Circle()
                            .fill(todo.isDone ? GwaTopHomeTheme.success : subject.color)
                            .frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(todo.title)
                                .font(.gwaTopSystem(size: 15, weight: .semibold))
                                .foregroundStyle(GwaTopHomeTheme.textPrimary)
                            Text(GwaTopDateFormatters.koMonthDayTime.string(from: todo.dueDate))
                                .font(.gwaTopSystem(size: 12, weight: .medium))
                                .foregroundStyle(GwaTopHomeTheme.textSecondary)
                        }
                        Spacer()
                        Text(dDayText(todo.dueDate))
                            .font(.system(size: 13, weight: .heavy, design: .rounded))
                            .foregroundStyle(subject.color)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .gwaTopCard(radius: 20)
    }
}

private struct GwaTopSubjectDetailRow: View {
    let iconName: String
    let title: String
    let value: String
    let tint: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .font(.gwaTopSystem(size: 15, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(tint.opacity(0.10))
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
        .gwaTopCard(radius: 18)
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
    let courseId: String
    let name: String
    let professor: String?
    /// 과목 전체 강의실 — 요일별(slot) 강의실이 비어 있을 때 폴백으로 표시.
    let location: String?
    let classTimes: [GwaTopClassTimeDTO]
    let progress: CGFloat
    let nextSchedule: String
    let iconName: String
    let color: Color

    // 실 데이터(GwaTopCourseDTO + GwaTopTodoDTO)에서 GwaTopHomeView 가 derive 한다.
    // 별도 mock 데이터는 없음 — 과목이 없으면 빈 상태 UI 가 표시됨.
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

    /// 비활성 컨트롤 배경 (disabled button bg 등) — 다크/라이트 모두에서 약하게 보이는 muted gray.
    /// 기존 `Color.gray.opacity(0.4)` 같은 정적 회색을 대체.
    static let controlDisabled = gwaTopAdaptive(
        light: Color(red: 0.78, green: 0.77, blue: 0.74),                  // warm light gray
        dark:  Color(red: 0.35, green: 0.34, blue: 0.32)                   // warm dark gray
    )
    /// 세그먼티드/탭 선택 상태에서 surfaceMute 위에 올라가는 "튀어오른" 표면.
    /// light: 순백 / dark: 살짝 밝은 surfaceElevated 톤.
    static let selectedSurface = gwaTopAdaptive(
        light: Color.white,
        dark:  Color(red: 0.235, green: 0.231, blue: 0.220)               // #3c3b39
    )
    /// 약한 wash/inlay 배경 — 기존 `Color.gray.opacity(0.06~0.1)` 정적 회색 대체.
    /// surfaceMute 보다 살짝 강한 chip/pill 배경 용도.
    static let chipFill = gwaTopAdaptive(
        light: Color.black.opacity(0.06),
        dark:  Color.white.opacity(0.08)
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
