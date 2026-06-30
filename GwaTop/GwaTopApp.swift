//
//  GwaTopApp.swift
//  GwaTop
//
//  Created by MJ Kwon on 5/18/26.
//

import SwiftUI
import GoogleSignIn

@main
struct GwaTopApp: App {
    /// SwiftUI 앱에서 APNs 토큰 콜백을 받기 위한 UIApplicationDelegate 연결.
    @UIApplicationDelegateAdaptor(GwaTopAppDelegate.self) private var appDelegate

    /// 강의계획서 파싱 진행 상태를 전역에서 추적 (시트 닫혀도 백그라운드 폴링).
    @StateObject private var syllabusWatcher = GwaTopSyllabusWatcher.shared
    @Environment(\.scenePhase) private var scenePhase

    /// 외관 설정 (system / light / dark) — 설정 화면에서 사용자 변경, 전체 앱에 적용.
    @AppStorage("gw_appearance") private var appearanceRaw: String = GwaTopAppearance.system.rawValue
    private var appearance: GwaTopAppearance {
        GwaTopAppearance(rawValue: appearanceRaw) ?? .system
    }

    init() {
        configureGoogleSignIn()
        configureURLCache()
    }

    /// URLSession.shared 의 캐시 용량 확대 — 백엔드가 Cache-Control: max-age=N 으로 보내는
    /// AI 콘텐츠 JSON 들을 더 많이 보관해 같은 탭/모드 재진입 시 네트워크 0회.
    /// 기본값 (memory 4MB / disk 20MB) 은 PDF/이미지엔 작아서 금세 evict 됨 → 키운다.
    private func configureURLCache() {
        let memoryMB = 32
        let diskMB = 200
        URLCache.shared = URLCache(
            memoryCapacity: memoryMB * 1024 * 1024,
            diskCapacity: diskMB * 1024 * 1024,
            diskPath: "gwatop-urlcache"
        )
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(appearance.colorScheme)
                .onOpenURL { url in
                    GIDSignIn.sharedInstance.handle(url)
                }
                .task {
                    // 첫 부팅 시 .onChange(of: scenePhase) 는 값이 "변하지" 않으므로
                    // 트리거되지 않는다 (앱 시작 시 scenePhase 가 처음부터 .active).
                    // 따라서 첫 시작 폴은 여기서 명시적으로 띄운다.
                    syllabusWatcher.startWatching()
                }
                .onChange(of: scenePhase) { _, newPhase in
                    // background ↔ foreground 전환 처리 — 배터리/네트워크 절약.
                    if newPhase == .active {
                        syllabusWatcher.startWatching()
                    } else {
                        syllabusWatcher.stopWatching()
                    }
                }
        }
    }

    private func configureGoogleSignIn() {
        guard
            let path = Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist"),
            let plist = NSDictionary(contentsOfFile: path),
            let clientID = plist["CLIENT_ID"] as? String
        else { return }
        GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
    }
}
