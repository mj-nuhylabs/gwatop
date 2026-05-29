//
//  GwaTopBootSplashView.swift
//  GwaTop
//
//  앱 콜드 스타트 직후 0.6 초간 표시되는 부팅 스플래시.
//  세션 복구 여부와 무관하게 한 번 보여줘서:
//   - 로그인 안 된 사용자: 부팅 splash → 로그인 화면 (깜빡임 방지)
//   - 로그인 된 사용자: 부팅 splash → 메인 탭 (GwaTopSplashView prefetch 거치고)
//
//  로고 + 텍스트 + 작은 프로그레스 표시 — 별도 작업 없이 시각 안정성만 제공.
//

import SwiftUI

struct GwaTopBootSplashView: View {
    var body: some View {
        ZStack {
            GwaTopHomeTheme.background.ignoresSafeArea()

            VStack(spacing: 18) {
                Image("GwaTopLogo")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(GwaTopHomeTheme.primary)
                    .frame(width: 96, height: 96)

                Text("과탑")
                    .font(.system(size: 32, weight: .black, design: .rounded))
                    .foregroundStyle(GwaTopHomeTheme.textPrimary)

                ProgressView()
                    .tint(GwaTopHomeTheme.primary)
                    .padding(.top, 6)
            }
        }
    }
}

#Preview {
    GwaTopBootSplashView()
}
