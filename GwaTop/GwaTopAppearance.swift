//
//  GwaTopAppearance.swift
//  GwaTop
//
//  앱 전체 외관(light/dark/system) 토글.
//
//  - AppStorage("gw_appearance") 에 raw string 으로 보관.
//  - GwaTopApp.swift 의 ContentView 에 `.preferredColorScheme(appearance.colorScheme)` 적용.
//  - GwaTopSettingsView 에서 사용자가 3 가지 옵션 중 선택 → 즉시 반영.
//
//  GwaTopHomeTheme 의 모든 컬러는 system colorScheme 에 반응하는 dynamic UIColor 라서
//  여기서 `.preferredColorScheme` 만 override 해도 앱 전체가 해당 외관으로 즉시 전환된다.
//

import SwiftUI

enum GwaTopAppearance: String, CaseIterable, Identifiable {
    case system   // 시스템 설정 따라감
    case light
    case dark

    var id: String { rawValue }

    /// SwiftUI .preferredColorScheme 에 넘길 값. system 이면 nil 로 override 해제.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }

    var label: String {
        switch self {
        case .system: return "시스템"
        case .light:  return "라이트"
        case .dark:   return "다크"
        }
    }

    var iconName: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light:  return "sun.max.fill"
        case .dark:   return "moon.fill"
        }
    }
}
