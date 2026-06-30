import SwiftUI

extension Notification.Name {
    /// API 401 응답 등 토큰 무효화 시 앱 루트가 로그아웃 처리하도록 신호 전달.
    static let gwaTopUnauthorized = Notification.Name("gwaTopUnauthorized")
}

struct ContentView: View {
    @AppStorage("signedInUserJSON") private var signedInUserJSON: String = ""
    /// 로그인 유지 체크 여부 — false 면 콜드 스타트 시 세션 폐기 후 다시 로그인 요구.
    @AppStorage("keepSignedIn") private var keepSignedIn: Bool = true

    @State private var signedInUser: GwaTopSignedInUser? = nil
    /// 로그인 또는 세션 복구 직후 스플래시를 노출 중인가? — 메인 탭으로 넘어가기 전 한 번만 켜짐.
    @State private var isWarmingUp: Bool = false
    /// 콜드 스타트 직후 0.6 초 동안 보여줄 부팅 스플래시 — 로그인 여부와 무관하게 한 번 표시.
    /// LoginView 가 곧장 렌더링되며 화면이 깜빡거리는 걸 방지.
    @State private var isBooting: Bool = true

    var body: some View {
        Group {
            if isBooting {
                GwaTopBootSplashView()
                    .transition(.opacity)
            } else if let signedInUser {
                if isWarmingUp {
                    GwaTopSplashView {
                        // prefetch 완료 — 메인 탭으로 페이드 전환.
                        withAnimation(.easeInOut(duration: 0.35)) {
                            isWarmingUp = false
                        }
                    }
                    .transition(.opacity)
                } else {
                    GwaTopMainTabView(user: signedInUser) {
                        logout()
                    }
                    .transition(.opacity)
                }
            } else {
                GwaTopLoginView { user in
                    persist(user)
                    // 로그인 직후(Bearer 확보) 알림 권한 요청 + APNs 등록.
                    GwaTopAppDelegate.requestAuthorizationAndRegister()
                    startWarmup()
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) {
                        signedInUser = user
                    }
                }
            }
        }
        .onAppear {
            restoreLoginSessionIfNeeded()
            // 콜드 스타트 후 최소 0.6 초 splash 표시 → 페이드아웃.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 600_000_000)
                withAnimation(.easeOut(duration: 0.3)) {
                    isBooting = false
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .gwaTopUnauthorized)) { _ in
            logout()
        }
    }

    private func persist(_ user: GwaTopSignedInUser) {
        if let data = try? JSONEncoder().encode(user),
           let s = String(data: data, encoding: .utf8) {
            signedInUserJSON = s
        }
    }

    /// 스플래시 모드 진입 + AppDataStore 캐시 초기화 (이전 사용자 캐시 잔재 방지).
    private func startWarmup() {
        Task { @MainActor in
            // 캐시는 그대로 두고 진행률만 0 으로 — 같은 사용자 재로그인 시 캐시 hit 활용.
            // 다른 사용자라면 logout() 이 이미 reset() 호출.
            isWarmingUp = true
        }
    }

    private func restoreLoginSessionIfNeeded() {
        guard signedInUser == nil else { return }

        // 로그인 유지를 끈 사용자는 콜드 스타트 시 세션을 폐기 → 다시 로그인 필요.
        guard keepSignedIn else {
            GwaTopAuthTokenStore.clear()
            signedInUserJSON = ""
            return
        }

        guard signedInUserJSON.isEmpty == false else { return }
        guard let data = signedInUserJSON.data(using: .utf8),
              let user = try? JSONDecoder().decode(GwaTopSignedInUser.self, from: data)
        else {
            GwaTopAuthTokenStore.clear()
            signedInUserJSON = ""
            return
        }

        // 앱 콜드 스타트 직후 자동 로그인 — 메인 탭이 그리기 전에 스플래시로 prefetch.
        // 세션 복구 시에도 APNs 토큰을 재등록(토큰 회전/새 기기 대비, 등록은 멱등 upsert).
        GwaTopAppDelegate.requestAuthorizationAndRegister()
        startWarmup()
        signedInUser = user
    }

    private func logout() {
        // 디바이스 등록 해제는 Bearer 가 유효할 때 먼저 시도하고, 끝난 뒤 토큰을 정리한다.
        // (unregister API 가 인증을 요구하므로 토큰을 먼저 지우면 401 로 실패한다.)
        Task {
            await GwaTopAppDelegate.unregisterCurrentDevice()
            GwaTopAuthTokenStore.clear()
        }
        signedInUserJSON = ""

        Task { @MainActor in
            GwaTopAppDataStore.shared.reset()
        }
        withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) {
            signedInUser = nil
            isWarmingUp = false
        }
    }
}

#Preview {
    ContentView()
}
