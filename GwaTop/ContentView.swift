import SwiftUI

extension Notification.Name {
    /// API 401 응답 등 토큰 무효화 시 앱 루트가 로그아웃 처리하도록 신호 전달.
    static let gwaTopUnauthorized = Notification.Name("gwaTopUnauthorized")
}

struct ContentView: View {
    @AppStorage("accessToken") private var accessToken: String = ""
    @AppStorage("signedInUserJSON") private var signedInUserJSON: String = ""

    @State private var signedInUser: GwaTopSignedInUser? = nil

    var body: some View {
        Group {
            if let signedInUser {
                GwaTopMainTabView(user: signedInUser) {
                    logout()
                }
            } else {
                GwaTopLoginView { user in
                    persist(user)
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

        signedInUser = user
    }

    private func logout() {
        accessToken = ""
        signedInUserJSON = ""

        withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) {
            signedInUser = nil
        }
    }
}

#Preview {
    ContentView()
}
