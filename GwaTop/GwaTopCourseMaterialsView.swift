//
//  GwaTopCourseMaterialsView.swift
//  GwaTop
//
//  S-1 학습 홈에서 진입: 과목 선택 → 주차별 강의 자료 목록 → 분류 상태 확인 → 필기 노트 진입.
//

import SwiftUI

struct GwaTopCourseMaterialsView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var courses: [GwaTopCourseDTO] = []
    @State private var selectedCourseId: String? = nil
    @State private var files: [GwaTopFileSummary] = []
    @State private var isLoadingCourses = false
    @State private var isLoadingFiles = false
    @State private var loadError: String? = nil
    @State private var selectedFileForNote: GwaTopFileSummary? = nil

    // 분류 진행 중 파일이 있을 때 잠시 후 다시 조회한다.
    @State private var refreshTrigger = 0

    var body: some View {
        NavigationStack {
            ZStack {
                GwaTopHomeTheme.background.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 18) {
                        header
                        coursePicker

                        if let err = loadError {
                            errorBanner(err)
                        }

                        if isLoadingFiles {
                            ProgressView("불러오는 중…")
                                .padding(.vertical, 24)
                        } else if selectedCourseId == nil {
                            placeholder(text: "위에서 과목을 골라주세요.")
                        } else if files.isEmpty {
                            placeholder(text: "이 과목에 업로드된 자료가 아직 없어요.")
                        } else {
                            ForEach(weekSections, id: \.key) { section in
                                weekSection(title: section.key, files: section.value)
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 22)
                }
            }
            .navigationTitle("내 강의 자료")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("닫기") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await reloadFiles() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(selectedCourseId == nil || isLoadingFiles)
                }
            }
            .task {
                await loadCoursesIfNeeded()
            }
            .onChange(of: selectedCourseId) { _, _ in
                Task { await reloadFiles() }
            }
            .sheet(item: $selectedFileForNote) { file in
                GwaTopFileNoteView(file: file)
                    .presentationDetents([.large])
            }
            .task(id: refreshTrigger) {
                guard refreshTrigger > 0 else { return }
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                if isAnyFileInProgress {
                    await reloadFiles(silent: true)
                }
            }
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("AI 자동 분류")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.blue)
            Text("주차별로 자동 정리된 강의 자료를 확인하세요.")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(.primary)
            Text("자료를 탭하면 추출된 필기 노트(텍스트)를 볼 수 있어요.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .gwaTopCard(radius: 20)
    }

    private var coursePicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("과목")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.secondary)

            if isLoadingCourses {
                ProgressView().padding(.vertical, 8)
            } else if courses.isEmpty {
                Text("등록된 과목이 없어요.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
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
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .gwaTopCard(radius: 20)
    }

    private func coursePill(_ c: GwaTopCourseDTO) -> some View {
        let isSelected = selectedCourseId == c.id
        return Button {
            selectedCourseId = c.id
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(c.color.map(Color.gwaTopHex) ?? .gray.opacity(0.4))
                    .frame(width: 8, height: 8)
                Text(c.name.isEmpty ? "이름 없는 과목" : c.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isSelected ? .white : .primary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isSelected ? GwaTopHomeTheme.primary : Color.gray.opacity(0.1))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func weekSection(title: String, files: [GwaTopFileSummary]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)

            VStack(spacing: 8) {
                ForEach(files) { f in
                    fileRow(f)
                }
            }
        }
    }

    private func fileRow(_ f: GwaTopFileSummary) -> some View {
        let badge = GwaTopFileStatusBadge.from(f)
        let badgeColor = badge.color

        return Button {
            selectedFileForNote = f
        } label: {
            HStack(spacing: 12) {
                Image(systemName: iconName(for: f.fileType))
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(GwaTopHomeTheme.primary)
                    .frame(width: 38, height: 38)
                    .background(GwaTopHomeTheme.primary.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text(f.filename)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    HStack(spacing: 6) {
                        Text(badge.label)
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(badgeColor)
                            .clipShape(Capsule())

                        if let src = f.classificationSource {
                            Text(GwaTopClassificationSource.label(src))
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
            .gwaTopCard(radius: 14)
        }
        .buttonStyle(.plain)
    }

    private func placeholder(text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            Text(message)
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
        // 강의계획서는 따로 보여주고, 나머지는 주차별 그룹.
        let syllabi = files.filter { $0.isSyllabus }
        let normal = files.filter { !$0.isSyllabus }

        var grouped: [Int?: [GwaTopFileSummary]] = [:]
        for f in normal {
            grouped[f.week, default: []].append(f)
        }

        var sections: [(key: String, value: [GwaTopFileSummary])] = []
        if !syllabi.isEmpty {
            sections.append(("강의계획서", syllabi))
        }

        let weekKeys = grouped.keys.compactMap { $0 }.sorted()
        for w in weekKeys {
            sections.append(("\(w)주차", grouped[w] ?? []))
        }
        if let unclassified = grouped[nil], !unclassified.isEmpty {
            sections.append(("미분류 / 분류 대기", unclassified))
        }
        return sections
    }

    private var isAnyFileInProgress: Bool {
        files.contains { f in
            ["processing", "extracting", "extracted", "parsing", "classifying"].contains(f.status)
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
            let fetched = try await GwaTopCourseService.shared.fetchAll()
            courses = fetched
            if selectedCourseId == nil {
                selectedCourseId = fetched.first?.id
            }
        } catch {
            loadError = "과목을 불러오지 못했어요: \(error.localizedDescription)"
        }
    }

    @MainActor
    private func reloadFiles(silent: Bool = false) async {
        guard let courseId = selectedCourseId else {
            files = []
            return
        }
        if !silent { isLoadingFiles = true }
        loadError = nil
        defer { if !silent { isLoadingFiles = false } }
        do {
            files = try await GwaTopFileService.shared.fetchFiles(courseId: courseId)
            // 진행 중인 파일이 있으면 한 번 더 자동 새로고침을 예약.
            if isAnyFileInProgress {
                refreshTrigger += 1
            }
        } catch {
            if !silent {
                loadError = "자료를 불러오지 못했어요: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Helpers

    private func iconName(for fileType: String) -> String {
        switch fileType {
        case "pdf":  return "doc.richtext"
        case "pptx": return "rectangle.stack"
        case "docx": return "doc.text"
        case "image": return "photo"
        default:     return "doc"
        }
    }

}

#Preview {
    GwaTopCourseMaterialsView()
}
