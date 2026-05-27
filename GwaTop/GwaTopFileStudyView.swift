//
//  GwaTopFileStudyView.swift
//  GwaTop
//
//  파일 한 개를 학습할 때의 화면. 9개 학습 기능 탭(PDF/요약/퀴즈/플래시카드/마인드맵/암기/주요 주제/노트/AI 튜터).
//  현재 활성: PDF 보기, 요약. 나머지는 곧 추가 예정 placeholder.
//

import Combine
import PDFKit
import SwiftUI

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

        /// 모든 탭 구현 완료. (placeholder 표기 제거)
        var isImplemented: Bool { true }
    }

    @Environment(\.dismiss) private var dismiss
    @State private var selectedTab: Tab = .summary

    var body: some View {
        NavigationStack {
            ZStack {
                GwaTopHomeTheme.background.ignoresSafeArea()

                VStack(spacing: 0) {
                    fileHeader
                    // 네트워크가 느리거나 끊기면 사용자에게 알림 (AI 응답 지연 사전 안내).
                    GwaTopNetworkBanner()
                        .padding(.bottom, 6)
                    tabBar
                    Divider().opacity(0.3)

                    Group {
                        switch selectedTab {
                        case .pdf:        GwaTopFilePDFTab(file: file)
                        case .summary:    GwaTopFileSummaryTab(file: file)
                        case .quiz:       GwaTopFileQuizTab(file: file)
                        case .flashcard:  GwaTopFileFlashcardTab(file: file)
                        case .mindmap:    GwaTopFileMindmapTab(file: file)
                        case .memorize:   GwaTopFileMemorizeTab(file: file)
                        case .topics:     GwaTopFileTopicsTab(file: file)
                        case .notes:      GwaTopFileNotesTab(file: file)
                        case .tutor:      GwaTopFileTutorTab(file: file)
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
            .task {
                // 0) 이전에 같은 파일을 닫고 다시 들어온 경우 자동 정리 타이머 취소 — 캐시 재사용.
                GwaTopPDFCache.shared.cancelEviction(fileId: file.id)

                // 1) AI 콘텐츠 prefetch 큐잉 (서버 POST 한 번, ~50ms).
                //    5종 학습 콘텐츠를 'all' scope 으로 미리 만들어 둠.
                //    시작 버튼 클릭 시점엔 캐시 hit 확률이 매우 높아 ~1초 안에 결과 표시.
                await GwaTopFileService.shared.prefetchAIContents(fileId: file.id)

                // 2) 사용자 첫 화면(요약 탭)이 자체 .task 로 summary HTTP 호출 중.
                //    PDF 다운로드(보통 1~5MB)가 같이 시작하면 대역폭 경쟁으로 요약 표시가 늦어짐.
                //    2초 양보 → summary HTTP (수 KB)가 먼저 완료될 시간 확보.
                try? await Task.sleep(nanoseconds: 2_000_000_000)

                // 3) PDF 백그라운드 다운로드 → PDF 탭 누르는 시점엔 캐시 hit.
                //    퀴즈/플래시카드 등 생성 탭이 generate 호출 시 자동으로 suspend → resume.
                GwaTopPDFCache.shared.load(fileId: file.id, fileType: file.fileType)
            }
            .onDisappear {
                // 파일 학습 화면을 닫으면 N분 후 PDF 메모리 자동 정리.
                // 그 안에 같은 파일로 다시 들어오면 .task 의 cancelEviction 이 취소.
                GwaTopPDFCache.shared.scheduleEviction(fileId: file.id)
            }
        }
    }

    private var fileHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.text")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(GwaTopHomeTheme.primary)
                .frame(width: 32, height: 32)
                .background(GwaTopHomeTheme.primary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(file.filename)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(GwaTopHomeTheme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let w = file.week {
                    Text("\(w)주차")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(GwaTopHomeTheme.textSecondary)
                }
            }

            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(GwaTopHomeTheme.surface)
    }

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(Tab.allCases) { tab in
                    tabButton(tab)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)
        }
        .background(GwaTopHomeTheme.surface)
    }

    private func tabButton(_ tab: Tab) -> some View {
        let isSelected = selectedTab == tab
        return Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                selectedTab = tab
            }
        } label: {
            VStack(spacing: 5) {
                HStack(spacing: 5) {
                    Image(systemName: tab.icon)
                        .font(.system(size: 12, weight: .semibold))
                    Text(tab.label)
                        .font(.system(size: 14, weight: .semibold))
                }
                .foregroundStyle(isSelected ? GwaTopHomeTheme.textPrimary : GwaTopHomeTheme.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                // 미세한 인디케이터 — 선택 탭에만 헤어라인 액센트.
                Capsule()
                    .fill(isSelected ? GwaTopHomeTheme.primary : Color.clear)
                    .frame(height: 2)
                    .padding(.horizontal, 8)
            }
        }
        .buttonStyle(.plain)
    }

    // placeholder UI는 모든 탭이 구현되면서 제거됨.
    @available(*, deprecated, message: "All tabs are now implemented; this helper is no longer used.")
    private var _legacy_placeholder: some View {
        EmptyView()
    }
}

// MARK: - PDF 탭 (launcher)

/// 탭 진입 화면 — 짧은 인트로 카드 + "PDF 보기" 큰 버튼. 누르면 fullScreenCover 로
/// GwaTopPDFPlayerView 가 떠서 검색·페이지 이동·확대/축소 도구와 함께 PDF 를 크게 표시한다.
struct GwaTopFilePDFTab: View {
    let file: GwaTopFileSummary

    @ObservedObject private var cache = GwaTopPDFCache.shared
    @State private var showingPlayer = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                introCard
                Button {
                    showingPlayer = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "doc.richtext.fill")
                        Text("PDF 보기")
                            .font(.system(size: 17, weight: .bold))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity).frame(height: 52)
                    .background(file.fileType == "pdf"
                                ? GwaTopHomeTheme.primary
                                : Color.gray.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .shadow(color: GwaTopHomeTheme.primary.opacity(0.3), radius: 8, y: 4)
                }
                .disabled(file.fileType != "pdf")
            }
            .padding(16)
        }
        .fullScreenCover(isPresented: $showingPlayer) {
            GwaTopPDFPlayerView(file: file)
        }
        .task {
            // 캐시가 비어 있으면 백그라운드 로드 시작. FileStudyView.task 에서도 호출하지만
            // idempotent 라 안전하게 한 번 더 — 사용자가 PDF 탭만 직접 누른 경우 대비.
            cache.load(fileId: file.id, fileType: file.fileType)
        }
    }

    private var introCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("원본 PDF")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(GwaTopHomeTheme.primary)
            if file.fileType == "pdf" {
                Text("PDF 를 크게 보면서 검색·페이지 이동·확대/축소 도구를 사용할 수 있어요.")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(GwaTopHomeTheme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("핀치 줌, 페이지 번호 입력으로 이동, 검색 결과 하이라이트 지원.")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(GwaTopHomeTheme.textSecondary)
            } else {
                Text("이 파일은 PDF 형식이 아니에요 (\(file.fileType)).")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.orange)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

// MARK: - PDF Player ViewModel

/// PDF 플레이어 상태 + PDFKit 명령적 API 래퍼.
/// PDFView 는 명령적이라 SwiftUI 의 단방향 데이터로 표현하기 어렵다 — 여기서 model 이
/// PDFView 참조(weak)를 들고 ViewModel 메서드로 명령을 발행한다.
@MainActor
final class GwaTopPDFPlayerViewModel: ObservableObject {
    @Published var currentPage: Int = 0       // 0-indexed
    @Published var totalPages: Int = 0
    @Published var searchText: String = ""
    @Published var searchResults: [PDFSelection] = []
    @Published var currentSearchIndex: Int = 0
    @Published var scaleFactor: CGFloat = 1.0

    weak var pdfView: PDFView?

    func attach(_ view: PDFView) {
        self.pdfView = view
        if let doc = view.document {
            self.totalPages = doc.pageCount
            if let cur = view.currentPage {
                self.currentPage = doc.index(for: cur)
            }
        }
        self.scaleFactor = view.scaleFactor
    }

    /// PDFViewPageChanged 알림에서 호출. 현재 페이지 인덱스를 동기화.
    func didChangePage() {
        guard let view = pdfView, let doc = view.document, let page = view.currentPage else { return }
        let idx = doc.index(for: page)
        if idx != currentPage { currentPage = idx }
    }

    func performSearch() {
        guard let view = pdfView, let doc = view.document else { return }
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            searchResults = []
            view.highlightedSelections = []
            return
        }
        // findString — 동기 검색. 학습용 PDF 크기(~50p) 면 즉시. options 는 대소문자 무시.
        let results = doc.findString(q, withOptions: [.caseInsensitive])
        searchResults = results
        currentSearchIndex = 0
        view.highlightedSelections = results
        if let first = results.first {
            view.go(to: first)
            view.setCurrentSelection(first, animate: true)
        }
    }

    func clearSearch() {
        searchText = ""
        searchResults = []
        currentSearchIndex = 0
        pdfView?.highlightedSelections = []
    }

    func nextResult() {
        guard let view = pdfView, !searchResults.isEmpty else { return }
        currentSearchIndex = (currentSearchIndex + 1) % searchResults.count
        let sel = searchResults[currentSearchIndex]
        view.go(to: sel)
        view.setCurrentSelection(sel, animate: true)
    }

    func prevResult() {
        guard let view = pdfView, !searchResults.isEmpty else { return }
        currentSearchIndex = (currentSearchIndex - 1 + searchResults.count) % searchResults.count
        let sel = searchResults[currentSearchIndex]
        view.go(to: sel)
        view.setCurrentSelection(sel, animate: true)
    }

    func goToPage(_ idx: Int) {
        guard let view = pdfView, let doc = view.document,
              idx >= 0, idx < doc.pageCount,
              let page = doc.page(at: idx) else { return }
        view.go(to: page)
        currentPage = idx
    }

    func zoomIn() {
        guard let view = pdfView else { return }
        let new = min(view.scaleFactor * 1.25, view.maxScaleFactor)
        view.scaleFactor = new
        scaleFactor = new
    }

    func zoomOut() {
        guard let view = pdfView else { return }
        let new = max(view.scaleFactor / 1.25, view.minScaleFactor)
        view.scaleFactor = new
        scaleFactor = new
    }
}

// MARK: - PDF Player View

/// fullScreenCover 로 띄우는 PDF 플레이어. 상단 toolbar(닫기/검색/확대축소),
/// 검색바(토글), PDFKit view, 하단 페이지 컨트롤(이전/번호 탭→이동/다음).
struct GwaTopPDFPlayerView: View {
    let file: GwaTopFileSummary

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var cache = GwaTopPDFCache.shared
    @StateObject private var model = GwaTopPDFPlayerViewModel()

    @State private var showingSearch: Bool = false
    @State private var showingPageInput: Bool = false
    @State private var pageInputText: String = ""

    var body: some View {
        NavigationStack {
            ZStack {
                GwaTopHomeTheme.background.ignoresSafeArea()

                if let doc = cache.document(for: file.id) {
                    VStack(spacing: 0) {
                        if showingSearch {
                            searchBar.transition(.move(edge: .top).combined(with: .opacity))
                        }
                        GwaTopPDFKitPlayerView(document: doc, model: model)
                            .ignoresSafeArea(edges: .bottom)
                        bottomControls
                    }
                } else {
                    VStack(spacing: 14) {
                        ProgressView()
                        Text("PDF 불러오는 중…")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(GwaTopHomeTheme.textSecondary)
                    }
                }
            }
            .navigationTitle(file.filename)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("닫기") { dismiss() }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showingSearch.toggle()
                        }
                        if !showingSearch { model.clearSearch() }
                    } label: {
                        Image(systemName: showingSearch ? "xmark.circle.fill" : "magnifyingglass")
                    }
                    Button { model.zoomOut() } label: {
                        Image(systemName: "minus.magnifyingglass")
                    }
                    Button { model.zoomIn() } label: {
                        Image(systemName: "plus.magnifyingglass")
                    }
                }
            }
            .alert("페이지 이동", isPresented: $showingPageInput) {
                TextField("페이지 번호", text: $pageInputText)
                    .keyboardType(.numberPad)
                Button("취소", role: .cancel) {}
                Button("이동") {
                    if let n = Int(pageInputText), n >= 1, n <= model.totalPages {
                        model.goToPage(n - 1)
                    }
                }
            } message: {
                Text("1 부터 \(max(model.totalPages, 1)) 사이의 페이지 번호")
            }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(GwaTopHomeTheme.textSecondary)
            TextField("검색어 입력", text: $model.searchText)
                .font(.system(size: 15, weight: .semibold))
                .submitLabel(.search)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .onSubmit { model.performSearch() }

            if !model.searchResults.isEmpty {
                Text("\(model.currentSearchIndex + 1) / \(model.searchResults.count)")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(GwaTopHomeTheme.primary)
                Button { model.prevResult() } label: {
                    Image(systemName: "chevron.up").font(.system(size: 14, weight: .bold))
                }
                Button { model.nextResult() } label: {
                    Image(systemName: "chevron.down").font(.system(size: 14, weight: .bold))
                }
            } else if !model.searchText.isEmpty {
                Text("결과 없음")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(GwaTopHomeTheme.textSecondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.white)
    }

    private var bottomControls: some View {
        HStack(spacing: 14) {
            Button {
                model.goToPage(model.currentPage - 1)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .bold))
                    .frame(width: 42, height: 42)
                    .background(.white)
                    .clipShape(Circle())
            }
            .disabled(model.currentPage <= 0)
            .opacity(model.currentPage <= 0 ? 0.4 : 1)

            Button {
                pageInputText = "\(model.currentPage + 1)"
                showingPageInput = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 12, weight: .bold))
                    Text("\(model.currentPage + 1) / \(max(model.totalPages, 1))")
                        .font(.system(size: 15, weight: .bold))
                }
                .foregroundStyle(GwaTopHomeTheme.textPrimary)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(.white)
                .clipShape(Capsule())
            }

            Button {
                model.goToPage(model.currentPage + 1)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 16, weight: .bold))
                    .frame(width: 42, height: 42)
                    .background(.white)
                    .clipShape(Circle())
            }
            .disabled(model.currentPage + 1 >= model.totalPages)
            .opacity(model.currentPage + 1 >= model.totalPages ? 0.4 : 1)
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(GwaTopHomeTheme.background)
    }
}

// MARK: - PDFKit UIViewRepresentable

/// PDFKit 의 PDFView 를 SwiftUI 에 래핑 + ViewModel 과 연결.
/// 핀치 줌·스와이프 스크롤은 PDFView 가 기본 제공. 명령적 API(go/scaleFactor/highlightedSelections)는
/// model 에 보관된 weak 참조로 호출.
struct GwaTopPDFKitPlayerView: UIViewRepresentable {
    let document: PDFDocument
    let model: GwaTopPDFPlayerViewModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.document = document
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.usePageViewController(false)
        view.minScaleFactor = 0.5
        view.maxScaleFactor = 5.0
        view.backgroundColor = UIColor.systemGray6

        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.pageChanged),
            name: .PDFViewPageChanged,
            object: view
        )

        // model 에 view 연결 — view 생성 후 publish 충돌 피하려고 다음 RunLoop tick.
        let m = self.model
        DispatchQueue.main.async {
            m.attach(view)
        }
        return view
    }

    func updateUIView(_ uiView: PDFView, context: Context) {
        if uiView.document !== document {
            uiView.document = document
            let m = self.model
            DispatchQueue.main.async {
                m.attach(uiView)
            }
        }
    }

    final class Coordinator: NSObject {
        let model: GwaTopPDFPlayerViewModel
        init(model: GwaTopPDFPlayerViewModel) { self.model = model }

        @objc func pageChanged() {
            Task { @MainActor in
                self.model.didChangePage()
            }
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
    @State private var showingPlayer = false

    var body: some View {
        launcherView
            .fullScreenCover(isPresented: $showingPlayer) { playerView }
    }

    private var launcherView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                introCard
                Button {
                    showingPlayer = true
                    Task { await load() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "doc.text.magnifyingglass")
                        Text("요약 보기").font(.system(size: 17, weight: .bold))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity).frame(height: 52)
                    .background(GwaTopHomeTheme.primary)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .shadow(color: GwaTopHomeTheme.primary.opacity(0.3), radius: 8, y: 4)
                }
            }
            .padding(16)
        }
    }

    private var introCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("AI 요약")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(GwaTopHomeTheme.primary)
            Text("자료를 한 줄 요약 + 핵심 포인트 + 섹션별로 정리해드려요.")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(GwaTopHomeTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text("PDF 전체를 빠르게 훑어볼 때 유용해요.")
                .font(.system(size: 14))
                .foregroundStyle(GwaTopHomeTheme.textSecondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var playerView: some View {
        NavigationStack {
            ZStack {
                GwaTopHomeTheme.background.ignoresSafeArea()
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
            }
            .navigationTitle("요약")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("닫기") { showingPlayer = false }
                }
            }
            .task(id: pollCount) {
                if pollCount > 0 && summary == nil {
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                    await load(silent: true)
                }
            }
        }
    }

    private func pendingCard(_ msg: String) -> some View {
        HStack(spacing: 12) {
            ProgressView()
            Text(msg)
                .font(.system(size: 15, weight: .semibold))
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
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(GwaTopHomeTheme.primary)
            // LaTeX 수식 자동 감지 → KaTeX 렌더 / 없으면 plain Text 폴백.
            GwaTopMathText(
                s.headline,
                fontSize: 20, weight: .bold,
                color: GwaTopHomeTheme.textPrimary
            )
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func keyPointsCard(_ s: GwaTopAISummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("핵심 포인트")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(GwaTopHomeTheme.textSecondary)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(s.keyPoints.enumerated()), id: \.offset) { idx, point in
                    HStack(alignment: .top, spacing: 10) {
                        Text("\(idx + 1)")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 18, height: 18)
                            .background(GwaTopHomeTheme.primary)
                            .clipShape(Circle())
                        // 핵심 포인트에 LaTeX 수식이 섞일 수 있어 GwaTopMathText 로 렌더.
                        GwaTopMathText(
                            point,
                            fontSize: 15, weight: .semibold,
                            color: GwaTopHomeTheme.textPrimary
                        )
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
            HStack(spacing: 6) {
                Text("섹션별 요약")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(GwaTopHomeTheme.textSecondary)
                if s.sections.count > 3 {
                    // 섹션이 많을 때 내부 스크롤이 있음을 시각적으로 안내.
                    Text("스크롤")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(GwaTopHomeTheme.textSecondary.opacity(0.7))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(GwaTopHomeTheme.textSecondary.opacity(0.08))
                        .clipShape(Capsule())
                }
                Spacer(minLength: 0)
            }
            // 섹션이 많아져도 카드가 화면 전체를 잠식하지 않도록 내부 스크롤로 제한.
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(s.sections.enumerated()), id: \.offset) { idx, section in
                        VStack(alignment: .leading, spacing: 4) {
                            // 섹션 제목 + 본문 모두 LaTeX 수식 가능성 있어 GwaTopMathText.
                            GwaTopMathText(
                                section.title,
                                fontSize: 15, weight: .bold,
                                color: GwaTopHomeTheme.textPrimary
                            )
                            GwaTopMathText(
                                section.body,
                                fontSize: 14, weight: .medium,
                                color: GwaTopHomeTheme.textSecondary
                            )
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.bottom, 4)
                        if idx < s.sections.count - 1 {
                            Divider().opacity(0.4)
                        }
                    }
                }
                .padding(.trailing, 4)
            }
            .frame(maxHeight: 380)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func studyTipCard(_ s: GwaTopAISummary) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lightbulb.fill")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("학습 팁")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.orange)
                GwaTopMathText(
                    s.studyTip,
                    fontSize: 15, weight: .semibold,
                    color: GwaTopHomeTheme.textPrimary
                )
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
                    .font(.system(size: 15, weight: .bold))
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
                .font(.system(size: 14, weight: .bold))
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
