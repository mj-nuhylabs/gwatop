//
//  GwaTopUploadProgress.swift
//  GwaTop
//
//  업로드를 시트(Sheet)와 분리해 전역에서 추적한다.
//  사용자가 시트 닫아도 백그라운드 업로드가 계속되며, 학습 탭 상단에 진행 카드가 표시된다.
//

import Foundation
import SwiftUI

/// 한 건의 업로드 진행 상황. 시작 → uploading → confirming → parsing(syllabus only) → done.
struct GwaTopUploadJob: Identifiable, Equatable {
    let id: String         // 클라이언트 임시 UUID
    let filename: String
    var phase: Phase
    var progress: Double   // 0.0 ~ 1.0 (uploading 단계에서만 의미 있음)
    var errorMessage: String?
    var startedAt: Date

    enum Phase: String, Equatable {
        case uploading      // S3 PUT 진행 중
        case confirming     // /confirm 호출 중
        case processing     // 백엔드 분석/요약 등 백그라운드 (사용자 화면엔 잠시 표시)
        case done
        case failed

        var label: String {
            switch self {
            case .uploading:   return "업로드 중"
            case .confirming:  return "마무리 중"
            case .processing:  return "AI 분석 중"
            case .done:        return "완료"
            case .failed:      return "실패"
            }
        }
    }
}

/// 앱 전역 업로드 진행 상태 관리. SwiftUI 가 변경을 자동 구독.
@MainActor
final class GwaTopUploadProgress: ObservableObject {
    static let shared = GwaTopUploadProgress()
    private init() {}

    @Published private(set) var jobs: [GwaTopUploadJob] = []

    var isAnyInProgress: Bool {
        jobs.contains { $0.phase == .uploading || $0.phase == .confirming || $0.phase == .processing }
    }

    @discardableResult
    func begin(filename: String) -> String {
        let id = UUID().uuidString
        let job = GwaTopUploadJob(
            id: id, filename: filename, phase: .uploading,
            progress: 0.0, errorMessage: nil, startedAt: Date(),
        )
        jobs.append(job)
        return id
    }

    func updateProgress(id: String, progress: Double) {
        guard let idx = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[idx].progress = max(0, min(1, progress))
    }

    func setPhase(id: String, phase: GwaTopUploadJob.Phase) {
        guard let idx = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[idx].phase = phase
        if phase == .done || phase == .failed {
            // 5초 후 자동 제거 — 사용자가 결과 확인할 시간.
            let toRemoveId = jobs[idx].id
            Task {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                await MainActor.run {
                    self.jobs.removeAll { $0.id == toRemoveId }
                }
            }
        }
    }

    func fail(id: String, message: String) {
        guard let idx = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[idx].phase = .failed
        jobs[idx].errorMessage = message
        let toRemoveId = jobs[idx].id
        Task {
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            await MainActor.run {
                self.jobs.removeAll { $0.id == toRemoveId }
            }
        }
    }

    func dismiss(id: String) {
        jobs.removeAll { $0.id == id }
    }

    // MARK: - 업로드 진행 헬퍼

    /// 강의계획서 업로드 시작. 시트가 즉시 닫혀도 백그라운드에서 계속 진행된다.
    /// Task 는 이 singleton 에 묶여 있어 View 가 사라져도 cancel 되지 않음.
    func startSyllabusUpload(filename: String, data: Data, courseId: String?) {
        let jobId = begin(filename: filename)
        // phase=uploading 으로 시작 (begin 이 그렇게 설정)
        updateProgress(id: jobId, progress: 0.15)  // 시각적 진행 단서

        Task { [weak self] in
            guard let self else { return }
            do {
                let fileId: String
                if let courseId {
                    fileId = try await GwaTopFileUploadService.shared.upload(
                        courseId: courseId, filename: filename,
                        fileType: "pdf", data: data, isSyllabus: true,
                    )
                } else {
                    fileId = try await GwaTopFileUploadService.shared.uploadSyllabusWithoutCourse(
                        filename: filename, data: data,
                    )
                }
                self.updateProgress(id: jobId, progress: 0.85)
                self.setPhase(id: jobId, phase: .confirming)
                try? await Task.sleep(nanoseconds: 500_000_000)
                self.updateProgress(id: jobId, progress: 1.0)
                self.setPhase(id: jobId, phase: .processing)
                // 캘린더에 알림 — watcher 가 파싱 완료 시 자동 reload.
                GwaTopSyllabusWatcher.shared.notifyUploaded(fileId: fileId)
                // 백엔드 파싱·분석은 평균 15~30초. 이 시간 동안 카드 표시.
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                self.setPhase(id: jobId, phase: .done)
            } catch {
                let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                self.fail(id: jobId, message: msg)
            }
        }
    }

    /// 일반 강의 자료 업로드 (학습 자료 탭 — syllabus 아님).
    func startMaterialUpload(filename: String, data: Data, fileType: String, courseId: String) {
        let jobId = begin(filename: filename)
        updateProgress(id: jobId, progress: 0.15)

        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await GwaTopFileUploadService.shared.upload(
                    courseId: courseId, filename: filename,
                    fileType: fileType, data: data, isSyllabus: false,
                )
                self.updateProgress(id: jobId, progress: 1.0)
                self.setPhase(id: jobId, phase: .processing)
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                self.setPhase(id: jobId, phase: .done)
            } catch {
                let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                self.fail(id: jobId, message: msg)
            }
        }
    }
}

// MARK: - 진행 카드 (학습/캘린더 탭 상단에 표시)

struct GwaTopUploadProgressBanner: View {
    @ObservedObject private var tracker = GwaTopUploadProgress.shared

    var body: some View {
        if tracker.jobs.isEmpty {
            EmptyView()
        } else {
            VStack(spacing: 8) {
                ForEach(tracker.jobs) { job in
                    bannerRow(job)
                }
            }
        }
    }

    @ViewBuilder
    private func bannerRow(_ job: GwaTopUploadJob) -> some View {
        HStack(spacing: 12) {
            iconFor(job.phase)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(backgroundColor(job.phase))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(job.filename)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(statusText(job))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(GwaTopHomeTheme.textSecondary)

                if job.phase == .uploading {
                    ProgressView(value: job.progress)
                        .progressViewStyle(.linear)
                        .tint(GwaTopHomeTheme.primary)
                        .frame(height: 3)
                }
            }

            Spacer()

            if job.phase == .done || job.phase == .failed {
                Button {
                    GwaTopUploadProgress.shared.dismiss(id: job.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(GwaTopHomeTheme.textSecondary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.06), radius: 8, y: 3)
    }

    private func statusText(_ job: GwaTopUploadJob) -> String {
        switch job.phase {
        case .uploading:
            return "업로드 중 \(Int(job.progress * 100))%"
        case .confirming:
            return "서버에 등록 중…"
        case .processing:
            return "AI 분석 중 (시간이 좀 걸려요)"
        case .done:
            return "완료"
        case .failed:
            return job.errorMessage ?? "실패"
        }
    }

    private func iconFor(_ phase: GwaTopUploadJob.Phase) -> Image {
        switch phase {
        case .uploading:   return Image(systemName: "arrow.up.circle.fill")
        case .confirming:  return Image(systemName: "ellipsis.circle.fill")
        case .processing:  return Image(systemName: "sparkles")
        case .done:        return Image(systemName: "checkmark.circle.fill")
        case .failed:      return Image(systemName: "exclamationmark.circle.fill")
        }
    }

    private func backgroundColor(_ phase: GwaTopUploadJob.Phase) -> Color {
        switch phase {
        case .uploading, .confirming, .processing: return GwaTopHomeTheme.primary
        case .done:    return .green
        case .failed:  return .red
        }
    }
}
