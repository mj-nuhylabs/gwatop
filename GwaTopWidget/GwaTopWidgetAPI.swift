//
//  GwaTopWidgetAPI.swift
//  GwaTopWidgetExtension (위젯 타겟 전용)
//
//  위젯의 "B. 직접 fetch" 경로. App Group 에 미러링된 access token + baseURL 로
//   - GET /v1/home/dashboard  (오늘 일정 / 임박 todo / 주간 / 다음 일정)
//   - GET /v1/schedules       (전체 일정 → 다가오는 일정 agenda)
//  를 받아 위젯 스냅샷으로 합친다.
//   - 토큰 만료/네트워크 실패는 nil 반환 → 프로바이더가 저장된 스냅샷(A)으로 폴백.
//   - 위젯에는 토큰 갱신 로직을 두지 않는다(앱이 refresh 시 미러링을 다시 해줌).
//

import Foundation

enum GwaTopWidgetAPI {

    /// 대시보드 + 전체 일정을 직접 받아 위젯 스냅샷으로 변환. 실패하면 nil.
    static func fetchSnapshot(upcomingLimit: Int = 8) async -> GwaTopWidgetSnapshot? {
        guard let token = GwaTopWidgetStore.loadAccessToken(), !token.isEmpty,
              let base = GwaTopWidgetStore.loadBaseURL()
        else { return nil }

        // 대시보드는 필수, 나머지는 보조(실패해도 대시보드만으로 진행).
        // 수업(시간표)을 '다음/다가오는 일정'에 포함하려면 courses(주간 슬롯) + semesters(학기 범위)도 받는다.
        async let dashTask = authedGET(base: base, path: "/v1/home/dashboard",
                                       query: [.init(name: "upcoming_limit", value: String(upcomingLimit))],
                                       token: token)
        async let schedTask = authedGET(base: base, path: "/v1/schedules", query: [], token: token)
        async let courseTask = authedGET(base: base, path: "/v1/courses", query: [], token: token)
        async let semTask = authedGET(base: base, path: "/v1/semesters", query: [], token: token)

        let dashData = await dashTask
        let schedData = await schedTask
        let courseData = await courseTask
        let semData = await semTask

        guard let dashData, let dash = try? Self.decoder.decode(DashboardResponse.self, from: dashData) else {
            return nil
        }
        var snapshot = dash.toSnapshot()

        let now = Date()
        let cal = Calendar(identifier: .gregorian)
        let startOfToday = cal.startOfDay(for: now)

        if let schedData, let rows = try? Self.decoder.decode([ScheduleRow].self, from: schedData) {
            snapshot.upcomingSchedules = rows
                .compactMap { row -> (Date, GwaTopWidgetItem)? in
                    guard let due = row.dueDate, due >= startOfToday else { return nil }
                    return (due, row.toItem())
                }
                .sorted { $0.0 < $1.0 }
                .prefix(15)
                .map { $0.1 }
        }

        // 수업 발생 펼치기 → '다가오는 일정'+'다음 일정'에 합치기.
        let classItems = Self.expandClasses(courseData: courseData, semData: semData, now: now)
        snapshot.mergeUpcomingClasses(classItems, now: now)

        return snapshot
    }

    /// courses(+semesters) 응답에서 활성 학기의 수업 발생을 위젯 아이템으로 펼친다. 실패/없음이면 [].
    private static func expandClasses(courseData: Data?, semData: Data?, now: Date) -> [GwaTopWidgetItem] {
        guard let courseData,
              let courses = try? decoder.decode([CourseRow].self, from: courseData)
        else { return [] }

        // 활성 학기 선택: is_active 우선, 없으면 오늘이 [start,end] 안에 드는 학기.
        var activeId: String?
        var semStart: Date?
        var semEnd: Date?
        if let semData, let sems = try? decoder.decode([SemesterRow].self, from: semData) {
            let parsed = sems.compactMap { s -> (id: String, start: Date, end: Date, active: Bool)? in
                guard let st = SemesterRow.day(s.startDate), let en = SemesterRow.day(s.endDate) else { return nil }
                return (s.id, st, en, s.isActive)
            }
            let chosen = parsed.first(where: { $0.active })
                ?? parsed.first(where: { now >= $0.start && now <= Calendar.current.date(byAdding: .day, value: 1, to: $0.end)! })
            if let c = chosen { activeId = c.id; semStart = c.start; semEnd = c.end }
        }

        let inputs: [GwaTopWidgetClassInput] = courses
            .filter { activeId == nil || $0.semesterId == activeId }
            .compactMap { c in
                let slots = (c.schedule ?? []).map { (day: $0.day, startTime: $0.startTime) }
                guard !slots.isEmpty else { return nil }
                return GwaTopWidgetClassInput(courseName: c.name, colorHex: c.color, slots: slots)
            }

        return GwaTopWidgetClassExpander.upcomingClassItems(
            courses: inputs, now: now, horizonDays: 14,
            semesterStart: semStart, semesterEnd: semEnd
        )
    }

    // MARK: - 공통 GET

    private static func authedGET(base: String, path: String,
                                  query: [URLQueryItem], token: String) async -> Data? {
        guard var comps = URLComponents(string: base + path) else { return nil }
        if !query.isEmpty { comps.queryItems = query }
        guard let url = comps.url else { return nil }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 10
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            return data
        } catch {
            return nil
        }
    }

    // MARK: - 디코딩 (앱과 동일하게 ISO8601 + fractional + naive KST 폴백)

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            if let date = GwaTopWidgetDateParser.parse(raw) { return date }
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Unparseable date: \(raw)")
            )
        }
        return d
    }()

    // MARK: - 응답 모델 (필요 필드만)

    private struct DashboardResponse: Decodable {
        let todaySchedules: [ScheduleRow]
        let upcomingTodos: [TodoRow]
        let thisWeekSummary: WeekSummary
        let nextEvent: NextEvent?

        enum CodingKeys: String, CodingKey {
            case todaySchedules  = "today_schedules"
            case upcomingTodos   = "upcoming_todos"
            case thisWeekSummary = "this_week_summary"
            case nextEvent       = "next_event"
        }

        func toSnapshot() -> GwaTopWidgetSnapshot {
            GwaTopWidgetSnapshot(
                generatedAt: Date(),
                todaySchedules: todaySchedules.map { $0.toItem() },
                upcomingTodos: upcomingTodos.map {
                    GwaTopWidgetItem(id: $0.id, kind: .todo, title: $0.title,
                                     courseName: $0.courseName, courseColorHex: $0.courseColor,
                                     dueDate: $0.dueDate, typeOrPriority: $0.priority, isDone: $0.isDone)
                },
                upcomingSchedules: [],   // fetchSnapshot 에서 /v1/schedules 로 채움
                weekTotal: thisWeekSummary.total,
                weekDone: thisWeekSummary.done,
                nextEventTitle: nextEvent?.title,
                nextEventDueDate: nextEvent?.dueDate,
                nextEventCourseName: nextEvent?.courseName,
                nextEventColorHex: nextEvent?.courseColor
            )
        }
    }

    private struct ScheduleRow: Decodable {
        let id, title, type: String
        let courseName: String?   // 외부(Apple) 일정은 과목명이 없음
        let courseColor: String?
        let source: String?
        let dueDate: Date?
        enum CodingKeys: String, CodingKey {
            case id, title, type, source
            case courseName = "course_name"
            case courseColor = "course_color"
            case dueDate = "due_date"
        }
        func toItem() -> GwaTopWidgetItem {
            let label = courseName ?? (source == "apple_calendar" ? "Apple 캘린더" : "")
            return GwaTopWidgetItem(id: id, kind: .schedule, title: title,
                             courseName: label, courseColorHex: courseColor,
                             dueDate: dueDate, typeOrPriority: type, isDone: false)
        }
    }

    private struct TodoRow: Decodable {
        let id, courseName, title, priority: String
        let courseColor: String?
        let dueDate: Date?
        let isDone: Bool
        enum CodingKeys: String, CodingKey {
            case id, title, priority
            case courseName = "course_name"
            case courseColor = "course_color"
            case dueDate = "due_date"
            case isDone = "is_done"
        }
    }

    private struct WeekSummary: Decodable {
        let total, done: Int
    }

    private struct NextEvent: Decodable {
        let title: String
        let courseName: String?
        let courseColor: String?
        let dueDate: Date?
        enum CodingKeys: String, CodingKey {
            case title
            case courseName = "course_name"
            case courseColor = "course_color"
            case dueDate = "due_date"
        }
    }

    // MARK: 수업(시간표) 펼치기용

    private struct CourseRow: Decodable {
        let id: String
        let semesterId: String
        let name: String
        let color: String?
        let schedule: [ClassSlotRow]?
        enum CodingKeys: String, CodingKey {
            case id, name, color, schedule
            case semesterId = "semester_id"
        }
    }

    private struct ClassSlotRow: Decodable {
        let day: String        // MON…SUN
        let startTime: String  // "HH:MM"
        enum CodingKeys: String, CodingKey {
            case day
            case startTime = "start_time"
        }
    }

    /// 학기 — start_date/end_date 는 "YYYY-MM-DD"(date-only)라 커스텀 날짜 디코더가 던진다.
    /// 그래서 문자열로 받고 별도 포맷터로 파싱한다.
    private struct SemesterRow: Decodable {
        let id: String
        let startDate: String
        let endDate: String
        let isActive: Bool
        enum CodingKeys: String, CodingKey {
            case id
            case startDate = "start_date"
            case endDate = "end_date"
            case isActive = "is_active"
        }
        private static let ymd: DateFormatter = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "Asia/Seoul")
            f.dateFormat = "yyyy-MM-dd"
            return f
        }()
        static func day(_ s: String) -> Date? { ymd.date(from: String(s.prefix(10))) }
    }
}

/// 백엔드가 보내는 여러 날짜 표기(타임존 유/무, fractional 유/무)를 모두 받아낸다.
enum GwaTopWidgetDateParser {
    private static let iso8601Full: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    /// 타임존 없는 naive datetime 은 KST 로 간주.
    private static let naive: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Asia/Seoul")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f
    }()
    private static let naiveFractional: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Asia/Seoul")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
        return f
    }()

    static func parse(_ raw: String) -> Date? {
        if let d = iso8601Full.date(from: raw) { return d }
        if let d = iso8601.date(from: raw) { return d }
        if let d = naiveFractional.date(from: raw) { return d }
        if let d = naive.date(from: raw) { return d }
        return nil
    }
}
