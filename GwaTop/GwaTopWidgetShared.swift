//
//  GwaTopWidgetShared.swift
//  GwaTop  +  GwaTopWidgetExtension  (양쪽 타겟에 모두 포함)
//
//  앱 ↔ 홈 화면 위젯이 공유하는 단 하나의 파일.
//   - 위젯은 별도 프로세스라 앱의 메모리 캐시(GwaTopAppDataStore)에 접근할 수 없다.
//   - 그래서 앱이 대시보드를 받을 때마다 "오늘 일정 / 임박 todo" 스냅샷을 App Group
//     UserDefaults 에 써두고(아래 GwaTopWidgetStore), 위젯은 그 스냅샷만 읽어 즉시 그린다. (A. 스냅샷)
//   - 위젯은 가능할 때만 access token + baseURL 로 백엔드를 가볍게 직접 호출해 최신화한다. (B. 직접 fetch)
//
//  ⚠️ 이 파일에는 앱 전용 타입(DTO 등)을 절대 참조하지 않는다 — 위젯 타겟에서도 그대로 컴파일돼야 한다.
//

import Foundation

// MARK: - 공유 상수

enum GwaTopWidgetConstants {
    /// 앱 / 위젯 공통 App Group. Signing & Capabilities → App Groups 에 동일하게 추가해야 한다.
    static let appGroupID = "group.com.minjunkwon.gwatop.dev"
    /// WidgetKit reloadTimelines(ofKind:) 와 Widget(kind:) 에서 쓰는 식별자.
    static let widgetKind = "GwaTopScheduleWidget"
    /// 구글 캘린더 스타일 위젯 식별자.
    static let calendarWidgetKind = "GwaTopCalendarWidget"
}

// MARK: - 위젯 표시 모델 (앱 DTO 와 의도적으로 분리)

/// 위젯 한 줄(일정 또는 할 일). 앱 DTO 를 위젯이 직접 디코드하지 않도록 최소 필드만 갖는 평면 구조.
struct GwaTopWidgetItem: Codable, Identifiable, Hashable {
    enum Kind: String, Codable { case schedule, todo }

    var id: String
    var kind: Kind
    var title: String
    var courseName: String
    /// "#8AB6F0" 형태. nil 이면 기본 파스텔.
    var courseColorHex: String?
    /// nil = 날짜 미정(강의계획서에 날짜가 없던 항목).
    var dueDate: Date?
    /// schedule 이면 type("exam"/"assignment"/"lecture"/"meeting"/"upload"), todo 면 priority("low"/"medium"/"high").
    var typeOrPriority: String
    var isDone: Bool
}

/// 위젯이 한 번에 그리는 모든 데이터. 앱이 만들어 App Group 에 저장, 위젯이 읽음.
struct GwaTopWidgetSnapshot: Codable, Hashable {
    /// 이 스냅샷을 만든 시각(앱 기준). 위젯에 "방금 갱신" 표시 / staleness 판단용.
    var generatedAt: Date
    var todaySchedules: [GwaTopWidgetItem]
    var upcomingTodos: [GwaTopWidgetItem]
    /// 오늘 이후로 다가오는 일정(시험/과제/미팅 등) — 캘린더 위젯 agenda 용.
    /// 기본값 [] 라 구버전 스냅샷(키 없음)도 디코드되고, 기존 init 호출부도 안 깨진다.
    var upcomingSchedules: [GwaTopWidgetItem] = []
    /// 이번 주 진척 (대비/요약 카드용).
    var weekTotal: Int
    var weekDone: Int
    /// 다음 가장 임박한 일정 (Small 위젯 핵심).
    var nextEventTitle: String?
    var nextEventDueDate: Date?
    var nextEventCourseName: String?
    var nextEventColorHex: String?

    /// 데이터가 한 번도 안 들어온 초기 상태 / 로그아웃 상태.
    static let empty = GwaTopWidgetSnapshot(
        generatedAt: .distantPast,
        todaySchedules: [],
        upcomingTodos: [],
        weekTotal: 0,
        weekDone: 0,
        nextEventTitle: nil,
        nextEventDueDate: nil,
        nextEventCourseName: nil,
        nextEventColorHex: nil
    )

    var isEmpty: Bool {
        todaySchedules.isEmpty && upcomingTodos.isEmpty
            && upcomingSchedules.isEmpty && nextEventTitle == nil
    }
}

// MARK: - 수업(시간표) → 다가오는 일정 확장

/// 수업 발생을 만들기 위한 최소 입력 (앱 DTO / 위젯 디코드 양쪽에서 채워 넣는다).
/// 수업은 schedules 테이블이 아니라 Course.schedule(주간 슬롯)에만 있어, 위젯의
/// '다음/다가오는 일정'에 포함하려면 클라이언트에서 발생 시각을 펼쳐야 한다.
struct GwaTopWidgetClassInput {
    var courseName: String
    var colorHex: String?
    /// (요일 "MON"…"SUN", 시작시각 "HH:MM")
    var slots: [(day: String, startTime: String)]
}

enum GwaTopWidgetClassExpander {
    /// 요일 문자열 → Gregorian weekday(1=일 … 7=토).
    private static let weekdayOf: [String: Int] = [
        "SUN": 1, "MON": 2, "TUE": 3, "WED": 4, "THU": 5, "FRI": 6, "SAT": 7,
    ]

    /// 수업 시각은 KST 벽시계("HH:MM")이므로 KST 기준으로 절대시각을 만든다.
    private static var kstCalendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Seoul") ?? .current
        return cal
    }

    /// `now` 부터 `horizonDays` 일까지, (주어지면) 학기 [start,end] 안의 수업 발생을
    /// 위젯 아이템으로 만든다. title=과목명, courseName="수업", type="lecture".
    static func upcomingClassItems(
        courses: [GwaTopWidgetClassInput],
        now: Date,
        horizonDays: Int = 14,
        semesterStart: Date? = nil,
        semesterEnd: Date? = nil
    ) -> [GwaTopWidgetItem] {
        guard !courses.isEmpty else { return [] }
        let cal = kstCalendar
        let startOfNow = cal.startOfDay(for: now)
        let semStartDay = semesterStart.map { cal.startOfDay(for: $0) }
        let semEndDay = semesterEnd.map { cal.startOfDay(for: $0) }
        let iso = ISO8601DateFormatter()
        var items: [GwaTopWidgetItem] = []

        for offset in 0...max(0, horizonDays) {
            guard let day = cal.date(byAdding: .day, value: offset, to: startOfNow) else { continue }
            if let s = semStartDay, day < s { continue }       // 학기 시작 전
            if let e = semEndDay, day > e { continue }          // 학기 종료 후
            let weekday = cal.component(.weekday, from: day)

            for course in courses {
                for slot in course.slots {
                    guard let wd = weekdayOf[slot.day.uppercased()], wd == weekday else { continue }
                    let hm = slot.startTime.split(separator: ":")
                    guard hm.count == 2, let h = Int(hm[0]), let m = Int(hm[1]),
                          let occur = cal.date(bySettingHour: h, minute: m, second: 0, of: day),
                          occur >= now
                    else { continue }
                    items.append(GwaTopWidgetItem(
                        id: "class-\(course.courseName)-\(iso.string(from: occur))",
                        kind: .schedule,
                        title: course.courseName,
                        courseName: "수업",
                        courseColorHex: course.colorHex,
                        dueDate: occur,
                        typeOrPriority: "lecture",
                        isDone: false
                    ))
                }
            }
        }
        return items
    }
}

extension GwaTopWidgetSnapshot {
    /// 수업 발생을 '다가오는 일정'에 합치고(오늘 0시 이후·정렬·상한 15) '다음 일정'도
    /// 재계산한다 — 지금 이후 가장 가까운 항목이 수업이면 다음 일정이 수업이 된다.
    mutating func mergeUpcomingClasses(_ classItems: [GwaTopWidgetItem], now: Date) {
        guard !classItems.isEmpty else { return }
        let cal = Calendar(identifier: .gregorian)
        let startOfToday = cal.startOfDay(for: now)
        let merged = (upcomingSchedules + classItems)
            .filter { ($0.dueDate ?? .distantPast) >= startOfToday }
            .sorted { ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture) }
        upcomingSchedules = Array(merged.prefix(15))

        // 다음 일정: 지금 이후 가장 가까운 일정(수업 포함). 기존보다 더 가까울 때만 교체
        // (기존 '다음 일정'을 절대 더 늦게 만들지 않는다 — 순수하게 수업을 더할 뿐).
        guard let soonest = merged.first(where: { ($0.dueDate ?? .distantPast) >= now }),
              let soonestDue = soonest.dueDate
        else { return }
        if let cur = nextEventDueDate, soonestDue >= cur { return }
        nextEventTitle = soonest.title
        nextEventDueDate = soonestDue
        nextEventCourseName = soonest.courseName
        nextEventColorHex = soonest.courseColorHex
    }
}

// MARK: - App Group 저장소

/// 앱과 위젯이 공유하는 App Group UserDefaults 래퍼.
/// 스냅샷 + (위젯 직접 fetch 용) access token + baseURL 을 보관한다.
///
/// 보안 메모(프로토타입 한정): access token 을 Keychain 이 아닌 App Group UserDefaults 에 둔다.
/// Keychain 공유(keychain-access-groups)를 쓰면 더 안전하지만 entitlement/prefix 설정이 까다로워,
/// 프로토타입에서는 App Group 컨테이너(샌드박스 보호) 저장으로 단순화했다. 운영 전환 시 Keychain 공유로 승격할 것.
enum GwaTopWidgetStore {

    private static let snapshotKey = "gwatop.widget.snapshot.v1"
    private static let tokenKey    = "gwatop.widget.accessToken"
    private static let baseURLKey  = "gwatop.widget.baseURL"

    static var defaults: UserDefaults? {
        UserDefaults(suiteName: GwaTopWidgetConstants.appGroupID)
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    // MARK: 스냅샷

    static func saveSnapshot(_ snapshot: GwaTopWidgetSnapshot) {
        guard let data = try? encoder.encode(snapshot) else { return }
        defaults?.set(data, forKey: snapshotKey)
    }

    static func loadSnapshot() -> GwaTopWidgetSnapshot? {
        guard let data = defaults?.data(forKey: snapshotKey),
              let snapshot = try? decoder.decode(GwaTopWidgetSnapshot.self, from: data)
        else { return nil }
        return snapshot
    }

    // MARK: 인증 / baseURL (위젯 직접 fetch 용)

    static func saveAccessToken(_ token: String?) {
        if let token, !token.isEmpty {
            defaults?.set(token, forKey: tokenKey)
        } else {
            defaults?.removeObject(forKey: tokenKey)
        }
    }

    static func loadAccessToken() -> String? {
        defaults?.string(forKey: tokenKey)
    }

    static func saveBaseURL(_ url: String) {
        defaults?.set(url, forKey: baseURLKey)
    }

    static func loadBaseURL() -> String? {
        defaults?.string(forKey: baseURLKey)
    }

    /// 로그아웃 시 호출 — 다른 사용자 잔재 / 만료 토큰 제거.
    static func clearAll() {
        defaults?.removeObject(forKey: snapshotKey)
        defaults?.removeObject(forKey: tokenKey)
        // baseURL 은 사용자 무관이라 유지.
    }
}
