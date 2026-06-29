//
//  GwaTopAIStudyView.swift
//  GwaTop
//
//  학습 탭 — 과목을 흰 카드로 세로 나열. 각 카드 왼쪽엔 과목 고유색 "포인트 바".
//
//  레이아웃:
//    [학습                                                   ⬆︎] (header)
//    [🔎 자료 이름으로 검색]
//    ┃┌──────────────────────────────────────────────┐
//    ┃│  과목명                                         ⌄ │  ← 접힘: 제목 + 자료수
//    ┃│  강의자료 2개                                      │     (┃ = 과목색 포인트 바)
//    ┃└──────────────────────────────────────────────┘
//
//  상호작용:
//    • 우측 화살표(⌄/⌃) 탭 → 그 자리에서 교수/시간 상세 펼침·접힘.
//    • 화살표 외 카드 영역 탭 → 곧장 과목별 학습 상세로 이동.
//  한 번에 하나만 펼쳐지는 아코디언(expandedCourseId).
//  파일 검색은 모든 과목 파일에 대해 filename contains.
//

import SwiftUI

struct GwaTopAIStudyView: View {
    @State private var courses: [GwaTopCourseDTO] = []
    @State private var filesByCourse: [String: [GwaTopFileSummary]] = [:]
    @State private var isLoadingCourses = false
    // reloadAllFiles 동시 실행 시 가장 최근 호출만 결과를 반영하기 위한 세대 카운터.
    @State private var reloadGeneration = 0
    @State private var loadingCourseIds: Set<String> = []
    @State private var loadError: String? = nil
    @State private var showUploadSheet = false
    @State private var selectedFile: GwaTopFileSummary? = nil
    @State private var searchText: String = ""
    /// 진행 중 파일이 있을 때 3초마다 자동 재조회 트리거.
    @State private var pollTick: Int = 0
    /// 자료 업로드 시트를 열 때 미리 선택할 과목 id.
    /// 과목 상세에서 열면 그 과목으로, 헤더 버튼에서 열면 nil(직접 선택).
    @State private var uploadCourseId: String? = nil
    /// 펼쳐진(상세 정보 표시) 과목 id. 한 번에 하나만 펼쳐지는 아코디언.
    /// 펼침/접힘은 카드 우측 화살표(chevron) 버튼으로만 토글한다.
    @State private var expandedCourseId: String? = nil
    /// 학습 상세로 push 할 과목 id. 카드의 화살표 외 영역을 탭하면 설정된다.
    /// (GwaTopCourseDTO 가 Hashable 이 아니라 id 로 navigate 후 courses 에서 역참조.)
    @State private var navCourseId: String? = nil

    /// 백엔드 처리 중인 상태값들. 이 중 하나라도 있으면 폴링 계속.
    private static let inProgressStatuses: Set<String> = [
        "pending", "uploading", "processing", "extracting",
        "extracted", "parsing", "classifying"
    ]

    private var hasInProgress: Bool {
        filesByCourse.values.flatMap { $0 }.contains { Self.inProgressStatuses.contains($0.status) }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                GwaTopHomeTheme.background.ignoresSafeArea()

                VStack(spacing: 0) {
                    GwaTopScreenHeader(title: "학습") {
                        Button {
                            uploadCourseId = nil
                            showUploadSheet = true
                        } label: {
                            Image(systemName: "doc.badge.arrow.up")
                                .font(.gwaTopSystem(size: 15, weight: .bold))
                                .foregroundStyle(GwaTopHomeTheme.primary)
                                .frame(width: 38, height: 38)
                                .background(GwaTopHomeTheme.surface)
                                .clipShape(Circle())
                        }
                    }

                    ScrollView(showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 0) {
                            // 상단(진행 배너 + 검색) — 좌우 여백 유지.
                            VStack(spacing: 14) {
                                // 백그라운드 업로드 진행 카드 — 시트가 닫혀도 여기에 표시.
                                GwaTopUploadProgressBanner()
                                searchBar
                            }
                            .padding(.horizontal, 18)
                            .padding(.top, 6)

                            if let err = loadError {
                                errorBanner(err) {
                                    Task { await loadAll() }
                                }
                                .padding(.horizontal, 18)
                                .padding(.top, 14)
                            }

                            if isLoadingCourses && courses.isEmpty {
                                ProgressView("불러오는 중…")
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 40)
                            } else if courses.isEmpty {
                                placeholder("등록된 과목이 없어요.\n학기/과목 관리에서 추가해 주세요.")
                                    .padding(.horizontal, 18)
                            } else if filteredCourses.isEmpty {
                                placeholder("\"\(searchText)\" 검색 결과가 없어요.")
                                    .padding(.horizontal, 18)
                            } else {
                                // 과목 리스트 — 흰 카드 + 과목 고유색을 왼쪽 "포인트 바"로.
                                // (흰 배경끼리 겹쳐 쌓으면 경계가 뭉개지므로, 카드 사이에 여백을
                                //  두고 얇은 테두리 + 옅은 그림자로 분리한다.)
                                VStack(spacing: 12) {
                                    ForEach(filteredCourses) { course in
                                        courseCard(course)
                                    }
                                }
                                .padding(.horizontal, 18)
                                .padding(.top, 12)
                            }
                        }
                        .padding(.bottom, 32)
                    }
                    .refreshable { await loadAll() }
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .task { await loadAll() }
            // 폴링 루프: pollTick 이 증가할 때마다 3초 후 재조회. hasInProgress 가 false 면 중지.
            .task(id: pollTick) {
                guard pollTick > 0 else { return }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if hasInProgress {
                    await reloadAllFiles(silent: true)
                }
            }
            // 카드 본문 탭 → 과목별 학습 상세로 push. id 로 navigate 후 현재 courses 에서 역참조해
            // 최신 파일/로딩 상태를 그대로 넘긴다.
            .navigationDestination(item: $navCourseId) { cid in
                if let course = courses.first(where: { $0.id == cid }) {
                    GwaTopCourseStudyDetailView(
                        course: course,
                        files: filesByCourse[course.id] ?? [],
                        isLoading: loadingCourseIds.contains(course.id),
                        onSelectFile: { selectedFile = $0 },
                        onUpload: {
                            uploadCourseId = course.id
                            showUploadSheet = true
                        }
                    )
                }
            }
            .sheet(isPresented: $showUploadSheet) {
                GwaTopMaterialUploadSheet(preselectedCourseId: uploadCourseId, onUploadCompleted: {
                    // silent=true 로 호출해서 cache fresh bail-out 우회 + 스피너 안 띄움
                    // (사용자는 상단 진행 카드를 보고 있음).
                    Task { await reloadAllFiles(silent: true) }
                })
                .presentationDetents([.large])
            }
            // 문서 클릭 → 전체화면 새 창에서 학습 탭 진행.
            // onDismiss: 상세 화면을 닫고 돌아오면 최신 상태로 silent reload. 상세를 보는
            // 동안 백엔드가 분류를 끝냈으면 행이 곧바로 "준비 완료" 로 바뀐다. (cache fresh
            // bail-out 을 우회하는 silent reload 라, 진행 중이면 폴링도 다시 가동된다.)
            .fullScreenCover(item: $selectedFile, onDismiss: {
                Task { await reloadAllFiles(silent: true) }
            }) { f in
                GwaTopFileStudyView(file: f)
            }
            // 강의계획서 파싱 완료 → 백엔드가 신규 과목을 추가했을 수 있음 → 강제 재조회.
            // force=true 로 캐시(신선 플래그) bail-out 을 우회해야 신규 과목이 즉시 뜬다.
            // store 의 디바운스(0.4s) refresh 를 기다리지 않고 학습 탭이 직접 fresh fetch.
            .onReceive(NotificationCenter.default.publisher(for: .syllabusParseCompleted)) { _ in
                Task {
                    await loadCourses(force: true)
                    await reloadAllFiles(silent: true)
                }
            }
            // 일반 자료 업로드의 S3 PUT + confirm 이 끝나면 즉시 재조회. 시트의 1.2초 후
            // reload 는 S3 PUT 이 길면 confirm 전이라 file row 가 안 보일 수 있는데,
            // 이 알림은 진짜 등록 시점에 발동돼서 새 자료가 확실히 목록에 들어온다.
            .onReceive(NotificationCenter.default.publisher(for: .materialUploadCompleted)) { _ in
                Task { await reloadAllFiles(silent: true) }
            }
        }
    }

    // MARK: - Search

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.gwaTopSystem(size: 14, weight: .semibold))
                .foregroundStyle(GwaTopHomeTheme.textSecondary)

            TextField("자료 이름으로 검색", text: $searchText)
                .font(.gwaTopSystem(size: 14, weight: .medium))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.gwaTopSystem(size: 14, weight: .semibold))
                        .foregroundStyle(GwaTopHomeTheme.textTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .gwaTopCard(radius: 14)
    }

    // MARK: - Course Card (아코디언)

    /// 과목 카드 — 흰(surface) 배경 + 왼쪽에 과목 고유색 "포인트 바".
    /// 상호작용 분리:
    ///   • 우측 화살표(chevron) 버튼 탭 → 인라인 펼침/접힘(교수/시간 상세 노출). expandedCourseId 관리.
    ///   • 화살표 외의 카드 영역 탭 → 과목별 학습 상세(GwaTopCourseStudyDetailView)로 push.
    /// 화살표는 Button 이라 자기 프레임의 탭을 가로채고, 나머지는 카드 전체 onTapGesture 가 받는다.
    private func courseCard(_ course: GwaTopCourseDTO) -> some View {
        let isOpen = expandedCourseId == course.id
        let materialCount = (filesByCourse[course.id] ?? []).filter { !$0.isSyllabus }.count
        let accent = course.color.map(Color.gwaTopHex) ?? Color.gwaTopHex(GwaTopDefaultCourseColor)
        let hasDetails = (course.professor?.isEmpty == false) || (course.schedule?.isEmpty == false)

        return HStack(spacing: 0) {
            // 왼쪽 포인트 바 — 과목 고유색. 카드 전체 높이를 채우고 둥근 모서리로 클립된다.
            Rectangle()
                .fill(accent)
                .frame(width: 6)

            VStack(alignment: .leading, spacing: 0) {
                // ── 헤더 행: 과목명+자료수 + 우측 펼침/접힘 화살표 버튼 ──
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(course.name.isEmpty ? "이름 없는 과목" : course.name)
                            .font(.gwaTopSystem(size: 19, weight: .bold))
                            .foregroundStyle(GwaTopHomeTheme.textPrimary)
                            .lineLimit(isOpen ? nil : 1)
                            .truncationMode(.tail)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("강의자료 \(materialCount)개")
                            .font(.gwaTopSystem(size: 13, weight: .semibold))
                            .foregroundStyle(GwaTopHomeTheme.textSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    // 펼침/접힘 토글 화살표 — 이 버튼만 펼침을 제어한다(카드 본문 탭은 네비게이션).
                    Button {
                        withAnimation(.spring(response: 0.34, dampingFraction: 0.9)) {
                            expandedCourseId = isOpen ? nil : course.id
                        }
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.gwaTopSystem(size: 14, weight: .bold))
                            .foregroundStyle(isOpen ? GwaTopHomeTheme.primary : GwaTopHomeTheme.textTertiary)
                            .rotationEffect(.degrees(isOpen ? 180 : 0))
                            .frame(width: 38, height: 38)
                            .background(isOpen ? GwaTopHomeTheme.primary.opacity(0.12) : Color.clear)
                            .clipShape(Circle())
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isOpen ? "접기" : "펼치기")
                }

                // ── 상세 정보 (펼쳐졌을 때, 교수/시간이 있을 때만) ──
                if isOpen && hasDetails {
                    VStack(alignment: .leading, spacing: 9) {
                        if let prof = course.professor, !prof.isEmpty {
                            detailRow(icon: "person.fill", text: prof)
                        }
                        if let schedule = course.schedule, !schedule.isEmpty {
                            detailRow(icon: "clock.fill", text: scheduleText(schedule))
                        }
                    }
                    .padding(.top, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
                }
            }
            .padding(.leading, 16)
            .padding(.trailing, 12)
            .padding(.vertical, isOpen ? 18 : 20)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GwaTopHomeTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(GwaTopHomeTheme.line, lineWidth: 1)
        )
        .shadow(color: GwaTopHomeTheme.cardShadow, radius: 6, x: 0, y: 3)
        // 화살표 외 카드 전체 탭 → 학습 상세로 이동. 위 chevron Button 이 자기 영역 탭을
        // 먼저 가로채므로 화살표를 눌렀을 땐 이 제스처가 발동하지 않는다.
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onTapGesture {
            navCourseId = course.id
        }
    }

    /// 펼쳐진 카드 안의 상세 정보 한 줄 (아이콘 + 텍스트).
    private func detailRow(icon: String, text: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(.gwaTopSystem(size: 12, weight: .semibold))
                .foregroundStyle(GwaTopHomeTheme.textTertiary)
                .frame(width: 16)
            Text(text)
                .font(.gwaTopSystem(size: 14, weight: .medium))
                .foregroundStyle(GwaTopHomeTheme.textSecondary)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
    }

    /// 수업 시간 슬롯들을 "월 13:00–14:30, 수 …" 형태 문자열로.
    private func scheduleText(_ slots: [GwaTopClassTimeDTO]) -> String {
        slots
            .map { "\(Self.dayLabel($0.day)) \($0.startTime)–\($0.endTime)" }
            .joined(separator: ", ")
    }

    /// 백엔드 요일 코드(MON…SUN) → 한글 1글자.
    private static func dayLabel(_ day: String) -> String {
        switch day.uppercased() {
        case "MON": return "월"
        case "TUE": return "화"
        case "WED": return "수"
        case "THU": return "목"
        case "FRI": return "금"
        case "SAT": return "토"
        case "SUN": return "일"
        default:    return day
        }
    }

    // MARK: - Helpers

    private func placeholder(_ msg: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.gwaTopSystem(size: 26, weight: .light))
                .foregroundStyle(GwaTopHomeTheme.textTertiary)
            Text(msg)
                .font(.gwaTopSystem(size: 13, weight: .medium))
                .foregroundStyle(GwaTopHomeTheme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private func errorBanner(_ msg: String, retry: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(GwaTopHomeTheme.danger)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 8) {
                Text(msg)
                    .font(.gwaTopSystem(size: 12, weight: .semibold))
                    .foregroundStyle(GwaTopHomeTheme.danger)
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: retry) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                            .font(.gwaTopSystem(size: 11, weight: .bold))
                        Text("다시 시도")
                            .font(.gwaTopSystem(size: 11, weight: .bold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(GwaTopHomeTheme.danger)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GwaTopHomeTheme.danger.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Derived

    /// 검색어가 비었으면 모든 과목, 있으면 해당 파일이 1개 이상 매치되는 과목만.
    private var filteredCourses: [GwaTopCourseDTO] {
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return courses }
        return courses.filter { course in
            filesFor(course).contains { $0.filename.lowercased().contains(q) }
        }
    }

    /// 과목별 파일 — 강의계획서 제외(이미 캘린더 반영). 검색어 있으면 매치만.
    private func filesFor(_ course: GwaTopCourseDTO) -> [GwaTopFileSummary] {
        let base = (filesByCourse[course.id] ?? []).filter { !$0.isSyllabus }
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return base }
        return base.filter { $0.filename.lowercased().contains(q) }
    }

    // MARK: - Actions

    @MainActor
    private func loadAll() async {
        await loadCourses()
        await reloadAllFiles()
    }

    /// force=true 면 캐시 신선도와 무관하게 항상 fresh fetch.
    /// (강의계획서 파싱 후 신규 과목을 즉시 반영하기 위해 — store 캐시가 fresh 로 찍혀 있어도 우회)
    @MainActor
    private func loadCourses(force: Bool = false) async {
        guard !isLoadingCourses else { return }
        // 스플래시 캐시 hydrate — 깜빡임 없음.
        let store = GwaTopAppDataStore.shared
        if !force, !store.courses.isEmpty {
            courses = store.courses
            if store.isCacheFresh { return }
        }
        if courses.isEmpty { isLoadingCourses = true }
        loadError = nil
        defer { isLoadingCourses = false }
        do {
            courses = try await GwaTopCourseService.shared.fetchAll()
        } catch {
            if isCancellation(error) { return }
            loadError = "과목을 불러오지 못했어요: \(error.localizedDescription)"
        }
    }

    /// 모든 과목 파일을 병렬로 fetch. silent=true 면 로딩 인디케이터 안 보이게.
    @MainActor
    private func reloadAllFiles(silent: Bool = false) async {
        guard !courses.isEmpty else { return }
        // 동시 실행 race 방지: 가장 최근에 시작한 reload 만 결과를 반영한다. 느린 이전
        // reload 가 나중에 끝나며 최신 데이터를 stale 응답으로 덮어쓰는 깜빡임을 막는다.
        reloadGeneration += 1
        let myGen = reloadGeneration
        let store = GwaTopAppDataStore.shared
        // ── 캐시 hydrate ─────────────────────────────────────────────────────────────
        // silent=false (.task / refreshable) — 사용자가 빈 화면을 보지 않게 캐시로 즉시 채움.
        //   단, **이미 local 이 가지고 있는 과목은 건너뜀** — 그러지 않으면 polling 이후
        //   silent reload 가 stale 캐시로 local 의 최신 데이터(방금 업로드한 파일, 진행중
        //   status) 를 덮어써서 "파일이 사라졌다 나왔다" 깜빡임이 생긴다.
        //   AppDataStore.filesByCourse 는 스플래시 prefetch 외엔 갱신 안 되는 1회성 캐시라
        //   특히 위험.
        // silent=true (업로드 완료 알림, polling) — 화면에 이미 표시 중인 데이터가 있으니
        //   캐시 hydrate 단계 자체를 통째로 스킵하고 곧장 fresh fetch 로.
        if !silent {
            if !store.filesByCourse.isEmpty {
                for (cid, list) in store.filesByCourse where filesByCourse[cid] == nil {
                    filesByCourse[cid] = list
                }
                if store.isCacheFresh {
                    // 캐시가 신선하면 network round-trip 없이 종료. silent 경로엔 적용 안 함.
                    return
                }
            }
            loadingCourseIds = Set(courses.map(\.id).filter { filesByCourse[$0] == nil })
        }
        await withTaskGroup(of: (String, [GwaTopFileSummary]?).self) { group in
            for c in courses {
                group.addTask {
                    do {
                        let list = try await GwaTopFileService.shared.fetchFiles(courseId: c.id)
                        return (c.id, list)
                    } catch {
                        return (c.id, nil)
                    }
                }
            }
            for await (cid, result) in group {
                // 더 새로운 reload 가 시작됐으면 이 결과는 stale — 반영하지 않는다.
                if myGen != reloadGeneration { continue }
                if let result {
                    filesByCourse[cid] = result
                }
                loadingCourseIds.remove(cid)
            }
        }
        // 진행 중 파일이 있으면 다음 폴 예약. (최신 reload 일 때만)
        if myGen == reloadGeneration && hasInProgress {
            pollTick += 1
        }
    }
}

#Preview {
    GwaTopAIStudyView()
}
