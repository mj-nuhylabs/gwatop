//
//  GwaTopMyDataManagementView.swift
//  GwaTop
//
//  설정 → "내 자료 관리" 진입점.
//  사용자가 직접 만든/업로드한 데이터를 한곳에서 관리한다:
//   - 학기 · 과목: 추가/이름변경/삭제 (기존 GwaTopAcademicManagementView 재사용)
//   - 업로드한 자료: 과목별로 올린 파일을 모아 보고, 탭하면 학습 화면으로 열람
//
//  참고: 파일 삭제·이름변경은 현재 백엔드 API 가 없어 제외(읽기/열람만 지원).
//        지원되는 동작만 우선 노출한다.
//

import SwiftUI

// MARK: - 허브

struct GwaTopMyDataManagementView: View {
    @State private var courses: [GwaTopCourseDTO] = []
    @State private var semesters: [GwaTopSemesterDTO] = []
    @State private var isLoading = false
    @State private var errorMessage: String? = nil

    /// 학기 id → 이름 (자료 섹션에서 과목의 학기 표기용).
    private var semesterName: [String: String] {
        Dictionary(uniqueKeysWithValues: semesters.map { ($0.id, $0.name) })
    }

    private var sortedCourses: [GwaTopCourseDTO] {
        courses.sorted { $0.name < $1.name }
    }

    var body: some View {
        List {
            Section("학사 정보") {
                NavigationLink {
                    GwaTopAcademicManagementView()
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("학기 · 과목 관리")
                                .font(.gwaTopSystem(size: 16, weight: .heavy))
                            Text("학기와 과목을 추가 · 이름변경 · 삭제")
                                .font(.gwaTopSystem(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "book.closed.fill")
                            .foregroundStyle(GwaTopHomeTheme.primary)
                    }
                    .padding(.vertical, 2)
                }
            }

            Section("업로드한 자료") {
                if let errorMessage {
                    Text(errorMessage)
                        .font(.gwaTopSystem(size: 13))
                        .foregroundStyle(GwaTopHomeTheme.warning)
                }

                if courses.isEmpty {
                    if isLoading {
                        HStack { ProgressView(); Text("불러오는 중…") }
                    } else {
                        Text("등록된 과목이 없습니다. 학기 · 과목 관리에서 먼저 과목을 추가해보세요.")
                            .font(.gwaTopSystem(size: 14))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(sortedCourses) { course in
                        NavigationLink {
                            GwaTopCourseFilesView(course: course)
                        } label: {
                            courseRow(course)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("내 자료 관리")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await reload() }
        .task { await reload() }
    }

    private func courseRow(_ c: GwaTopCourseDTO) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Color.gwaTopHex(c.color ?? "#4F8EF7"))
                .frame(width: 12, height: 12)
            VStack(alignment: .leading, spacing: 2) {
                Text(c.name.isEmpty ? "이름 없는 과목" : c.name)
                    .font(.gwaTopSystem(size: 16, weight: .heavy))
                if let name = semesterName[c.semesterId] {
                    Text(name)
                        .font(.gwaTopSystem(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }

    @MainActor
    private func reload() async {
        isLoading = true
        errorMessage = nil
        // 스플래시 캐시가 있으면 즉시 표시 — 깜빡임 제거.
        let store = GwaTopAppDataStore.shared
        if !store.courses.isEmpty { courses = store.courses }
        if !store.semesters.isEmpty { semesters = store.semesters }
        do {
            async let crsTask = GwaTopCourseService.shared.fetchAll()
            async let semTask = GwaTopSemesterService.shared.fetchAll()
            let (cList, sList) = try await (crsTask, semTask)
            self.courses = cList
            self.semesters = sList
        } catch {
            self.errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        isLoading = false
    }
}

// MARK: - 과목별 업로드 자료 목록

struct GwaTopCourseFilesView: View {
    let course: GwaTopCourseDTO

    @State private var files: [GwaTopFileSummary] = []
    @State private var isLoading = false
    @State private var errorMessage: String? = nil
    @State private var searchText = ""
    /// 학습자료 탭 → 학습 화면(전체 학습 탭) 으로 열람.
    @State private var selectedFile: GwaTopFileSummary? = nil
    /// 강의계획서 탭 → 홈에서 과목 클릭 시 나오는 정보 시트로 열람.
    @State private var selectedSubject: GwaTopSubject? = nil
    /// 삭제 확인 대상 파일.
    @State private var pendingDelete: GwaTopFileSummary? = nil

    /// 검색어로 거른 파일. 파일명 부분일치(대소문자 무시).
    private var filteredFiles: [GwaTopFileSummary] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return files }
        return files.filter { $0.filename.lowercased().contains(q) }
    }

    private func sorted(_ list: [GwaTopFileSummary]) -> [GwaTopFileSummary] {
        // 주차 → 생성일 순. 주차 없는 파일은 뒤로.
        list.sorted {
            let aw = $0.week ?? Int.max
            let bw = $1.week ?? Int.max
            if aw != bw { return aw < bw }
            return $0.createdAt > $1.createdAt
        }
    }

    private var syllabusFiles: [GwaTopFileSummary] { sorted(filteredFiles.filter { $0.isSyllabus }) }
    private var materialFiles: [GwaTopFileSummary] { sorted(filteredFiles.filter { !$0.isSyllabus }) }

    var body: some View {
        List {
            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .font(.gwaTopSystem(size: 13))
                        .foregroundStyle(GwaTopHomeTheme.warning)
                }
            }

            if files.isEmpty {
                if isLoading {
                    HStack { ProgressView(); Text("불러오는 중…") }
                } else {
                    Text("이 과목에 업로드된 자료가 없습니다.")
                        .font(.gwaTopSystem(size: 14))
                        .foregroundStyle(.secondary)
                }
            } else if filteredFiles.isEmpty {
                Text("'\(searchText)' 검색 결과가 없습니다.")
                    .font(.gwaTopSystem(size: 14))
                    .foregroundStyle(.secondary)
            } else {
                // 1) 강의계획서 — 탭하면 과목 정보 시트(홈과 동일).
                if !syllabusFiles.isEmpty {
                    Section("강의계획서 \(syllabusFiles.count)개") {
                        ForEach(syllabusFiles) { file in
                            Button {
                                selectedSubject = makeSubject()
                            } label: {
                                fileRow(file)
                            }
                            .buttonStyle(.plain)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    pendingDelete = file
                                } label: { Label("삭제", systemImage: "trash") }
                            }
                        }
                    }
                }

                // 2) 학습 자료 — 탭하면 학습 화면(학습 탭과 동일).
                if !materialFiles.isEmpty {
                    Section("학습 자료 \(materialFiles.count)개") {
                        ForEach(materialFiles) { file in
                            Button {
                                selectedFile = file
                            } label: {
                                fileRow(file)
                            }
                            .buttonStyle(.plain)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    pendingDelete = file
                                } label: { Label("삭제", systemImage: "trash") }
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(course.name.isEmpty ? "자료" : course.name)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "자료 검색 (파일명)")
        .refreshable { await reload() }
        .task { await reload() }
        .fullScreenCover(item: $selectedFile) { f in
            GwaTopFileStudyView(file: f)
        }
        .sheet(item: $selectedSubject) { subject in
            GwaTopSubjectDetailSheet(
                subject: subject,
                upcoming: (GwaTopAppDataStore.shared.dashboard?.upcomingTodos ?? [])
                    .filter { $0.courseId == course.id }
                    .sorted { $0.dueDate < $1.dueDate }
            )
            .presentationDetents([.medium, .large])
        }
        .confirmationDialog(
            "이 자료를 삭제할까요?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("삭제", role: .destructive) {
                if let f = pendingDelete { Task { await deleteFile(f) } }
            }
            Button("취소", role: .cancel) { pendingDelete = nil }
        } message: {
            if let f = pendingDelete {
                Text("'\(f.filename)' 을(를) 삭제하면 되돌릴 수 없어요.")
            }
        }
    }

    @MainActor
    private func deleteFile(_ f: GwaTopFileSummary) async {
        pendingDelete = nil
        do {
            try await GwaTopFileService.shared.delete(fileId: f.id)
            files.removeAll { $0.id == f.id }
            // 캐시 무효화 → 학습 탭/홈 등 다른 화면도 다음 진입 시 갱신.
            GwaTopAppDataStore.shared.invalidate()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// 이 과목으로 홈의 과목 정보 시트(GwaTopSubjectDetailSheet)에 넘길 GwaTopSubject 생성.
    private func makeSubject() -> GwaTopSubject {
        GwaTopSubject(
            courseId: course.id,
            name: course.name.isEmpty ? "이름 없는 과목" : course.name,
            professor: course.professor,
            location: course.location,
            classTimes: course.schedule ?? [],
            progress: 0,
            nextSchedule: "",
            iconName: "book.closed.fill",
            color: course.color.map(Color.gwaTopHex) ?? GwaTopHomeTheme.primary
        )
    }

    private func fileRow(_ f: GwaTopFileSummary) -> some View {
        HStack(spacing: 12) {
            Image(systemName: f.isSyllabus ? "doc.text.magnifyingglass" : "doc.text.fill")
                .font(.gwaTopSystem(size: 16, weight: .semibold))
                .foregroundStyle(GwaTopHomeTheme.primary)
                .frame(width: 34, height: 34)
                .background(GwaTopHomeTheme.primary.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(f.filename)
                    .font(.gwaTopSystem(size: 15, weight: .bold))
                    .foregroundStyle(GwaTopHomeTheme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    if f.isSyllabus {
                        tag("강의계획서", color: GwaTopHomeTheme.primary)
                    }
                    if let w = f.week {
                        tag("\(w)주차", color: GwaTopHomeTheme.textSecondary)
                    }
                    tag(statusLabel(f.status), color: statusColor(f.status))
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.gwaTopSystem(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private func tag(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.gwaTopSystem(size: 11, weight: .bold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(color.opacity(0.12))
            .clipShape(Capsule())
    }

    /// 백엔드 status 코드를 사용자용 한국어 라벨로.
    private func statusLabel(_ status: String) -> String {
        switch status {
        case "classified", "unclassified", "parsed", "done": return "완료"
        case "pending", "processing", "uploading", "uploaded": return "처리 중"
        case "failed", "error": return "실패"
        default: return status
        }
    }

    private func statusColor(_ status: String) -> Color {
        switch status {
        case "classified", "unclassified", "parsed", "done": return GwaTopHomeTheme.success
        case "failed", "error": return GwaTopHomeTheme.danger
        default: return GwaTopHomeTheme.warning
        }
    }

    @MainActor
    private func reload() async {
        isLoading = true
        errorMessage = nil
        // 스플래시 캐시가 있으면 즉시 표시.
        let cached = GwaTopAppDataStore.shared.filesByCourse[course.id]
        if let cached, !cached.isEmpty { files = cached }
        do {
            files = try await GwaTopFileService.shared.fetchFiles(courseId: course.id)
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        isLoading = false
    }
}
