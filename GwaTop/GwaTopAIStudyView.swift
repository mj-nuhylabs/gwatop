import SwiftUI

// MARK: - GwaTop AI Study View
// S-1 학습 홈, S-4 AI 요약 노트, S-5 퀴즈, S-6 플래시카드, S-7 AI 튜터 진입 UI를 Mock 데이터로 구성합니다.

struct GwaTopAIStudyView: View {
    @State private var contents: [GwaTopAIContent] = GwaTopAIContent.sampleData
    @State private var selectedContent: GwaTopAIContent = GwaTopAIContent.sampleData[0]
    @State private var selectedMode: GwaTopAIStudyMode = .summary
    @State private var selectedQuizIndex: Int = 0
    @State private var selectedAnswerIndex: Int? = nil
    @State private var showQuizResult: Bool = false
    @State private var selectedFlashcardIndex: Int = 0
    @State private var isFlashcardFlipped: Bool = false
    @State private var tutorQuestion: String = ""
    @State private var showMaterialUploadSheet: Bool = false
    @State private var showMaterialsSheet: Bool = false

    private var currentQuiz: GwaTopQuizItem? {
        guard selectedContent.quizItems.indices.contains(selectedQuizIndex) else { return nil }
        return selectedContent.quizItems[selectedQuizIndex]
    }

    private var currentFlashcard: GwaTopFlashcard? {
        guard selectedContent.flashcards.indices.contains(selectedFlashcardIndex) else { return nil }
        return selectedContent.flashcards[selectedFlashcardIndex]
    }

    var body: some View {
        NavigationStack {
            ZStack {
                GwaTopHomeTheme.background
                    .ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 18) {
                        heroCard
                            .padding(.top, 14)

                        courseSelector
                        modeSelector

                        Group {
                            switch selectedMode {
                            case .summary:
                                summarySection
                            case .quiz:
                                quizSection
                            case .flashcard:
                                flashcardSection
                            case .tutor:
                                tutorSection
                            }
                        }
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 32)
                }
            }
            .navigationTitle("AI 학습")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 10) {
                        Button {
                            showMaterialsSheet = true
                        } label: {
                            Image(systemName: "folder.fill")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(GwaTopHomeTheme.primary)
                                .frame(width: 40, height: 40)
                                .background(.white)
                                .clipShape(Circle())
                                .shadow(color: .black.opacity(0.05), radius: 10, x: 0, y: 5)
                        }
                        Button {
                            showMaterialUploadSheet = true
                        } label: {
                            Image(systemName: "doc.badge.arrow.up")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(GwaTopHomeTheme.primary)
                                .frame(width: 40, height: 40)
                                .background(.white)
                                .clipShape(Circle())
                                .shadow(color: .black.opacity(0.05), radius: 10, x: 0, y: 5)
                        }
                    }
                }
            }
            .sheet(isPresented: $showMaterialUploadSheet) {
                GwaTopMaterialUploadSheet(onUploadCompleted: {
                    // 업로드 완료 후 자연스럽게 자료 화면으로 넘어가도록 트리거.
                    showMaterialUploadSheet = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        showMaterialsSheet = true
                    }
                })
                .presentationDetents([.large])
            }
            .sheet(isPresented: $showMaterialsSheet) {
                GwaTopCourseMaterialsView()
                    .presentationDetents([.large])
            }
            .onChange(of: selectedContent.id) { _ in
                resetInteractiveStates()
            }
        }
    }

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("AI가 정리한 이번 주 학습")
                        .font(.system(size: 23, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)

                    Text("요약, 예상 문제, 플래시카드까지 한 번에 확인하세요")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.84))
                        .lineLimit(2)
                }

                Spacer()

                Image(systemName: "sparkles")
                    .font(.system(size: 25, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 58, height: 58)
                    .background(.white.opacity(0.16))
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            }

            HStack(spacing: 10) {
                GwaTopAIHeroMetric(title: "요약 노트", value: "\(contents.count)", unit: "개")
                GwaTopAIHeroMetric(title: "문제", value: "\(selectedContent.quizItems.count)", unit: "개")
                GwaTopAIHeroMetric(title: "카드", value: "\(selectedContent.flashcards.count)", unit: "장")
            }
        }
        .padding(20)
        .background(GwaTopHomeTheme.primaryGradient)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .shadow(color: GwaTopHomeTheme.primary.opacity(0.22), radius: 18, x: 0, y: 12)
    }

    private var courseSelector: some View {
        VStack(alignment: .leading, spacing: 12) {
            GwaTopAISectionHeader(title: "과목별 AI 콘텐츠", subtitle: "업로드된 강의자료를 기준으로 생성된 Mock 콘텐츠입니다")

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(contents) { content in
                        Button {
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                                selectedContent = content
                            }
                        } label: {
                            GwaTopAICourseCard(content: content, isSelected: selectedContent.id == content.id)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var modeSelector: some View {
        HStack(spacing: 8) {
            ForEach(GwaTopAIStudyMode.allCases) { mode in
                Button {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.86)) {
                        selectedMode = mode
                    }
                } label: {
                    VStack(spacing: 5) {
                        Image(systemName: mode.iconName)
                            .font(.system(size: 15, weight: .bold))
                        Text(mode.title)
                            .font(.system(size: 12, weight: .bold))
                    }
                    .foregroundStyle(selectedMode == mode ? .white : GwaTopHomeTheme.textSecondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 58)
                    .background(selectedMode == mode ? GwaTopHomeTheme.primary : .white)
                    .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
                }
            }
        }
    }

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 14) {
            GwaTopAIContentTitle(content: selectedContent, label: "AI 요약 노트")

            VStack(alignment: .leading, spacing: 12) {
                ForEach(summaryLines, id: \.self) { line in
                    GwaTopMarkdownLikeLine(line: line)
                }
            }
            .padding(16)
            .background(.white)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .shadow(color: .black.opacity(0.045), radius: 14, x: 0, y: 7)

            HStack(spacing: 10) {
                quickModeButton(mode: .quiz, title: "예상 문제 풀기")
                quickModeButton(mode: .flashcard, title: "플래시카드 보기")
            }
        }
    }

    private var summaryLines: [String] {
        selectedContent.summaryMarkdown
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private var quizSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            GwaTopAIContentTitle(content: selectedContent, label: "AI 예상 문제")

            if let quiz = currentQuiz {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("문제 \(selectedQuizIndex + 1) / \(selectedContent.quizItems.count)")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(GwaTopHomeTheme.primary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(GwaTopHomeTheme.primary.opacity(0.10))
                            .clipShape(Capsule())

                        Spacer()
                    }

                    Text(quiz.question)
                        .font(.system(size: 19, weight: .heavy))
                        .foregroundStyle(GwaTopHomeTheme.textPrimary)
                        .lineSpacing(4)

                    VStack(spacing: 10) {
                        ForEach(Array(quiz.choices.enumerated()), id: \.offset) { index, choice in
                            Button {
                                selectedAnswerIndex = index
                                showQuizResult = true
                            } label: {
                                HStack(spacing: 12) {
                                    Text("\(index + 1)")
                                        .font(.system(size: 13, weight: .heavy))
                                        .foregroundStyle(choiceForeground(index: index, answerIndex: quiz.answerIndex))
                                        .frame(width: 28, height: 28)
                                        .background(choiceForeground(index: index, answerIndex: quiz.answerIndex).opacity(0.12))
                                        .clipShape(Circle())

                                    Text(choice)
                                        .font(.system(size: 15, weight: .bold))
                                        .foregroundStyle(GwaTopHomeTheme.textPrimary)
                                        .multilineTextAlignment(.leading)

                                    Spacer()
                                }
                                .padding(14)
                                .background(choiceBackground(index: index, answerIndex: quiz.answerIndex))
                                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    if showQuizResult, let selectedAnswerIndex {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(selectedAnswerIndex == quiz.answerIndex ? "정답입니다" : "다시 확인해볼까요?")
                                .font(.system(size: 16, weight: .heavy))
                                .foregroundStyle(selectedAnswerIndex == quiz.answerIndex ? GwaTopHomeTheme.success : .red)

                            Text(quiz.explanation)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(GwaTopHomeTheme.textPrimary)
                                .lineSpacing(4)
                        }
                        .padding(14)
                        .background((selectedAnswerIndex == quiz.answerIndex ? GwaTopHomeTheme.success : Color.red).opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }

                    HStack(spacing: 10) {
                        Button("이전") {
                            moveQuiz(by: -1)
                        }
                        .disabled(selectedQuizIndex == 0)
                        .buttonStyle(GwaTopSecondaryButtonStyle())

                        Button(selectedQuizIndex == selectedContent.quizItems.count - 1 ? "처음으로" : "다음") {
                            moveQuiz(by: 1)
                        }
                        .buttonStyle(GwaTopPrimaryButtonStyle())
                    }
                }
                .padding(16)
                .background(.white)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .shadow(color: .black.opacity(0.045), radius: 14, x: 0, y: 7)
            }
        }
    }

    private var flashcardSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            GwaTopAIContentTitle(content: selectedContent, label: "AI 플래시카드")

            if let flashcard = currentFlashcard {
                VStack(spacing: 16) {
                    Button {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.78)) {
                            isFlashcardFlipped.toggle()
                        }
                    } label: {
                        VStack(spacing: 14) {
                            Text(isFlashcardFlipped ? "뒷면" : "앞면")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(.white.opacity(0.80))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(.white.opacity(0.16))
                                .clipShape(Capsule())

                            Text(isFlashcardFlipped ? flashcard.back : flashcard.front)
                                .font(.system(size: isFlashcardFlipped ? 20 : 28, weight: .heavy, design: .rounded))
                                .foregroundStyle(.white)
                                .multilineTextAlignment(.center)
                                .lineSpacing(5)
                                .minimumScaleFactor(0.75)

                            Text("카드를 눌러 \(isFlashcardFlipped ? "앞면" : "뒷면") 보기")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.78))
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 250)
                        .padding(20)
                        .background(
                            LinearGradient(
                                colors: [selectedContent.course.color, GwaTopHomeTheme.primary],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                        .rotation3DEffect(.degrees(isFlashcardFlipped ? 0 : 0), axis: (x: 0, y: 1, z: 0))
                    }
                    .buttonStyle(.plain)

                    HStack(spacing: 10) {
                        Button("모르겠어요") {
                            moveFlashcard(markAs: "low")
                        }
                        .buttonStyle(GwaTopSecondaryButtonStyle())

                        Button("알았어요") {
                            moveFlashcard(markAs: "high")
                        }
                        .buttonStyle(GwaTopPrimaryButtonStyle())
                    }

                    Text("\(selectedFlashcardIndex + 1) / \(selectedContent.flashcards.count)")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(GwaTopHomeTheme.textSecondary)
                }
                .padding(16)
                .background(.white)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .shadow(color: .black.opacity(0.045), radius: 14, x: 0, y: 7)
            }
        }
    }

    private var tutorSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            GwaTopAIContentTitle(content: selectedContent, label: "AI 튜터")

            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 38, height: 38)
                        .background(GwaTopHomeTheme.primary)
                        .clipShape(Circle())

                    VStack(alignment: .leading, spacing: 6) {
                        Text("무엇이든 물어보세요")
                            .font(.system(size: 17, weight: .heavy))
                            .foregroundStyle(GwaTopHomeTheme.textPrimary)

                        Text("현재는 Mock UI입니다. 백엔드 연결 후에는 업로드된 강의자료와 AI 요약을 바탕으로 답변합니다.")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(GwaTopHomeTheme.textSecondary)
                            .lineSpacing(4)
                    }
                }

                TextField("예: LEFT JOIN과 INNER JOIN 차이를 알려줘", text: $tutorQuestion, axis: .vertical)
                    .font(.system(size: 15, weight: .medium))
                    .padding(14)
                    .background(GwaTopHomeTheme.background)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                Button {
                    // 추후 POST /ai/chat API로 연결합니다.
                } label: {
                    HStack {
                        Text("AI 튜터에게 질문하기")
                        Image(systemName: "paperplane.fill")
                    }
                }
                .buttonStyle(GwaTopPrimaryButtonStyle())
            }
            .padding(16)
            .background(.white)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .shadow(color: .black.opacity(0.045), radius: 14, x: 0, y: 7)
        }
    }

    @ViewBuilder
    private func quickModeButton(mode: GwaTopAIStudyMode, title: String) -> some View {
        if mode == .quiz {
            Button {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.86)) {
                    selectedMode = mode
                }
            } label: {
                Text(title)
            }
            .buttonStyle(GwaTopPrimaryButtonStyle())
        } else {
            Button {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.86)) {
                    selectedMode = mode
                }
            } label: {
                Text(title)
            }
            .buttonStyle(GwaTopSecondaryButtonStyle())
        }
    }

    private func choiceForeground(index: Int, answerIndex: Int) -> Color {
        guard showQuizResult else { return GwaTopHomeTheme.primary }
        if index == answerIndex { return GwaTopHomeTheme.success }
        if index == selectedAnswerIndex { return .red }
        return GwaTopHomeTheme.textSecondary
    }

    private func choiceBackground(index: Int, answerIndex: Int) -> Color {
        guard showQuizResult else { return GwaTopHomeTheme.background }
        if index == answerIndex { return GwaTopHomeTheme.success.opacity(0.10) }
        if index == selectedAnswerIndex { return Color.red.opacity(0.08) }
        return GwaTopHomeTheme.background
    }

    private func moveQuiz(by offset: Int) {
        let lastIndex = max(0, selectedContent.quizItems.count - 1)
        if selectedQuizIndex == lastIndex && offset > 0 {
            selectedQuizIndex = 0
        } else {
            selectedQuizIndex = min(max(selectedQuizIndex + offset, 0), lastIndex)
        }
        selectedAnswerIndex = nil
        showQuizResult = false
    }

    private func moveFlashcard(markAs confidence: String) {
        if let contentIndex = contents.firstIndex(where: { $0.id == selectedContent.id }),
           contents[contentIndex].flashcards.indices.contains(selectedFlashcardIndex) {
            contents[contentIndex].flashcards[selectedFlashcardIndex].confidence = confidence
            selectedContent = contents[contentIndex]
        }

        let lastIndex = max(0, selectedContent.flashcards.count - 1)
        selectedFlashcardIndex = selectedFlashcardIndex == lastIndex ? 0 : selectedFlashcardIndex + 1
        isFlashcardFlipped = false
    }

    private func resetInteractiveStates() {
        selectedQuizIndex = 0
        selectedAnswerIndex = nil
        showQuizResult = false
        selectedFlashcardIndex = 0
        isFlashcardFlipped = false
    }
}

private enum GwaTopAIStudyMode: String, CaseIterable, Identifiable {
    case summary
    case quiz
    case flashcard
    case tutor

    var id: String { rawValue }

    var title: String {
        switch self {
        case .summary: return "요약"
        case .quiz: return "퀴즈"
        case .flashcard: return "카드"
        case .tutor: return "튜터"
        }
    }

    var iconName: String {
        switch self {
        case .summary: return "doc.text.fill"
        case .quiz: return "questionmark.circle.fill"
        case .flashcard: return "rectangle.on.rectangle.angled.fill"
        case .tutor: return "bubble.left.and.bubble.right.fill"
        }
    }
}

private struct GwaTopAIHeroMetric: View {
    let title: String
    let value: String
    let unit: String

    var body: some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white.opacity(0.72))

            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: 18, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                Text(unit)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.84))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(.white.opacity(0.14))
        .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
    }
}

private struct GwaTopAISectionHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 21, weight: .bold))
                .foregroundStyle(GwaTopHomeTheme.textPrimary)
            Text(subtitle)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(GwaTopHomeTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct GwaTopAICourseCard: View {
    let content: GwaTopAIContent
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: content.course.iconName)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(isSelected ? .white : content.course.color)
                    .frame(width: 42, height: 42)
                    .background(isSelected ? .white.opacity(0.16) : content.course.color.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))

                Spacer()

                Text("\(content.week)주차")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(isSelected ? .white.opacity(0.86) : GwaTopHomeTheme.textSecondary)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(content.course.name)
                    .font(.system(size: 17, weight: .heavy))
                    .foregroundStyle(isSelected ? .white : GwaTopHomeTheme.textPrimary)

                Text(content.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isSelected ? .white.opacity(0.80) : GwaTopHomeTheme.textSecondary)
                    .lineLimit(2)
            }

            Text("생성: \(content.generatedAtText)")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(isSelected ? .white.opacity(0.76) : GwaTopHomeTheme.textSecondary)
        }
        .frame(width: 190, alignment: .leading)
        .padding(16)
        .background(isSelected ? content.course.color : .white)
        .clipShape(RoundedRectangle(cornerRadius: 23, style: .continuous))
        .shadow(color: isSelected ? content.course.color.opacity(0.22) : .black.opacity(0.04), radius: 12, x: 0, y: 7)
    }
}

private struct GwaTopAIContentTitle: View {
    let content: GwaTopAIContent
    let label: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: content.course.iconName)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(content.course.color)
                .frame(width: 42, height: 42)
                .background(content.course.color.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(label)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(GwaTopHomeTheme.primary)
                Text(content.title)
                    .font(.system(size: 20, weight: .heavy))
                    .foregroundStyle(GwaTopHomeTheme.textPrimary)
                Text("\(content.course.name) · \(content.week)주차")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(GwaTopHomeTheme.textSecondary)
            }

            Spacer()
        }
    }
}

private struct GwaTopMarkdownLikeLine: View {
    let line: String

    var body: some View {
        if line.hasPrefix("###") {
            Text(line.replacingOccurrences(of: "#", with: "").trimmingCharacters(in: .whitespaces))
                .font(.system(size: 17, weight: .heavy))
                .foregroundStyle(GwaTopHomeTheme.primary)
        } else if line.hasPrefix("##") {
            Text(line.replacingOccurrences(of: "#", with: "").trimmingCharacters(in: .whitespaces))
                .font(.system(size: 20, weight: .heavy, design: .rounded))
                .foregroundStyle(GwaTopHomeTheme.textPrimary)
        } else if line.hasPrefix("-") {
            HStack(alignment: .top, spacing: 9) {
                Circle()
                    .fill(GwaTopHomeTheme.primary)
                    .frame(width: 6, height: 6)
                    .padding(.top, 7)
                Text(cleanMarkdown(String(line.dropFirst())))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(GwaTopHomeTheme.textPrimary)
                    .lineSpacing(4)
            }
        } else {
            Text(cleanMarkdown(line))
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(GwaTopHomeTheme.textPrimary)
                .lineSpacing(4)
        }
    }

    private func cleanMarkdown(_ value: String) -> String {
        value
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")
            .trimmingCharacters(in: .whitespaces)
    }
}

private struct GwaTopPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(GwaTopHomeTheme.primary.opacity(configuration.isPressed ? 0.78 : 1.0))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct GwaTopSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(GwaTopHomeTheme.primary)
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(GwaTopHomeTheme.primary.opacity(configuration.isPressed ? 0.16 : 0.09))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

#Preview {
    GwaTopAIStudyView()
}
