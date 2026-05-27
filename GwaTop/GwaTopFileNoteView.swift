//
//  GwaTopFileNoteView.swift
//  GwaTop
//
//  S-3 파일 뷰어 — 추출된 텍스트(필기 노트)를 보여준다.
//  분류 결과(주차, confidence, source)와 처리 상태도 함께 표시한다.
//

import SwiftUI

struct GwaTopFileNoteView: View {
    let file: GwaTopFileSummary

    @Environment(\.dismiss) private var dismiss

    @State private var debug: GwaTopFileDebug? = nil
    @State private var fullText: String? = nil
    @State private var isLoading = false
    @State private var errorMessage: String? = nil

    var body: some View {
        NavigationStack {
            ZStack {
                GwaTopHomeTheme.background.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        headerCard
                        statusCard

                        if isLoading && debug == nil {
                            ProgressView("필기 노트 불러오는 중…")
                                .padding(.top, 40)
                                .frame(maxWidth: .infinity)
                        } else if let err = errorMessage {
                            errorBanner(err)
                        } else if let debug {
                            noteCard(debug)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 22)
                }
            }
            .navigationTitle("필기 노트")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("닫기") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await reload() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(isLoading)
                }
            }
            .task { await reload() }
        }
    }

    // MARK: - UI

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(debug?.course.name ?? "강의 자료")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.blue)
            Text(file.filename)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.primary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .gwaTopCard(radius: 18)
    }

    private var statusCard: some View {
        let badge = GwaTopFileStatusBadge.from(file)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text(badge.label)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(badge.color)
                    .clipShape(Capsule())

                if let src = file.classificationSource {
                    Label(GwaTopClassificationSource.label(src), systemImage: src == "embedding" ? "sparkles" : (src == "filename" ? "textformat" : "hand.tap"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }

            if let conf = file.aiConfidence, file.status == "classified" {
                ProgressView(value: max(0, min(1, conf)))
                    .tint(.green)
                Text("자동 분류 신뢰도: \(Int(conf * 100))%")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            if let err = file.parseError {
                Text("⚠️ \(err)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.red)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .gwaTopCard(radius: 16)
    }

    private func noteCard(_ d: GwaTopFileDebug) -> some View {
        let preview = d.file.extractedTextPreview
        let length = d.file.extractedTextLength
        let body = fullText ?? preview

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "doc.text.magnifyingglass")
                    .foregroundStyle(.blue)
                Text("추출된 텍스트")
                    .font(.system(size: 14, weight: .bold))
                Spacer()
                Text("\(length) 자")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }

            if body.isEmpty {
                Text(d.file.isSyllabus
                     ? "강의계획서는 별도 파싱 파이프라인을 통해 일정으로 변환됩니다."
                     : "아직 추출된 텍스트가 없어요. 파일이 PDF가 아니거나 처리 중일 수 있어요.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 12)
            } else {
                Text(body)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }

            if fullText == nil && length > preview.count {
                Text("미리보기 500자만 표시됨")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .gwaTopCard(radius: 18)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            Text(message)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Actions

    @MainActor
    private func reload() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            debug = try await GwaTopFileService.shared.fetchDebug(fileId: file.id)
        } catch {
            errorMessage = "필기 노트를 불러오지 못했어요: \(error.localizedDescription)"
        }
    }

}
