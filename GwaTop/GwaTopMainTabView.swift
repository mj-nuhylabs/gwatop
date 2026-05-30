import SwiftUI

// MARK: - GwaTop Main Tab View
// 기존 GwaTopHomeRootView의 Placeholder 탭을 실제 화면으로 교체하기 위한 새 루트 탭 뷰입니다.
// ContentView.swift에서 GwaTopHomeRootView(user:onLogout:) 대신 GwaTopMainTabView(user:onLogout:)를 호출하면 됩니다.

struct GwaTopMainTabView: View {
    let user: GwaTopSignedInUser
    var onLogout: (() -> Void)? = nil

    @State private var selectedTab: GwaTopTab = .home

    var body: some View {
        TabView(selection: $selectedTab) {
            GwaTopHomeView(user: user)
                .tabItem {
                    Image(systemName: "house.fill")
                    Text("홈")
                }
                .tag(GwaTopTab.home)

            GwaTopCalendarView()
                .tabItem {
                    Image(systemName: "calendar")
                    Text("캘린더")
                }
                .tag(GwaTopTab.calendar)

            GwaTopAIStudyView()
                .tabItem {
                    Image(systemName: "book.closed.fill")
                    Text("학습")
                }
                .tag(GwaTopTab.ai)

            GwaTopAssignmentsView()
                .tabItem {
                    Image(systemName: "checklist")
                    Text("Todo")
                }
                .tag(GwaTopTab.tasks)

            GwaTopSettingsView(user: user, onLogout: onLogout)
                .tabItem {
                    Image(systemName: "gearshape.fill")
                    Text("설정")
                }
                .tag(GwaTopTab.settings)

            // 출시 전 테스트용 임시 탭. 백엔드의 ADMIN_EMAILS 화이트리스트로 게이트되며,
            // 현재 사용자가 admin 이 아니면 화면 안에서 "권한 없음" 메시지가 나온다.
            // 출시 직전에 이 탭과 GwaTopAdminView/Service 를 함께 제거하면 됨.
            GwaTopAdminView()
                .tabItem {
                    Image(systemName: "lock.shield.fill")
                    Text("관리자")
                }
                .tag(GwaTopTab.admin)
        }
        .tint(GwaTopHomeTheme.primary)
        // Apple 캘린더 연동은 로그인 직후 안내하지 않고, 설정 화면의 토글에서만 켜고 끈다.
    }
}

#Preview {
    GwaTopMainTabView(user: .guest)
}
