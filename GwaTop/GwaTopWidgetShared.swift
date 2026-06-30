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
