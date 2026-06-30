//
//  GwaTopAppDelegate.swift
//  GwaTop
//
//  APNs 푸시 알림 배선.
//  - SwiftUI 앱은 원격 알림 토큰 콜백을 받으려면 UIApplicationDelegate 가 필요하다
//    (GwaTopApp 에서 @UIApplicationDelegateAdaptor 로 연결).
//  - 흐름: 로그인/세션복구 직후 requestAuthorizationAndRegister() 호출
//          → 권한 허용 시 registerForRemoteNotifications()
//          → didRegister...DeviceToken 콜백에서 토큰 hex 변환 후 백엔드 등록.
//  - 로그아웃 시 unregisterCurrentDevice() 로 디바이스 해제(Bearer 가 살아있을 때 호출).
//

import UIKit
import UserNotifications

final class GwaTopAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    /// 마지막으로 APNs 에서 받은 디바이스 토큰(hex). 로그아웃 시 unregister 에 쓰려고 보관.
    private static let tokenDefaultsKey = "gw_apns_token"
    private(set) static var apnsToken: String? {
        get { UserDefaults.standard.string(forKey: tokenDefaultsKey) }
        set {
            if let value = newValue {
                UserDefaults.standard.set(value, forKey: tokenDefaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: tokenDefaultsKey)
            }
        }
    }

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    // MARK: - 진입점 (로그인 직후 호출)

    /// 알림 권한을 요청하고, 허용되면 APNs 등록을 시작한다.
    /// 백엔드 register API 가 Bearer 를 요구하므로 반드시 로그인 이후에 호출할 것.
    static func requestAuthorizationAndRegister() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
            if let error {
                print("[Push] 권한 요청 실패: \(error)")
            }
            guard granted else {
                print("[Push] 알림 권한이 거부됨 — 등록 건너뜀")
                return
            }
            DispatchQueue.main.async {
                UIApplication.shared.registerForRemoteNotifications()
            }
        }
    }

    /// 로그아웃 시 디바이스 등록 해제. Bearer 가 아직 유효할 때 호출해야 한다(베스트 에포트).
    static func unregisterCurrentDevice() async {
        guard let token = apnsToken else { return }
        do {
            try await GwaTopDeviceService.shared.unregister(apnsToken: token)
        } catch {
            // 401(이미 토큰 만료) 등은 무시 — 서버는 무효 토큰을 BadDeviceToken 시점에 정리한다.
            print("[Push] 디바이스 해제 실패(무시): \(error)")
        }
        apnsToken = nil
    }

    // MARK: - APNs 콜백

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        Self.apnsToken = token
        Task {
            do {
                _ = try await GwaTopDeviceService.shared.register(apnsToken: token)
            } catch {
                print("[Push] 디바이스 등록 실패: \(error)")
            }
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        print("[Push] APNs 등록 실패: \(error)")
    }

    // 앱이 포그라운드일 때도 배너/사운드 노출.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound, .badge]
    }
}
