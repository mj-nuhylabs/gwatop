//
//  GwaTopSplashView.swift
//  GwaTop
//
//  로그인 직후 또는 세션 복구 직후 백엔드 데이터를 미리 받아오는 동안 보여주는
//  스플래시(랜딩) 화면. 중앙 로고 + 0→100% 에너지바 + 현재 작업 텍스트.
//
//  GwaTopAppDataStore.shared.warmup() 이 끝나면 onFinished() 콜백 호출 →
//  부모(ContentView)가 메인 탭으로 전환한다.
//
//  동작:
//   - 매 진입마다 warmup() 한 번 호출 (이미 신선한 캐시 있어도 0.5초 정도 노출).
//   - 에너지바는 store.progress 를 직접 반영 (TaskGroup 단계 완료마다 단계적으로 채워짐).
//   - 너무 빨리 끝나면 (예: 캐시 hit) 최소 0.6초는 보여서 화면 깜빡임 방지.
//

import SwiftUI

struct GwaTopSplashView: View {
    @ObservedObject private var store = GwaTopAppDataStore.shared
    let onFinished: () -> Void

    /// 사용자가 보기에 너무 빨리 끝나서 깜빡임만 남는 걸 방지하기 위한 최소 노출 시간.
    private let minimumDuration: TimeInterval = 0.6
    /// 스플래시 등장 애니메이션용.
    @State private var didAppear = false
    /// 한 번 warmup 시작했는지 — task 가 두 번 실행돼도 중복 호출 방지.
    @State private var didStart = false

    var body: some View {
        ZStack {
            GwaTopHomeTheme.background
                .ignoresSafeArea()

            VStack(spacing: 36) {
                Spacer()

                logoBlock
                    .scaleEffect(didAppear ? 1.0 : 0.92)
                    .opacity(didAppear ? 1.0 : 0)
                    .animation(.spring(response: 0.55, dampingFraction: 0.82), value: didAppear)

                Spacer()

                progressBlock
                    .opacity(didAppear ? 1.0 : 0)
                    .offset(y: didAppear ? 0 : 18)
                    .animation(.easeOut(duration: 0.45).delay(0.15), value: didAppear)
                    .padding(.bottom, 56)
            }
            .padding(.horizontal, 32)
        }
        .task {
            guard !didStart else { return }
            didStart = true
            didAppear = true
            let startedAt = Date()
            await store.warmup()
            let elapsed = Date().timeIntervalSince(startedAt)
            if elapsed < minimumDuration {
                let remaining = minimumDuration - elapsed
                try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            }
            // 페이드 아웃은 부모(ContentView)가 처리. 여기선 콜백만 호출.
            onFinished()
        }
    }

    // MARK: - 로고

    private var logoBlock: some View {
        VStack(spacing: 14) {
            // 코랄 primary 톤의 부드러운 글로우 — 로고 뒤에 깔린다.
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                GwaTopHomeTheme.primary.opacity(0.22),
                                GwaTopHomeTheme.primary.opacity(0.0),
                            ],
                            center: .center,
                            startRadius: 4,
                            endRadius: 130
                        )
                    )
                    .frame(width: 240, height: 240)
                Image("GwaTopLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 136, height: 136)
                    .accessibilityLabel("과탑 로고")
            }
            Text("과탑")
                .font(.system(size: 30, weight: .heavy, design: .rounded))
                .foregroundStyle(GwaTopHomeTheme.textPrimary)
            Text("학생의 학습 동반자")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(GwaTopHomeTheme.textSecondary)
        }
    }

    // MARK: - 에너지바 + 단계 텍스트

    private var progressBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    // 트랙 — 부드러운 surfaceMute.
                    Capsule()
                        .fill(GwaTopHomeTheme.surfaceMute)

                    // 진행 부분 — coral primary → secondary 그라데이션 + 살짝 빛나는 highlight.
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [
                                    GwaTopHomeTheme.primary,
                                    GwaTopHomeTheme.secondary,
                                ],
                                startPoint: .leading, endPoint: .trailing
                            )
                        )
                        .frame(width: max(0, proxy.size.width * progressFraction))
                        .animation(.easeOut(duration: 0.35), value: progressFraction)

                    // 진행 끝부분 가벼운 highlight 점 — "충전" 인상.
                    if progressFraction > 0.02 {
                        Circle()
                            .fill(Color.white.opacity(0.55))
                            .frame(width: 10, height: 10)
                            .offset(x: max(0, proxy.size.width * progressFraction) - 8)
                            .blur(radius: 1)
                            .animation(.easeOut(duration: 0.35), value: progressFraction)
                    }
                }
            }
            .frame(height: 10)

            HStack(spacing: 6) {
                if progressFraction < 1.0 {
                    ProgressView().scaleEffect(0.6)
                } else {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(GwaTopHomeTheme.primary)
                }
                Text(store.currentStage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(GwaTopHomeTheme.textSecondary)
                Spacer()
                Text("\(Int(progressFraction * 100))%")
                    .font(.system(size: 13, weight: .bold).monospacedDigit())
                    .foregroundStyle(GwaTopHomeTheme.textSecondary)
            }
        }
    }

    /// 0.0 ~ 1.0 클램프된 진행률. store.progress 가 음수/이상값이 와도 안전하게.
    private var progressFraction: Double {
        min(max(store.progress, 0), 1)
    }
}

#Preview {
    GwaTopSplashView(onFinished: {})
}
