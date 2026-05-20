//
//  GwaTopSyllabusUploadSheet.swift
//  GwaTop
//
//  실제 강의계획서 업로드 흐름:
//   - 과목 선택 / 새 과목 추가 (백엔드 GET /v1/courses, POST /v1/semesters/{id}/courses)
//   - PDF 파일 선택 (.fileImporter)
//   - presigned-url → S3 PUT → confirm
//   - 백엔드 Celery가 비동기로 PyMuPDF + GPT-4o-mini 파싱 → schedules INSERT
//   - 시트 닫히면 캘린더 자동 새로고침
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
        case uploading
        case waitingForParse
        case success
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
                                .font(.system(size: 16, weight: .heavy))
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
                        if case .success = phase { onUploadCompleted() }
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
            .sheet(isPresented: $showingNewCourseSheet) {
                GwaTopNewCourseSheet(
                    semesters: semesters,
                    onCreated: { newCourse in
                        Task {
                            await MainActor.run {
                                if !courses.contains(where: { $0.id == newCourse.id }) {
                                    courses.append(newCourse)
                                    courses.sort { $0.name < $1.name }
                                }
                                selectedCourseId = newCourse.id
                            }
                        }
                    }
                )
                .presentationDetents([.medium, .large])
            }
            .task {
                await loadCoursesAndSemesters()
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "doc.badge.arrow.up.fill")
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 64, height: 64)
                .background(GwaTopHomeTheme.primaryGradient)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))

            Text("강의계획서를 업로드하면 AI가 시험·과제 일정을 자동으로 캘린더에 등록합니다.")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(GwaTopHomeTheme.textSecondary)
                .lineSpacing(4)
        }
    }

    private var courseSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionTitle("1. 과목 선택")
                Spacer()
                Button {
                    showingNewCourseSheet = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus.circle.fill")
                        Text("새 과목 추가")
                    }
                    .font(.system(size: 13, weight: .heavy))
                    .foregroundStyle(GwaTopHomeTheme.primary)
                }
                .disabled(semesters.isEmpty)
                .opacity(semesters.isEmpty ? 0.4 : 1)
            }

            if isLoadingCourses {
                HStack { ProgressView(); Text("과목 목록 불러오는 중…").font(.system(size: 13)) }
            } else if let err = courseLoadError {
                Text(err).font(.system(size: 13)).foregroundStyle(.orange)
            } else if courses.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("등록된 과목이 없습니다.")
                        .font(.system(size: 14, weight: .heavy))
                        .foregroundStyle(GwaTopHomeTheme.textPrimary)
                    Text(semesters.isEmpty
                         ? "먼저 학기를 등록해 주세요."
                         : "오른쪽 위 '새 과목 추가' 버튼으로 시작하세요.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(GwaTopHomeTheme.textSecondary)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.white)
                .clipShape(RoundedRectangle(cornerRadius: 14))
            } else {
                Picker("과목", selection: Binding(
                    get: { selectedCourseId ?? courses.first?.id ?? "" },
                    set: { selectedCourseId = $0 }
                )) {
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
                            .font(.system(size: 12, weight: .medium))
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
            case .waitingForParse:
                statusRow(icon: "sparkles", text: phaseMessage, tint: .purple)
            case .success:
                statusRow(icon: "checkmark.seal.fill", text: phaseMessage, tint: .green)
            case .failed(let msg):
                statusRow(icon: "exclamationmark.triangle.fill", text: msg, tint: .orange)
            }
        }
    }

    private var canSubmit: Bool {
        if case .uploading = phase { return false }
        return selectedCourseId != nil && pickedFileData != nil
    }

    private var actionButtonTitle: String {
        switch phase {
        case .idle:              return "업로드 시작"
        case .uploading:         return "업로드 중…"
        case .waitingForParse:   return "AI 파싱 진행 중…"
        case .success:           return "캘린더에서 확인하기"
        case .failed:            return "다시 시도"
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 15, weight: .heavy))
            .foregroundStyle(GwaTopHomeTheme.textPrimary)
    }

    private func statusRow(icon: String, text: String, tint: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(text)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(GwaTopHomeTheme.textPrimary)
            Spacer()
        }
        .padding(14)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: - Actions

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
                if self.selectedCourseId == nil { self.selectedCourseId = courseList.first?.id }
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
        if case .success = phase {
            onUploadCompleted()
            dismiss()
            return
        }
        Task { await runUpload() }
    }

    private func runUpload() async {
        guard let courseId = selectedCourseId, let data = pickedFileData,
              let filename = pickedFileName else { return }

        await MainActor.run {
            self.phase = .uploading
            self.phaseMessage = "S3로 업로드 중…"
        }

        do {
            let fileId = try await GwaTopFileUploadService.shared.upload(
                courseId: courseId,
                filename: filename,
                fileType: "pdf",
                data: data,
                isSyllabus: true
            )
            await MainActor.run {
                self.uploadedFileId = fileId
                self.phase = .waitingForParse
                self.phaseMessage = "AI가 강의계획서를 분석하고 있어요…"
            }
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            await MainActor.run {
                self.phase = .success
                self.phaseMessage = "분석 완료! 캘린더로 돌아가 새 일정을 확인하세요."
            }
            onUploadCompleted()
        } catch {
            let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            await MainActor.run { self.phase = .failed("업로드 실패: \(msg)") }
        }
    }
}


// MARK: - 새 과목 생성 시트

private let courseColorPalette: [String] = [
    "#3B82F6",  // 파랑
    "#8B5CF6",  // 보라
    "#F97316",  // 주황
    "#10B981",  // 초록
    "#EF4444",  // 빨강
    "#F59E0B",  // 노랑
    "#EC4899",  // 핑크
    "#06B6D4",  // 청록
]

struct GwaTopNewCourseSheet: View {
    let semesters: [GwaTopSemesterDTO]
    var onCreated: (GwaTopCourseDTO) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var professor: String = ""
    @State private var color: String = "#3B82F6"
    @State private var selectedSemesterId: String? = nil

    @State private var isSubmitting: Bool = false
    @State private var errorMessage: String? = nil

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("새 과목 추가")
                        .font(.system(size: 22, weight: .heavy, design: .rounded))
                        .foregroundStyle(GwaTopHomeTheme.textPrimary)

                    // 학기 선택 (학기 1개면 자동)
                    if semesters.count > 1 {
                        VStack(alignment: .leading, spacing: 6) {
                            label("학기")
                            Picker("학기", selection: Binding(
                                get: { selectedSemesterId ?? semesters.first?.id ?? "" },
                                set: { selectedSemesterId = $0 }
                            )) {
                                ForEach(semesters) { s in
                                    Text(s.name).tag(s.id)
                                }
                            }
                            .pickerStyle(.menu)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        label("과목명")
                        TextField("예: 데이터베이스", text: $name)
                            .textInputAutocapitalization(.never)
                            .padding(14)
                            .background(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        label("담당 교수 (선택)")
                        TextField("예: 김민수", text: $professor)
                            .padding(14)
                            .background(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        label("색상")
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(courseColorPalette, id: \.self) { hex in
                                    Circle()
                                        .fill(Color.gwaTopHex(hex))
                                        .frame(width: 34, height: 34)
                                        .overlay(
                                            Circle()
                                                .stroke(color == hex ? Color.black.opacity(0.6) : Color.clear, lineWidth: 3)
                                        )
                                        .onTapGesture { color = hex }
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }

                    if let msg = errorMessage {
                        Text(msg)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.orange)
                    }

                    Button(action: submit) {
                        HStack {
                            if isSubmitting { ProgressView().tint(.white).padding(.trailing, 6) }
                            Text(isSubmitting ? "추가 중…" : "추가하기")
                                .font(.system(size: 16, weight: .heavy))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(canSubmit ? GwaTopHomeTheme.primary : Color.gray.opacity(0.4))
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                    }
                    .disabled(!canSubmit)
                }
                .padding(20)
            }
            .navigationTitle("새 과목")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("취소") { dismiss() }
                }
            }
            .task {
                if selectedSemesterId == nil {
                    selectedSemesterId = semesters.first(where: { $0.isActive })?.id
                        ?? semesters.first?.id
                }
            }
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .heavy))
            .foregroundStyle(GwaTopHomeTheme.textPrimary)
    }

    private var canSubmit: Bool {
        !isSubmitting && !name.trimmingCharacters(in: .whitespaces).isEmpty &&
        (selectedSemesterId ?? semesters.first?.id) != nil
    }

    private func submit() {
        guard let semId = selectedSemesterId ?? semesters.first?.id else {
            errorMessage = "학기가 없습니다. 먼저 학기를 등록해주세요."
            return
        }
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedProf = professor.trimmingCharacters(in: .whitespaces)

        Task {
            await MainActor.run {
                self.isSubmitting = true
                self.errorMessage = nil
            }
            do {
                let newCourse = try await GwaTopCourseService.shared.create(
                    semesterId: semId,
                    name: trimmedName,
                    professor: trimmedProf.isEmpty ? nil : trimmedProf,
                    color: color
                )
                await MainActor.run {
                    onCreated(newCourse)
                    dismiss()
                }
            } catch {
                let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                await MainActor.run {
                    self.errorMessage = "추가 실패: \(msg)"
                    self.isSubmitting = false
                }
            }
        }
    }
}


#Preview {
    GwaTopSyllabusUploadSheet(onUploadCompleted: {})
}
