//
//  GwaTopFont.swift
//  GwaTop
//
//  Pretendard 폰트 헬퍼 — gwatop-web 과 동일한 타이포 시스템.
//
//  Web 은 Pretendard Variable (weight 45~920) 단일 woff2 를 쓰고,
//  iOS 는 같은 가변 ttf 를 Info.plist UIAppFonts 로 번들. PostScript 이름은
//  "Pretendard Variable" — UIFont(name: "Pretendard Variable", size:) 로 접근.
//
//  font-family 이름이 시스템에 등록 안 됐을 가능성에 대비해, 폰트 fetch 가 실패하면
//  자동으로 .gwaTopSystem(size:) 로 폴백 (Font.custom 의 자체 폴백 동작).
//
//  설계 원칙:
//  - 의미 단위로 호출 — `.gwaTopHeadline`, `.gwaTopBody`, `.gwaTopCaption`
//  - weight 도 같은 호출에서 — `gwaTopHeadline(.bold)` 식으로 토글
//  - 사이즈 hardcoding 대신 시맨틱 한 곳에서 관리 — 디자인 변경 시 단일 지점 수정
//
//  사용 예:
//      Text("이번 학기 과목")
//          .font(.gwaTopHeadline())
//      Text("3개 등록됨")
//          .font(.gwaTopBody(.medium))
//

import SwiftUI

/// PostScript 이름 — Info.plist UIAppFonts 에 등록된 PretendardVariable.ttf 의
/// font family name. ttf 메타데이터의 family 가 "Pretendard Variable".
private let GwaTopFontFamily = "Pretendard Variable"

/// 디자인 시스템 시맨틱 사이즈 — 웹 토큰과 1:1.
enum GwaTopFontScale {
    case caption2   // 10pt — 미세 메타
    case caption    // 11pt — 캡션, 메타
    case footnote   // 12pt — 보조
    case body       // 13pt — 기본 본문 (web text-[13px])
    case callout    // 14pt — 강조 본문
    case subheadline // 15pt — 강조 (web text-[15px])
    case headline   // 17pt — 섹션 제목
    case title3     // 20pt
    case title2     // 24pt
    case title1     // 28pt
    case largeTitle // 34pt — 화면 타이틀 / hero

    var size: CGFloat {
        switch self {
        case .caption2:    return 10
        case .caption:     return 11
        case .footnote:    return 12
        case .body:        return 13
        case .callout:     return 14
        case .subheadline: return 15
        case .headline:    return 17
        case .title3:      return 20
        case .title2:      return 24
        case .title1:      return 28
        case .largeTitle:  return 34
        }
    }
}

extension Font {
    /// Pretendard 가변 폰트 — 등록 실패 시 system 폰트로 자동 폴백 (Font.custom 동작).
    static func gwaTop(_ scale: GwaTopFontScale, weight: Font.Weight = .regular) -> Font {
        .custom(GwaTopFontFamily, size: scale.size).weight(weight)
    }

    /// `.gwaTopSystem(size:weight:)` 의 Pretendard 대체 — 기존 코드의 임의 사이즈를
    /// Pretendard 로 일괄 전환할 때 사용. design 파라미터(.rounded 등) 가 필요한 곳은
    /// 시스템 폰트의 디자인 메트릭을 유지해야 하므로 호출하지 말 것.
    static func gwaTopSystem(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .custom(GwaTopFontFamily, size: size).weight(weight)
    }

    // MARK: - 시맨틱 단축 헬퍼

    static func gwaTopLargeTitle(_ weight: Font.Weight = .heavy) -> Font { gwaTop(.largeTitle, weight: weight) }
    static func gwaTopTitle1(_ weight: Font.Weight = .bold) -> Font { gwaTop(.title1, weight: weight) }
    static func gwaTopTitle2(_ weight: Font.Weight = .bold) -> Font { gwaTop(.title2, weight: weight) }
    static func gwaTopTitle3(_ weight: Font.Weight = .bold) -> Font { gwaTop(.title3, weight: weight) }
    static func gwaTopHeadline(_ weight: Font.Weight = .bold) -> Font { gwaTop(.headline, weight: weight) }
    static func gwaTopSubheadline(_ weight: Font.Weight = .semibold) -> Font { gwaTop(.subheadline, weight: weight) }
    static func gwaTopCallout(_ weight: Font.Weight = .medium) -> Font { gwaTop(.callout, weight: weight) }
    static func gwaTopBody(_ weight: Font.Weight = .regular) -> Font { gwaTop(.body, weight: weight) }
    static func gwaTopFootnote(_ weight: Font.Weight = .regular) -> Font { gwaTop(.footnote, weight: weight) }
    static func gwaTopCaption(_ weight: Font.Weight = .regular) -> Font { gwaTop(.caption, weight: weight) }
}
