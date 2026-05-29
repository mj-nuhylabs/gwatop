import SwiftUI

extension Notification.Name {
    /// API 401 응답 등 토큰 무효화 시 앱 루트가 로그아웃 처리하도록 신호 전달.
    static let gwaTopUnauthorized = Notification.Name("gwaTopUnauthorized")
}

struct ContentView: View {
    @AppStorage("accessToken") private var accessToken: String = ""
    @AppStorage("signedInUserJSON") private var signedInUserJSON: String = ""

    @State private var signedInUser: GwaTopSignedInUser? = nil
    /// 로그인 또는 세션 복구 직후 스플래시를 노출 중인가? — 메인 탭으로 넘어가기 전 한 번만 켜짐.
    @State private var isWarmingUp: Bool = false

    var body: some View {
        Group {
            if let signedInUser {
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
                    startWarmup()
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) {
                        signedInUser = user
                    }
                }
            }
        }
        .onAppear {
            restoreLoginSessionIfNeeded()
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
        guard signedInUserJSON.isEmpty == false else { return }
        guard let data = signedInUserJSON.data(using: .utf8),
              let user = try? JSONDecoder().decode(GwaTopSignedInUser.self, from: data)
        else {
            accessToken = ""
            signedInUserJSON = ""
            return
        }

        // 앱 콜드 스타트 직후 자동 로그인 — 메인 탭이 그리기 전에 스플래시로 prefetch.
        startWarmup()
        signedInUser = user
    }

    private func logout() {
        accessToken = ""
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
