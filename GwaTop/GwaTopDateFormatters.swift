//
//  GwaTopDateFormatters.swift
//  GwaTop
//
//  View body / Service 양쪽에서 반복 생성되던 DateFormatter 인스턴스를 한 곳에 모아 캐시.
//  - body computed에서 alloc 하지 않도록 static let 으로 고정
//  - locale / timeZone / dateFormat 변경은 여기서만 (사용처는 호출만)
//

import Foundation

enum GwaTopDateFormatters {

    // MARK: - 화면 표시용 (ko_KR)

    /// "2026.5.21" — 학기 기간 등 짧은 날짜
    static let koShortDate: DateFormatter = make(locale: "ko_KR", format: "yyyy.M.d")

    /// "2026년 5월" — 캘린더 월 헤더
    static let koYearMonth: DateFormatter = make(locale: "ko_KR", format: "yyyy년 M월")

    /// "5월 21일 목요일" — 캘린더 선택 날짜 / 홈 오늘 날짜
    static let koMonthDayWeekday: DateFormatter = make(locale: "ko_KR", format: "M월 d일 EEEE")

    /// "5월 21일 목요일" — Calendar Event date (E요일 표기)
    static let koMonthDayShortWeekday: DateFormatter = make(locale: "ko_KR", format: "M월 d일 E요일")

    /// "5월 21일 목요일 14:30" — Assignment due date
    static let koMonthDayWeekdayTime: DateFormatter = make(locale: "ko_KR", format: "M월 d일 E요일 HH:mm")

    /// "5월 21일 14:30" — AI Content generatedAt
    static let koMonthDayTime: DateFormatter = make(locale: "ko_KR", format: "M월 d일 HH:mm")

    /// "14:30" — 시각만
    static let koTimeOnly: DateFormatter = make(locale: "ko_KR", format: "HH:mm")

    // MARK: - 서버 송신용 (KST POSIX)

    /// "2026-05-21T14:30:00" — Schedule/Todo due_date 인코딩
    static let serverDateTime: DateFormatter = make(locale: "en_US_POSIX", tz: "Asia/Seoul", format: "yyyy-MM-dd'T'HH:mm:ss")

    /// "2026-05-21" — Semester start/end date 인코딩
    static let serverDateOnly: DateFormatter = make(locale: "en_US_POSIX", tz: "Asia/Seoul", format: "yyyy-MM-dd")

    // MARK: - Helpers

    private static func make(locale: String, tz: String? = nil, format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: locale)
        if let tz, let zone = TimeZone(identifier: tz) {
            f.timeZone = zone
        }
        f.dateFormat = format
        return f
    }
}
