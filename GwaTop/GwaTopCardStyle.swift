//
//  GwaTopCardStyle.swift
//  GwaTop
//
//  gwatop-web 의 Card 와 통일된 평면(flat) 카드 스타일.
//
//  Web 의 카드는 `ring-1 ring-foreground/10 rounded-xl bg-card` — 그림자 없이
//  얇은 ring(border) 만으로 깊이를 표현한다. iOS 도 동일한 인상을 주려고
//  ViewModifier 로 캡슐화. 기존 inline 카드 패턴(흰 배경 + black opacity 0.04~0.06 그림자)
//  을 `.gwaTopCard()` 한 줄로 대체.
//
//  - radius: 기본 14 (현재 코드베이스에서 가장 흔한 값)
//  - surface: 기본 흰색(GwaTopHomeTheme.surface)
//  - line: GwaTopHomeTheme.line (Web --border rgba(0,0,0,0.08) 와 1:1)
//
//  사용 예:
//      VStack { ... }
//          .padding(16)
//          .gwaTopCard()
//
//      // 강조 카드(예: 빈 상태 안내 박스) — surfaceElevated 톤
//      VStack { ... }
//          .padding(16)
//          .gwaTopCard(radius: 16, surface: GwaTopHomeTheme.surfaceElevated)
//

import SwiftUI

struct GwaTopCardStyle: ViewModifier {
    let radius: CGFloat
    let surface: Color
    let lineColor: Color
    let lineWidth: CGFloat

    func body(content: Content) -> some View {
        content
            .background(surface)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(lineColor, lineWidth: lineWidth)
            )
    }
}

extension View {
    /// 표준 카드 스타일 — 흰 배경 + 1px ring border + 라운드(기본 14). 그림자 없음.
    /// gwatop-web 의 `Card` (`rounded-xl bg-card ring-1 ring-foreground/10`) 와 통일.
    func gwaTopCard(
        radius: CGFloat = 14,
        surface: Color = GwaTopHomeTheme.surface,
        lineColor: Color = GwaTopHomeTheme.line,
        lineWidth: CGFloat = 1
    ) -> some View {
        modifier(GwaTopCardStyle(
            radius: radius,
            surface: surface,
            lineColor: lineColor,
            lineWidth: lineWidth
        ))
    }
}
