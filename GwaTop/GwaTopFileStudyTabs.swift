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
import PencilKit
import PhotosUI

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
                .font(.gwaTopSystem(size: 13, weight: .bold))
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
                        .font(.gwaTopSystem(size: 15, weight: .semibold))
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
                .font(.gwaTopSystem(size: 14, weight: .bold))
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
                    .font(.gwaTopSystem(size: 16, weight: .bold))
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
                    .font(.gwaTopSystem(size: 15, weight: .bold))
            }
            .foregroundStyle(GwaTopHomeTheme.primary)
            .frame(maxWidth: .infinity).frame(height: 42)
            .background(GwaTopHomeTheme.primary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .disabled(isLoading)
    }
}

/// 사용자에게 노출할 짧은 라벨. "all" → "전체 페이지", 그 외엔 그대로 (예: "1-3 페이지").
func scopeLabel(_ scope: String) -> String {
    if scope == "all" || scope.isEmpty { return "전체 페이지" }
    return "\(scope) 페이지"
}

private struct GwaTopErrorBanner: View {
    let message: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(GwaTopHomeTheme.danger)
            Text(message).font(.gwaTopSystem(size: 14, weight: .bold))
                .foregroundStyle(GwaTopHomeTheme.danger)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GwaTopHomeTheme.danger.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - 1) 퀴즈

/// 퀴즈 진행 방식. 시작 화면에서 사용자가 고른다.
enum GwaTopQuizMode: String, CaseIterable, Identifiable {
    /// 한 문제씩 정답을 즉시 확인. 학습 중심.
    case instant
    /// 모든 문제를 먼저 풀고 마지막에 한 번에 정답·해설을 본다. 시험 형식.
    case batch

    var id: String { rawValue }

    var label: String {
        switch self {
        case .instant: return "바로 정답 공개"
        case .batch:   return "끝나고 한 번에"
        }
    }

    var helper: String {
        switch self {
        case .instant: return "한 문제씩 풀고 정답을 바로 확인해요."
        case .batch:   return "모든 문제를 푼 뒤 정답과 해설을 한 번에 봐요."
        }
    }
}

/// 한 문제에 대한 사용자의 풀이 상태. 이전/다음 이동 시에도 입력이 유지되도록 보관.
private struct GwaTopQuizAttempt: Equatable {
    var selectedChoice: Int? = nil
    var shortAnswerInput: String = ""
    var hasRevealedAnswer: Bool = false
}

struct GwaTopFileQuizTab: View {
    let file: GwaTopFileSummary

    @State private var quiz: GwaTopQuizContent? = nil
    @State private var scope: String = "all"
    @State private var mode: GwaTopQuizMode = .instant
    @State private var isLoading = false
    @State private var isGenerating = false
    @State private var error: String? = nil

    @State private var currentIndex: Int = 0
    @State private var attempts: [Int: GwaTopQuizAttempt] = [:]
    /// `.batch` 모드에서 모든 문제를 푼 뒤 결과 뷰로 전환.
    @State private var showingResult: Bool = false

    @State private var showingPlayer = false

    var body: some View {
        launcherView
            .fullScreenCover(isPresented: $showingPlayer, onDismiss: resetPlayerState) {
                playerView
            }
    }

    /// 탭 진입 시 보여줄 페이지 범위 + 모드 선택 + 시작 버튼.
    /// "자료 기반 퀴즈" 인트로 설명 카드는 사용자 요청으로 제거 — 곧장 옵션부터 노출.
    private var launcherView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                GwaTopScopeSelector(scope: $scope)
                modeSelector
                Button {
                    showingPlayer = true
                    Task { await load() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "play.fill")
                        Text("퀴즈 시작")
                            .font(.gwaTopSystem(size: 17, weight: .bold))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity).frame(height: 52)
                    .background(GwaTopHomeTheme.primary)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
            .padding(16)
        }
    }

    private var modeSelector: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("정답 공개 방식")
                .font(.gwaTopSystem(size: 13, weight: .bold))
                .foregroundStyle(GwaTopHomeTheme.textSecondary)
            HStack(spacing: 8) {
                ForEach(GwaTopQuizMode.allCases) { m in
                    Button {
                        mode = m
                    } label: {
                        Text(m.label)
                            .font(.gwaTopSystem(size: 14, weight: .bold))
                            .foregroundStyle(mode == m ? .white : GwaTopHomeTheme.textPrimary)
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .frame(maxWidth: .infinity)
                            .background(mode == m ? GwaTopHomeTheme.primary : Color.gray.opacity(0.1))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            Text(mode.helper)
                .font(.gwaTopSystem(size: 12))
                .foregroundStyle(GwaTopHomeTheme.textSecondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GwaTopHomeTheme.primary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// fullScreenCover 로 띄우는 실제 학습 화면.
    /// 레이아웃: 상단 ScrollView(문제/해설) + 하단 고정 액션 바. 해설이 길어도 위 영역에서
    /// 스크롤 가능하고, 버튼은 화면 아래에 항상 노출된다.
    private var playerView: some View {
        NavigationStack {
            ZStack {
                GwaTopHomeTheme.background.ignoresSafeArea()
                VStack(spacing: 0) {
                    ScrollView {
                        VStack(spacing: 14) {
                            if let err = error { GwaTopErrorBanner(message: err) }
                            if let q = quiz, !q.questions.isEmpty {
                                if showingResult {
                                    resultCard(q)
                                } else {
                                    quizCard(q)
                                }
                                GwaTopRegenerateButton(isLoading: isGenerating) {
                                    Task { await generate(force: true, excludePrevious: false) }
                                }
                                generateDifferentButton
                            } else if isLoading || isGenerating {
                                pendingCard
                            } else {
                                HStack(spacing: 10) {
                                    ProgressView()
                                    Text("준비 중…").font(.gwaTopSystem(size: 15, weight: .semibold))
                                        .foregroundStyle(GwaTopHomeTheme.textSecondary)
                                }
                                .padding(16)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.white)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            }
                        }
                        .padding(16)
                    }
                    if let q = quiz, !q.questions.isEmpty, !showingResult {
                        bottomActionBar(q)
                    }
                }
            }
            .navigationTitle("퀴즈 · \(scopeLabel(scope))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("닫기") { showingPlayer = false }
                }
            }
        }
    }

    private var generateDifferentButton: some View {
        Button {
            Task { await generate(force: true, excludePrevious: true) }
        } label: {
            HStack(spacing: 6) {
                if isGenerating {
                    ProgressView().scaleEffect(0.7)
                } else {
                    Image(systemName: "sparkles")
                }
                Text(isGenerating ? "새 문제 만드는 중…" : "다른 문제로 새 퀴즈")
                    .font(.gwaTopSystem(size: 15, weight: .bold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity).frame(height: 42)
            .background(isGenerating ? GwaTopHomeTheme.primary.opacity(0.6) : GwaTopHomeTheme.primary)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .disabled(isGenerating)
    }

    private func resetPlayerState() {
        currentIndex = 0
        attempts = [:]
        showingResult = false
    }

    private var pendingCard: some View {
        HStack(spacing: 10) {
            ProgressView()
            Text("AI가 퀴즈를 만드는 중이에요…")
                .font(.gwaTopSystem(size: 15, weight: .semibold))
                .foregroundStyle(GwaTopHomeTheme.textSecondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func currentAttempt(total: Int) -> GwaTopQuizAttempt {
        let safe = min(max(0, currentIndex), max(0, total - 1))
        return attempts[safe] ?? GwaTopQuizAttempt()
    }

    private func updateAttempt(_ block: (inout GwaTopQuizAttempt) -> Void) {
        var a = attempts[currentIndex] ?? GwaTopQuizAttempt()
        block(&a)
        attempts[currentIndex] = a
    }

    private func quizCard(_ q: GwaTopQuizContent) -> some View {
        let total = q.questions.count
        let safeIndex = min(max(0, currentIndex), total - 1)
        let question = q.questions[safeIndex]
        let attempt = currentAttempt(total: total)
        // `.batch` 모드에서는 마지막 결과 화면 전까지 절대 정답을 노출하지 않는다.
        let revealed = mode == .instant && attempt.hasRevealedAnswer

        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("문제 \(safeIndex + 1) / \(total)")
                    .font(.gwaTopSystem(size: 13, weight: .bold))
                    .foregroundStyle(GwaTopHomeTheme.primary)
                Spacer()
                Text(question.type == "multiple_choice" ? "객관식" : "주관식")
                    .font(.gwaTopSystem(size: 12, weight: .heavy))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Color.gray.opacity(0.1))
                    .foregroundStyle(GwaTopHomeTheme.textSecondary)
                    .clipShape(Capsule())
            }

            GwaTopMathText(question.question, fontSize: 17, color: GwaTopHomeTheme.textPrimary)

            if question.type == "multiple_choice", let choices = question.choices {
                VStack(spacing: 8) {
                    ForEach(Array(choices.enumerated()), id: \.offset) { idx, choice in
                        choiceRow(idx: idx, text: choice, question: question, revealed: revealed, attempt: attempt)
                    }
                }
            } else {
                TextField("답을 입력하세요",
                          text: Binding(
                            get: { attempt.shortAnswerInput },
                            set: { v in updateAttempt { $0.shortAnswerInput = v } }
                          ),
                          axis: .vertical)
                    .font(.gwaTopSystem(size: 16))
                    .padding(12)
                    .background(Color.gray.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                if revealed, let ans = question.answer {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("정답").font(.gwaTopSystem(size: 13, weight: .bold)).foregroundStyle(GwaTopHomeTheme.success)
                        GwaTopMathText(ans, fontSize: 15, color: GwaTopHomeTheme.textPrimary)
                    }
                }
            }

            if revealed && !question.explanation.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("해설").font(.gwaTopSystem(size: 13, weight: .bold)).foregroundStyle(GwaTopHomeTheme.primary)
                    GwaTopMathText(question.explanation, fontSize: 14, color: GwaTopHomeTheme.textPrimary)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(GwaTopHomeTheme.primary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .padding(16)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    /// 하단 고정 액션 바. 이전 / 정답 보기(또는 다음) / 다음(또는 결과 보기).
    private func bottomActionBar(_ q: GwaTopQuizContent) -> some View {
        let total = q.questions.count
        let safeIndex = min(max(0, currentIndex), total - 1)
        let attempt = currentAttempt(total: total)
        let isLast = safeIndex == total - 1

        return HStack(spacing: 8) {
            Button {
                goPrevious()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                    Text("이전")
                }
                .font(.gwaTopSystem(size: 15, weight: .bold))
                .frame(maxWidth: .infinity).frame(height: 44)
                .foregroundStyle(safeIndex == 0 ? Color.gray : GwaTopHomeTheme.primary)
                .background(Color.gray.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .disabled(safeIndex == 0)

            if mode == .instant && !attempt.hasRevealedAnswer {
                Button {
                    updateAttempt { $0.hasRevealedAnswer = true }
                } label: {
                    Text("제출")
                        .font(.gwaTopSystem(size: 15, weight: .bold))
                        .frame(maxWidth: .infinity).frame(height: 44)
                        .foregroundStyle(.white)
                        .background(GwaTopHomeTheme.primary)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            } else {
                Button {
                    goNext(total: total)
                } label: {
                    HStack(spacing: 4) {
                        Text(isLast ? (mode == .batch ? "결과 보기" : "처음으로") : "다음")
                        if !isLast { Image(systemName: "chevron.right") }
                    }
                    .font(.gwaTopSystem(size: 15, weight: .bold))
                    .frame(maxWidth: .infinity).frame(height: 44)
                    .foregroundStyle(.white)
                    .background(GwaTopHomeTheme.primary)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.white)
        .overlay(Rectangle().frame(height: 0.5).foregroundStyle(Color.gray.opacity(0.2)), alignment: .top)
    }

    private func choiceRow(
        idx: Int, text: String, question: GwaTopQuizQuestion,
        revealed: Bool, attempt: GwaTopQuizAttempt
    ) -> some View {
        let isSelected = attempt.selectedChoice == idx
        let isCorrect = revealed && question.answerIndex == idx
        let isWrong = revealed && isSelected && question.answerIndex != idx
        let bg: Color = isCorrect ? GwaTopHomeTheme.success.opacity(0.15)
            : isWrong ? GwaTopHomeTheme.danger.opacity(0.12)
            : (isSelected ? GwaTopHomeTheme.primary.opacity(0.10) : Color.gray.opacity(0.05))
        return Button {
            if !revealed { updateAttempt { $0.selectedChoice = idx } }
        } label: {
            HStack {
                Text("\(["A","B","C","D","E","F"][min(idx, 5)])")
                    .font(.gwaTopSystem(size: 13, weight: .heavy))
                    .frame(width: 22, height: 22)
                    .background(isCorrect ? GwaTopHomeTheme.success : (isSelected ? GwaTopHomeTheme.primary : Color.gray.opacity(0.2)))
                    .foregroundStyle(.white)
                    .clipShape(Circle())
                GwaTopMathText(text, fontSize: 15, color: GwaTopHomeTheme.textPrimary)
                Spacer()
                if isCorrect { Image(systemName: "checkmark.circle.fill").foregroundStyle(GwaTopHomeTheme.success) }
                if isWrong   { Image(systemName: "xmark.circle.fill").foregroundStyle(GwaTopHomeTheme.danger) }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(bg)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    /// `.batch` 모드에서 모든 문제를 풀고 마지막 '결과 보기' 를 누르면 표시되는 통합 결과 뷰.
    private func resultCard(_ q: GwaTopQuizContent) -> some View {
        let total = q.questions.count
        let mcCount = q.questions.enumerated().filter { idx, qq in
            qq.type == "multiple_choice" && qq.answerIndex != nil
                && attempts[idx]?.selectedChoice == qq.answerIndex
        }.count
        let mcTotal = q.questions.filter { $0.type == "multiple_choice" }.count

        return VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("결과")
                    .font(.gwaTopSystem(size: 18, weight: .heavy))
                    .foregroundStyle(GwaTopHomeTheme.textPrimary)
                if mcTotal > 0 {
                    Text("객관식 \(mcCount) / \(mcTotal) 정답")
                        .font(.gwaTopSystem(size: 14, weight: .bold))
                        .foregroundStyle(GwaTopHomeTheme.primary)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(GwaTopHomeTheme.primary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            ForEach(Array(q.questions.enumerated()), id: \.offset) { idx, question in
                resultQuestionCard(idx: idx, total: total, question: question)
            }

            Button {
                resetPlayerState()
            } label: {
                Text("다시 풀기")
                    .font(.gwaTopSystem(size: 15, weight: .bold))
                    .foregroundStyle(GwaTopHomeTheme.primary)
                    .frame(maxWidth: .infinity).frame(height: 44)
                    .background(GwaTopHomeTheme.primary.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    private func resultQuestionCard(idx: Int, total: Int, question: GwaTopQuizQuestion) -> some View {
        let attempt = attempts[idx] ?? GwaTopQuizAttempt()
        let userChose = attempt.selectedChoice
        let correctIdx = question.answerIndex
        let isCorrect = question.type == "multiple_choice" && correctIdx != nil && userChose == correctIdx

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("문제 \(idx + 1) / \(total)")
                    .font(.gwaTopSystem(size: 13, weight: .bold))
                    .foregroundStyle(GwaTopHomeTheme.primary)
                Spacer()
                if question.type == "multiple_choice" {
                    if isCorrect {
                        Label("정답", systemImage: "checkmark.circle.fill")
                            .font(.gwaTopSystem(size: 12, weight: .heavy))
                            .foregroundStyle(GwaTopHomeTheme.success)
                    } else if userChose != nil {
                        Label("오답", systemImage: "xmark.circle.fill")
                            .font(.gwaTopSystem(size: 12, weight: .heavy))
                            .foregroundStyle(GwaTopHomeTheme.danger)
                    } else {
                        Text("미응답")
                            .font(.gwaTopSystem(size: 12, weight: .heavy))
                            .foregroundStyle(GwaTopHomeTheme.textSecondary)
                    }
                }
            }
            GwaTopMathText(question.question, fontSize: 16, color: GwaTopHomeTheme.textPrimary)

            if question.type == "multiple_choice", let choices = question.choices {
                VStack(spacing: 6) {
                    ForEach(Array(choices.enumerated()), id: \.offset) { cIdx, choice in
                        let isAnswer = cIdx == correctIdx
                        let isPicked = cIdx == userChose
                        let bg: Color = isAnswer ? GwaTopHomeTheme.success.opacity(0.15)
                            : (isPicked ? GwaTopHomeTheme.danger.opacity(0.12) : Color.gray.opacity(0.05))
                        HStack {
                            Text("\(["A","B","C","D","E","F"][min(cIdx, 5)])")
                                .font(.gwaTopSystem(size: 12, weight: .heavy))
                                .frame(width: 20, height: 20)
                                .background(isAnswer ? GwaTopHomeTheme.success : (isPicked ? GwaTopHomeTheme.danger : Color.gray.opacity(0.2)))
                                .foregroundStyle(.white)
                                .clipShape(Circle())
                            GwaTopMathText(choice, fontSize: 14, color: GwaTopHomeTheme.textPrimary)
                            Spacer()
                            if isAnswer {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(GwaTopHomeTheme.success)
                            } else if isPicked {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(GwaTopHomeTheme.danger)
                            }
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(bg)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    if !attempt.shortAnswerInput.isEmpty {
                        Text("내 답").font(.gwaTopSystem(size: 12, weight: .bold))
                            .foregroundStyle(GwaTopHomeTheme.textSecondary)
                        Text(attempt.shortAnswerInput)
                            .font(.gwaTopSystem(size: 14))
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.gray.opacity(0.06))
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    if let ans = question.answer {
                        Text("정답").font(.gwaTopSystem(size: 12, weight: .bold))
                            .foregroundStyle(GwaTopHomeTheme.success)
                        GwaTopMathText(ans, fontSize: 14, color: GwaTopHomeTheme.textPrimary)
                    }
                }
            }

            if !question.explanation.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("해설").font(.gwaTopSystem(size: 12, weight: .bold)).foregroundStyle(GwaTopHomeTheme.primary)
                    GwaTopMathText(question.explanation, fontSize: 13, color: GwaTopHomeTheme.textPrimary)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(GwaTopHomeTheme.primary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        .padding(14)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func goPrevious() {
        guard currentIndex > 0 else { return }
        currentIndex -= 1
    }

    private func goNext(total: Int) {
        if currentIndex == total - 1 {
            // 마지막 문제. batch 모드면 결과 화면, instant 모드면 처음으로 되돌아간다.
            if mode == .batch {
                showingResult = true
            } else {
                resetPlayerState()
            }
            return
        }
        currentIndex += 1
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
            resetPlayerState()
            // 캐시 없음 + 에러 marker 도 아님 → 백엔드 큐잉 + 폴링.
            if quiz == nil && resp.generationError == nil {
                await generate(force: false, excludePrevious: false)
            }
        } catch {
            if isCancellation(error) { return }
            self.error = error.localizedDescription
        }
    }

    @MainActor
    private func generate(force: Bool, excludePrevious: Bool) async {
        isGenerating = true
        error = nil
        defer { isGenerating = false }
        // 새 문제 생성 옵션이면 현재 보고 있던 문제 텍스트를 그대로 백엔드에 넘겨 중복 출제 방지.
        let exclude: [String]? = excludePrevious
            ? quiz?.questions.map { $0.question }
            : nil
        do {
            let resp = try await GwaTopPDFCache.shared.withDownloadSuspended {
                try await GwaTopFileService.shared.generateAIContentAndWait(
                    fileId: file.id, contentType: "quiz",
                    pages: scope == "all" ? nil : scope,
                    force: force || excludePrevious,
                    excludeQuestions: exclude
                )
            }
            if let errMsg = resp.generationError {
                self.error = "AI 생성 실패: \(errMsg). '다시 생성' 을 눌러주세요."
                return
            }
            quiz = resp.quiz()
            resetPlayerState()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - 2) 플래시카드

/// 플래시카드 필터 — "전체 / 알아요만 / 몰라요만" 보기.
enum GwaTopFlashcardFilter: String, CaseIterable, Identifiable {
    case all, known, unknown
    var id: String { rawValue }
    var label: String {
        switch self {
        case .all: return "전체"
        case .known: return "알아요만"
        case .unknown: return "몰라요만"
        }
    }
}

struct GwaTopFileFlashcardTab: View {
    let file: GwaTopFileSummary

    @State private var cards: [GwaTopAIFlashcard] = []
    @State private var isLoading = false
    @State private var isGenerating = false
    @State private var isAddingMore = false
    @State private var error: String? = nil

    @State private var currentIndex: Int = 0
    @State private var isFlipped: Bool = false
    @State private var knownIds: Set<String> = []
    @State private var unknownIds: Set<String> = []
    @State private var filter: GwaTopFlashcardFilter = .all
    @State private var reachedEnd: Bool = false

    @State private var scope: String = "all"
    @State private var showingPlayer = false

    var body: some View {
        launcherView
            .fullScreenCover(isPresented: $showingPlayer, onDismiss: resetPlayerState) {
                playerView
            }
    }

    /// 현재 필터 기준 카드 목록. .all 이면 전체 순서 유지.
    private var filteredCards: [GwaTopAIFlashcard] {
        switch filter {
        case .all: return cards
        case .known: return cards.filter { knownIds.contains($0.id) }
        case .unknown: return cards.filter { unknownIds.contains($0.id) }
        }
    }

    private var launcherView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                introCard
                GwaTopScopeSelector(scope: $scope)
                Button {
                    showingPlayer = true
                    Task { await load() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "play.fill")
                        Text("플래시카드 시작")
                            .font(.gwaTopSystem(size: 17, weight: .bold))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity).frame(height: 52)
                    .background(GwaTopHomeTheme.primary)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
            .padding(16)
        }
    }

    private var playerView: some View {
        NavigationStack {
            ZStack {
                GwaTopHomeTheme.background.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 14) {
                        if let err = error { GwaTopErrorBanner(message: err) }
                        if cards.isEmpty {
                            if isGenerating || isLoading {
                                pendingCard
                            } else {
                                HStack(spacing: 10) {
                                    ProgressView()
                                    Text("준비 중…").font(.gwaTopSystem(size: 15, weight: .semibold))
                                        .foregroundStyle(GwaTopHomeTheme.textSecondary)
                                }
                                .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                                .background(.white)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            }
                        } else {
                            filterBar
                            statsBar
                            if filteredCards.isEmpty {
                                emptyFilterCard
                            } else if reachedEnd {
                                completionCard
                            } else {
                                cardView
                                actionButtons
                            }
                            moreCardsButton
                        }
                    }
                    .padding(16)
                }
            }
            .navigationTitle("플래시카드 · \(scopeLabel(scope))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("닫기") { showingPlayer = false }
                }
            }
        }
    }

    private func resetPlayerState() {
        currentIndex = 0
        isFlipped = false
        knownIds = []
        unknownIds = []
        filter = .all
        reachedEnd = false
    }

    private var pendingCard: some View {
        HStack(spacing: 10) {
            ProgressView()
            Text("AI가 플래시카드를 만드는 중이에요…")
                .font(.gwaTopSystem(size: 15, weight: .semibold))
                .foregroundStyle(GwaTopHomeTheme.textSecondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var introCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("어려운 개념 카드").font(.gwaTopSystem(size: 17, weight: .bold))
            Text("핵심 용어를 단어장 카드로 만들어 \"알아요/몰라요\"로 스스로 점검할 수 있어요.")
                .font(.gwaTopSystem(size: 14)).foregroundStyle(GwaTopHomeTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// 전체 / 알아요만 / 몰라요만 토글.
    private var filterBar: some View {
        HStack(spacing: 6) {
            ForEach(GwaTopFlashcardFilter.allCases) { f in
                let active = filter == f
                Button {
                    if filter != f {
                        filter = f
                        currentIndex = 0
                        isFlipped = false
                        reachedEnd = false
                    }
                } label: {
                    Text(f.label)
                        .font(.gwaTopSystem(size: 13, weight: .bold))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .foregroundStyle(active ? .white : GwaTopHomeTheme.textPrimary)
                        .background(active ? GwaTopHomeTheme.primary : Color.gray.opacity(0.1))
                        .clipShape(Capsule())
                }
            }
            Spacer()
        }
    }

    private var statsBar: some View {
        HStack {
            if filteredCards.isEmpty {
                Text("0 / 0")
                    .font(.gwaTopSystem(size: 13, weight: .bold))
                    .foregroundStyle(GwaTopHomeTheme.textSecondary)
            } else {
                let pos = min(currentIndex, filteredCards.count - 1) + 1
                Text("\(pos) / \(filteredCards.count)")
                    .font(.gwaTopSystem(size: 13, weight: .bold))
                    .foregroundStyle(GwaTopHomeTheme.primary)
            }
            Spacer()
            Label("\(knownIds.count)", systemImage: "checkmark.circle.fill")
                .font(.gwaTopSystem(size: 13, weight: .bold)).foregroundStyle(GwaTopHomeTheme.success)
            Label("\(unknownIds.count)", systemImage: "xmark.circle.fill")
                .font(.gwaTopSystem(size: 13, weight: .bold)).foregroundStyle(GwaTopHomeTheme.danger)
                .padding(.leading, 6)
        }
    }

    /// 필터 결과가 비어 있을 때 안내.
    private var emptyFilterCard: some View {
        VStack(spacing: 6) {
            Image(systemName: "tray").font(.gwaTopSystem(size: 28))
                .foregroundStyle(GwaTopHomeTheme.textSecondary)
            Text(filter == .known ? "아직 \"알아요\" 표시한 카드가 없어요"
                                  : "아직 \"몰라요\" 표시한 카드가 없어요")
                .font(.gwaTopSystem(size: 14, weight: .semibold))
                .foregroundStyle(GwaTopHomeTheme.textSecondary)
        }
        .padding(28)
        .frame(maxWidth: .infinity)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    /// 카드를 다 본 후 표시되는 완료 화면. "처음으로 돌아가기" 버튼 포함.
    private var completionCard: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.seal.fill")
                .font(.gwaTopSystem(size: 42))
                .foregroundStyle(GwaTopHomeTheme.primary)
            Text("이 묶음을 모두 봤어요!")
                .font(.gwaTopSystem(size: 18, weight: .bold))
            HStack(spacing: 14) {
                Label("\(knownIds.count)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(GwaTopHomeTheme.success)
                Label("\(unknownIds.count)", systemImage: "xmark.circle.fill")
                    .foregroundStyle(GwaTopHomeTheme.danger)
            }
            .font(.gwaTopSystem(size: 14, weight: .semibold))
            Button {
                currentIndex = 0
                isFlipped = false
                reachedEnd = false
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.counterclockwise")
                    Text("처음으로 돌아가기")
                        .font(.gwaTopSystem(size: 16, weight: .bold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity).frame(height: 48)
                .background(GwaTopHomeTheme.primary)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var cardView: some View {
        let safeIndex = min(currentIndex, max(filteredCards.count - 1, 0))
        let card = filteredCards[safeIndex]
        return Button {
            withAnimation(.easeInOut(duration: 0.4)) { isFlipped.toggle() }
        } label: {
            ZStack {
                if isFlipped {
                    VStack(spacing: 12) {
                        Text("정의 / 설명")
                            .font(.gwaTopSystem(size: 12, weight: .bold)).foregroundStyle(.white.opacity(0.8))
                        Text(card.back)
                            .font(.gwaTopSystem(size: 17, weight: .semibold))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(20)
                    .rotation3DEffect(.degrees(180), axis: (x: 0, y: 1, z: 0))
                } else {
                    VStack(spacing: 12) {
                        Text("용어 / 개념")
                            .font(.gwaTopSystem(size: 12, weight: .bold)).foregroundStyle(.white.opacity(0.8))
                        Text(card.front)
                            .font(.system(size: 24, weight: .heavy, design: .rounded))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                        if let hint = card.hint, !hint.isEmpty {
                            Text("힌트: \(hint)")
                                .font(.gwaTopSystem(size: 13)).foregroundStyle(.white.opacity(0.85))
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
                mark(known: false); advance()
            } label: {
                Text("몰라요")
                    .font(.gwaTopSystem(size: 16, weight: .bold))
                    .frame(maxWidth: .infinity).frame(height: 48)
                    .foregroundStyle(GwaTopHomeTheme.danger)
                    .background(GwaTopHomeTheme.danger.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            Button {
                mark(known: true); advance()
            } label: {
                Text("알아요")
                    .font(.gwaTopSystem(size: 16, weight: .bold))
                    .frame(maxWidth: .infinity).frame(height: 48)
                    .foregroundStyle(.white)
                    .background(GwaTopHomeTheme.success)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    /// 기존 카드와 겹치지 않는 새 카드 추가. OpenAI 호출이라 5~10초 대기.
    private var moreCardsButton: some View {
        Button {
            Task { await addMoreCards() }
        } label: {
            HStack(spacing: 6) {
                if isAddingMore { ProgressView().scaleEffect(0.7) }
                else { Image(systemName: "plus.circle") }
                Text(isAddingMore ? "새 카드 만드는 중…" : "플래시카드 더 만들기")
                    .font(.gwaTopSystem(size: 15, weight: .bold))
            }
            .foregroundStyle(GwaTopHomeTheme.primary)
            .frame(maxWidth: .infinity).frame(height: 42)
            .background(GwaTopHomeTheme.primary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .disabled(isAddingMore || isGenerating || isLoading)
    }

    private func mark(known: Bool) {
        let list = filteredCards
        guard !list.isEmpty else { return }
        let idx = min(currentIndex, list.count - 1)
        let id = list[idx].id
        if known {
            knownIds.insert(id); unknownIds.remove(id)
        } else {
            unknownIds.insert(id); knownIds.remove(id)
        }
        // 서버 저장 — 실패 시 사용자에게 표시해서 진단 가능하게.
        // 흔한 원인: 백엔드 재시작 안 함, 마이그레이션 미적용, 인증 만료.
        let fileId = file.id
        let savedScope = scope
        Task { @MainActor in
            do {
                try await GwaTopFileService.shared.setFlashcardStatus(
                    fileId: fileId, scope: savedScope,
                    cardFront: id, status: known ? "known" : "unknown"
                )
            } catch {
                self.error = "상태 저장 실패: \(error.localizedDescription)"
            }
        }
    }

    /// 다음 카드로. 필터 결과 마지막 카드면 완료 화면을 띄운다 (wrap-around 안 함).
    private func advance() {
        let count = filteredCards.count
        guard count > 0 else { return }
        if currentIndex >= count - 1 {
            withAnimation { reachedEnd = true }
        } else {
            withAnimation { isFlipped = false }
            currentIndex += 1
        }
    }

    @MainActor
    private func load() async {
        isLoading = true; error = nil
        defer { isLoading = false }
        do {
            async let contentTask = GwaTopFileService.shared.aiContent(
                fileId: file.id, contentType: "flashcard", scope: scope
            )
            // 이전 마킹 복원은 콘텐츠와 병렬로.
            async let statusTask: [String: String] = (try? await GwaTopFileService.shared
                .flashcardStatuses(fileId: file.id, scope: scope)) ?? [:]

            let resp = try await contentTask
            cards = resp.flashcards()?.cards ?? []
            let statuses = await statusTask
            applyStatuses(statuses)
            currentIndex = 0; isFlipped = false; reachedEnd = false
            // 캐시 미스인 경우 자동으로 생성 큐잉 후 폴링.
            if cards.isEmpty && resp.generationError == nil {
                await generate(force: false)
            }
        } catch { if !isCancellation(error) { self.error = error.localizedDescription } }
    }

    private func applyStatuses(_ statuses: [String: String]) {
        var known: Set<String> = []
        var unknown: Set<String> = []
        for (front, s) in statuses {
            if s == "known" { known.insert(front) }
            else if s == "unknown" { unknown.insert(front) }
        }
        knownIds = known
        unknownIds = unknown
    }

    @MainActor
    private func generate(force: Bool) async {
        isGenerating = true; error = nil
        defer { isGenerating = false }
        do {
            // 생성하는 동안 PDF 다운로드 양보.
            let resp = try await GwaTopPDFCache.shared.withDownloadSuspended {
                try await GwaTopFileService.shared.generateAIContentAndWait(
                    fileId: file.id, contentType: "flashcard",
                    pages: scope == "all" ? nil : scope, force: force
                )
            }
            if let errMsg = resp.generationError {
                self.error = "AI 생성 실패: \(errMsg). '다시 생성' 을 눌러주세요."
                return
            }
            cards = resp.flashcards()?.cards ?? []
            currentIndex = 0; isFlipped = false; reachedEnd = false
            // 같은 front 가 재등장하면 서버에 남은 이전 마킹이 살아남도록 한 번 더 조회.
            let statuses = (try? await GwaTopFileService.shared
                .flashcardStatuses(fileId: file.id, scope: scope)) ?? [:]
            applyStatuses(statuses)
        } catch { self.error = error.localizedDescription }
    }

    @MainActor
    private func addMoreCards() async {
        guard !isAddingMore else { return }
        isAddingMore = true; error = nil
        defer { isAddingMore = false }
        do {
            let resp = try await GwaTopPDFCache.shared.withDownloadSuspended {
                try await GwaTopFileService.shared.generateMoreFlashcards(
                    fileId: file.id, scope: scope
                )
            }
            let prevCount = cards.count
            cards = resp.content.cards
            // 새 카드부터 보여주기 — 사용자가 방금 만든 카드를 바로 확인하도록.
            if filter == .all && cards.count > prevCount {
                currentIndex = prevCount
            } else {
                currentIndex = 0
            }
            isFlipped = false
            reachedEnd = false
        } catch {
            self.error = error.localizedDescription
        }
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

    @State private var scope: String = "all"
    @State private var showingPlayer = false

    var body: some View {
        launcherView
            .fullScreenCover(isPresented: $showingPlayer, onDismiss: { expandedLabels = [] }) {
                playerView
            }
    }

    private var launcherView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                introCard
                GwaTopScopeSelector(scope: $scope)
                Button {
                    showingPlayer = true
                    Task { await load() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "play.fill")
                        Text("마인드맵 시작")
                            .font(.gwaTopSystem(size: 17, weight: .bold))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity).frame(height: 52)
                    .background(GwaTopHomeTheme.primary)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
            .padding(16)
        }
    }

    private var playerView: some View {
        NavigationStack {
            ZStack {
                GwaTopHomeTheme.background.ignoresSafeArea()

                if let m = mindmap {
                    // 캔버스는 ScrollView 밖에서 전체 화면을 채워야 드래그/핀치가 동작.
                    GwaTopMindmapCanvas(mindmap: m)
                        .ignoresSafeArea(edges: .bottom)
                } else if isGenerating || isLoading {
                    pendingCard.padding(16)
                } else {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("준비 중…").font(.gwaTopSystem(size: 15, weight: .semibold))
                            .foregroundStyle(GwaTopHomeTheme.textSecondary)
                    }
                    .padding(16)
                    .background(GwaTopHomeTheme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }

                if let err = error {
                    VStack {
                        GwaTopErrorBanner(message: err)
                        Spacer()
                    }
                    .padding(16)
                }
            }
            .navigationTitle("마인드맵 · \(scopeLabel(scope))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("닫기") { showingPlayer = false }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await generate(force: true) }
                    } label: {
                        if isGenerating {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .disabled(isGenerating)
                }
            }
        }
    }

    private var pendingCard: some View {
        HStack(spacing: 10) {
            ProgressView()
            Text("AI가 트리 구조를 그리는 중이에요…")
                .font(.gwaTopSystem(size: 15, weight: .semibold))
                .foregroundStyle(GwaTopHomeTheme.textSecondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var introCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("개념 마인드맵").font(.gwaTopSystem(size: 17, weight: .bold))
            Text("자료의 핵심 개념을 트리 구조로 시각화해드려요.")
                .font(.gwaTopSystem(size: 14)).foregroundStyle(GwaTopHomeTheme.textSecondary)
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(.white).clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func rootNode(_ m: GwaTopMindmapContent) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(m.root)
                .font(.system(size: 20, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(GwaTopHomeTheme.primary)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            ForEach(m.children) { child in
                MindmapNodeView(node: child, depth: 1, expandedLabels: $expandedLabels)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    @MainActor
    private func load() async {
        isLoading = true; error = nil
        defer { isLoading = false }
        do {
            let resp = try await GwaTopFileService.shared.aiContent(
                fileId: file.id, contentType: "mindmap", scope: scope
            )
            mindmap = resp.mindmap()
            if mindmap == nil && resp.generationError == nil {
                await generate(force: false)
            }
        } catch { if !isCancellation(error) { self.error = error.localizedDescription } }
    }

    @MainActor
    private func generate(force: Bool) async {
        isGenerating = true; error = nil
        defer { isGenerating = false }
        do {
            // 생성하는 동안 PDF 다운로드 양보.
            let resp = try await GwaTopPDFCache.shared.withDownloadSuspended {
                try await GwaTopFileService.shared.generateAIContentAndWait(
                    fileId: file.id, contentType: "mindmap",
                    pages: scope == "all" ? nil : scope, force: force
                )
            }
            if let errMsg = resp.generationError {
                self.error = "AI 생성 실패: \(errMsg). '다시 생성' 을 눌러주세요."
                return
            }
            mindmap = resp.mindmap()
            expandedLabels = []
        } catch { self.error = error.localizedDescription }
    }
}

/// 마인드맵 노드 — 재귀 뷰는 SwiftUI 에서 self-referencing opaque type 을 만들 수 없어
/// 별도 View 구조체로 분리해야 한다. (`some View` 안에서 같은 함수를 재귀 호출 불가)
struct MindmapNodeView: View {
    let node: GwaTopMindmapNode
    let depth: Int
    @Binding var expandedLabels: Set<String>

    var body: some View {
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
                        .font(.gwaTopSystem(size: hasChildren ? 9 : 5, weight: .bold))
                        .foregroundStyle(hasChildren ? GwaTopHomeTheme.primary : Color.gray)
                        .frame(width: 14)
                    Text(node.label)
                        .font(.gwaTopSystem(size: 15 - CGFloat(depth - 1), weight: depth <= 2 ? .bold : .semibold))
                        .foregroundStyle(GwaTopHomeTheme.textPrimary)
                }
            }
            .buttonStyle(.plain)

            if expanded && hasChildren {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(node.children) { sub in
                        MindmapNodeView(node: sub, depth: depth + 1, expandedLabels: $expandedLabels)
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
}

// MARK: - 4) 암기 포인트

struct GwaTopFileMemorizeTab: View {
    let file: GwaTopFileSummary

    @State private var content: GwaTopMemorizeContent? = nil
    @State private var scope: String = "all"
    @State private var isGenerating = false
    @State private var isLoading = false
    @State private var error: String? = nil
    @State private var showingPlayer = false

    var body: some View {
        launcherView
            .fullScreenCover(isPresented: $showingPlayer) { playerView }
    }

    private var launcherView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                introCard
                GwaTopScopeSelector(scope: $scope)
                Button {
                    showingPlayer = true
                    Task { await load() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "play.fill")
                        Text("암기 포인트 보기").font(.gwaTopSystem(size: 17, weight: .bold))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity).frame(height: 52)
                    .background(GwaTopHomeTheme.primary)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
            .padding(16)
        }
    }

    private var playerView: some View {
        NavigationStack {
            ZStack {
                GwaTopHomeTheme.background.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 14) {
                        if let err = error { GwaTopErrorBanner(message: err) }
                        if let c = content {
                            pointsList(c)
                            GwaTopRegenerateButton(isLoading: isGenerating) {
                                Task { await generate(force: true) }
                            }
                        } else if isGenerating || isLoading {
                            pendingCard
                        } else {
                            HStack(spacing: 10) {
                                ProgressView()
                                Text("준비 중…").font(.gwaTopSystem(size: 15, weight: .semibold))
                                    .foregroundStyle(GwaTopHomeTheme.textSecondary)
                            }
                            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                            .background(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                    }
                    .padding(16)
                }
            }
            .navigationTitle("암기 포인트 · \(scopeLabel(scope))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("닫기") { showingPlayer = false }
                }
            }
        }
    }

    private var pendingCard: some View {
        HStack(spacing: 10) {
            ProgressView()
            Text("AI가 암기 포인트를 정리하는 중이에요…")
                .font(.gwaTopSystem(size: 15, weight: .semibold))
                .foregroundStyle(GwaTopHomeTheme.textSecondary)
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(.white).clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var introCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("시험 대비 암기 포인트").font(.gwaTopSystem(size: 17, weight: .bold))
            Text("자료에서 시험에 자주 출제될 만한 사실/공식/정의/날짜를 뽑아드려요.")
                .font(.gwaTopSystem(size: 14)).foregroundStyle(GwaTopHomeTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(.white).clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func pointsList(_ c: GwaTopMemorizeContent) -> some View {
        let grouped = Dictionary(grouping: c.points, by: { $0.category })
        let categories = grouped.keys.sorted()
        return VStack(alignment: .leading, spacing: 22) {
            ForEach(categories, id: \.self) { cat in
                VStack(alignment: .leading, spacing: 10) {
                    if !cat.isEmpty {
                        // 카테고리 헤더 — 미니멀, 트래킹으로 디테일.
                        HStack(spacing: 8) {
                            Capsule()
                                .fill(GwaTopHomeTheme.textSecondary.opacity(0.35))
                                .frame(width: 12, height: 2)
                            Text(cat)
                                .font(.gwaTopSystem(size: 11, weight: .heavy))
                                .foregroundStyle(GwaTopHomeTheme.textSecondary)
                                .tracking(1.6)
                        }
                        .padding(.leading, 4)
                        .padding(.bottom, 2)
                    }
                    VStack(spacing: 10) {
                        ForEach(grouped[cat] ?? []) { p in
                            pointRow(p)
                        }
                    }
                }
            }
        }
    }

    private func pointRow(_ p: GwaTopMemorizePoint) -> some View {
        // 애플 리마인더/메일 카드 스타일 — 좌측 액센트 스파인 + 본문 + 미니멀 도트 인디케이터.
        // 별 5개 가로 정렬을 폐기하여 본문이 카드 폭 전체를 차지 → 글자가 커져도 안 짤림.
        let accent = Self.accentColor(for: p.importance)
        return HStack(alignment: .top, spacing: 0) {
            Rectangle()
                .fill(accent)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 12) {
                // 본문 — LaTeX/수식 자동 KaTeX 렌더 (`$\text{부피}$` 공식도 정상 표시).
                GwaTopMathText(
                    p.text,
                    fontSize: 16,
                    weight: .semibold,
                    color: GwaTopHomeTheme.textPrimary
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                // 중요도 — 별 대신 미세한 도트 (애플 미니멀).
                HStack(spacing: 4) {
                    ForEach(0..<5, id: \.self) { i in
                        Circle()
                            .fill(i < p.importance ? accent : Color.gray.opacity(0.16))
                            .frame(width: 4, height: 4)
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .gwaTopCard(radius: 14)
    }

    /// 중요도 1~5 → 액센트 색상. Claude warm 톤에 맞춘 코랄 → 무채색 그라데이션.
    /// 원색 오렌지/노랑 대신 primary 코랄을 단계적으로 톤다운해 brand 일관성 유지.
    private static func accentColor(for importance: Int) -> Color {
        switch importance {
        case 5: return GwaTopHomeTheme.primary                          // 가장 진한 코랄
        case 4: return GwaTopHomeTheme.primary.opacity(0.75)            // 옅은 코랄
        case 3: return GwaTopHomeTheme.warning                          // muted amber
        case 2: return GwaTopHomeTheme.textSecondary.opacity(0.7)
        default: return GwaTopHomeTheme.textSecondary.opacity(0.45)
        }
    }

    @MainActor
    private func load() async {
        isLoading = true; error = nil
        defer { isLoading = false }
        do {
            let resp = try await GwaTopFileService.shared.aiContent(
                fileId: file.id, contentType: "memorize", scope: scope
            )
            content = resp.memorize()
            if content == nil && resp.generationError == nil {
                await generate(force: false)
            }
        } catch { if !isCancellation(error) { self.error = error.localizedDescription } }
    }

    @MainActor
    private func generate(force: Bool) async {
        isGenerating = true; error = nil
        defer { isGenerating = false }
        do {
            // 생성하는 동안 PDF 다운로드 양보.
            let resp = try await GwaTopPDFCache.shared.withDownloadSuspended {
                try await GwaTopFileService.shared.generateAIContentAndWait(
                    fileId: file.id, contentType: "memorize",
                    pages: scope == "all" ? nil : scope, force: force
                )
            }
            if let errMsg = resp.generationError {
                self.error = "AI 생성 실패: \(errMsg). '다시 생성' 을 눌러주세요."
                return
            }
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
    @State private var isLoading = false
    @State private var error: String? = nil
    @State private var showingPlayer = false

    var body: some View {
        launcherView
            .fullScreenCover(isPresented: $showingPlayer) { playerView }
    }

    private var launcherView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                introCard
                GwaTopScopeSelector(scope: $scope)
                Button {
                    showingPlayer = true
                    Task { await load() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "play.fill")
                        Text("주요 개념 보기").font(.gwaTopSystem(size: 17, weight: .bold))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity).frame(height: 52)
                    .background(GwaTopHomeTheme.primary)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
            .padding(16)
        }
    }

    private var playerView: some View {
        NavigationStack {
            ZStack {
                GwaTopHomeTheme.background.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 14) {
                        if let err = error { GwaTopErrorBanner(message: err) }
                        if let c = content {
                            ForEach(c.topics) { topicCard($0) }
                            GwaTopRegenerateButton(isLoading: isGenerating) {
                                Task { await generate(force: true) }
                            }
                        } else if isGenerating || isLoading {
                            pendingCard
                        } else {
                            HStack(spacing: 10) {
                                ProgressView()
                                Text("준비 중…").font(.gwaTopSystem(size: 15, weight: .semibold))
                                    .foregroundStyle(GwaTopHomeTheme.textSecondary)
                            }
                            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                            .background(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                    }
                    .padding(16)
                }
            }
            .navigationTitle("주요 개념 · \(scopeLabel(scope))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("닫기") { showingPlayer = false }
                }
            }
        }
    }

    private var pendingCard: some View {
        HStack(spacing: 10) {
            ProgressView()
            Text("AI가 주요 개념을 정리하는 중이에요…")
                .font(.gwaTopSystem(size: 15, weight: .semibold))
                .foregroundStyle(GwaTopHomeTheme.textSecondary)
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(.white).clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var introCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("주요 개념").font(.gwaTopSystem(size: 17, weight: .bold))
            Text("자료의 핵심 개념을 짧은 설명과 예시로 정리해드려요.")
                .font(.gwaTopSystem(size: 14)).foregroundStyle(GwaTopHomeTheme.textSecondary)
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(.white).clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func topicCard(_ t: GwaTopTopic) -> some View {
        // 미니멀 — 좌측 헤어라인 액센트 + 충분한 여백.
        // 본문은 GwaTopMathText 로 — 수식이 폭을 넘어도 가로 스크롤되어 잘리지 않음.
        HStack(alignment: .top, spacing: 14) {
            Capsule()
                .fill(GwaTopHomeTheme.primary)
                .frame(width: 2)
                .padding(.vertical, 2)
            VStack(alignment: .leading, spacing: 10) {
                GwaTopMathText(
                    t.title,
                    fontSize: 17, weight: .semibold,
                    color: GwaTopHomeTheme.textPrimary
                )
                GwaTopMathText(
                    t.body,
                    fontSize: 15, weight: .regular,
                    color: GwaTopHomeTheme.textSecondary
                )
                if !t.examples.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(t.examples.enumerated()), id: \.offset) { _, ex in
                            HStack(alignment: .top, spacing: 8) {
                                Circle()
                                    .fill(GwaTopHomeTheme.textTertiary)
                                    .frame(width: 3, height: 3)
                                    .padding(.top, 7)
                                GwaTopMathText(
                                    ex, fontSize: 14, weight: .regular,
                                    color: GwaTopHomeTheme.textSecondary
                                )
                            }
                        }
                    }
                    .padding(.top, 2)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GwaTopHomeTheme.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(GwaTopHomeTheme.separator, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    @MainActor
    private func load() async {
        isLoading = true; error = nil
        defer { isLoading = false }
        do {
            let resp = try await GwaTopFileService.shared.aiContent(
                fileId: file.id, contentType: "topics", scope: scope
            )
            content = resp.topics()
            if content == nil && resp.generationError == nil {
                await generate(force: false)
            }
        } catch { if !isCancellation(error) { self.error = error.localizedDescription } }
    }

    @MainActor
    private func generate(force: Bool) async {
        isGenerating = true; error = nil
        defer { isGenerating = false }
        do {
            // 생성하는 동안 PDF 다운로드 양보.
            let resp = try await GwaTopPDFCache.shared.withDownloadSuspended {
                try await GwaTopFileService.shared.generateAIContentAndWait(
                    fileId: file.id, contentType: "topics",
                    pages: scope == "all" ? nil : scope, force: force
                )
            }
            if let errMsg = resp.generationError {
                self.error = "AI 생성 실패: \(errMsg). '다시 생성' 을 눌러주세요."
                return
            }
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
    @State private var searchQuery: String = ""
    @FocusState private var searchFocused: Bool

    // 검색바는 노트가 3개 이상이거나 사용자가 직접 검색 중일 때만 노출 — 미니멀.
    private var showSearchBar: Bool { notes.count >= 3 || !searchQuery.isEmpty }

    private var filteredNotes: [GwaTopUserNote] {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return notes }
        return notes.filter { n in
            let title = (n.title ?? "").lowercased()
            let content = GwaTopNoteContent.decode(n.body).searchableText.lowercased()
            return title.contains(q) || content.contains(q)
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                if let err = error { GwaTopErrorBanner(message: err) }

                newNoteButton

                if showSearchBar {
                    searchField
                        .padding(.top, 2)
                }

                if isLoading && notes.isEmpty {
                    ProgressView()
                        .tint(GwaTopHomeTheme.textSecondary)
                        .padding(.top, 40)
                } else if notes.isEmpty {
                    emptyState
                } else if filteredNotes.isEmpty {
                    noMatchState
                } else {
                    ForEach(filteredNotes) { n in
                        noteCard(n)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .background(GwaTopHomeTheme.background)
        .task { await load() }
        .sheet(isPresented: $showEditor) {
            GwaTopNoteEditorSheet(fileId: file.id, existing: editingNote) {
                Task { await load() }
            }
        }
    }

    // MARK: 헤더 & 검색

    private var newNoteButton: some View {
        Button {
            editingNote = nil
            showEditor = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "square.and.pencil")
                    .font(.gwaTopSystem(size: 15, weight: .semibold))
                Text("새 노트")
                    .font(.gwaTopSystem(size: 15, weight: .semibold))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.gwaTopSystem(size: 12, weight: .semibold))
                    .foregroundStyle(GwaTopHomeTheme.textTertiary)
            }
            .foregroundStyle(GwaTopHomeTheme.primary)
            .padding(.horizontal, 16)
            .frame(height: 48)
            .frame(maxWidth: .infinity)
            .background(GwaTopHomeTheme.surface)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(GwaTopHomeTheme.separator, lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.gwaTopSystem(size: 14, weight: .medium))
                .foregroundStyle(GwaTopHomeTheme.textTertiary)
            TextField("노트 검색", text: $searchQuery)
                .font(.gwaTopSystem(size: 15))
                .focused($searchFocused)
                .submitLabel(.search)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !searchQuery.isEmpty {
                Button {
                    searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.gwaTopSystem(size: 15))
                        .foregroundStyle(GwaTopHomeTheme.textTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(GwaTopHomeTheme.surfaceMute)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: 빈 상태

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "note.text")
                .font(.gwaTopSystem(size: 28, weight: .light))
                .foregroundStyle(GwaTopHomeTheme.textTertiary)
            Text("아직 노트가 없어요")
                .font(.gwaTopSystem(size: 15, weight: .medium))
                .foregroundStyle(GwaTopHomeTheme.textSecondary)
            Text("위의 ‘새 노트’ 로 시작해보세요")
                .font(.gwaTopSystem(size: 13))
                .foregroundStyle(GwaTopHomeTheme.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 56)
    }

    private var noMatchState: some View {
        VStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.gwaTopSystem(size: 22, weight: .light))
                .foregroundStyle(GwaTopHomeTheme.textTertiary)
            Text("일치하는 노트가 없어요")
                .font(.gwaTopSystem(size: 14, weight: .medium))
                .foregroundStyle(GwaTopHomeTheme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 36)
    }

    // MARK: 노트 카드

    @ViewBuilder
    private func noteCard(_ n: GwaTopUserNote) -> some View {
        let content = GwaTopNoteContent.decode(n.body)
        Button {
            editingNote = n
            showEditor = true
        } label: {
            HStack(alignment: .top, spacing: 12) {
                // 손글씨 노트는 좌측 미니 썸네일, 텍스트는 작은 아이콘.
                noteLeadingIcon(content)

                VStack(alignment: .leading, spacing: 4) {
                    if let title = n.title, !title.isEmpty {
                        highlightedText(title, query: searchQuery, size: 16, weight: .semibold,
                                        color: GwaTopHomeTheme.textPrimary, lineLimit: 1)
                    }
                    if content.isInk {
                        Text(content.previewText.isEmpty ? "손글씨 노트" : content.previewText)
                            .font(.gwaTopSystem(size: 14))
                            .foregroundStyle(GwaTopHomeTheme.textSecondary)
                            .lineLimit(2)
                    } else {
                        highlightedText(content.previewText, query: searchQuery,
                                        size: 14, weight: .regular,
                                        color: GwaTopHomeTheme.textSecondary, lineLimit: 3)
                    }
                    Text(shortDate(n.updatedAt))
                        .font(.gwaTopSystem(size: 12))
                        .foregroundStyle(GwaTopHomeTheme.textTertiary)
                        .padding(.top, 2)
                }

                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(GwaTopHomeTheme.surface)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(GwaTopHomeTheme.separator, lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) {
                Task { await delete(n) }
            } label: { Label("삭제", systemImage: "trash") }
        }
    }

    @ViewBuilder
    private func noteLeadingIcon(_ content: GwaTopNoteContent) -> some View {
        switch content {
        case .ink(let drawing, _):
            if let img = drawing.gwaTopThumbnail(size: CGSize(width: 44, height: 44)) {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 44, height: 44)
                    .background(GwaTopHomeTheme.surfaceMute)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                fallbackIcon(systemName: "scribble.variable")
            }
        case .text:
            fallbackIcon(systemName: "text.alignleft")
        }
    }

    private func fallbackIcon(systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.gwaTopSystem(size: 16, weight: .medium))
            .foregroundStyle(GwaTopHomeTheme.primary)
            .frame(width: 32, height: 32)
            .background(GwaTopHomeTheme.primary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    /// 검색어가 본문 내에 포함되면 노란 하이라이트로 표시.
    @ViewBuilder
    private func highlightedText(
        _ text: String, query: String,
        size: CGFloat, weight: Font.Weight, color: Color, lineLimit: Int
    ) -> some View {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty {
            Text(text)
                .font(.gwaTopSystem(size: size, weight: weight))
                .foregroundStyle(color)
                .lineLimit(lineLimit)
                .multilineTextAlignment(.leading)
        } else {
            Text(Self.attributed(text, highlight: q))
                .font(.gwaTopSystem(size: size, weight: weight))
                .foregroundStyle(color)
                .lineLimit(lineLimit)
                .multilineTextAlignment(.leading)
        }
    }

    /// 검색어 매칭 부분을 강조한 AttributedString 생성.
    private static func attributed(_ source: String, highlight: String) -> AttributedString {
        var attr = AttributedString(source)
        let lcSource = source.lowercased()
        let lcQuery = highlight.lowercased()
        guard !lcQuery.isEmpty else { return attr }
        var searchStart = lcSource.startIndex
        while let range = lcSource.range(of: lcQuery, range: searchStart..<lcSource.endIndex) {
            if let lower = AttributedString.Index(range.lowerBound, within: attr),
               let upper = AttributedString.Index(range.upperBound, within: attr) {
                attr[lower..<upper].backgroundColor = GwaTopHomeTheme.warning.opacity(0.35)
                attr[lower..<upper].foregroundColor = GwaTopHomeTheme.textPrimary
            }
            searchStart = range.upperBound
        }
        return attr
    }

    private func shortDate(_ d: Date) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "ko_KR")
        let cal = Calendar.current
        if cal.isDateInToday(d) {
            fmt.dateFormat = "HH:mm"
        } else if cal.isDateInYesterday(d) {
            return "어제"
        } else {
            fmt.dateFormat = "M월 d일"
        }
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
        } catch {
            self.error = error.localizedDescription
        }
    }
}


struct GwaTopNoteEditorSheet: View {
    let fileId: String
    let existing: GwaTopUserNote?
    let onSaved: () -> Void

    enum Mode: String, CaseIterable { case text, ink }

    @Environment(\.dismiss) private var dismiss
    @State private var noteTitle: String = ""
    @State private var noteBody: String = ""    // 주의: View 프로토콜의 `body` 와 충돌하지 않게 별도 이름.
    @State private var mode: Mode = .text
    @State private var drawing = PKDrawing()
    @State private var inkTool: PKTool = PKInkingTool(.pen, color: .label, width: 4)
    @State private var inkColorChoice: InkColor = .black
    @State private var inkStyle: InkStyle = .pen
    @State private var isSaving = false
    @State private var errorMessage: String? = nil
    @FocusState private var titleFocused: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                GwaTopHomeTheme.background.ignoresSafeArea()
                VStack(spacing: 10) {
                    titleField

                    modeSegmented

                    if mode == .text {
                        textCanvas
                    } else {
                        inkCanvas
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.gwaTopSystem(size: 13))
                            .foregroundStyle(GwaTopHomeTheme.danger)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 12)
            }
            .navigationTitle(existing == nil ? "새 노트" : "노트 편집")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("취소") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(isSaving ? "저장 중…" : "저장") {
                        Task { await save() }
                    }
                    .fontWeight(.semibold)
                    .disabled(isSaving || !canSave)
                }
            }
            .onAppear { loadExisting() }
        }
    }

    // MARK: 헤더

    private var titleField: some View {
        TextField("제목", text: $noteTitle)
            .font(.gwaTopSystem(size: 22, weight: .semibold))
            .focused($titleFocused)
            .padding(.horizontal, 4)
            .padding(.vertical, 4)
    }

    private var modeSegmented: some View {
        HStack(spacing: 4) {
            ForEach(Mode.allCases, id: \.self) { m in
                Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                        mode = m
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: m == .text ? "textformat" : "pencil.tip")
                            .font(.gwaTopSystem(size: 13, weight: .semibold))
                        Text(m == .text ? "텍스트" : "손글씨")
                            .font(.gwaTopSystem(size: 14, weight: .semibold))
                    }
                    .foregroundStyle(mode == m ? GwaTopHomeTheme.textPrimary : GwaTopHomeTheme.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(mode == m ? Color.white : Color.clear)
                            .shadow(color: mode == m ? GwaTopHomeTheme.cardShadow : .clear, radius: 1, y: 0.5)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(GwaTopHomeTheme.surfaceMute)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    // MARK: 텍스트 캔버스

    private var textCanvas: some View {
        TextEditor(text: $noteBody)
            .font(.gwaTopSystem(size: 17))
            .scrollContentBackground(.hidden)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(GwaTopHomeTheme.surface)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(GwaTopHomeTheme.separator, lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: 손글씨 캔버스

    private var inkCanvas: some View {
        VStack(spacing: 8) {
            ZStack {
                // 종이 격자 — Apple Notes 의 미세한 점 그리드 느낌.
                GridBackground()
                    .opacity(0.5)
                GwaTopInkCanvasView(drawing: $drawing, tool: $inkTool, isEditable: true)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(GwaTopHomeTheme.surface)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(GwaTopHomeTheme.separator, lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            inkToolbar

            TextField("캡션 (선택)", text: $noteBody)
                .font(.gwaTopSystem(size: 14))
                .padding(.horizontal, 12)
                .frame(height: 36)
                .background(GwaTopHomeTheme.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(GwaTopHomeTheme.separator, lineWidth: 0.5)
                )
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private var inkToolbar: some View {
        HStack(spacing: 12) {
            // 도구
            HStack(spacing: 6) {
                inkStyleButton(.pen, systemName: "pencil.tip")
                inkStyleButton(.marker, systemName: "highlighter")
                inkStyleButton(.eraser, systemName: "eraser")
            }

            Divider().frame(height: 18)

            // 색상
            HStack(spacing: 8) {
                ForEach(InkColor.allCases, id: \.self) { c in
                    Button {
                        inkColorChoice = c
                        applyTool()
                    } label: {
                        Circle()
                            .fill(c.color)
                            .frame(width: 18, height: 18)
                            .overlay(
                                Circle()
                                    .stroke(GwaTopHomeTheme.textPrimary,
                                            lineWidth: inkColorChoice == c ? 1.5 : 0)
                                    .padding(-3)
                            )
                            .opacity(inkStyle == .eraser ? 0.3 : 1)
                    }
                    .buttonStyle(.plain)
                    .disabled(inkStyle == .eraser)
                }
            }

            Spacer()

            Button {
                drawing = PKDrawing()
            } label: {
                Image(systemName: "trash")
                    .font(.gwaTopSystem(size: 14, weight: .semibold))
                    .foregroundStyle(GwaTopHomeTheme.textSecondary)
                    .frame(width: 32, height: 32)
                    .background(GwaTopHomeTheme.surfaceMute)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(drawing.strokes.isEmpty)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(GwaTopHomeTheme.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(GwaTopHomeTheme.separator, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func inkStyleButton(_ style: InkStyle, systemName: String) -> some View {
        Button {
            inkStyle = style
            applyTool()
        } label: {
            Image(systemName: systemName)
                .font(.gwaTopSystem(size: 14, weight: .semibold))
                .foregroundStyle(inkStyle == style ? .white : GwaTopHomeTheme.textPrimary)
                .frame(width: 32, height: 32)
                .background(inkStyle == style ? GwaTopHomeTheme.primary : GwaTopHomeTheme.surfaceMute)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func applyTool() {
        switch inkStyle {
        case .pen:
            inkTool = PKInkingTool(.pen, color: UIColor(inkColorChoice.color), width: 4)
        case .marker:
            inkTool = PKInkingTool(.marker, color: UIColor(inkColorChoice.color), width: 12)
        case .eraser:
            inkTool = PKEraserTool(.bitmap)
        }
    }

    // MARK: 저장 / 로드

    private var canSave: Bool {
        if mode == .ink {
            return !drawing.strokes.isEmpty
        }
        return !noteBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func loadExisting() {
        noteTitle = existing?.title ?? ""
        if let existing {
            let parsed = GwaTopNoteContent.decode(existing.body)
            switch parsed {
            case .text(let s):
                noteBody = s
                mode = .text
            case .ink(let d, let caption):
                drawing = d
                noteBody = caption
                mode = .ink
            }
        } else {
            // 새 노트는 제목에 포커스 — 곧장 입력 가능.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                titleFocused = true
            }
        }
        applyTool()
    }

    @MainActor
    private func save() async {
        isSaving = true
        defer { isSaving = false }

        let serializedBody: String
        switch mode {
        case .text:
            serializedBody = GwaTopNoteContent.text(noteBody).encode()
        case .ink:
            serializedBody = GwaTopNoteContent.ink(
                drawing: drawing,
                caption: noteBody.trimmingCharacters(in: .whitespacesAndNewlines)
            ).encode()
        }

        do {
            if let existing {
                _ = try await GwaTopFileService.shared.updateNote(
                    fileId: fileId, noteId: existing.id,
                    title: noteTitle.isEmpty ? nil : noteTitle, body: serializedBody
                )
            } else {
                _ = try await GwaTopFileService.shared.createNote(
                    fileId: fileId,
                    title: noteTitle.isEmpty ? nil : noteTitle, body: serializedBody
                )
            }
            onSaved()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - 7) AI 튜터 (전문 학습 튜터 UI)

/// AI 가 응답을 만드는 동안 사용자에게 보여줄 단계별 진행 메시지.
/// 일정 시간 경과 시 자연스럽게 다음 단계로 넘어가서 "지금 어디까지 했어요" 느낌을 준다.
private struct GwaTopThinkingStage {
    let label: String
    let icon: String
    let afterSeconds: Double
}

private let GwaTopThinkingStages: [GwaTopThinkingStage] = [
    .init(label: "자료를 다시 읽고 있어요", icon: "doc.text.magnifyingglass", afterSeconds: 0),
    .init(label: "관련 개념을 정리 중이에요", icon: "brain.head.profile", afterSeconds: 3),
    .init(label: "예시와 풀이 흐름을 구성 중", icon: "list.bullet.indent", afterSeconds: 8),
    .init(label: "수식을 다듬는 중이에요", icon: "function", afterSeconds: 15),
    .init(label: "답변을 마무리하고 있어요", icon: "checkmark.seal", afterSeconds: 25),
]

struct GwaTopFileTutorTab: View {
    let file: GwaTopFileSummary

    @State private var messages: [GwaTopTutorMessage] = []
    @State private var input: String = ""
    @State private var isLoading = false
    @State private var isSending = false
    @State private var error: String? = nil
    /// 최초 진입 시 이전 대화 fetch 가 끝났는지. 끝나기 전엔 로딩만 보여 메시지가
    /// "팍" 튀어나오는 깜빡임을 방지한다.
    @State private var hasLoaded = false

    /// 진행 중인 AI 응답의 누적 텍스트 (스트리밍 도중 렌더).
    @State private var streamingBody: String = ""
    /// 응답 생성 시작 시각 (경과 시간 표시용).
    @State private var sendStartedAt: Date? = nil
    /// 1초마다 tick — 경과시간 갱신 trigger.
    @State private var elapsedTick: Int = 0

    /// 사진 첨부 — PhotosPicker 선택값과 변환된 base64 data URL 둘 다 보관.
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var attachedImages: [GwaTopTutorAttachment] = []
    @State private var isAttaching: Bool = false

    /// 확대 보기 시트로 띄울 메시지.
    @State private var enlargedMessage: GwaTopTutorMessage? = nil

    var body: some View {
        VStack(spacing: 0) {
            if let err = error {
                GwaTopErrorBanner(message: err).padding(.horizontal, 16).padding(.top, 8)
            }

            if !hasLoaded {
                // 이전 대화를 불러오는 동안 — 로딩만 표시 (메시지 깜빡임 방지).
                loadingState
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 10) {
                            if messages.isEmpty && !isSending {
                                emptyState.padding(.top, 30)
                            }
                            ForEach(messages) { msg in
                                messageRow(msg).id(msg.id)
                            }
                            if isSending {
                                streamingRow.id("__streaming")
                            }
                            Color.clear.frame(height: 1).id("__bottom")
                        }
                        .padding(.vertical, 12)
                    }
                    // 진입 시 최신 메시지(맨 아래)부터 보이도록 초기 앵커를 하단에 고정.
                    .defaultScrollAnchor(.bottom)
                    .onAppear {
                        // ScrollView 가 hasLoaded 이후 생성돼 messages.count onChange 가
                        // 발동하지 않으므로, 등장 시 즉시 맨 아래로 점프.
                        proxy.scrollTo("__bottom", anchor: .bottom)
                    }
                    .onChange(of: messages.count) { _, _ in
                        withAnimation { proxy.scrollTo("__bottom", anchor: .bottom) }
                    }
                    .onChange(of: streamingBody) { _, _ in
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo("__bottom", anchor: .bottom)
                        }
                    }
                }
                .transition(.opacity)
            }

            inputArea
        }
        .animation(.easeInOut(duration: 0.25), value: hasLoaded)
        .task { await load() }
        .task(id: elapsedTick) {
            guard isSending else { return }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if isSending { elapsedTick += 1 }
        }
        .sheet(item: $enlargedMessage) { msg in
            GwaTopTutorEnlargedSheet(message: msg)
        }
    }

    // MARK: 로딩 상태 — 이전 대화 fetch 중

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("이전 대화를 불러오는 중…")
                .font(.gwaTopSystem(size: 14, weight: .medium))
                .foregroundStyle(GwaTopHomeTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 빈 상태 — 추천 질문 칩

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "sparkles")
                .font(.gwaTopSystem(size: 38, weight: .regular))
                .foregroundStyle(GwaTopHomeTheme.primary.opacity(0.55))
            Text("이 자료에 대해 무엇이든 물어보세요")
                .font(.gwaTopSystem(size: 17, weight: .bold))
            Text("이해 안 가는 부분, 시험에 나올 만한 포인트,\n사진 속 수식을 풀어달라고 부탁하기 등 자유롭게.")
                .font(.gwaTopSystem(size: 14))
                .foregroundStyle(GwaTopHomeTheme.textSecondary)
                .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: 8) {
                Text("이렇게 물어볼 수 있어요")
                    .font(.gwaTopSystem(size: 12, weight: .bold))
                    .foregroundStyle(GwaTopHomeTheme.textSecondary)
                ForEach(suggestedPrompts, id: \.self) { prompt in
                    Button {
                        input = prompt
                    } label: {
                        HStack {
                            Image(systemName: "arrow.up.right")
                                .font(.gwaTopSystem(size: 11, weight: .bold))
                                .foregroundStyle(GwaTopHomeTheme.primary)
                            Text(prompt)
                                .font(.gwaTopSystem(size: 14))
                                .foregroundStyle(GwaTopHomeTheme.textPrimary)
                                .multilineTextAlignment(.leading)
                            Spacer()
                        }
                        .padding(.horizontal, 12).padding(.vertical, 10)
                        .background(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 6)
        }
    }

    private var suggestedPrompts: [String] {
        [
            "이 자료의 핵심 개념을 표로 정리해줘",
            "시험에 나올 만한 공식 5개를 LaTeX 로 알려줘",
            "이 부분이 헷갈리는데 단계별로 풀이 과정 보여줘",
            "이 자료의 가장 어려운 개념을 예시와 함께 설명해줘",
        ]
    }

    // MARK: 메시지 표시 (사용자 / AI 분리)

    private func messageRow(_ msg: GwaTopTutorMessage) -> some View {
        Group {
            if msg.role == "user" {
                userBubble(msg)
            } else {
                assistantBubble(msg)
            }
        }
        .padding(.horizontal, 14)
    }

    private func userBubble(_ msg: GwaTopTutorMessage) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Spacer(minLength: 30)
            Text(msg.body)
                .font(.gwaTopSystem(size: 15))
                .foregroundStyle(.white)
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(GwaTopHomeTheme.primary)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .fixedSize(horizontal: false, vertical: true)
            Image(systemName: "person.fill")
                .font(.gwaTopSystem(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Color.gray)
                .clipShape(Circle())
        }
    }

    private func assistantBubble(_ msg: GwaTopTutorMessage) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "sparkles")
                .font(.gwaTopSystem(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(GwaTopHomeTheme.primary)
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 6) {
                // 우측 상단 "크게 보기" 칩 — 본문이 길 때 사용자가 답변 카드 안에서 스크롤
                // 하지 않고도 바로 전체보기 시트를 열 수 있게.
                // 같은 액션이 하단 액션바에도 있어 답변 위/아래 어디서든 접근 가능.
                HStack {
                    Spacer()
                    Button {
                        enlargedMessage = msg
                    } label: {
                        Label("크게 보기", systemImage: "arrow.up.left.and.arrow.down.right")
                            .labelStyle(.titleAndIcon)
                            .font(.gwaTopSystem(size: 11, weight: .bold))
                            .foregroundStyle(GwaTopHomeTheme.primary)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(GwaTopHomeTheme.primary.opacity(0.10))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("답변 크게 보기")
                }

                GwaTopRichText(
                    msg.body,
                    fontSize: 15,
                    color: GwaTopHomeTheme.textPrimary,
                    accent: GwaTopHomeTheme.primary
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                assistantActionBar(for: msg)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(.white)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            Spacer(minLength: 30)
        }
    }

    private func assistantActionBar(for msg: GwaTopTutorMessage) -> some View {
        HStack(spacing: 10) {
            Button {
                UIPasteboard.general.string = msg.body
            } label: {
                Label("복사", systemImage: "doc.on.doc")
                    .font(.gwaTopSystem(size: 12, weight: .semibold))
                    .foregroundStyle(GwaTopHomeTheme.primary)
            }
            .buttonStyle(.plain)

            Button {
                enlargedMessage = msg
            } label: {
                Label("크게 보기", systemImage: "arrow.up.left.and.arrow.down.right")
                    .font(.gwaTopSystem(size: 12, weight: .semibold))
                    .foregroundStyle(GwaTopHomeTheme.primary)
            }
            .buttonStyle(.plain)

            ShareLink(item: msg.body, preview: SharePreview("AI 튜터 답변")) {
                Label("공유", systemImage: "square.and.arrow.up")
                    .font(.gwaTopSystem(size: 12, weight: .semibold))
                    .foregroundStyle(GwaTopHomeTheme.primary)
            }
            .buttonStyle(.plain)

            Button {
                downloadAsText(msg)
            } label: {
                Label("저장", systemImage: "arrow.down.doc")
                    .font(.gwaTopSystem(size: 12, weight: .semibold))
                    .foregroundStyle(GwaTopHomeTheme.primary)
            }
            .buttonStyle(.plain)

            Spacer()
        }
        .padding(.top, 2)
    }

    /// 텍스트 파일로 임시 디렉토리에 저장 후 시스템 공유 시트 띄움.
    private func downloadAsText(_ msg: GwaTopTutorMessage) {
        let header = "GwaTop AI 튜터 답변\n자료: \(file.filename)\n작성: \(msg.createdAt)\n\n---\n\n"
        let content = header + msg.body
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd_HHmmss"
        let name = "gwatop_tutor_\(fmt.string(from: msg.createdAt)).txt"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
            let av = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            let root = scenes.first?.windows.first { $0.isKeyWindow }?.rootViewController
            root?.present(av, animated: true)
        } catch {
            self.error = "텍스트 저장 실패: \(error.localizedDescription)"
        }
    }

    // MARK: 스트리밍 진행 표시

    private var streamingRow: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "sparkles")
                .font(.gwaTopSystem(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(GwaTopHomeTheme.primary)
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 8) {
                thinkingHeader
                if !streamingBody.isEmpty {
                    // 스트리밍 중에는 WebView 를 리로드하면 매 청크마다 깜빡이고 글자가 겹쳐 보임.
                    // 가벼운 SwiftUI Text 로 즉시 표시하고, 완료된 메시지(`.done`)는 어차피
                    // messages 배열에 append 되어 assistantBubble 의 GwaTopRichText 로 다시 렌더된다.
                    Text(streamingBody)
                        .font(.gwaTopSystem(size: 15))
                        .foregroundStyle(GwaTopHomeTheme.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(.white)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            Spacer(minLength: 30)
        }
        .padding(.horizontal, 14)
    }

    private var thinkingHeader: some View {
        _ = elapsedTick  // 매 초 재계산 트리거.
        let elapsed = sendStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        let stage = GwaTopThinkingStages.last { elapsed >= $0.afterSeconds } ?? GwaTopThinkingStages[0]
        return HStack(spacing: 8) {
            ProgressView().scaleEffect(0.7)
            Image(systemName: stage.icon)
                .font(.gwaTopSystem(size: 12, weight: .bold))
                .foregroundStyle(GwaTopHomeTheme.primary)
            Text(stage.label)
                .font(.gwaTopSystem(size: 13, weight: .semibold))
                .foregroundStyle(GwaTopHomeTheme.textSecondary)
            Spacer()
            Text(formatElapsed(elapsed))
                .font(.gwaTopSystem(size: 11, weight: .bold).monospacedDigit())
                .foregroundStyle(GwaTopHomeTheme.textSecondary)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Color.gray.opacity(0.1))
                .clipShape(Capsule())
        }
    }

    private func formatElapsed(_ s: TimeInterval) -> String {
        if s < 60 {
            return String(format: "%.0f초", s)
        }
        let m = Int(s) / 60
        let sec = Int(s) % 60
        return String(format: "%d분 %02d초", m, sec)
    }

    // MARK: 입력 영역 — 첨부 + 텍스트 + 전송

    private var inputArea: some View {
        VStack(spacing: 6) {
            if !attachedImages.isEmpty {
                attachmentStrip
            }
            inputBar
        }
        .padding(12)
        .background(GwaTopHomeTheme.background.opacity(0.92))
    }

    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachedImages) { att in
                    ZStack(alignment: .topTrailing) {
                        Image(uiImage: att.thumbnail)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 56, height: 56)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        Button {
                            attachedImages.removeAll { $0.id == att.id }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.gwaTopSystem(size: 16))
                                .foregroundStyle(.white, .black.opacity(0.7))
                        }
                        .offset(x: 6, y: -6)
                    }
                }
            }
            .padding(.horizontal, 2)
        }
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            PhotosPicker(
                selection: $pickerItems,
                maxSelectionCount: max(1, 4 - attachedImages.count),
                matching: .images
            ) {
                ZStack {
                    Circle()
                        .fill(Color.gray.opacity(0.12))
                        .frame(width: 42, height: 42)
                    if isAttaching {
                        ProgressView().scaleEffect(0.7)
                    } else {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.gwaTopSystem(size: 17, weight: .semibold))
                            .foregroundStyle(GwaTopHomeTheme.primary)
                    }
                }
            }
            .disabled(isAttaching || attachedImages.count >= 4 || isSending)
            .onChange(of: pickerItems) { _, newItems in
                Task { await loadPickerItems(newItems) }
            }

            TextField("질문을 입력하세요", text: $input, axis: .vertical)
                .font(.gwaTopSystem(size: 16))
                .lineLimit(1...5)
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(.white)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            Button {
                Task { await send() }
            } label: {
                Image(systemName: "paperplane.fill")
                    .font(.gwaTopSystem(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(canSend ? GwaTopHomeTheme.primary : Color.gray.opacity(0.5))
                    .clipShape(Circle())
            }
            .disabled(!canSend)
        }
    }

    private var canSend: Bool {
        guard !isSending else { return false }
        let hasText = !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasText || !attachedImages.isEmpty
    }

    // MARK: 액션 — 사진 변환, 로드, 전송

    @MainActor
    private func loadPickerItems(_ items: [PhotosPickerItem]) async {
        guard !items.isEmpty else { return }
        isAttaching = true
        defer { isAttaching = false }
        for item in items {
            guard attachedImages.count < 4 else { break }
            do {
                guard let data = try await item.loadTransferable(type: Data.self),
                      let original = UIImage(data: data) else { continue }
                // 다운샘플링: 긴 변 1024px. base64 페이로드를 OpenAI vision 한도 안에 유지.
                let resized = original.gwaTopDownsampled(maxPixel: 1024)
                guard let jpeg = resized.jpegData(compressionQuality: 0.82) else { continue }
                let base64 = jpeg.base64EncodedString()
                let dataURL = "data:image/jpeg;base64,\(base64)"
                let thumb = original.gwaTopDownsampled(maxPixel: 200)
                attachedImages.append(.init(thumbnail: thumb, dataURL: dataURL))
            } catch {
                self.error = "사진 첨부 실패: \(error.localizedDescription)"
            }
        }
        pickerItems = []
    }

    @MainActor
    private func load() async {
        // 이미 한 번 불러왔으면(예: elapsedTick task 재실행) 다시 로딩 화면을 띄우지 않는다.
        if hasLoaded { return }
        isLoading = true; error = nil
        defer { isLoading = false; hasLoaded = true }
        do {
            messages = try await GwaTopFileService.shared.listTutorMessages(fileId: file.id)
        } catch { if !isCancellation(error) { self.error = error.localizedDescription } }
    }

    @MainActor
    private func send() async {
        let q = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend else { return }
        let images = attachedImages.map(\.dataURL)
        let imageCount = attachedImages.count
        input = ""
        attachedImages = []
        isSending = true
        streamingBody = ""
        sendStartedAt = Date()
        elapsedTick = 1
        defer {
            isSending = false
            streamingBody = ""
            sendStartedAt = nil
        }

        let placeholderId = "__pending_user_\(UUID().uuidString)"
        let placeholderUser = GwaTopTutorMessage(
            id: placeholderId,
            role: "user",
            body: imageCount > 0 ? "\(q)\n\n[이미지 \(imageCount)장 첨부]" : q,
            tokens: nil,
            createdAt: Date()
        )
        messages.append(placeholderUser)

        // 실패 시 placeholder 정리를 한 곳에서 보장.
        func removePlaceholder() {
            messages.removeAll { $0.id == placeholderId }
        }

        let normalizedQ = q.isEmpty ? "첨부한 사진에 대해 설명해줘" : q

        do {
            let stream = GwaTopFileService.shared.askTutorStream(
                fileId: file.id,
                question: normalizedQ,
                images: images.isEmpty ? nil : images
            )
            var receivedAnyDelta = false
            for try await event in stream {
                switch event {
                case .userMessage(let m):
                    if let idx = messages.firstIndex(where: { $0.id == placeholderId }) {
                        messages[idx] = m
                    } else {
                        messages.append(m)
                    }
                case .start:
                    streamingBody = ""
                case .delta(let chunk):
                    receivedAnyDelta = true
                    streamingBody += chunk
                case .done(let m):
                    messages.append(m)
                case .error(let msg):
                    self.error = msg
                    removePlaceholder()
                    input = q
                    return
                }
            }
            _ = receivedAnyDelta  // 향후 분석용
        } catch {
            if isCancellation(error) {
                removePlaceholder()
                return
            }
            // SSE 엔드포인트가 서버에 아직 배포 안 된 경우 (404) — 기존 동기 엔드포인트로 폴백.
            // 같은 이유로 405(Method Not Allowed) / 501 같은 경우도 폴백.
            if Self.isEndpointMissing(error) {
                removePlaceholder()
                // 폴백 경로(OLD 백엔드)는 이미지 미지원 — 첨부가 있으면 사용자에게 알림.
                if imageCount > 0 {
                    self.error = "서버가 아직 사진 첨부 기능을 지원하지 않아요. 텍스트만 보내볼게요."
                }
                await sendFallback(
                    question: normalizedQ,
                    images: [],
                    imageCount: 0,
                    placeholderBody: placeholderUser.body
                )
                return
            }
            self.error = error.localizedDescription
            removePlaceholder()
            input = q
        }
    }

    /// 스트림 엔드포인트가 미배포일 때 사용할 동기 폴백 경로.
    /// 사용자 입력은 이미 비워졌으므로 실패해도 복구할 q 를 인자로 받아둔다.
    @MainActor
    private func sendFallback(
        question: String, images: [String], imageCount: Int, placeholderBody: String
    ) async {
        // 폴백 placeholder — 답이 오기 전까지 사용자 메시지 자리 유지.
        let placeholderId = "__pending_user_fb_\(UUID().uuidString)"
        let placeholder = GwaTopTutorMessage(
            id: placeholderId,
            role: "user",
            body: placeholderBody,
            tokens: nil,
            createdAt: Date()
        )
        messages.append(placeholder)

        do {
            let resp = try await GwaTopFileService.shared.askTutor(
                fileId: file.id,
                question: question,
                images: images.isEmpty ? nil : images
            )
            if let idx = messages.firstIndex(where: { $0.id == placeholderId }) {
                messages[idx] = resp.userMessage
            } else {
                messages.append(resp.userMessage)
            }
            messages.append(resp.assistantMessage)
        } catch {
            messages.removeAll { $0.id == placeholderId }
            if !isCancellation(error) {
                self.error = error.localizedDescription
                input = question
            }
        }
    }

    /// 404/405/501 같은 "엔드포인트 자체 부재" 신호 감지.
    /// 이런 에러일 땐 동기 엔드포인트로 폴백해서 사용자 흐름을 끊지 않는다.
    private static func isEndpointMissing(_ error: Error) -> Bool {
        if let api = error as? GwaTopAPIError, case .server(let code, _) = api {
            return code == 404 || code == 405 || code == 501
        }
        return false
    }
}

/// 첨부된 사진 한 장. 썸네일은 UI, dataURL 은 API 전송용.
private struct GwaTopTutorAttachment: Identifiable {
    let id = UUID()
    let thumbnail: UIImage
    let dataURL: String
}

// MARK: 확대 보기 시트

private struct GwaTopTutorEnlargedSheet: View {
    let message: GwaTopTutorMessage
    @Environment(\.dismiss) private var dismiss
    @State private var scaleFontSize: CGFloat = 18

    var body: some View {
        NavigationStack {
            ZStack {
                GwaTopHomeTheme.background.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        GwaTopRichText(
                            message.body,
                            fontSize: scaleFontSize,
                            color: GwaTopHomeTheme.textPrimary,
                            accent: GwaTopHomeTheme.primary
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .background(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .padding(16)
                }
            }
            .navigationTitle("AI 튜터 답변")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("닫기") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 8) {
                        Button {
                            scaleFontSize = max(13, scaleFontSize - 1)
                        } label: { Image(systemName: "textformat.size.smaller") }
                        Button {
                            scaleFontSize = min(28, scaleFontSize + 1)
                        } label: { Image(systemName: "textformat.size.larger") }
                        Button {
                            UIPasteboard.general.string = message.body
                        } label: { Image(systemName: "doc.on.doc") }
                    }
                }
            }
        }
    }
}

// MARK: - UIImage 다운샘플링 헬퍼

private extension UIImage {
    /// 긴 변이 `maxPixel` 을 넘으면 비율 유지하며 축소.
    func gwaTopDownsampled(maxPixel: CGFloat) -> UIImage {
        let longest = max(size.width, size.height) * scale
        guard longest > maxPixel else { return self }
        let factor = maxPixel / longest
        let newSize = CGSize(width: size.width * factor, height: size.height * factor)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            self.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}

// MARK: - 손글씨 노트 도구 모델

enum InkStyle {
    case pen, marker, eraser
}

enum InkColor: CaseIterable {
    case black, blue, red, green, orange

    var color: Color {
        switch self {
        case .black:  return GwaTopHomeTheme.textPrimary
        case .blue:   return GwaTopHomeTheme.primary
        case .red:    return GwaTopHomeTheme.danger
        case .green:  return GwaTopHomeTheme.success
        case .orange: return GwaTopHomeTheme.warning
        }
    }
}

/// 손글씨 캔버스 배경에 깔리는 미세한 점 격자 — Apple Notes 의 dot grid 느낌.
struct GridBackground: View {
    var spacing: CGFloat = 22
    var dotSize: CGFloat = 1

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                let dotColor = GwaTopHomeTheme.textTertiary.opacity(0.5)
                var y: CGFloat = spacing
                while y < size.height {
                    var x: CGFloat = spacing
                    while x < size.width {
                        let rect = CGRect(x: x - dotSize/2, y: y - dotSize/2,
                                          width: dotSize, height: dotSize)
                        ctx.fill(Path(ellipseIn: rect), with: .color(dotColor))
                        x += spacing
                    }
                    y += spacing
                }
                _ = geo
            }
        }
        .allowsHitTesting(false)
    }
}
