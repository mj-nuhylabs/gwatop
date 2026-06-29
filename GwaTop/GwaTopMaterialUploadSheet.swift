//
//  GwaTopMaterialUploadSheet.swift
//  GwaTop
//
//  S-1 강의 자료 업로드 시트.
//  과목을 선택하고 PDF/PPT/DOCX 파일을 업로드하면 백엔드에서 자동 분류된다.
//  강의계획서가 아니라 일반 강의 자료 업로드 진입점이다.
//

import SwiftUI
import UniformTypeIdentifiers

struct GwaTopMaterialUploadSheet: View {
    /// 시트 진입 시 미리 선택할 과목 id. 과목 상세에서 열 때 그 과목으로 고정된다.
    /// nil 이면 첫 번째 과목이 기본 선택된다.
    var preselectedCourseId: String? = nil
    var onUploadCompleted: () -> Void = {}

    @Environment(\.dismiss) private var dismiss

    @State private var courses: [GwaTopCourseDTO] = []
    @State private var selectedCourseId: String? = nil
    @State private var isLoadingCourses = false
    @State private var loadError: String? = nil

    @State private var showingFileImporter = false
    @State private var isUploading = false
    @State private var uploadMessage: String? = nil
    @State private var uploadError: String? = nil

    private static let allowedTypes: [UTType] = {
        var t: [UTType] = [.pdf]
        if let pptx = UTType(filenameExtension: "pptx") { t.append(pptx) }
        if let docx = UTType(filenameExtension: "docx") { t.append(docx) }
        return t
    }()

    var body: some View {
        NavigationStack {
            ZStack {
                GwaTopHomeTheme.background.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 22) {
                        header

                        courseCard

                        actionCard

                        if let uploadMessage {
                            successBanner(uploadMessage)
                        }
                        if let uploadError {
                            errorBanner(uploadError)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 24)
                }

                if isUploading {
                    Color.black.opacity(0.35).ignoresSafeArea()
                    VStack(spacing: 12) {
                        ProgressView().tint(.white).scaleEffect(1.4)
                        Text("업로드 중…")
                            .font(.gwaTopSystem(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }
            }
            .navigationTitle("강의 자료 업로드")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("닫기") { dismiss() }
                        .disabled(isUploading)
                }
            }
            .task {
                await loadCoursesIfNeeded()
            }
            .fileImporter(
                isPresented: $showingFileImporter,
                allowedContentTypes: Self.allowedTypes,
                allowsMultipleSelection: false
            ) { result in
                handleFileImport(result: result)
            }
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("AI 자동 분류")
                .font(.gwaTopSystem(size: 13, weight: .bold))
                .foregroundStyle(GwaTopHomeTheme.primary)
            Text("강의 자료를 업로드하면 주차별로 자동 정리돼요.")
                .font(.gwaTopSystem(size: 18, weight: .bold))
                .foregroundStyle(.primary)
            Text("PDF / PPTX / DOCX 지원. 업로드 후 백엔드에서 텍스트 추출과 임베딩 기반 분류를 진행합니다.")
                .font(.gwaTopSystem(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .gwaTopCard(radius: 22)
    }

    private var courseCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("어느 과목인가요?")
                .font(.gwaTopSystem(size: 15, weight: .bold))
                .foregroundStyle(.primary)

            if isLoadingCourses {
                HStack {
                    ProgressView()
                    Text("과목 불러오는 중…")
                        .font(.gwaTopSystem(size: 13))
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 12)
            } else if let loadError {
                Text(loadError)
                    .font(.gwaTopSystem(size: 13, weight: .semibold))
                    .foregroundStyle(GwaTopHomeTheme.danger)
            } else if courses.isEmpty {
                Text("등록된 과목이 없어요. 먼저 학기/과목을 추가해 주세요.")
                    .font(.gwaTopSystem(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(courses) { course in
                    courseRow(course)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .gwaTopCard(radius: 22)
    }

    private func courseRow(_ course: GwaTopCourseDTO) -> some View {
        let isSelected = selectedCourseId == course.id
        return Button {
            selectedCourseId = course.id
        } label: {
            HStack(spacing: 12) {
                Circle()
                    .fill(course.color.map(Color.gwaTopHex) ?? .gray.opacity(0.4))
                    .frame(width: 14, height: 14)

                VStack(alignment: .leading, spacing: 2) {
                    Text(course.name)
                        .font(.gwaTopSystem(size: 15, weight: .semibold))
                        .foregroundStyle(.primary)
                    if let prof = course.professor, !prof.isEmpty {
                        Text(prof)
                            .font(.gwaTopSystem(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.gwaTopSystem(size: 18, weight: .bold))
                    .foregroundStyle(isSelected ? GwaTopHomeTheme.primary : GwaTopHomeTheme.textTertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isSelected ? GwaTopHomeTheme.primary.opacity(0.08) : GwaTopHomeTheme.surfaceMute)
            )
        }
        .buttonStyle(.plain)
    }

    private var actionCard: some View {
        VStack(spacing: 12) {
            Button {
                showingFileImporter = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "doc.badge.plus")
                        .font(.gwaTopSystem(size: 18, weight: .bold))
                    Text("파일 선택")
                }
            }
            .gwaTopPrimaryButton(size: .large)
            .opacity(selectedCourseId == nil || isUploading ? 0.55 : 1.0)
            .disabled(selectedCourseId == nil || isUploading)

            Text("강의계획서(syllabus)는 캘린더 탭에서 따로 업로드해 주세요.")
                .font(.gwaTopSystem(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(18)
        .gwaTopCard(radius: 22)
    }

    private func successBanner(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(GwaTopHomeTheme.success)
                    .font(.gwaTopSystem(size: 18, weight: .bold))
                Text(message)
                    .font(.gwaTopSystem(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button {
                onUploadCompleted()
                dismiss()
            } label: {
                HStack {
                    Image(systemName: "folder.fill")
                    Text("내 강의 자료 보기")
                        .font(.gwaTopSystem(size: 14, weight: .bold))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.gwaTopSystem(size: 12, weight: .bold))
                }
                .foregroundStyle(GwaTopHomeTheme.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(GwaTopHomeTheme.primary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GwaTopHomeTheme.success.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(GwaTopHomeTheme.danger)
                .font(.gwaTopSystem(size: 18, weight: .bold))
            Text(message)
                .font(.gwaTopSystem(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GwaTopHomeTheme.danger.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
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
            loadError = "과목 목록을 불러오지 못했어요: \(error.localizedDescription)"
        }
    }

    private func handleFileImport(result: Result<[URL], Error>) {
        uploadError = nil
        uploadMessage = nil
        switch result {
        case .failure(let error):
            uploadError = "파일 선택 실패: \(error.localizedDescription)"
        case .success(let urls):
            guard let url = urls.first else { return }
            Task { @MainActor in
                await uploadFile(url: url)
            }
        }
    }

    @MainActor
    private func uploadFile(url: URL) async {
        guard let courseId = selectedCourseId else {
            uploadError = "과목을 먼저 선택해 주세요."
            return
        }

        let needsSecurityScope = url.startAccessingSecurityScopedResource()
        defer { if needsSecurityScope { url.stopAccessingSecurityScopedResource() } }

        let filename = url.lastPathComponent
        let fileType = inferFileType(from: url)

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            uploadError = "파일을 읽지 못했어요: \(error.localizedDescription)"
            return
        }

        // 업로드를 전역 GwaTopUploadProgress 에 위임 — 시트가 닫혀도 백그라운드에서 계속.
        // 사용자는 즉시 시트가 닫히고, 학습 탭 상단의 작은 진행 카드만 본다.
        GwaTopUploadProgress.shared.startMaterialUpload(
            filename: filename, data: data, fileType: fileType, courseId: courseId,
        )

        uploadMessage = "‘\(filename)’ 업로드를 시작했어요. 학습 탭 상단에서 진행 상태를 확인할 수 있어요."

        // 짧은 토스트 효과 후 시트 자동 dismiss.
        Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            await MainActor.run {
                onUploadCompleted()
                dismiss()
            }
        }
    }

    private func inferFileType(from url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "pdf":   return "pdf"
        case "pptx":  return "pptx"
        case "docx":  return "docx"
        case "jpg", "jpeg", "png", "heic": return "image"
        default:      return "other"
        }
    }

}

#Preview {
    GwaTopMaterialUploadSheet()
}
