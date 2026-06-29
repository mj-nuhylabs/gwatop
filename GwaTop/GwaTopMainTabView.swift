import SwiftUI

// MARK: - GwaTop Main Tab View
// 기존 GwaTopHomeRootView의 Placeholder 탭을 실제 화면으로 교체하기 위한 새 루트 탭 뷰입니다.
// ContentView.swift에서 GwaTopHomeRootView(user:onLogout:) 대신 GwaTopMainTabView(user:onLogout:)를 호출하면 됩니다.

struct GwaTopMainTabView: View {
    let user: GwaTopSignedInUser
    var onLogout: (() -> Void)? = nil

    @State private var selectedTab: GwaTopTab = .home
    /// 현재 사용자가 백엔드 ADMIN_EMAILS 화이트리스트에 포함될 때만 true.
    /// admin 엔드포인트를 한 번 가볍게 호출해서 성공 여부로 판별한다.
    /// 관리자 화면은 별도 탭이 아니라 "설정" 안의 링크로 노출 → 탭은 항상 5개로 고정되어
    /// iOS 의 "More" 래퍼(겹치는 < 뒤로가기 2개 + 하단 탭바 침범)가 생기지 않는다.
    @State private var isAdmin = false

    var body: some View {
        TabView(selection: $selectedTab) {
            GwaTopHomeView(user: user)
                .tabItem {
                    Image(systemName: "house.fill")
                        .accessibilityLabel("홈")
                }
                .tag(GwaTopTab.home)

            GwaTopCalendarView()
                .tabItem {
                    Image(systemName: "calendar")
                        .accessibilityLabel("캘린더")
                }
                .tag(GwaTopTab.calendar)

            GwaTopAIStudyView()
                .tabItem {
                    Image(systemName: "book.closed.fill")
                        .accessibilityLabel("학습")
                }
                .tag(GwaTopTab.ai)

            GwaTopAssignmentsView()
                .tabItem {
                    Image(systemName: "checklist")
                        .accessibilityLabel("Todo")
                }
                .tag(GwaTopTab.tasks)

            // 관리자 화면은 설정 안의 링크로 들어간다 (탭을 5개로 유지해 More 래퍼 방지).
            GwaTopSettingsView(user: user, onLogout: onLogout, isAdmin: isAdmin)
                .tabItem {
                    Image(systemName: "gearshape.fill")
                        .accessibilityLabel("설정")
                }
                .tag(GwaTopTab.settings)
        }
        .tint(GwaTopHomeTheme.primary)
        // Apple 캘린더 연동은 로그인 직후 안내하지 않고, 설정 화면의 토글에서만 켜고 끈다.
        .task { await detectAdmin() }
    }

    /// admin overview 를 가볍게 한 번 호출해 성공하면 관리자 탭을 노출한다.
    /// 비관리자/게스트는 404·403 등으로 실패하므로 탭이 그대로 숨겨진다.
    @MainActor
    private func detectAdmin() async {
        guard !isAdmin else { return }
        if (try? await GwaTopAdminService.shared.fetchOverview()) != nil {
            isAdmin = true
        }
    }
}

#Preview {
    GwaTopMainTabView(user: .guest)
}
