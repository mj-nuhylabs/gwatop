import SwiftUI

// MARK: - GwaTop Main Tab View
// 기존 GwaTopHomeRootView의 Placeholder 탭을 실제 화면으로 교체하기 위한 새 루트 탭 뷰입니다.
// ContentView.swift에서 GwaTopHomeRootView(user:onLogout:) 대신 GwaTopMainTabView(user:onLogout:)를 호출하면 됩니다.

struct GwaTopMainTabView: View {
    let user: GwaTopSignedInUser
    var onLogout: (() -> Void)? = nil

    @State private var selectedTab: GwaTopTab = .home

    // MARK: - Apple 캘린더 1회 안내
    /// 최초 로그인/회원가입 후 한 번만 "Apple 캘린더 연동할까요?" 안내를 띄우기 위한 플래그.
    /// 이후엔 설정 화면에서 켜고 끌 수 있다.
    @AppStorage("gwaTopAppleCalendarPrompted") private var promptedAppleCalendar: Bool = false
    @AppStorage(UserDefaults.gwaTopAppleCalendarEnabledKey) private var appleCalendarEnabled: Bool = false
    @State private var showAppleCalendarPrompt = false

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
                    Text("과제")
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
        .task {
            // 최초 1회만 — 탭 전환 직후 alert 충돌을 피하려고 살짝 지연 후 표시.
            guard !promptedAppleCalendar else { return }
            try? await Task.sleep(nanoseconds: 700_000_000)
            showAppleCalendarPrompt = true
        }
        .alert("Apple 캘린더 연동", isPresented: $showAppleCalendarPrompt) {
            Button("연동하기") {
                promptedAppleCalendar = true
                Task {
                    let granted = await GwaTopAppleCalendarService.shared.requestAccess()
                    if granted { appleCalendarEnabled = true }
                }
            }
            Button("나중에", role: .cancel) {
                promptedAppleCalendar = true
            }
        } message: {
            Text("기기의 Apple 캘린더 일정을 과탑 캘린더에 함께 표시할까요? 설정에서 언제든 켜고 끌 수 있어요.")
        }
    }
}

#Preview {
    GwaTopMainTabView(user: .guest)
}
