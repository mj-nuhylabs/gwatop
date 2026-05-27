//
//  GwaTopAIStudyView.swift
//  GwaTop
//
//  학습 탭 — 과목 선택 → (주차별로 그룹된) 강의 자료 목록 → 자료 학습 화면.
//  자료 학습 화면(GwaTopFileStudyView) 안에서 9개 학습 기능 탭을 전환한다.
//

import SwiftUI

struct GwaTopAIStudyView: View {
    @State private var courses: [GwaTopCourseDTO] = []
    @State private var selectedCourseId: String? = nil
    @State private var files: [GwaTopFileSummary] = []
    @State private var isLoadingCourses = false
    @State private var isLoadingFiles = false
    @State private var loadError: String? = nil
    @State private var showUploadSheet = false
    @State private var selectedFile: GwaTopFileSummary? = nil
    /// 진행 중 파일이 있을 때 3초마다 자동 재조회 트리거. 안정화되면 자동 중지.
    @State private var pollTick: Int = 0

    /// 백엔드 처리 중인 상태값들. 이 중 하나라도 있으면 폴링 계속.
    private static let inProgressStatuses: Set<String> = [
        "pending", "uploading", "processing", "extracting",
        "extracted", "parsing", "classifying"
    ]

    private var hasInProgress: Bool {
        files.contains { Self.inProgressStatuses.contains($0.status) }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                GwaTopHomeTheme.background.ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 16) {
                        intro
                            .padding(.top, 8)

                        // 백그라운드 업로드 진행 카드 — 시트가 닫혀도 여기에 표시.
                        GwaTopNetworkBanner()
                        GwaTopUploadProgressBanner()

                        coursePicker

                        if let err = loadError {
                            errorBanner(err)
                        }

                        if isLoadingFiles {
                            ProgressView("자료 불러오는 중…")
                                .padding(.vertical, 28)
                        } else if selectedCourseId == nil {
                            placeholder("위에서 학습할 과목을 골라주세요.")
                        } else if files.isEmpty {
                            placeholder("이 과목에 업로드된 자료가 아직 없어요.\n오른쪽 위 ⬆️ 버튼으로 자료를 추가해보세요.")
                        } else {
                            ForEach(weekSections, id: \.key) { section in
                                weekSection(title: section.key, files: section.value)
                            }
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 32)
                }
            }
            .navigationTitle("학습")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showUploadSheet = true
                    } label: {
                        Image(systemName: "doc.badge.arrow.up")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(GwaTopHomeTheme.primary)
                            .frame(width: 38, height: 38)
                            .background(.white)
                            .clipShape(Circle())
                    }
                }
            }
            .task { await loadCoursesIfNeeded() }
            .onChange(of: selectedCourseId) { _, _ in
                Task { await reloadFiles() }
            }
            // 폴링 루프: pollTick 이 증가할 때마다 3초 후 재조회. hasInProgress 가 false 면 중지.
            .task(id: pollTick) {
                guard pollTick > 0 else { return }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if hasInProgress {
                    await reloadFiles(silent: true)
                }
            }
            .sheet(isPresented: $showUploadSheet) {
                GwaTopMaterialUploadSheet(onUploadCompleted: {
                    Task { await reloadFiles() }
                })
                .presentationDetents([.large])
            }
            // 문서 클릭 → 전체화면 새 창에서 학습 탭 진행.
            // sheet 대신 fullScreenCover 로 띄워서 진짜 별도 페이지처럼 느껴지게.
            .fullScreenCover(item: $selectedFile) { f in
                GwaTopFileStudyView(file: f)
            }
        }
    }

    // MARK: - Sections

    private var intro: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("AI 학습")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(GwaTopHomeTheme.primary)
            Text("자료를 골라 요약·퀴즈·플래시카드로 학습하세요")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(GwaTopHomeTheme.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var coursePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isLoadingCourses {
                ProgressView().padding(.vertical, 8)
            } else if courses.isEmpty {
                Text("등록된 과목이 없어요.")
                    .font(.system(size: 13))
                    .foregroundStyle(GwaTopHomeTheme.textSecondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(courses) { c in
                            coursePill(c)
                        }
                    }
                }
            }
        }
    }

    private func coursePill(_ c: GwaTopCourseDTO) -> some View {
        let isSelected = selectedCourseId == c.id
        return Button {
            selectedCourseId = c.id
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(c.color.map(Color.gwaTopHex) ?? Color.gray.opacity(0.4))
                    .frame(width: 8, height: 8)
                Text(c.name.isEmpty ? "이름 없는 과목" : c.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isSelected ? .white : GwaTopHomeTheme.textPrimary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isSelected ? GwaTopHomeTheme.primary : .white)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func weekSection(title: String, files: [GwaTopFileSummary]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(GwaTopHomeTheme.textSecondary)
                .padding(.leading, 4)

            VStack(spacing: 8) {
                ForEach(files) { f in
                    Button { selectedFile = f } label: { fileRow(f) }
                        .buttonStyle(.plain)
                }
            }
        }
    }

    private func fileRow(_ f: GwaTopFileSummary) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon(for: f.fileType))
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(GwaTopHomeTheme.primary)
                .frame(width: 40, height: 40)
                .background(GwaTopHomeTheme.primary.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(f.filename)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(GwaTopHomeTheme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                statusBadge(for: f)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func statusBadge(for f: GwaTopFileSummary) -> some View {
        let badge = GwaTopFileStatusBadge.from(f)
        return HStack(spacing: 6) {
            Text(badge.label)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(badge.color)
                .clipShape(Capsule())
            if let src = f.classificationSource {
                Text(GwaTopClassificationSource.label(src))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(GwaTopHomeTheme.textSecondary)
            }
        }
    }

    private func placeholder(_ msg: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.tertiary)
            Text(msg)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(GwaTopHomeTheme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private func errorBanner(_ msg: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            Text(msg)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.red)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Derived

    private var weekSections: [(key: String, value: [GwaTopFileSummary])] {
        // 강의계획서는 분류 대상 아님 → 학습 탭에서는 제외 (이미 캘린더에 반영됨)
        let normal = files.filter { !$0.isSyllabus }
        var grouped: [Int?: [GwaTopFileSummary]] = [:]
        for f in normal { grouped[f.week, default: []].append(f) }

        var sections: [(String, [GwaTopFileSummary])] = []
        for w in grouped.keys.compactMap({ $0 }).sorted() {
            sections.append(("\(w)주차", grouped[w] ?? []))
        }
        if let unclassified = grouped[nil], !unclassified.isEmpty {
            sections.append(("미분류 / 분류 대기", unclassified))
        }
        return sections
    }

    private func icon(for fileType: String) -> String {
        switch fileType {
        case "pdf":  return "doc.richtext"
        case "pptx": return "rectangle.stack"
        case "docx": return "doc.text"
        case "image": return "photo"
        default:     return "doc"
        }
    }

    // MARK: - Actions

    @MainActor
    private func loadCoursesIfNeeded() async {
        guard courses.isEmpty, !isLoadingCourses else { return }
        isLoadingCourses = true
        loadError = nil
        defer { isLoadingCourses = false }
        do {
            let list = try await GwaTopCourseService.shared.fetchAll()
            courses = list
            if selectedCourseId == nil { selectedCourseId = list.first?.id }
        } catch {
            if isCancellation(error) { return }
            loadError = "과목을 불러오지 못했어요: \(error.localizedDescription)"
        }
    }

    @MainActor
    private func reloadFiles(silent: Bool = false) async {
        guard let cid = selectedCourseId else { files = []; return }
        if !silent { isLoadingFiles = true }
        loadError = nil
        defer { if !silent { isLoadingFiles = false } }
        do {
            files = try await GwaTopFileService.shared.fetchFiles(courseId: cid)
            // 진행 중 파일이 있으면 다음 폴 예약. 안정화 상태면 자동 중지.
            if hasInProgress {
                pollTick += 1
            }
        } catch {
            if isCancellation(error) { return }
            loadError = "자료를 불러오지 못했어요: \(error.localizedDescription)"
        }
    }
}

#Preview {
    GwaTopAIStudyView()
}
