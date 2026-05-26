//
//  GwaTopFileStudyView.swift
//  GwaTop
//
//  파일 한 개를 학습할 때의 화면. 9개 학습 기능 탭(PDF/요약/퀴즈/플래시카드/마인드맵/암기/주요 주제/노트/AI 튜터).
//  현재 활성: PDF 보기, 요약. 나머지는 곧 추가 예정 placeholder.
//

import SwiftUI
import PDFKit

struct GwaTopFileStudyView: View {
    let file: GwaTopFileSummary

    enum Tab: String, CaseIterable, Identifiable {
        case pdf, summary, quiz, flashcard, mindmap, memorize, topics, notes, tutor

        var id: String { rawValue }

        var label: String {
            switch self {
            case .pdf:        return "PDF"
            case .summary:    return "요약"
            case .quiz:       return "퀴즈"
            case .flashcard:  return "플래시카드"
            case .mindmap:    return "마인드맵"
            case .memorize:   return "암기"
            case .topics:     return "주요 주제"
            case .notes:      return "노트"
            case .tutor:      return "AI 튜터"
            }
        }

        var icon: String {
            switch self {
            case .pdf:        return "doc.richtext"
            case .summary:    return "text.alignleft"
            case .quiz:       return "questionmark.diamond"
            case .flashcard:  return "rectangle.on.rectangle"
            case .mindmap:    return "circle.hexagongrid"
            case .memorize:   return "brain.head.profile"
            case .topics:     return "list.bullet.indent"
            case .notes:      return "square.and.pencil"
            case .tutor:      return "sparkles"
            }
        }

        /// 아직 구현 안 된 탭은 placeholder 안내 메시지만 보여준다.
        var isImplemented: Bool {
            self == .pdf || self == .summary
        }
    }

    @Environment(\.dismiss) private var dismiss
    @State private var selectedTab: Tab = .summary

    var body: some View {
        NavigationStack {
            ZStack {
                GwaTopHomeTheme.background.ignoresSafeArea()

                VStack(spacing: 0) {
                    fileHeader
                    tabBar
                    Divider().opacity(0.3)

                    Group {
                        switch selectedTab {
                        case .pdf:        GwaTopFilePDFTab(file: file)
                        case .summary:    GwaTopFileSummaryTab(file: file)
                        default:          comingSoonPlaceholder
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle(file.filename)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("닫기") { dismiss() }
                }
            }
        }
    }

    private var fileHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.richtext")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(GwaTopHomeTheme.primary)
                .frame(width: 40, height: 40)
                .background(GwaTopHomeTheme.primary.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(file.filename)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let w = file.week {
                    Text("\(w)주차")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(GwaTopHomeTheme.textSecondary)
                }
            }

            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.white)
    }

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Tab.allCases) { tab in
                    tabButton(tab)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .background(.white)
    }

    private func tabButton(_ tab: Tab) -> some View {
        let isSelected = selectedTab == tab
        return Button {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.86)) {
                selectedTab = tab
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: tab.icon)
                    .font(.system(size: 12, weight: .bold))
                Text(tab.label)
                    .font(.system(size: 13, weight: .semibold))
                if !tab.isImplemented {
                    Text("준비중")
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.orange.opacity(0.15))
                        .foregroundStyle(.orange)
                        .clipShape(Capsule())
                }
            }
            .foregroundStyle(isSelected ? .white : GwaTopHomeTheme.textPrimary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isSelected ? GwaTopHomeTheme.primary : Color.gray.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var comingSoonPlaceholder: some View {
        VStack(spacing: 14) {
            Image(systemName: selectedTab.icon)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(GwaTopHomeTheme.primary.opacity(0.4))
            Text("\(selectedTab.label) 기능은 준비 중이에요")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(GwaTopHomeTheme.textPrimary)
            Text(comingSoonHint)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(GwaTopHomeTheme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            // 페이지 범위 셀렉터 UI 미리보기 — 실제 동작은 기능 구현 후 활성화.
            if [.quiz, .memorize, .topics].contains(selectedTab) {
                pageScopePreview
                    .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var comingSoonHint: String {
        switch selectedTab {
        case .quiz:      return "객관식·주관식 문제를 자동으로 만들어 출제할 예정이에요."
        case .flashcard: return "어려운 개념을 카드로 만들어 '알아요/몰라요'로 분류할 수 있어요."
        case .mindmap:   return "노트 핵심 개념을 트리 형태로 시각화해드릴게요."
        case .memorize:  return "시험에 나올 만한 암기 포인트를 정리해드릴게요."
        case .topics:    return "주요 개념을 짧은 설명과 함께 정리해드릴게요."
        case .notes:     return "추가 노트나 메모를 직접 적고 저장할 수 있어요."
        case .tutor:     return "이 자료를 기반으로 AI 튜터에게 질문할 수 있어요."
        default:         return ""
        }
    }

    private var pageScopePreview: some View {
        VStack(spacing: 6) {
            Text("범위 선택 (미리보기)")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(GwaTopHomeTheme.textSecondary)
            HStack(spacing: 6) {
                Text("전체 페이지")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(GwaTopHomeTheme.primary)
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
                Text("특정 페이지 (예: 1-3)")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Color.gray.opacity(0.1))
                    .foregroundStyle(GwaTopHomeTheme.textSecondary)
                    .clipShape(Capsule())
            }
        }
    }
}

// MARK: - PDF 탭

struct GwaTopFilePDFTab: View {
    let file: GwaTopFileSummary

    @State private var pdfDocument: PDFDocument? = nil
    @State private var isLoading = false
    @State private var errorMessage: String? = nil

    var body: some View {
        ZStack {
            GwaTopHomeTheme.background

            if let doc = pdfDocument {
                GwaTopPDFKitView(document: doc)
                    .ignoresSafeArea(edges: .bottom)
            } else if let err = errorMessage {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.system(size: 24))
                    Text(err)
                        .font(.system(size: 13, weight: .semibold))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 30)
                }
            } else {
                ProgressView("PDF 불러오는 중…")
            }
        }
        .task { await load() }
    }

    @MainActor
    private func load() async {
        guard file.fileType == "pdf" else {
            errorMessage = "이 파일은 PDF 형식이 아니에요 (\(file.fileType))."
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let info = try await GwaTopFileService.shared.presignedDownloadURL(fileId: file.id)
            guard let url = URL(string: info.url) else {
                errorMessage = "다운로드 URL이 올바르지 않아요."
                return
            }
            // PDFDocument(url:) 은 동기 호출이라 백그라운드에서 수행.
            let doc = await Task.detached(priority: .userInitiated) {
                PDFDocument(url: url)
            }.value
            if let doc {
                pdfDocument = doc
            } else {
                errorMessage = "PDF를 열지 못했어요."
            }
        } catch {
            if isCancellation(error) { return }
            errorMessage = "PDF 다운로드 실패: \(error.localizedDescription)"
        }
    }
}

/// PDFKit 의 PDFView 를 SwiftUI 로 래핑.
struct GwaTopPDFKitView: UIViewRepresentable {
    let document: PDFDocument

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.document = document
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.usePageViewController(false)
        return view
    }

    func updateUIView(_ uiView: PDFView, context: Context) {
        if uiView.document !== document {
            uiView.document = document
        }
    }
}

// MARK: - 요약 탭

struct GwaTopFileSummaryTab: View {
    let file: GwaTopFileSummary

    @State private var summary: GwaTopAISummary? = nil
    @State private var status: String = "loading"
    @State private var isLoading = false
    @State private var isRegenerating = false
    @State private var errorMessage: String? = nil
    @State private var pollCount = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if isLoading && summary == nil {
                    pendingCard("요약을 불러오는 중…")
                } else if status == "pending" {
                    pendingCard("AI가 자료를 분석해 요약을 만들고 있어요. 잠시만 기다려주세요.")
                } else if let err = errorMessage {
                    errorBanner(err)
                } else if let s = summary {
                    headlineCard(s)
                    keyPointsCard(s)
                    if !s.sections.isEmpty {
                        sectionsCard(s)
                    }
                    if !s.studyTip.isEmpty {
                        studyTipCard(s)
                    }
                    regenerateButton
                }
            }
            .padding(16)
        }
        .task { await load() }
        .task(id: pollCount) {
            if pollCount > 0 && summary == nil {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                await load(silent: true)
            }
        }
    }

    private func pendingCard(_ msg: String) -> some View {
        HStack(spacing: 12) {
            ProgressView()
            Text(msg)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(GwaTopHomeTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func headlineCard(_ s: GwaTopAISummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("핵심 한 줄")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(GwaTopHomeTheme.primary)
            Text(s.headline)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(GwaTopHomeTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func keyPointsCard(_ s: GwaTopAISummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("핵심 포인트")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(GwaTopHomeTheme.textSecondary)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(s.keyPoints.enumerated()), id: \.offset) { idx, point in
                    HStack(alignment: .top, spacing: 10) {
                        Text("\(idx + 1)")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 18, height: 18)
                            .background(GwaTopHomeTheme.primary)
                            .clipShape(Circle())
                        Text(point)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(GwaTopHomeTheme.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func sectionsCard(_ s: GwaTopAISummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("섹션별 요약")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(GwaTopHomeTheme.textSecondary)
            ForEach(Array(s.sections.enumerated()), id: \.offset) { _, section in
                VStack(alignment: .leading, spacing: 4) {
                    Text(section.title)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(GwaTopHomeTheme.textPrimary)
                    Text(section.body)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(GwaTopHomeTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 4)
                Divider().opacity(0.4)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func studyTipCard(_ s: GwaTopAISummary) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lightbulb.fill")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("학습 팁")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.orange)
                Text(s.studyTip)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(GwaTopHomeTheme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var regenerateButton: some View {
        Button {
            Task { await regenerate() }
        } label: {
            HStack(spacing: 6) {
                if isRegenerating {
                    ProgressView().scaleEffect(0.7)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
                Text(isRegenerating ? "재생성 중…" : "요약 다시 만들기")
                    .font(.system(size: 13, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .foregroundStyle(GwaTopHomeTheme.primary)
            .background(GwaTopHomeTheme.primary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .disabled(isRegenerating)
        .padding(.top, 4)
    }

    private func errorBanner(_ msg: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            Text(msg)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @MainActor
    private func load(silent: Bool = false) async {
        if !silent { isLoading = true }
        defer { if !silent { isLoading = false } }
        do {
            let resp = try await GwaTopFileService.shared.aiContent(
                fileId: file.id, contentType: "summary"
            )
            status = resp.status
            summary = resp.summary()
            // pending 이면 백그라운드에서 다시 조회.
            if resp.status == "pending" && pollCount < 30 {
                pollCount += 1
            }
        } catch {
            if isCancellation(error) { return }
            errorMessage = "요약을 불러오지 못했어요: \(error.localizedDescription)"
        }
    }

    @MainActor
    private func regenerate() async {
        isRegenerating = true
        defer { isRegenerating = false }
        do {
            try await GwaTopFileService.shared.regenerateAIContent(
                fileId: file.id, contentType: "summary"
            )
            summary = nil
            status = "pending"
            pollCount += 1   // 폴링 트리거
        } catch {
            errorMessage = "재생성 요청 실패: \(error.localizedDescription)"
        }
    }
}
