import SwiftUI

struct ContentView: View {
    @AppStorage("accessToken") private var accessToken: String = ""
    @AppStorage("signedInUserJSON") private var signedInUserJSON: String = ""

    @State private var signedInUser: GwaTopSignedInUser? = nil

    var body: some View {
        Group {
            if let signedInUser {
                GwaTopHomeRootView(user: signedInUser) {
                    logout()
                }
            } else {
                GwaTopLoginView { user in
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) {
                        signedInUser = user
                    }
                }
            }
        }
        .onAppear {
            restoreLoginSessionIfNeeded()
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
