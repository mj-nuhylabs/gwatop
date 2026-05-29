//
//  GwaTopAIStudyView.swift
//  GwaTop
//
//  학습 탭 — 과목별 카드 세로 나열 + 각 카드 안에 강의 자료 행.
//  PC(gwatop-web) /study 페이지 디자인 패턴을 따른다.
//
//  레이아웃:
//    [학습 ▼ 학기] (header)
//    [🔎 자료 이름으로 검색]
//    [● 과목명                                                1개]
//    [📄 17-Hashmaps.pdf   17주차 · 5월 28일 · ✓ 준비 완료     >]
//
//  과목 카드는 항상 펼쳐 보임 (collapse 없음).
//  파일 검색은 모든 과목 파일에 대해 filename contains.
//

import SwiftUI

struct GwaTopAIStudyView: View {
    @State private var courses: [GwaTopCourseDTO] = []
    @State private var filesByCourse: [String: [GwaTopFileSummary]] = [:]
    @State private var isLoadingCourses = false
    @State private var loadingCourseIds: Set<String> = []
    @State private var loadError: String? = nil
    @State private var showUploadSheet = false
    @State private var selectedFile: GwaTopFileSummary? = nil
    @State private var searchText: String = ""
    /// 진행 중 파일이 있을 때 3초마다 자동 재조회 트리거.
    @State private var pollTick: Int = 0
    /// 사용자가 접어둔 과목 id 집합. 기본은 펼침.
    @State private var collapsedCourseIds: Set<String> = []

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
                        VStack(spacing: 14) {
                            // 백그라운드 업로드 진행 카드 — 시트가 닫혀도 여기에 표시.
                            GwaTopUploadProgressBanner()

                            searchBar

                            if let err = loadError {
                                errorBanner(err) {
                                    Task { await loadAll() }
                                }
                            }

                            if isLoadingCourses && courses.isEmpty {
                                ProgressView("불러오는 중…")
                                    .padding(.vertical, 40)
                            } else if courses.isEmpty {
                                placeholder("등록된 과목이 없어요.\n학기/과목 관리에서 추가해 주세요.")
                            } else if filteredCourses.isEmpty {
                                placeholder("\"\(searchText)\" 검색 결과가 없어요.")
                            } else {
                                ForEach(filteredCourses) { course in
                                    courseCard(course)
                                }
                            }
                        }
                        .padding(.horizontal, 18)
                        .padding(.top, 6)
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
            .sheet(isPresented: $showUploadSheet) {
                GwaTopMaterialUploadSheet(onUploadCompleted: {
                    Task { await reloadAllFiles() }
                })
                .presentationDetents([.large])
            }
            // 문서 클릭 → 전체화면 새 창에서 학습 탭 진행.
            .fullScreenCover(item: $selectedFile) { f in
                GwaTopFileStudyView(file: f)
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

    // MARK: - Course Card

    private func courseCard(_ course: GwaTopCourseDTO) -> some View {
        let files = filesFor(course)
        let isCollapsed = collapsedCourseIds.contains(course.id)
        return VStack(spacing: 0) {
            courseHeader(course, fileCount: files.count, isCollapsed: isCollapsed) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if isCollapsed {
                        collapsedCourseIds.remove(course.id)
                    } else {
                        collapsedCourseIds.insert(course.id)
                    }
                }
            }
            if !isCollapsed {
                if loadingCourseIds.contains(course.id) && files.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().scaleEffect(0.8)
                        Text("자료 불러오는 중…")
                            .font(.gwaTopSystem(size: 12))
                            .foregroundStyle(GwaTopHomeTheme.textSecondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                } else if files.isEmpty {
                    Text("업로드된 자료가 없어요.")
                        .font(.gwaTopSystem(size: 12, weight: .medium))
                        .foregroundStyle(GwaTopHomeTheme.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 18)
                } else {
                    VStack(spacing: 0) {
                        ForEach(files) { f in
                            Button { selectedFile = f } label: { fileRow(f) }
                                .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .gwaTopCard(radius: 16)
    }

    private func courseHeader(
        _ course: GwaTopCourseDTO,
        fileCount: Int,
        isCollapsed: Bool,
        onToggle: @escaping () -> Void
    ) -> some View {
        Button(action: onToggle) {
            HStack(spacing: 10) {
                Circle()
                    .fill(course.color.map(Color.gwaTopHex) ?? Color.gray.opacity(0.4))
                    .frame(width: 10, height: 10)

                Text(course.name.isEmpty ? "이름 없는 과목" : course.name)
                    .font(.gwaTopSystem(size: 16, weight: .bold))
                    .foregroundStyle(GwaTopHomeTheme.textPrimary)

                Spacer()

                Image(systemName: "chevron.down")
                    .font(.gwaTopSystem(size: 12, weight: .bold))
                    .foregroundStyle(GwaTopHomeTheme.textSecondary)
                    .rotationEffect(.degrees(isCollapsed ? -90 : 0))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())   // 탭 영역은 유지, 원형 배경만 제거
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, isCollapsed ? 14 : (fileCount > 0 ? 10 : 12))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - File Row

    private func fileRow(_ f: GwaTopFileSummary) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon(for: f.fileType))
                .font(.gwaTopSystem(size: 16, weight: .semibold))
                .foregroundStyle(GwaTopHomeTheme.textSecondary)
                .frame(width: 32, height: 32)
                .background(GwaTopHomeTheme.surfaceMute)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(f.filename)
                    .font(.gwaTopSystem(size: 14, weight: .semibold))
                    .foregroundStyle(GwaTopHomeTheme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                fileMeta(f)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.gwaTopSystem(size: 12, weight: .semibold))
                .foregroundStyle(GwaTopHomeTheme.textTertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .contentShape(Rectangle())   // 행 전체(빈 공간 포함)를 탭 영역으로.
    }

    /// 주차 chip + 날짜 + 상태(준비 완료 / 처리 중 / 실패).
    private func fileMeta(_ f: GwaTopFileSummary) -> some View {
        HStack(spacing: 8) {
            // 주차 chip (또는 미분류)
            weekChip(f)

            Text(Self.dateFormatter.string(from: f.createdAt))
                .font(.gwaTopSystem(size: 11, weight: .medium))
                .foregroundStyle(GwaTopHomeTheme.textSecondary)

            statusIcon(f)
        }
    }

    private func weekChip(_ f: GwaTopFileSummary) -> some View {
        let label: String = {
            if let w = f.week { return "\(w)주차" }
            switch f.status {
            case "unclassified": return "미분류"
            case "classifying":  return "분류 중"
            case "extracted":    return "분류 대기"
            default:             return "분류 대기"
            }
        }()
        return Text(label)
            .font(.gwaTopSystem(size: 10, weight: .bold))
            .foregroundStyle(GwaTopHomeTheme.textSecondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(GwaTopHomeTheme.surfaceMute)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    /// 백엔드의 최종(준비 완료) 상태들. 자료는 classified/unclassified,
    /// 강의계획서는 parsed 로 끝난다. 이 중 하나면 더 이상 "처리 중"이 아니다.
    private static let readyStatuses: Set<String> = [
        "classified", "unclassified", "parsed", "done"
    ]

    @ViewBuilder
    private func statusIcon(_ f: GwaTopFileSummary) -> some View {
        switch f.status {
        case let s where Self.readyStatuses.contains(s):
            HStack(spacing: 3) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.gwaTopSystem(size: 10, weight: .semibold))
                    .foregroundStyle(GwaTopHomeTheme.primary)
                Text("준비 완료")
                    .font(.gwaTopSystem(size: 11, weight: .semibold))
                    .foregroundStyle(GwaTopHomeTheme.primary)
            }
        case "failed":
            HStack(spacing: 3) {
                Image(systemName: "xmark.circle.fill")
                    .font(.gwaTopSystem(size: 10, weight: .semibold))
                Text("실패")
                    .font(.gwaTopSystem(size: 11, weight: .semibold))
            }
            .foregroundStyle(GwaTopHomeTheme.danger)
        default:
            HStack(spacing: 3) {
                ProgressView().scaleEffect(0.55)
                Text("처리 중")
                    .font(.gwaTopSystem(size: 11, weight: .semibold))
                    .foregroundStyle(GwaTopHomeTheme.textSecondary)
            }
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

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "M월 d일"
        return f
    }()

    private func icon(for fileType: String) -> String {
        switch fileType {
        case "pdf":   return "doc.richtext"
        case "pptx":  return "rectangle.stack"
        case "docx":  return "doc.text"
        case "image": return "photo"
        default:      return "doc"
        }
    }

    // MARK: - Actions

    @MainActor
    private func loadAll() async {
        await loadCourses()
        await reloadAllFiles()
    }

    @MainActor
    private func loadCourses() async {
        guard !isLoadingCourses else { return }
        // 스플래시 캐시 hydrate — 깜빡임 없음.
        let store = GwaTopAppDataStore.shared
        if !store.courses.isEmpty {
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
        // 스플래시 캐시 hydrate — 깜빡임 없음.
        let store = GwaTopAppDataStore.shared
        if !store.filesByCourse.isEmpty {
            for (cid, list) in store.filesByCourse {
                filesByCourse[cid] = list
            }
            if store.isCacheFresh && !silent {
                // 캐시 사용 → 로딩 인디케이터 안 띄움.
                return
            }
        }
        if !silent {
            // 캐시 없는 과목만 spinner — 이미 cached 면 inflight 표시 안 함.
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
                if let result {
                    filesByCourse[cid] = result
                }
                loadingCourseIds.remove(cid)
            }
        }
        // 진행 중 파일이 있으면 다음 폴 예약.
        if hasInProgress {
            pollTick += 1
        }
    }
}

#Preview {
    GwaTopAIStudyView()
}
