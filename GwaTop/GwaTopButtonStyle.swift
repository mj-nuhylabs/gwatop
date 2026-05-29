//
//  GwaTopButtonStyle.swift
//  GwaTop
//
//  gwatop-web 의 Button(base-ui + shadcn) 과 통일된 버튼 스타일.
//
//  Web 의 버튼은 `h-7/8/9 rounded-lg + variant{default,secondary,outline,ghost,destructive}`
//  + 누르는 순간 `translate-y-px` 마이크로 인터랙션. iOS 도 동일한 인상을 주려고
//  ButtonStyle 로 캡슐화.
//
//  iOS HIG 의 최소 터치 영역(44pt)을 지키기 위해 height 는 다음과 같이 정의:
//      .compact = 36pt  (인라인 아이콘 버튼/세컨더리)
//      .regular = 44pt  (기본 — HIG 준수)
//      .large   = 54pt  (메인 CTA — 회원가입/생성 등)
//
//  사용 예:
//      Button("저장") { ... }
//          .buttonStyle(GwaTopButtonStyle(variant: .primary, size: .large))
//
//      Button { ... } label: { Label("취소", systemImage: "xmark") }
//          .buttonStyle(GwaTopButtonStyle(variant: .secondary))
//
//  헬퍼 모디파이어:
//      .gwaTopPrimaryButton(size: .large)
//      .gwaTopSecondaryButton()
//      .gwaTopGhostButton()
//

import SwiftUI

enum GwaTopButtonVariant {
    case primary       // 코랄 단색 배경, 흰 글자 — 주요 액션
    case secondary     // surfaceElevated 배경 + 라인 — 보조 액션
    case ghost         // 투명 배경, 호버 시 옅은 배경 — 인라인 액션
    case destructive   // 위험 액션 — 빨강 톤
}

enum GwaTopButtonSize {
    case compact   // 36pt — 인라인/세컨더리
    case regular   // 44pt — HIG 기본
    case large     // 54pt — 메인 CTA

    var height: CGFloat {
        switch self {
        case .compact: return 36
        case .regular: return 44
        case .large:   return 54
        }
    }
    var fontSize: CGFloat {
        switch self {
        case .compact: return 13
        case .regular: return 15
        case .large:   return 16
        }
    }
    var horizontalPadding: CGFloat {
        switch self {
        case .compact: return 12
        case .regular: return 16
        case .large:   return 20
        }
    }
}

/// 웹과 동일 — radius 12 (Tailwind rounded-lg). 모든 사이즈 공통.
private let GwaTopButtonRadius: CGFloat = 12

struct GwaTopButtonStyle: ButtonStyle {
    let variant: GwaTopButtonVariant
    let size: GwaTopButtonSize
    /// true 면 가로 폭 가득 채움. 기본은 hugging.
    let fillsWidth: Bool

    init(
        variant: GwaTopButtonVariant = .primary,
        size: GwaTopButtonSize = .regular,
        fillsWidth: Bool = false
    ) {
        self.variant = variant
        self.size = size
        self.fillsWidth = fillsWidth
    }

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        return configuration.label
            .font(.gwaTopSystem(size: size.fontSize, weight: .semibold))
            .foregroundStyle(textColor)
            .padding(.horizontal, size.horizontalPadding)
            .frame(maxWidth: fillsWidth ? .infinity : nil)
            .frame(height: size.height)
            .background(background)
            .overlay(borderOverlay)
            .clipShape(RoundedRectangle(cornerRadius: GwaTopButtonRadius, style: .continuous))
            // 웹 base-ui 의 active:translate-y-px 와 동일 효과
            .offset(y: pressed ? 1 : 0)
            .opacity(pressed ? 0.92 : 1.0)
            .animation(.easeOut(duration: 0.08), value: pressed)
    }

    // MARK: - Variant 별 외관

    private var textColor: Color {
        switch variant {
        case .primary:     return .white
        case .secondary:   return GwaTopHomeTheme.textPrimary
        case .ghost:       return GwaTopHomeTheme.textPrimary
        case .destructive: return GwaTopHomeTheme.danger
        }
    }

    @ViewBuilder
    private var background: some View {
        switch variant {
        case .primary:     GwaTopHomeTheme.primary
        case .secondary:   GwaTopHomeTheme.surface
        case .ghost:       Color.clear
        case .destructive: GwaTopHomeTheme.danger.opacity(0.10)
        }
    }

    @ViewBuilder
    private var borderOverlay: some View {
        switch variant {
        case .primary, .destructive, .ghost:
            EmptyView()
        case .secondary:
            RoundedRectangle(cornerRadius: GwaTopButtonRadius, style: .continuous)
                .strokeBorder(GwaTopHomeTheme.line, lineWidth: 1)
        }
    }
}

extension View {
    /// 주요 액션 버튼 — 코랄 배경. 기본 fillsWidth=true (메인 CTA 가정).
    func gwaTopPrimaryButton(
        size: GwaTopButtonSize = .regular,
        fillsWidth: Bool = true
    ) -> some View {
        buttonStyle(GwaTopButtonStyle(variant: .primary, size: size, fillsWidth: fillsWidth))
    }

    /// 보조 액션 버튼 — 흰 배경 + 1px 라인.
    func gwaTopSecondaryButton(
        size: GwaTopButtonSize = .regular,
        fillsWidth: Bool = false
    ) -> some View {
        buttonStyle(GwaTopButtonStyle(variant: .secondary, size: size, fillsWidth: fillsWidth))
    }

    /// 인라인 액션 버튼 — 투명 배경.
    func gwaTopGhostButton(
        size: GwaTopButtonSize = .compact,
        fillsWidth: Bool = false
    ) -> some View {
        buttonStyle(GwaTopButtonStyle(variant: .ghost, size: size, fillsWidth: fillsWidth))
    }
}
