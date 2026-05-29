//
//  GwaTopAppleCalendarService.swift
//  GwaTop
//
//  Apple 캘린더(EventKit) 읽기 전용 통합.
//  - 권한 요청 (iOS 17+ : requestFullAccessToEvents, 이하 : requestAccess)
//  - 지정 기간의 EKEvent 를 GwaTopCalendarEvent 로 매핑해서 우리 캘린더 뷰에 표시
//  - EKEventStoreChanged 알림 구독 → 사용자가 Apple 캘린더에서 변경하면 자동 갱신 트리거
//
//  ⚠️ 서버에는 저장하지 않는다. 모두 클라이언트 로컬.
//

import EventKit
import SwiftUI
import Combine  // Swift 6 모드에서 ObservableObject / @Published 명시 import 필요

/// 사용자가 설정에서 토글한 "Apple 캘린더 연동" 상태 보존 키 — @AppStorage 와 NotificationCenter 양쪽 호환.
extension UserDefaults {
    static let gwaTopAppleCalendarEnabledKey = "gwaTopAppleCalendarEnabled"
}

@MainActor
final class GwaTopAppleCalendarService: ObservableObject {
    static let shared = GwaTopAppleCalendarService()

    private let store = EKEventStore()

    /// 현재 EventKit 권한 상태. UI 가 직접 읽어서 "권한 요청 필요" 배너 등을 표시.
    @Published private(set) var authorizationStatus: EKAuthorizationStatus

    /// EKEventStoreChanged 알림이 들어올 때마다 증가 — 뷰가 onChange 로 구독하면 자동 reload.
    @Published private(set) var changeCounter: Int = 0

    private init() {
        self.authorizationStatus = EKEventStore.authorizationStatus(for: .event)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleStoreChanged),
            name: .EKEventStoreChanged,
            object: store
        )
    }

    @objc private func handleStoreChanged() {
        Task { @MainActor in
            changeCounter &+= 1
        }
    }

    /// 권한 요청. 결과를 Bool 로 반환 (true = full/write 권한 또는 read 권한 획득).
    /// iOS 17+ 는 풀 액세스 요청 (우리는 읽기만 쓰지만 read-only API 는 iOS 17 부터). 16 이하는 requestAccess.
    func requestAccess() async -> Bool {
        do {
            let granted: Bool
            if #available(iOS 17.0, *) {
                granted = try await store.requestFullAccessToEvents()
            } else {
                granted = try await store.requestAccess(to: .event)
            }
            await MainActor.run {
                self.authorizationStatus = EKEventStore.authorizationStatus(for: .event)
            }
            return granted
        } catch {
            await MainActor.run {
                self.authorizationStatus = EKEventStore.authorizationStatus(for: .event)
            }
            return false
        }
    }

    /// 사용자가 현재 권한을 줬는지 — iOS 17+ 는 .fullAccess / .writeOnly, 이하는 .authorized.
    var hasAccess: Bool {
        if #available(iOS 17.0, *) {
            return authorizationStatus == .fullAccess
        } else {
            return authorizationStatus == .authorized
        }
    }

    /// 사용자가 명시적으로 "안 허용" 선택한 상태 — 다시 권한 요청해도 시스템이 즉시 거부.
    var isDenied: Bool {
        authorizationStatus == .denied || authorizationStatus == .restricted
    }

    /// 지정한 기간의 Apple 캘린더 이벤트를 GwaTopCalendarEvent 로 매핑해 반환.
    /// 권한이 없거나 store 가 비어 있으면 빈 배열.
    func fetchEvents(from start: Date, to end: Date) -> [GwaTopCalendarEvent] {
        guard hasAccess else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let ekEvents = store.events(matching: predicate)
        return ekEvents.compactMap { Self.mapToGwaTopEvent($0) }
    }

    /// EKEvent → GwaTopCalendarEvent 매핑.
    /// 식별자는 "apple_event/" prefix 로 우리 서버 일정과 ID 충돌 회피.
    /// 캘린더 색은 EKCalendar.cgColor 그대로 사용해서 사용자에게 익숙한 색감 유지.
    private static func mapToGwaTopEvent(_ ek: EKEvent) -> GwaTopCalendarEvent? {
        let identifier = ek.eventIdentifier ?? UUID().uuidString
        // start 가 nil 인 케이스는 거의 없지만, 안전망.
        guard let start = ek.startDate as Date? else { return nil }
        let end = ek.endDate as Date?

        let calendar = ek.calendar
        let colorHex = hexString(from: calendar?.cgColor) ?? "#9CA3AF" // 기본 회색
        let calendarName = calendar?.title ?? "Apple 캘린더"

        // 같은 EKCalendar 의 모든 이벤트가 같은 sentinel "course" 를 공유하도록
        // calendar.calendarIdentifier 를 sentinel id 로 사용.
        let course = GwaTopCourseSummary(
            id: "apple_calendar/\(calendar?.calendarIdentifier ?? "unknown")",
            name: calendarName,
            professor: "Apple 캘린더",
            colorHex: colorHex,
            iconName: "calendar",
            currentWeek: 0,
            progress: 0
        )

        return GwaTopCalendarEvent(
            id: "apple_event/\(identifier)",
            course: course,
            title: ek.title ?? "(제목 없음)",
            // Apple 일정엔 강의/과제 구분이 없으니 "meeting" 으로 통일 — 아이콘이 사람 3명이라 무난.
            eventType: .meeting,
            startDate: start,
            endDate: end,
            location: ek.location ?? "",
            memo: ek.notes ?? "",
            source: "apple_calendar"
        )
    }

    /// CGColor → "#RRGGBB". 알파는 무시 (캘린더 색은 본질적으로 불투명).
    private static func hexString(from cgColor: CGColor?) -> String? {
        guard let cg = cgColor,
              let comps = cg.components, comps.count >= 3
        else { return nil }
        let r = Int(round(comps[0] * 255))
        let g = Int(round(comps[1] * 255))
        let b = Int(round(comps[2] * 255))
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
