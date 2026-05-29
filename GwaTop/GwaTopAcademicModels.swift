import SwiftUI

// MARK: - GwaTop Academic Models
// 이 파일은 과제, AI 학습, 캘린더 화면에서 함께 사용하는 공통 모델입니다.
// 모든 모델은 Identifiable + Codable + Equatable을 준수하여 향후 FastAPI JSON 응답과 쉽게 연결할 수 있습니다.

struct GwaTopCourseSummary: Identifiable, Codable, Equatable {
    let id: String
    let name: String
    let professor: String
    let colorHex: String
    let iconName: String
    let currentWeek: Int
    let progress: Double

    var color: Color {
        Color.gwaTopHex(colorHex)
    }

    static let database = GwaTopCourseSummary(
        id: "course_database",
        name: "데이터베이스",
        professor: "김민수 교수",
        colorHex: "#3B82F6",
        iconName: "server.rack",
        currentWeek: 6,
        progress: 0.72
    )

    static let dataStructure = GwaTopCourseSummary(
        id: "course_data_structure",
        name: "자료구조",
        professor: "이서연 교수",
        colorHex: "#8B5CF6",
        iconName: "point.3.connected.trianglepath.dotted",
        currentWeek: 5,
        progress: 0.58
    )

    static let capstone = GwaTopCourseSummary(
        id: "course_capstone",
        name: "캡스톤디자인",
        professor: "박지훈 교수",
        colorHex: "#F97316",
        iconName: "lightbulb.fill",
        currentWeek: 4,
        progress: 0.41
    )

    static let sampleData: [GwaTopCourseSummary] = [database, dataStructure, capstone]
}

enum GwaTopAssignmentPriority: String, Codable, CaseIterable, Equatable {
    case high
    case medium
    case low

    var displayTitle: String {
        switch self {
        case .high: return "높음"
        case .medium: return "보통"
        case .low: return "낮음"
        }
    }

    var color: Color {
        switch self {
        case .high: return .red
        case .medium: return .orange
        case .low: return .green
        }
    }
}

enum GwaTopAssignmentStatus: String, Codable, CaseIterable, Equatable {
    case pending
    case inProgress
    case completed

    var displayTitle: String {
        switch self {
        case .pending: return "대기"
        case .inProgress: return "진행 중"
        case .completed: return "완료"
        }
    }
}

struct GwaTopAssignment: Identifiable, Codable, Equatable {
    let id: String
    let course: GwaTopCourseSummary
    var title: String
    var description: String
    var dueDate: Date
    var priority: GwaTopAssignmentPriority
    var status: GwaTopAssignmentStatus
    var estimatedMinutes: Int      // 0이면 UI 숨김
    var recommendedAction: String  // 비어있으면 UI 숨김
    var scheduleId: String? = nil  // 백엔드 schedule 연결 (auto todo면 source schedule)
    var isAuto: Bool = false

    var isCompleted: Bool {
        status == .completed
    }

    /// 백엔드 TodoDTO에서 화면용 모델로 변환.
    /// description / estimatedMinutes / recommendedAction은 백엔드에 없으므로 비움.
    init(dto: GwaTopTodoDTO) {
        self.id = dto.id
        self.course = GwaTopCourseSummary(
            id: dto.courseId,
            name: dto.courseName,
            professor: "",
            colorHex: dto.courseColor ?? "#4F8EF7",
            iconName: "book.closed.fill",
            currentWeek: 0,
            progress: 0.0
        )
        self.title = dto.title
        self.description = ""
        self.dueDate = dto.dueDate
        self.priority = GwaTopAssignmentPriority(rawValue: dto.priority) ?? .low
        self.status = dto.isDone ? .completed : .pending
        self.estimatedMinutes = 0
        self.recommendedAction = ""
        self.scheduleId = dto.scheduleId
        self.isAuto = dto.isAuto
    }

    init(
        id: String,
        course: GwaTopCourseSummary,
        title: String,
        description: String,
        dueDate: Date,
        priority: GwaTopAssignmentPriority,
        status: GwaTopAssignmentStatus,
        estimatedMinutes: Int,
        recommendedAction: String,
        scheduleId: String? = nil,
        isAuto: Bool = false
    ) {
        self.id = id
        self.course = course
        self.title = title
        self.description = description
        self.dueDate = dueDate
        self.priority = priority
        self.status = status
        self.estimatedMinutes = estimatedMinutes
        self.recommendedAction = recommendedAction
        self.scheduleId = scheduleId
        self.isAuto = isAuto
    }

    var dDayText: String {
        if isCompleted { return "완료" }
        let day = Date.gwaTopDDayFromToday(to: dueDate)
        if day == 0 { return "D-Day" }
        if day > 0 { return "D-\(day)" }
        return "D+\(abs(day))"
    }

    var dueDateText: String {
        GwaTopDateFormatters.koMonthDayWeekdayTime.string(from: dueDate)
    }

    static let sampleData: [GwaTopAssignment] = [
        GwaTopAssignment(
            id: "assignment_db_erd",
            course: .database,
            title: "ERD 초안 작성",
            description: "온라인 서점 서비스의 핵심 엔티티와 관계를 정의하고 1차 ERD를 제출합니다.",
            dueDate: Date.gwaTopDaysFromNow(1, hour: 23, minute: 59),
            priority: .high,
            status: .inProgress,
            estimatedMinutes: 80,
            recommendedAction: "먼저 User, Book, Order, Payment 엔티티를 나누고 관계선을 그려보세요."
        ),
        GwaTopAssignment(
            id: "assignment_ds_tree",
            course: .dataStructure,
            title: "트리 순회 문제 풀이",
            description: "전위, 중위, 후위 순회 결과를 비교하고 예제 코드 실행 결과를 정리합니다.",
            dueDate: Date.gwaTopDaysFromNow(3, hour: 18, minute: 0),
            priority: .medium,
            status: .pending,
            estimatedMinutes: 45,
            recommendedAction: "손으로 순회 순서를 적은 뒤 Swift 배열로 결과를 검증해보세요."
        ),
        GwaTopAssignment(
            id: "assignment_capstone_minutes",
            course: .capstone,
            title: "팀 회의록 정리",
            description: "이번 주 회의에서 결정된 기능 범위, 담당자, 다음 액션 아이템을 정리합니다.",
            dueDate: Date.gwaTopDaysFromNow(0, hour: 20, minute: 0),
            priority: .medium,
            status: .completed,
            estimatedMinutes: 25,
            recommendedAction: "회의록은 완료되었습니다. 다음에는 화면 플로우 캡처를 추가하면 좋아요."
        ),
        GwaTopAssignment(
            id: "assignment_db_normalization",
            course: .database,
            title: "정규화 개념 복습",
            description: "1NF, 2NF, 3NF의 차이를 예시 테이블로 설명하는 짧은 노트를 작성합니다.",
            dueDate: Date.gwaTopDaysFromNow(5, hour: 23, minute: 59),
            priority: .low,
            status: .pending,
            estimatedMinutes: 35,
            recommendedAction: "이상 현상 예시를 하나 정하고 단계별로 테이블을 분해해보세요."
        )
    ]
}

enum GwaTopCalendarEventType: String, Codable, CaseIterable, Equatable {
    case lecture
    case assignment
    case exam
    case meeting
    case upload

    var displayTitle: String {
        switch self {
        case .lecture: return "강의"
        case .assignment: return "과제"
        case .exam: return "시험"
        case .meeting: return "회의"
        case .upload: return "업로드"
        }
    }

    var iconName: String {
        switch self {
        case .lecture: return "book.closed.fill"
        case .assignment: return "checklist"
        case .exam: return "pencil.and.list.clipboard"
        case .meeting: return "person.3.fill"
        case .upload: return "doc.badge.arrow.up"
        }
    }
}

struct GwaTopCalendarEvent: Identifiable, Codable, Equatable {
    let id: String
    let course: GwaTopCourseSummary
    var title: String
    var eventType: GwaTopCalendarEventType
    var startDate: Date
    var endDate: Date?
    var location: String
    var memo: String
    var source: String

    var timeText: String {
        GwaTopDateFormatters.koTimeOnly.string(from: startDate)
    }

    var dateText: String {
        GwaTopDateFormatters.koMonthDayShortWeekday.string(from: startDate)
    }

    var dDayText: String {
        let day = Date.gwaTopDDayFromToday(to: startDate)
        if day == 0 { return "오늘" }
        if day > 0 { return "D-\(day)" }
        return "D+\(abs(day))"
    }

    static let sampleData: [GwaTopCalendarEvent] = [
        GwaTopCalendarEvent(
            id: "event_db_lecture_week6",
            course: .database,
            title: "6주차 SQL JOIN 실습",
            eventType: .lecture,
            startDate: Date.gwaTopDaysFromNow(0, hour: 10, minute: 30),
            endDate: Date.gwaTopDaysFromNow(0, hour: 12, minute: 0),
            location: "공학관 302호",
            memo: "INNER JOIN, LEFT JOIN 실습 파일 준비",
            source: "syllabus"
        ),
        GwaTopCalendarEvent(
            id: "event_db_assignment_erd",
            course: .database,
            title: "ERD 초안 제출 마감",
            eventType: .assignment,
            startDate: Date.gwaTopDaysFromNow(1, hour: 23, minute: 59),
            endDate: nil,
            location: "LMS",
            memo: "PDF로 변환 후 LMS에 제출",
            source: "todo"
        ),
        GwaTopCalendarEvent(
            id: "event_ds_quiz",
            course: .dataStructure,
            title: "트리와 그래프 퀴즈",
            eventType: .exam,
            startDate: Date.gwaTopDaysFromNow(3, hour: 14, minute: 0),
            endDate: Date.gwaTopDaysFromNow(3, hour: 14, minute: 30),
            location: "온라인",
            memo: "범위: 트리 순회, 그래프 탐색",
            source: "syllabus"
        ),
        GwaTopCalendarEvent(
            id: "event_capstone_meeting",
            course: .capstone,
            title: "캡스톤 팀 미팅",
            eventType: .meeting,
            startDate: Date.gwaTopDaysFromNow(2, hour: 19, minute: 0),
            endDate: Date.gwaTopDaysFromNow(2, hour: 20, minute: 0),
            location: "Zoom",
            memo: "프로토타입 화면 공유 및 담당 기능 점검",
            source: "manual"
        ),
        GwaTopCalendarEvent(
            id: "event_upload_syllabus",
            course: .database,
            title: "강의계획서 업로드 확인",
            eventType: .upload,
            startDate: Date.gwaTopDaysFromNow(5, hour: 9, minute: 0),
            endDate: nil,
            location: "GwaTop 앱",
            memo: "AI 파싱 결과를 캘린더에 등록하는 흐름을 테스트합니다.",
            source: "ai_parsed"
        )
    ]
}

struct GwaTopAIContent: Identifiable, Codable, Equatable {
    let id: String
    let course: GwaTopCourseSummary
    var week: Int
    var title: String
    var summaryMarkdown: String
    var quizItems: [GwaTopQuizItem]
    var flashcards: [GwaTopFlashcard]
    var generatedAt: Date
    var status: String

    var generatedAtText: String {
        GwaTopDateFormatters.koMonthDayTime.string(from: generatedAt)
    }

    static let sampleData: [GwaTopAIContent] = [
        GwaTopAIContent(
            id: "ai_database_week6",
            course: .database,
            week: 6,
            title: "SQL JOIN과 정규화 핵심 정리",
            summaryMarkdown: """
            ## 핵심 요약
            관계형 데이터베이스에서 **JOIN**은 여러 테이블에 흩어진 데이터를 연결해 하나의 결과 집합으로 조회하는 기능입니다.

            ### 오늘 반드시 기억할 내용
            - `INNER JOIN`은 양쪽 테이블에 모두 존재하는 행만 반환합니다.
            - `LEFT JOIN`은 왼쪽 테이블을 기준으로 결과를 보존합니다.
            - 정규화는 중복을 줄이고 데이터 이상 현상을 예방하기 위한 테이블 분해 과정입니다.

            ### 시험 포인트
            ERD를 볼 때 기본키와 외래키 관계를 먼저 찾고, 조인 조건이 어떤 컬럼에 걸리는지 확인하세요.
            """,
            quizItems: GwaTopQuizItem.databaseSamples,
            flashcards: GwaTopFlashcard.databaseSamples,
            generatedAt: Date.gwaTopDaysFromNow(0, hour: 8, minute: 40),
            status: "completed"
        ),
        GwaTopAIContent(
            id: "ai_datastructure_week5",
            course: .dataStructure,
            week: 5,
            title: "트리 순회와 그래프 탐색",
            summaryMarkdown: """
            ## 핵심 요약
            트리는 계층 관계를 표현하는 비선형 자료구조이며, 그래프는 정점과 간선으로 복잡한 연결 관계를 표현합니다.

            ### 오늘 반드시 기억할 내용
            - 전위 순회는 루트 노드를 먼저 방문합니다.
            - 중위 순회는 이진 탐색 트리에서 정렬된 결과를 얻는 데 유용합니다.
            - BFS는 큐, DFS는 스택 또는 재귀를 자주 사용합니다.
            """,
            quizItems: GwaTopQuizItem.dataStructureSamples,
            flashcards: GwaTopFlashcard.dataStructureSamples,
            generatedAt: Date.gwaTopDaysFromNow(-1, hour: 21, minute: 10),
            status: "completed"
        )
    ]
}

struct GwaTopQuizItem: Identifiable, Codable, Equatable {
    let id: String
    let question: String
    let choices: [String]
    let answerIndex: Int
    let explanation: String

    static let databaseSamples: [GwaTopQuizItem] = [
        GwaTopQuizItem(
            id: "quiz_db_1",
            question: "INNER JOIN의 결과로 가장 알맞은 설명은 무엇인가요?",
            choices: ["왼쪽 테이블의 모든 행", "양쪽 테이블 조건이 일치하는 행", "오른쪽 테이블의 모든 행", "중복을 제거한 모든 컬럼"],
            answerIndex: 1,
            explanation: "INNER JOIN은 조인 조건을 만족하는 양쪽 테이블의 행만 결과로 반환합니다."
        ),
        GwaTopQuizItem(
            id: "quiz_db_2",
            question: "정규화의 주된 목적은 무엇인가요?",
            choices: ["화면 디자인 개선", "데이터 중복과 이상 현상 감소", "서버 비용 증가", "API 호출 횟수 증가"],
            answerIndex: 1,
            explanation: "정규화는 데이터 중복을 줄이고 삽입, 수정, 삭제 이상 현상을 예방하는 데 목적이 있습니다."
        )
    ]

    static let dataStructureSamples: [GwaTopQuizItem] = [
        GwaTopQuizItem(
            id: "quiz_ds_1",
            question: "BFS 구현에 일반적으로 사용하는 자료구조는 무엇인가요?",
            choices: ["스택", "큐", "힙", "해시맵"],
            answerIndex: 1,
            explanation: "BFS는 가까운 정점부터 차례대로 방문하므로 FIFO 구조인 큐를 사용합니다."
        )
    ]
}

struct GwaTopFlashcard: Identifiable, Codable, Equatable {
    let id: String
    let front: String
    let back: String
    var confidence: String

    static let databaseSamples: [GwaTopFlashcard] = [
        GwaTopFlashcard(id: "card_db_1", front: "INNER JOIN", back: "두 테이블에서 조인 조건이 일치하는 행만 반환하는 조인 방식", confidence: "unknown"),
        GwaTopFlashcard(id: "card_db_2", front: "외래키", back: "다른 테이블의 기본키를 참조하여 테이블 간 관계를 만드는 컬럼", confidence: "unknown"),
        GwaTopFlashcard(id: "card_db_3", front: "제3정규형", back: "기본키가 아닌 속성 간의 이행적 종속을 제거한 정규형", confidence: "unknown")
    ]

    static let dataStructureSamples: [GwaTopFlashcard] = [
        GwaTopFlashcard(id: "card_ds_1", front: "BFS", back: "큐를 사용해 가까운 정점부터 탐색하는 그래프 탐색 방식", confidence: "unknown"),
        GwaTopFlashcard(id: "card_ds_2", front: "DFS", back: "스택 또는 재귀를 사용해 한 경로를 깊게 탐색하는 방식", confidence: "unknown")
    ]
}

// MARK: - Convenience Helpers

extension Color {
    static func gwaTopHex(_ hex: String) -> Color {
        // 1) 원색 팔레트로 저장된 기존 과목을 파스텔로 리매핑.
        //    DB 마이그레이션 없이 표시 시점에만 변환하므로 백엔드 변경 불필요.
        let upper = hex.uppercased()
        let remapped = GwaTopVividToPastel[upper] ?? hex

        let cleaned = remapped.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&int)

        let red: UInt64
        let green: UInt64
        let blue: UInt64

        switch cleaned.count {
        case 6:
            red = (int >> 16) & 0xFF
            green = (int >> 8) & 0xFF
            blue = int & 0xFF
        default:
            // fallback = pastel sky #8AB6F0 (GwaTopDefaultCourseColor)
            red = 138
            green = 182
            blue = 240
        }

        return Color(
            red: Double(red) / 255,
            green: Double(green) / 255,
            blue: Double(blue) / 255
        )
    }
}

extension Date {
    static func gwaTopDaysFromNow(_ dayOffset: Int, hour: Int, minute: Int) -> Date {
        let calendar = Calendar.current
        let base = calendar.date(byAdding: .day, value: dayOffset, to: Date()) ?? Date()
        var components = calendar.dateComponents([.year, .month, .day], from: base)
        components.hour = hour
        components.minute = minute
        return calendar.date(from: components) ?? base
    }

    /// 오늘 자정 기준 D-Day 일수를 반환. 양수면 미래, 0이면 오늘, 음수면 과거.
    /// 시각은 모두 startOfDay로 정규화되므로 시간대 노이즈가 없다.
    static func gwaTopDDayFromToday(to target: Date) -> Int {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let day = cal.startOfDay(for: target)
        return cal.dateComponents([.day], from: today, to: day).day ?? 0
    }
}
