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
    /// 강의계획서 파싱 진행 상태를 전역에서 추적 (시트 닫혀도 백그라운드 폴링).
    @StateObject private var syllabusWatcher = GwaTopSyllabusWatcher.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        configureGoogleSignIn()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onOpenURL { url in
                    GIDSignIn.sharedInstance.handle(url)
                }
                .onChange(of: scenePhase) { _, newPhase in
                    // foreground 일 때만 폴링 — 배터리/네트워크 절약.
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
