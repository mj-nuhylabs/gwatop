//
//  GwaTopFileStudyTabs.swift
//  GwaTop
//
//  학습 탭의 7개 기능 탭 구현 (PDF/요약은 별도 파일에서):
//    퀴즈 / 플래시카드 / 마인드맵 / 암기 / 주요 주제 / 노트 / AI 튜터
//
//  공통 패턴:
//   - 진입 시 캐시된 결과를 조회
//   - 없으면 "생성하기" 버튼 → 동기 호출(8~15초) → 결과 표시
//   - 결과 표시 후 "다시 만들기" 버튼 항상 노출
//   - quiz/memorize/topics 는 페이지 범위 선택 (GwaTopScopeSelector) 제공
//

import SwiftUI

// MARK: - 페이지 범위 선택기

struct GwaTopScopeSelector: View {
    @Binding var scope: String   // "all" 또는 "1-3" 같은 문자열

    @State private var isCustom: Bool
    @State private var customText: String

    init(scope: Binding<String>) {
        self._scope = scope
        let initial = scope.wrappedValue
        let custom = initial != "all" && !initial.isEmpty
        _isCustom = State(initialValue: custom)
        _customText = State(initialValue: custom ? initial : "1-3")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("범위 선택")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(GwaTopHomeTheme.textSecondary)

            HStack(spacing: 8) {
                pill(label: "전체 페이지", active: !isCustom) {
                    isCustom = false
                    scope = "all"
                }
                pill(label: "특정 페이지", active: isCustom) {
                    isCustom = true
                    scope = customText
                }
            }

            if isCustom {
                HStack(spacing: 6) {
                    Image(systemName: "doc.text").foregroundStyle(GwaTopHomeTheme.textSecondary)
                    TextField("예: 1-3 또는 5", text: $customText)
                        .keyboardType(.numbersAndPunctuation)
                        .font(.system(size: 13, weight: .medium))
                        .onChange(of: customText) { _, newValue in
                            scope = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(.white)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GwaTopHomeTheme.primary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func pill(label: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(active ? .white : GwaTopHomeTheme.textPrimary)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(active ? GwaTopHomeTheme.primary : Color.gray.opacity(0.1))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 공통 컴포넌트

private struct GwaTopGenerateButton: View {
    let title: String
    let isLoading: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isLoading {
                    ProgressView().scaleEffect(0.75)
                } else {
                    Image(systemName: "sparkles")
                }
                Text(isLoading ? "생성 중…" : title)
                    .font(.system(size: 14, weight: .bold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(isLoading ? GwaTopHomeTheme.primary.opacity(0.6) : GwaTopHomeTheme.primary)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .disabled(isLoading)
    }
}

private struct GwaTopRegenerateButton: View {
    let isLoading: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if isLoading { ProgressView().scaleEffect(0.7) } else { Image(systemName: "arrow.clockwise") }
                Text(isLoading ? "재생성 중…" : "다시 만들기")
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(GwaTopHomeTheme.primary)
            .frame(maxWidth: .infinity).frame(height: 42)
            .background(GwaTopHomeTheme.primary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .disabled(isLoading)
    }
}

private struct GwaTopErrorBanner: View {
    let message: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            Text(message).font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - 1) 퀴즈

struct GwaTopFileQuizTab: View {
    let file: GwaTopFileSummary

    @State private var quiz: GwaTopQuizContent? = nil
    @State private var scope: String = "all"
    @State private var isLoading = false
    @State private var isGenerating = false
    @State private var error: String? = nil

    @State private var currentIndex: Int = 0
    @State private var selectedChoice: Int? = nil
    @State private var shortAnswerInput: String = ""
    @State private var showAnswer: Bool = false

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                GwaTopScopeSelector(scope: $scope)
                    .onChange(of: scope) { _, _ in
                        Task { await load() }
                    }

                if let err = error {
                    GwaTopErrorBanner(message: err)
                }

                if let q = quiz {
                    quizCard(q)
                    GwaTopRegenerateButton(isLoading: isGenerating) {
                        Task { await generate(force: true) }
                    }
                } else if isLoading || isGenerating {
                    pendingCard
                } else {
                    introCard
                    GwaTopGenerateButton(title: "퀴즈 만들기", isLoading: isGenerating) {
                        Task { await generate(force: false) }
                    }
                }
            }
            .padding(16)
        }
        .task { await load() }
    }

    private var pendingCard: some View {
        HStack(spacing: 10) {
            ProgressView()
            Text("AI가 퀴즈를 만드는 중이에요…")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(GwaTopHomeTheme.textSecondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var introCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("자료 기반 퀴즈")
                .font(.system(size: 15, weight: .bold))
            Text("객관식 5~7개 + 주관식 2~3개를 자동으로 만들어드려요. 페이지 범위를 좁히면 더 정확합니다.")
                .font(.system(size: 12))
                .foregroundStyle(GwaTopHomeTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func quizCard(_ q: GwaTopQuizContent) -> some View {
        guard !q.questions.isEmpty else {
            return AnyView(
                Text("생성된 문제가 없어요.")
                    .font(.system(size: 12)).foregroundStyle(GwaTopHomeTheme.textSecondary)
            )
        }
        let total = q.questions.count
        let safeIndex = min(max(0, currentIndex), total - 1)
        let question = q.questions[safeIndex]

        return AnyView(
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("문제 \(safeIndex + 1) / \(total)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(GwaTopHomeTheme.primary)
                    Spacer()
                    Text(question.type == "multiple_choice" ? "객관식" : "주관식")
                        .font(.system(size: 10, weight: .heavy))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Color.gray.opacity(0.1))
                        .foregroundStyle(GwaTopHomeTheme.textSecondary)
                        .clipShape(Capsule())
                }

                Text(question.question)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(GwaTopHomeTheme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                if question.type == "multiple_choice", let choices = question.choices {
                    VStack(spacing: 8) {
                        ForEach(Array(choices.enumerated()), id: \.offset) { idx, choice in
                            choiceRow(idx: idx, text: choice, question: question)
                        }
                    }
                } else {
                    TextField("답을 입력하세요", text: $shortAnswerInput, axis: .vertical)
                        .font(.system(size: 14))
                        .padding(12)
                        .background(Color.gray.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    if showAnswer, let ans = question.answer {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("정답").font(.system(size: 11, weight: .bold)).foregroundStyle(.green)
                            Text(ans).font(.system(size: 13, weight: .semibold))
                        }
                    }
                }

                if showAnswer && !question.explanation.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("해설").font(.system(size: 11, weight: .bold)).foregroundStyle(GwaTopHomeTheme.primary)
                        Text(question.explanation)
                            .font(.system(size: 12)).foregroundStyle(GwaTopHomeTheme.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(GwaTopHomeTheme.primary.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }

                HStack(spacing: 8) {
                    Button {
                        showAnswer = true
                    } label: {
                        Text(showAnswer ? "정답 확인됨" : "정답 보기")
                            .font(.system(size: 13, weight: .bold))
                            .frame(maxWidth: .infinity).frame(height: 40)
                            .foregroundStyle(.white)
                            .background(showAnswer ? Color.gray.opacity(0.5) : GwaTopHomeTheme.primary)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .disabled(showAnswer)

                    Button {
                        nextQuestion(total: total)
                    } label: {
                        Text(safeIndex == total - 1 ? "처음으로" : "다음")
                            .font(.system(size: 13, weight: .bold))
                            .frame(maxWidth: .infinity).frame(height: 40)
                            .foregroundStyle(GwaTopHomeTheme.primary)
                            .background(GwaTopHomeTheme.primary.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                }
            }
            .padding(16)
            .background(.white)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        )
    }

    private func choiceRow(idx: Int, text: String, question: GwaTopQuizQuestion) -> some View {
        let isSelected = selectedChoice == idx
        let isCorrect = showAnswer && question.answerIndex == idx
        let isWrong = showAnswer && isSelected && question.answerIndex != idx
        let bg: Color = isCorrect ? Color.green.opacity(0.15)
            : isWrong ? Color.red.opacity(0.12)
            : (isSelected ? GwaTopHomeTheme.primary.opacity(0.10) : Color.gray.opacity(0.05))
        return Button {
            if !showAnswer { selectedChoice = idx }
        } label: {
            HStack {
                Text("\(["A","B","C","D","E","F"][min(idx, 5)])")
                    .font(.system(size: 11, weight: .heavy))
                    .frame(width: 22, height: 22)
                    .background(isCorrect ? .green : (isSelected ? GwaTopHomeTheme.primary : Color.gray.opacity(0.2)))
                    .foregroundStyle(.white)
                    .clipShape(Circle())
                Text(text)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(GwaTopHomeTheme.textPrimary)
                Spacer()
                if isCorrect { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                if isWrong   { Image(systemName: "xmark.circle.fill").foregroundStyle(.red) }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(bg)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func nextQuestion(total: Int) {
        showAnswer = false
        selectedChoice = nil
        shortAnswerInput = ""
        currentIndex = (currentIndex + 1) % total
    }

    @MainActor
    private func load() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let resp = try await GwaTopFileService.shared.aiContent(
                fileId: file.id, contentType: "quiz", scope: scope
            )
            quiz = resp.quiz()
            currentIndex = 0
            showAnswer = false
            selectedChoice = nil
            shortAnswerInput = ""
        } catch {
            if isCancellation(error) { return }
            self.error = error.localizedDescription
        }
    }

    @MainActor
    private func generate(force: Bool) async {
        isGenerating = true
        error = nil
        defer { isGenerating = false }
        do {
            let resp = try await GwaTopFileService.shared.generateAIContent(
                fileId: file.id, contentType: "quiz",
                pages: scope == "all" ? nil : scope, force: force
            )
            quiz = resp.quiz()
            currentIndex = 0; showAnswer = false; selectedChoice = nil; shortAnswerInput = ""
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - 2) 플래시카드

struct GwaTopFileFlashcardTab: View {
    let file: GwaTopFileSummary

    @State private var cards: [GwaTopFlashcard] = []
    @State private var isLoading = false
    @State private var isGenerating = false
    @State private var error: String? = nil

    @State private var currentIndex: Int = 0
    @State private var isFlipped: Bool = false
    @State private var knownIds: Set<String> = []
    @State private var unknownIds: Set<String> = []

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                if let err = error { GwaTopErrorBanner(message: err) }

                if cards.isEmpty {
                    if isGenerating {
                        pendingCard
                    } else {
                        introCard
                        GwaTopGenerateButton(title: "플래시카드 만들기", isLoading: isGenerating) {
                            Task { await generate(force: false) }
                        }
                    }
                } else {
                    statsBar
                    cardView
                    actionButtons
                    GwaTopRegenerateButton(isLoading: isGenerating) {
                        Task { await generate(force: true) }
                    }
                }
            }
            .padding(16)
        }
        .task { await load() }
    }

    private var pendingCard: some View {
        HStack(spacing: 10) {
            ProgressView()
            Text("AI가 플래시카드를 만드는 중이에요…")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(GwaTopHomeTheme.textSecondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var introCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("어려운 개념 카드").font(.system(size: 15, weight: .bold))
            Text("핵심 용어를 단어장 카드로 만들어 \"알아요/몰라요\"로 스스로 점검할 수 있어요.")
                .font(.system(size: 12)).foregroundStyle(GwaTopHomeTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var statsBar: some View {
        HStack {
            Text("\(currentIndex + 1) / \(cards.count)")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(GwaTopHomeTheme.primary)
            Spacer()
            Label("\(knownIds.count)", systemImage: "checkmark.circle.fill")
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(.green)
            Label("\(unknownIds.count)", systemImage: "xmark.circle.fill")
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(.red)
                .padding(.leading, 6)
        }
    }

    private var cardView: some View {
        let card = cards[min(currentIndex, cards.count - 1)]
        return Button {
            withAnimation(.easeInOut(duration: 0.4)) { isFlipped.toggle() }
        } label: {
            ZStack {
                if isFlipped {
                    VStack(spacing: 12) {
                        Text("정의 / 설명")
                            .font(.system(size: 10, weight: .bold)).foregroundStyle(.white.opacity(0.8))
                        Text(card.back)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(20)
                    .rotation3DEffect(.degrees(180), axis: (x: 0, y: 1, z: 0))
                } else {
                    VStack(spacing: 12) {
                        Text("용어 / 개념")
                            .font(.system(size: 10, weight: .bold)).foregroundStyle(.white.opacity(0.8))
                        Text(card.front)
                            .font(.system(size: 22, weight: .heavy, design: .rounded))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                        if let hint = card.hint, !hint.isEmpty {
                            Text("힌트: \(hint)")
                                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.85))
                        }
                    }
                    .padding(20)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 200)
            .background(
                LinearGradient(
                    colors: [GwaTopHomeTheme.primary, GwaTopHomeTheme.primary.opacity(0.7)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .rotation3DEffect(.degrees(isFlipped ? 180 : 0), axis: (x: 0, y: 1, z: 0))
        }
        .buttonStyle(.plain)
    }

    private var actionButtons: some View {
        HStack(spacing: 10) {
            Button {
                mark(known: false); next()
            } label: {
                Text("몰라요")
                    .font(.system(size: 14, weight: .bold))
                    .frame(maxWidth: .infinity).frame(height: 48)
                    .foregroundStyle(.red)
                    .background(Color.red.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            Button {
                mark(known: true); next()
            } label: {
                Text("알아요")
                    .font(.system(size: 14, weight: .bold))
                    .frame(maxWidth: .infinity).frame(height: 48)
                    .foregroundStyle(.white)
                    .background(Color.green)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    private func mark(known: Bool) {
        guard currentIndex < cards.count else { return }
        let id = cards[currentIndex].id
        if known { knownIds.insert(id); unknownIds.remove(id) }
        else     { unknownIds.insert(id); knownIds.remove(id) }
    }
    private func next() {
        withAnimation { isFlipped = false }
        currentIndex = (currentIndex + 1) % cards.count
    }

    @MainActor
    private func load() async {
        isLoading = true; error = nil
        defer { isLoading = false }
        do {
            let resp = try await GwaTopFileService.shared.aiContent(
                fileId: file.id, contentType: "flashcard"
            )
            cards = resp.flashcards()?.cards ?? []
            currentIndex = 0; isFlipped = false
        } catch { if !isCancellation(error) { self.error = error.localizedDescription } }
    }

    @MainActor
    private func generate(force: Bool) async {
        isGenerating = true; error = nil
        defer { isGenerating = false }
        do {
            let resp = try await GwaTopFileService.shared.generateAIContent(
                fileId: file.id, contentType: "flashcard", pages: nil, force: force
            )
            cards = resp.flashcards()?.cards ?? []
            currentIndex = 0; isFlipped = false; knownIds = []; unknownIds = []
        } catch { self.error = error.localizedDescription }
    }
}

// MARK: - 3) 마인드맵

struct GwaTopFileMindmapTab: View {
    let file: GwaTopFileSummary

    @State private var mindmap: GwaTopMindmapContent? = nil
    @State private var isLoading = false
    @State private var isGenerating = false
    @State private var error: String? = nil
    @State private var expandedLabels: Set<String> = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let err = error { GwaTopErrorBanner(message: err) }

                if let m = mindmap {
                    rootNode(m)
                    GwaTopRegenerateButton(isLoading: isGenerating) {
                        Task { await generate(force: true) }
                    }
                } else if isGenerating {
                    pendingCard
                } else {
                    introCard
                    GwaTopGenerateButton(title: "마인드맵 만들기", isLoading: isGenerating) {
                        Task { await generate(force: false) }
                    }
                }
            }
            .padding(16)
        }
        .task { await load() }
    }

    private var pendingCard: some View {
        HStack(spacing: 10) {
            ProgressView()
            Text("AI가 트리 구조를 그리는 중이에요…")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(GwaTopHomeTheme.textSecondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var introCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("개념 마인드맵").font(.system(size: 15, weight: .bold))
            Text("자료의 핵심 개념을 트리 구조로 시각화해드려요.")
                .font(.system(size: 12)).foregroundStyle(GwaTopHomeTheme.textSecondary)
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(.white).clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func rootNode(_ m: GwaTopMindmapContent) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(m.root)
                .font(.system(size: 18, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(GwaTopHomeTheme.primary)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            ForEach(m.children) { child in
                treeNode(node: child, depth: 1)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    @ViewBuilder
    private func treeNode(node: GwaTopMindmapNode, depth: Int) -> some View {
        let hasChildren = !node.children.isEmpty
        let expanded = expandedLabels.contains(node.label) || depth <= 1
        VStack(alignment: .leading, spacing: 6) {
            Button {
                if hasChildren {
                    if expanded { expandedLabels.remove(node.label) }
                    else { expandedLabels.insert(node.label) }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: hasChildren
                          ? (expanded ? "chevron.down" : "chevron.right")
                          : "circle.fill")
                        .font(.system(size: hasChildren ? 9 : 5, weight: .bold))
                        .foregroundStyle(hasChildren ? GwaTopHomeTheme.primary : Color.gray)
                        .frame(width: 14)
                    Text(node.label)
                        .font(.system(size: 13 - CGFloat(depth - 1), weight: depth <= 2 ? .bold : .semibold))
                        .foregroundStyle(GwaTopHomeTheme.textPrimary)
                }
            }
            .buttonStyle(.plain)

            if expanded && hasChildren {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(node.children) { sub in
                        treeNode(node: sub, depth: depth + 1)
                    }
                }
                .padding(.leading, 16)
                .overlay(
                    Rectangle()
                        .fill(Color.gray.opacity(0.2))
                        .frame(width: 1)
                        .padding(.leading, 6),
                    alignment: .leading
                )
            }
        }
        .padding(.leading, CGFloat(max(0, depth - 1)) * 6)
    }

    @MainActor
    private func load() async {
        isLoading = true; error = nil
        defer { isLoading = false }
        do {
            let resp = try await GwaTopFileService.shared.aiContent(
                fileId: file.id, contentType: "mindmap"
            )
            mindmap = resp.mindmap()
        } catch { if !isCancellation(error) { self.error = error.localizedDescription } }
    }

    @MainActor
    private func generate(force: Bool) async {
        isGenerating = true; error = nil
        defer { isGenerating = false }
        do {
            let resp = try await GwaTopFileService.shared.generateAIContent(
                fileId: file.id, contentType: "mindmap", pages: nil, force: force
            )
            mindmap = resp.mindmap()
            expandedLabels = []
        } catch { self.error = error.localizedDescription }
    }
}

// MARK: - 4) 암기 포인트

struct GwaTopFileMemorizeTab: View {
    let file: GwaTopFileSummary

    @State private var content: GwaTopMemorizeContent? = nil
    @State private var scope: String = "all"
    @State private var isGenerating = false
    @State private var error: String? = nil

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                GwaTopScopeSelector(scope: $scope)
                    .onChange(of: scope) { _, _ in Task { await load() } }

                if let err = error { GwaTopErrorBanner(message: err) }

                if let c = content {
                    pointsList(c)
                    GwaTopRegenerateButton(isLoading: isGenerating) {
                        Task { await generate(force: true) }
                    }
                } else if isGenerating {
                    pendingCard
                } else {
                    introCard
                    GwaTopGenerateButton(title: "암기 포인트 만들기", isLoading: isGenerating) {
                        Task { await generate(force: false) }
                    }
                }
            }
            .padding(16)
        }
        .task { await load() }
    }

    private var pendingCard: some View {
        HStack(spacing: 10) {
            ProgressView()
            Text("AI가 암기 포인트를 정리하는 중이에요…")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(GwaTopHomeTheme.textSecondary)
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(.white).clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var introCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("시험 대비 암기 포인트").font(.system(size: 15, weight: .bold))
            Text("자료에서 시험에 자주 출제될 만한 사실/공식/정의/날짜를 뽑아드려요.")
                .font(.system(size: 12)).foregroundStyle(GwaTopHomeTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(.white).clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func pointsList(_ c: GwaTopMemorizeContent) -> some View {
        let grouped = Dictionary(grouping: c.points, by: { $0.category })
        let categories = grouped.keys.sorted()
        return VStack(spacing: 12) {
            ForEach(categories, id: \.self) { cat in
                VStack(alignment: .leading, spacing: 6) {
                    if !cat.isEmpty {
                        Text(cat)
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(GwaTopHomeTheme.textSecondary)
                            .padding(.leading, 4)
                    }
                    VStack(spacing: 8) {
                        ForEach(grouped[cat] ?? []) { p in
                            pointRow(p)
                        }
                    }
                }
            }
        }
    }

    private func pointRow(_ p: GwaTopMemorizePoint) -> some View {
        HStack(alignment: .top, spacing: 10) {
            HStack(spacing: 1) {
                ForEach(0..<5, id: \.self) { i in
                    Image(systemName: i < p.importance ? "star.fill" : "star")
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                }
            }
            .frame(width: 60, alignment: .leading)
            Text(p.text)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(GwaTopHomeTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @MainActor
    private func load() async {
        error = nil
        do {
            let resp = try await GwaTopFileService.shared.aiContent(
                fileId: file.id, contentType: "memorize", scope: scope
            )
            content = resp.memorize()
        } catch { if !isCancellation(error) { self.error = error.localizedDescription } }
    }

    @MainActor
    private func generate(force: Bool) async {
        isGenerating = true; error = nil
        defer { isGenerating = false }
        do {
            let resp = try await GwaTopFileService.shared.generateAIContent(
                fileId: file.id, contentType: "memorize",
                pages: scope == "all" ? nil : scope, force: force
            )
            content = resp.memorize()
        } catch { self.error = error.localizedDescription }
    }
}

// MARK: - 5) 주요 주제

struct GwaTopFileTopicsTab: View {
    let file: GwaTopFileSummary

    @State private var content: GwaTopTopicsContent? = nil
    @State private var scope: String = "all"
    @State private var isGenerating = false
    @State private var error: String? = nil

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                GwaTopScopeSelector(scope: $scope)
                    .onChange(of: scope) { _, _ in Task { await load() } }

                if let err = error { GwaTopErrorBanner(message: err) }

                if let c = content {
                    ForEach(c.topics) { topicCard($0) }
                    GwaTopRegenerateButton(isLoading: isGenerating) {
                        Task { await generate(force: true) }
                    }
                } else if isGenerating {
                    pendingCard
                } else {
                    introCard
                    GwaTopGenerateButton(title: "주요 개념 정리하기", isLoading: isGenerating) {
                        Task { await generate(force: false) }
                    }
                }
            }
            .padding(16)
        }
        .task { await load() }
    }

    private var pendingCard: some View {
        HStack(spacing: 10) {
            ProgressView()
            Text("AI가 주요 개념을 정리하는 중이에요…")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(GwaTopHomeTheme.textSecondary)
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(.white).clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var introCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("주요 개념").font(.system(size: 15, weight: .bold))
            Text("자료의 핵심 개념을 짧은 설명과 예시로 정리해드려요.")
                .font(.system(size: 12)).foregroundStyle(GwaTopHomeTheme.textSecondary)
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(.white).clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func topicCard(_ t: GwaTopTopic) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(t.title)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(GwaTopHomeTheme.primary)
            Text(t.body)
                .font(.system(size: 13)).foregroundStyle(GwaTopHomeTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            if !t.examples.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(t.examples.enumerated()), id: \.offset) { _, ex in
                        HStack(alignment: .top, spacing: 6) {
                            Text("·").foregroundStyle(GwaTopHomeTheme.primary)
                            Text(ex).font(.system(size: 12)).foregroundStyle(GwaTopHomeTheme.textSecondary)
                        }
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(.white).clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @MainActor
    private func load() async {
        error = nil
        do {
            let resp = try await GwaTopFileService.shared.aiContent(
                fileId: file.id, contentType: "topics", scope: scope
            )
            content = resp.topics()
        } catch { if !isCancellation(error) { self.error = error.localizedDescription } }
    }

    @MainActor
    private func generate(force: Bool) async {
        isGenerating = true; error = nil
        defer { isGenerating = false }
        do {
            let resp = try await GwaTopFileService.shared.generateAIContent(
                fileId: file.id, contentType: "topics",
                pages: scope == "all" ? nil : scope, force: force
            )
            content = resp.topics()
        } catch { self.error = error.localizedDescription }
    }
}

// MARK: - 6) 노트

struct GwaTopFileNotesTab: View {
    let file: GwaTopFileSummary

    @State private var notes: [GwaTopUserNote] = []
    @State private var isLoading = false
    @State private var error: String? = nil
    @State private var showEditor = false
    @State private var editingNote: GwaTopUserNote? = nil

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if let err = error { GwaTopErrorBanner(message: err) }

                Button {
                    editingNote = nil
                    showEditor = true
                } label: {
                    HStack {
                        Image(systemName: "square.and.pencil")
                        Text("새 노트 작성").font(.system(size: 14, weight: .bold))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity).frame(height: 46)
                    .background(GwaTopHomeTheme.primary)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }

                if isLoading && notes.isEmpty {
                    ProgressView().padding(.top, 30)
                } else if notes.isEmpty {
                    Text("아직 노트가 없어요.")
                        .font(.system(size: 13)).foregroundStyle(GwaTopHomeTheme.textSecondary)
                        .padding(.top, 30)
                } else {
                    ForEach(notes) { n in
                        noteCard(n)
                    }
                }
            }
            .padding(16)
        }
        .task { await load() }
        .sheet(isPresented: $showEditor) {
            GwaTopNoteEditorSheet(fileId: file.id, existing: editingNote) {
                Task { await load() }
            }
        }
    }

    private func noteCard(_ n: GwaTopUserNote) -> some View {
        Button {
            editingNote = n
            showEditor = true
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                if let title = n.title, !title.isEmpty {
                    Text(title).font(.system(size: 14, weight: .bold))
                        .foregroundStyle(GwaTopHomeTheme.textPrimary)
                }
                Text(n.body)
                    .font(.system(size: 13)).foregroundStyle(GwaTopHomeTheme.textPrimary)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                Text(shortDate(n.updatedAt))
                    .font(.system(size: 10)).foregroundStyle(GwaTopHomeTheme.textSecondary)
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(.white)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .swipeActions(allowsFullSwipe: false) {
            Button(role: .destructive) {
                Task { await delete(n) }
            } label: { Label("삭제", systemImage: "trash") }
        }
    }

    private func shortDate(_ d: Date) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "ko_KR")
        fmt.dateFormat = "M/d HH:mm"
        return fmt.string(from: d)
    }

    @MainActor
    private func load() async {
        isLoading = true; error = nil
        defer { isLoading = false }
        do {
            notes = try await GwaTopFileService.shared.listNotes(fileId: file.id)
        } catch { if !isCancellation(error) { self.error = error.localizedDescription } }
    }

    @MainActor
    private func delete(_ n: GwaTopUserNote) async {
        do {
            try await GwaTopFileService.shared.deleteNote(fileId: file.id, noteId: n.id)
            notes.removeAll { $0.id == n.id }
        } catch { error = error.localizedDescription }
    }
}

struct GwaTopNoteEditorSheet: View {
    let fileId: String
    let existing: GwaTopUserNote?
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title: String = ""
    @State private var body: String = ""
    @State private var isSaving = false
    @State private var error: String? = nil

    var body: some View {
        NavigationStack {
            ZStack {
                GwaTopHomeTheme.background.ignoresSafeArea()
                VStack(spacing: 12) {
                    TextField("제목 (선택)", text: $title)
                        .font(.system(size: 15, weight: .semibold))
                        .padding(12)
                        .background(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    TextEditor(text: $body)
                        .font(.system(size: 14))
                        .padding(8)
                        .background(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    if let error {
                        Text(error).font(.system(size: 12)).foregroundStyle(.red)
                    }
                }
                .padding(16)
            }
            .navigationTitle(existing == nil ? "새 노트" : "노트 편집")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("취소") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(isSaving ? "저장 중…" : "저장") {
                        Task { await save() }
                    }
                    .disabled(isSaving || body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear {
                title = existing?.title ?? ""
                body = existing?.body ?? ""
            }
        }
    }

    @MainActor
    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            if let existing {
                _ = try await GwaTopFileService.shared.updateNote(
                    fileId: fileId, noteId: existing.id,
                    title: title.isEmpty ? nil : title, body: body
                )
            } else {
                _ = try await GwaTopFileService.shared.createNote(
                    fileId: fileId,
                    title: title.isEmpty ? nil : title, body: body
                )
            }
            onSaved()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - 7) AI 튜터

struct GwaTopFileTutorTab: View {
    let file: GwaTopFileSummary

    @State private var messages: [GwaTopTutorMessage] = []
    @State private var input: String = ""
    @State private var isLoading = false
    @State private var isSending = false
    @State private var error: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            if let err = error {
                GwaTopErrorBanner(message: err).padding(.horizontal, 16).padding(.top, 8)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 8) {
                        if messages.isEmpty && !isLoading {
                            emptyState.padding(.top, 40)
                        }
                        ForEach(messages) { msg in
                            messageRow(msg).id(msg.id)
                        }
                        if isSending {
                            HStack {
                                ProgressView().scaleEffect(0.7)
                                Text("AI 튜터가 답변을 작성 중이에요…")
                                    .font(.system(size: 11)).foregroundStyle(GwaTopHomeTheme.textSecondary)
                                Spacer()
                            }
                            .padding(.horizontal, 16).padding(.vertical, 6)
                        }
                    }
                    .padding(.vertical, 12)
                }
                .onChange(of: messages.count) { _, _ in
                    if let last = messages.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }

            inputBar
        }
        .task { await load() }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(GwaTopHomeTheme.primary.opacity(0.5))
            Text("이 자료에 대해 물어보세요")
                .font(.system(size: 14, weight: .bold))
            Text("이해 안 가는 부분, 시험에 나올 만한 포인트,\n예시 만들어달라고 하기 등 자유롭게.")
                .font(.system(size: 12))
                .foregroundStyle(GwaTopHomeTheme.textSecondary)
                .multilineTextAlignment(.center)
        }
    }

    private func messageRow(_ msg: GwaTopTutorMessage) -> some View {
        HStack(alignment: .top, spacing: 8) {
            if msg.role == "assistant" {
                Image(systemName: "sparkles")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(GwaTopHomeTheme.primary)
                    .clipShape(Circle())
            } else {
                Spacer(minLength: 30)
            }

            VStack(alignment: msg.role == "user" ? .trailing : .leading, spacing: 4) {
                Text(msg.body)
                    .font(.system(size: 13))
                    .foregroundStyle(msg.role == "user" ? .white : GwaTopHomeTheme.textPrimary)
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(msg.role == "user" ? GwaTopHomeTheme.primary : Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: msg.role == "user" ? .trailing : .leading)

            if msg.role == "user" {
                Image(systemName: "person.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(Color.gray)
                    .clipShape(Circle())
            } else {
                Spacer(minLength: 30)
            }
        }
        .padding(.horizontal, 14)
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("질문을 입력하세요", text: $input, axis: .vertical)
                .font(.system(size: 14))
                .lineLimit(1...4)
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(.white)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            Button {
                Task { await send() }
            } label: {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(canSend ? GwaTopHomeTheme.primary : Color.gray.opacity(0.5))
                    .clipShape(Circle())
            }
            .disabled(!canSend)
        }
        .padding(12)
        .background(GwaTopHomeTheme.background.opacity(0.85))
    }

    private var canSend: Bool {
        !isSending && !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @MainActor
    private func load() async {
        isLoading = true; error = nil
        defer { isLoading = false }
        do {
            messages = try await GwaTopFileService.shared.listTutorMessages(fileId: file.id)
        } catch { if !isCancellation(error) { self.error = error.localizedDescription } }
    }

    @MainActor
    private func send() async {
        let q = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        input = ""
        isSending = true
        defer { isSending = false }
        do {
            let resp = try await GwaTopFileService.shared.askTutor(fileId: file.id, question: q)
            messages.append(resp.userMessage)
            messages.append(resp.assistantMessage)
        } catch {
            self.error = error.localizedDescription
            // 실패 시 입력값 복구
            input = q
        }
    }
}
