//
//  GwaTopSyllabusUploadSheet.swift
//  GwaTop
//
//  실제 강의계획서 업로드 흐름:
//   - 과목 선택 / 새 과목 추가 (백엔드 GET /v1/courses, POST /v1/semesters/{id}/courses)
//   - PDF 파일 선택 (.fileImporter)
//   - presigned-url → S3 PUT → confirm
//   - confirm 응답 직후 시트 즉시 닫음 + GwaTopSyllabusWatcher 에 등록
//   - 백엔드 Celery 가 비동기 파싱 (보통 5~30초). 완료되면 watcher 가 캘린더 자동 새로고침.
//
//  이전엔 시트가 45초간 폴링해서 사용자가 화면에 묶여 있었음 (status=pending 타임아웃 빈발).
//  지금은 업로드 자체(3~5초)만 시트가 잡고, 파싱은 백그라운드로 빠진다.
//

import SwiftUI
import UniformTypeIdentifiers

struct GwaTopSyllabusUploadSheet: View {
    var onUploadCompleted: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var courses: [GwaTopCourseDTO] = []
    @State private var semesters: [GwaTopSemesterDTO] = []
    @State private var selectedCourseId: String? = nil
    @State private var isLoadingCourses: Bool = false
    @State private var courseLoadError: String? = nil
    @State private var showingNewCourseSheet: Bool = false

    @State private var showingFileImporter: Bool = false
    @State private var pickedFileName: String? = nil
    @State private var pickedFileData: Data? = nil

    @State private var phase: Phase = .idle
    @State private var phaseMessage: String = ""
    @State private var uploadedFileId: String? = nil

    enum Phase: Equatable {
        case idle
        /// presigned URL 발급 → S3 PUT → confirm 진행 중. 사용자가 화면에 잡혀 있는 유일한 구간.
        case uploading
        /// confirm 완료 — 파싱은 백그라운드로 빠졌고 시트는 곧 닫힘. 0.6초 토스트 표시용.
        case dispatched
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header

                    courseSection
                    fileSection
                    statusSection

                    Button(action: uploadTapped) {
                        HStack {
                            if case .uploading = phase {
                                ProgressView().tint(.white).padding(.trailing, 6)
                            }
                            Text(actionButtonTitle)
                                .font(.gwaTopSystem(size: 16, weight: .heavy))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(canSubmit ? GwaTopHomeTheme.primary : Color.gray.opacity(0.4))
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                    .disabled(!canSubmit)
                }
                .padding(20)
            }
            .navigationTitle("강의계획서 업로드")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("닫기") {
                        dismiss()
                    }
                }
            }
            .fileImporter(
                isPresented: $showingFileImporter,
                allowedContentTypes: [.pdf],
                allowsMultipleSelection: false
            ) { result in
                handleFilePick(result)
            }
            .navigationDestination(isPresented: $showingNewCourseSheet) {
                GwaTopCourseFormView(
                    mode: .create,
                    defaultSemesterId: nil,
                    onSaved: { newCourse in
                        if !courses.contains(where: { $0.id == newCourse.id }) {
                            courses.append(newCourse)
                            courses.sort { $0.name < $1.name }
                        }
                        selectedCourseId = newCourse.id
                        Task { await refreshSemestersOnly() }
                    }
                )
            }
            .task {
                await loadCoursesAndSemesters()
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "doc.badge.arrow.up.fill")
                .font(.gwaTopSystem(size: 30, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 64, height: 64)
                .background(GwaTopHomeTheme.primary)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))

            Text("강의계획서를 업로드하면 AI가 시험·과제 일정을 자동으로 캘린더에 등록합니다.")
                .font(.gwaTopSystem(size: 14, weight: .medium))
                .foregroundStyle(GwaTopHomeTheme.textSecondary)
                .lineSpacing(4)
        }
    }

    private var courseSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionTitle("1. 과목 선택")
                Text("(선택)")
                    .font(.gwaTopSystem(size: 12, weight: .semibold))
                    .foregroundStyle(GwaTopHomeTheme.textSecondary)
                Spacer()
                Button {
                    showingNewCourseSheet = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus.circle.fill")
                        Text("새 과목 추가")
                    }
                    .font(.gwaTopSystem(size: 13, weight: .heavy))
                    .foregroundStyle(GwaTopHomeTheme.primary)
                }
            }

            Text("과목을 선택하지 않으면 AI가 강의계획서를 분석해서 자동으로 매칭하거나 새 과목을 만들어 줍니다.")
                .font(.gwaTopSystem(size: 12, weight: .medium))
                .foregroundStyle(GwaTopHomeTheme.textSecondary)
                .lineSpacing(2)

            if isLoadingCourses {
                HStack { ProgressView(); Text("과목 목록 불러오는 중…").font(.gwaTopSystem(size: 13)) }
            } else if let err = courseLoadError {
                Text(err).font(.gwaTopSystem(size: 13)).foregroundStyle(GwaTopHomeTheme.warning)
            } else if courses.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("등록된 과목이 없습니다.")
                        .font(.gwaTopSystem(size: 14, weight: .heavy))
                        .foregroundStyle(GwaTopHomeTheme.textPrimary)
                    Text(semesters.isEmpty
                         ? "먼저 학기를 등록해 주세요. (강의계획서 자동 매칭은 학기가 1개 이상 있어야 동작합니다.)"
                         : "그대로 업로드하면 AI가 새 과목을 자동 생성합니다.")
                        .font(.gwaTopSystem(size: 12, weight: .medium))
                        .foregroundStyle(GwaTopHomeTheme.textSecondary)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.white)
                .clipShape(RoundedRectangle(cornerRadius: 14))
            } else {
                // "AI 자동 매칭" + 기존 과목 리스트를 함께 Picker 선택지로
                Picker("과목", selection: Binding(
                    get: { selectedCourseId ?? "" },  // "" 면 자동 매칭 모드
                    set: { selectedCourseId = $0.isEmpty ? nil : $0 }
                )) {
                    HStack {
                        Image(systemName: "sparkles")
                            .foregroundStyle(GwaTopHomeTheme.primary)
                        Text("AI 자동 매칭/생성")
                    }
                    .tag("")

                    ForEach(courses) { c in
                        HStack {
                            Circle()
                                .fill(Color.gwaTopHex(c.color ?? "#4F8EF7"))
                                .frame(width: 10, height: 10)
                            Text(c.name)
                        }
                        .tag(c.id)
                    }
                }
                .pickerStyle(.menu)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.white)
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }
        }
    }

    private var fileSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("2. PDF 파일 선택")
            Button {
                showingFileImporter = true
            } label: {
                HStack {
                    Image(systemName: pickedFileName == nil ? "tray.and.arrow.up" : "doc.fill")
                    Text(pickedFileName ?? "Files 앱에서 PDF 선택")
                        .lineLimit(1)
                    Spacer()
                    if pickedFileData != nil {
                        Text("\((pickedFileData?.count ?? 0) / 1024) KB")
                            .font(.gwaTopSystem(size: 12, weight: .medium))
                            .foregroundStyle(GwaTopHomeTheme.textSecondary)
                    }
                }
                .padding(14)
                .background(.white)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("3. 업로드 상태")
            switch phase {
            case .idle:
                statusRow(icon: "circle.dashed", text: "대기 중", tint: .gray)
            case .uploading:
                statusRow(icon: "arrow.up.circle.fill", text: phaseMessage, tint: GwaTopHomeTheme.primary)
            case .dispatched:
                statusRow(icon: "sparkles", text: phaseMessage, tint: GwaTopHomeTheme.success)
            case .failed(let msg):
                statusRow(icon: "exclamationmark.triangle.fill", text: msg, tint: GwaTopHomeTheme.warning)
            }
        }
    }

    private var canSubmit: Bool {
        if case .uploading = phase { return false }
        // 과목 선택은 optional — 파일만 있으면 업로드 가능
        return pickedFileData != nil
    }

    private var actionButtonTitle: String {
        switch phase {
        case .idle:        return "업로드 시작"
        case .uploading:   return "업로드 중…"
        case .dispatched:  return "잠시 후 닫힙니다…"
        case .failed:      return "다시 시도"
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.gwaTopSystem(size: 15, weight: .heavy))
            .foregroundStyle(GwaTopHomeTheme.textPrimary)
    }

    private func statusRow(icon: String, text: String, tint: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(text)
                .font(.gwaTopSystem(size: 13, weight: .medium))
                .foregroundStyle(GwaTopHomeTheme.textPrimary)
            Spacer()
        }
        .padding(14)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: - Actions

    private func refreshSemestersOnly() async {
        if let list = try? await GwaTopSemesterService.shared.fetchAll() {
            await MainActor.run { self.semesters = list }
        }
    }

    private func loadCoursesAndSemesters() async {
        isLoadingCourses = true
        courseLoadError = nil
        do {
            async let coursesTask = GwaTopCourseService.shared.fetchAll()
            async let semestersTask = GwaTopSemesterService.shared.fetchAll()
            let (courseList, semesterList) = try await (coursesTask, semestersTask)

            await MainActor.run {
                self.courses = courseList
                self.semesters = semesterList
                // 기본값은 "AI 자동 매칭" 모드 (selectedCourseId = nil). 사용자가 명시적으로
                // Picker에서 특정 과목을 고를 때만 selectedCourseId가 채워진다.
            }
        } catch {
            let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            await MainActor.run { self.courseLoadError = msg }
        }
        await MainActor.run { self.isLoadingCourses = false }
    }

    private func handleFilePick(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let started = url.startAccessingSecurityScopedResource()
            defer { if started { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                self.pickedFileData = data
                self.pickedFileName = url.lastPathComponent
                self.phase = .idle
            } catch {
                self.phase = .failed("파일 읽기 실패: \(error.localizedDescription)")
            }
        case .failure(let err):
            self.phase = .failed("파일 선택 취소: \(err.localizedDescription)")
        }
    }

    private func uploadTapped() {
        guard let data = pickedFileData, let filename = pickedFileName else { return }

        // 업로드를 전역 GwaTopUploadProgress 에 위임 — 시트가 닫혀도 백그라운드에서 계속.
        // 사용자는 즉시 시트가 닫히는 걸 보고, 학습/캘린더 탭 상단에 작은 진행 카드만 본다.
        GwaTopUploadProgress.shared.startSyllabusUpload(
            filename: filename, data: data, courseId: selectedCourseId,
        )

        // 시트 자체는 짧은 "시작했어요" 상태 보여준 뒤 닫힘. 더 이상 업로드 완료를 기다리지 않음.
        phase = .dispatched
        phaseMessage = "분석을 시작했어요. 학습 탭에서 진행 상태를 확인할 수 있어요."

        Task {
            try? await Task.sleep(nanoseconds: 1_300_000_000)
            await MainActor.run {
                onUploadCompleted()
                dismiss()
            }
        }
    }
}


#Preview {
    GwaTopSyllabusUploadSheet(onUploadCompleted: {})
}
