//
//  GwaTopLoginView.swift
//  GwaTop
//
//  Created by hyunwoo on 5/19/26.
//

import SwiftUI
import GoogleSignIn

struct GwaTopLoginView: View {
    var onLoginSuccess: (GwaTopSignedInUser) -> Void = { _ in }

    @AppStorage("accessToken")  private var accessToken:  String = ""
    @AppStorage("refreshToken") private var refreshToken: String = ""

    @State private var email: String = ""
    @State private var password: String = ""
    @State private var isPasswordVisible: Bool = false
    @State private var isLoading: Bool = false
    @State private var errorMessage: String? = nil

    var body: some View {
        NavigationStack {
            ZStack {
                GwaTopTheme.backgroundGradient
                    .ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 28) {
                        headerSection
                            .padding(.top, 28)

                        loginCardSection

                        policyText
                            .padding(.bottom, 28)
                    }
                    .padding(.horizontal, 22)
                }

                if isLoading {
                    Color.black.opacity(0.35)
                        .ignoresSafeArea()
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                        .scaleEffect(1.6)
                }
            }
            .navigationBarHidden(true)
            .alert("오류", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("확인", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    // MARK: - 상단 브랜딩 영역

    private var headerSection: some View {
        VStack(spacing: 18) {
            ZStack {
                // 흰 바탕 위 부드러운 코랄 wash orb — matte 인상.
                Circle()
                    .fill(GwaTopTheme.primary.opacity(0.10))
                    .frame(width: 96, height: 96)

                Circle()
                    .fill(GwaTopHomeTheme.surface)
                    .frame(width: 78, height: 78)
                    .overlay(
                        Circle().strokeBorder(GwaTopTheme.primary.opacity(0.20), lineWidth: 1)
                    )

                Image(systemName: "graduationcap.fill")
                    .font(.gwaTopSystem(size: 34, weight: .bold))
                    .foregroundStyle(GwaTopTheme.primary)
            }

            Text("GwaTop")
                .font(.system(size: 38, weight: .heavy, design: .rounded))
                .foregroundStyle(GwaTopTheme.textPrimary)
        }
    }

    // MARK: - 로그인 카드 영역

    private var loginCardSection: some View {
        VStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text("로그인")
                    .font(.gwaTopSystem(size: 24, weight: .bold))
                    .foregroundStyle(GwaTopTheme.textPrimary)

                Text("계정에 로그인하고 나만의 학기와 과목을 설정해보세요.")
                    .font(.gwaTopSystem(size: 14, weight: .medium))
                    .foregroundStyle(GwaTopTheme.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 12) {
                GwaTopTextField(
                    title: "이메일",
                    placeholder: "example@gwatop.com",
                    text: $email,
                    iconName: "envelope.fill",
                    keyboardType: .emailAddress
                )

                GwaTopPasswordField(
                    title: "비밀번호",
                    placeholder: "비밀번호를 입력하세요",
                    text: $password,
                    isVisible: $isPasswordVisible
                )
            }

            Button("이메일로 로그인") {
                handleEmailLogin()
            }
            .gwaTopPrimaryButton(size: .large)
            .disabled(email.isEmpty || password.isEmpty || isLoading)
            .opacity(email.isEmpty || password.isEmpty ? 0.55 : 1.0)

            HStack(spacing: 12) {
                Rectangle().fill(GwaTopTheme.line).frame(height: 1)
                Text("또는")
                    .font(.gwaTopSystem(size: 13, weight: .semibold))
                    .foregroundStyle(GwaTopTheme.textSecondary)
                Rectangle().fill(GwaTopTheme.line).frame(height: 1)
            }

            Button {
                handleGoogleLogin()
            } label: {
                HStack(spacing: 10) {
                    Text("G")
                        .font(.system(size: 18, weight: .heavy, design: .rounded))
                        .foregroundStyle(GwaTopHomeTheme.primary)
                        .frame(width: 26, height: 26)
                        .background(.white)
                        .clipShape(Circle())

                    Text("Google로 계속하기")
                        .font(.gwaTopSystem(size: 16, weight: .bold))
                        .foregroundStyle(GwaTopTheme.textPrimary)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                .background(.white)
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(GwaTopTheme.line, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .disabled(isLoading)

            HStack(spacing: 4) {
                Text("아직 계정이 없나요?")
                    .font(.gwaTopSystem(size: 14, weight: .medium))
                    .foregroundStyle(GwaTopTheme.textSecondary)

                NavigationLink(destination: GwaTopSignUpView(onSignUpSuccess: onLoginSuccess)) {
                    Text("회원가입")
                        .font(.gwaTopSystem(size: 14, weight: .bold))
                        .foregroundStyle(GwaTopTheme.primary)
                }
            }
            .padding(.top, 2)
        }
        .padding(22)
        // 매트 코랄 카드 — 테두리 없이 흰 배경 위에서 부드럽게 부상.
        .background(GwaTopTheme.primary.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
    }

    private var policyText: some View {
        Text("로그인 또는 회원가입을 진행하면 GwaTop의 이용약관과 개인정보처리방침에 동의한 것으로 간주됩니다.")
            .font(.gwaTopSystem(size: 12, weight: .medium))
            .foregroundStyle(GwaTopTheme.textSecondary)
            .multilineTextAlignment(.center)
            .lineSpacing(3)
            .padding(.horizontal, 8)
    }

    // MARK: - 액션

    private func handleEmailLogin() {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedEmail.contains("@") && trimmedEmail.contains(".") else {
            errorMessage = "이메일 형식이 올바르지 않습니다."
            return
        }
        guard password.count >= 6 else {
            errorMessage = "비밀번호는 최소 6자 이상으로 입력해 주세요."
            return
        }

        Task { @MainActor in
            isLoading = true
            defer { isLoading = false }

            do {
                let authResponse = try await AuthService.shared.emailLogin(
                    email: trimmedEmail,
                    password: password
                )

                let signedInUser = GwaTopSignedInUser(
                    id: authResponse.user.id,
                    displayName: authResponse.user.name,
                    email: authResponse.user.email,
                    givenName: nil,
                    familyName: nil,
                    profileImageURL: nil,
                    loginProvider: "email"
                )

                accessToken  = authResponse.accessToken
                refreshToken = authResponse.refreshToken
                onLoginSuccess(signedInUser)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func handleGoogleLogin() {
        guard let windowScene = UIApplication.shared.connectedScenes
            .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
              let rootVC = windowScene.windows.first(where: { $0.isKeyWindow })?.rootViewController
        else {
            errorMessage = "화면을 찾을 수 없습니다."
            return
        }

        Task { @MainActor in
            isLoading = true
            defer { isLoading = false }

            do {
                let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: rootVC)

                guard let idToken = result.user.idToken?.tokenString else {
                    throw AuthError.noIdToken
                }

                let authResponse = try await AuthService.shared.googleLogin(idToken: idToken)

                let profile = result.user.profile
                let signedInUser = GwaTopSignedInUser(
                    id: authResponse.user.id,
                    displayName: authResponse.user.name,
                    email: authResponse.user.email,
                    givenName: profile?.givenName,
                    familyName: profile?.familyName,
                    profileImageURL: profile?.imageURL(withDimension: 240)?.absoluteString,
                    loginProvider: "google"
                )

                accessToken  = authResponse.accessToken
                refreshToken = authResponse.refreshToken
                onLoginSuccess(signedInUser)

            } catch let error as GIDSignInError where error.code == .canceled {
                // 사용자가 직접 취소한 경우 — 에러 표시 안 함
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - 재사용 입력 컴포넌트

struct GwaTopTextField: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    let iconName: String
    let keyboardType: UIKeyboardType

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.gwaTopSystem(size: 13, weight: .bold))
                .foregroundStyle(GwaTopTheme.textPrimary)

            HStack(spacing: 12) {
                Image(systemName: iconName)
                    .font(.gwaTopSystem(size: 15, weight: .bold))
                    .foregroundStyle(GwaTopTheme.primary)
                    .frame(width: 22)

                TextField(placeholder, text: $text)
                    .keyboardType(keyboardType)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .font(.gwaTopSystem(size: 15, weight: .semibold))
            }
            .padding(.horizontal, 14)
            .frame(height: 52)
            .background(GwaTopHomeTheme.background)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }
}

struct GwaTopPasswordField: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    @Binding var isVisible: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.gwaTopSystem(size: 13, weight: .bold))
                .foregroundStyle(GwaTopTheme.textPrimary)

            HStack(spacing: 12) {
                Image(systemName: "lock.fill")
                    .font(.gwaTopSystem(size: 15, weight: .bold))
                    .foregroundStyle(GwaTopTheme.primary)
                    .frame(width: 22)

                Group {
                    if isVisible {
                        TextField(placeholder, text: $text)
                    } else {
                        SecureField(placeholder, text: $text)
                    }
                }
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .font(.gwaTopSystem(size: 15, weight: .semibold))

                Button {
                    isVisible.toggle()
                } label: {
                    Image(systemName: isVisible ? "eye.slash.fill" : "eye.fill")
                        .font(.gwaTopSystem(size: 15, weight: .bold))
                        .foregroundStyle(GwaTopTheme.textSecondary)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 52)
            .background(GwaTopHomeTheme.background)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }
}

// MARK: - 테마

/// 로그인/회원가입 화면 전용 테마. GwaTopHomeTheme(Claude warm light) 와 통일.
/// Web 의 코랄 #cc785c 와 warm off-white 배경에 맞춰 그라데이션도 따뜻한 코랄→다크코랄 톤.
struct GwaTopTheme {
    static let primary       = Color(red: 0.80, green: 0.47, blue: 0.36)  // #cc785c
    static let primaryDark   = Color(red: 0.55, green: 0.30, blue: 0.22)  // 더 짙은 coral
    static let textPrimary   = Color(red: 0.122, green: 0.118, blue: 0.114) // #1f1e1d
    static let textSecondary = Color(red: 0.420, green: 0.408, blue: 0.384) // #6b6862
    static let line          = Color.black.opacity(0.08)                   // #00000014

    /// 로그인/회원가입 화면 배경 — 평면 warm off-white (메인 앱과 동일).
    /// 코랄은 로그인 카드/포인트 요소에만 사용해서 brand 톤을 강조.
    static var backgroundGradient: Color {
        GwaTopHomeTheme.background
    }
}

// MARK: - 미리보기

#Preview {
    GwaTopLoginView()
}
