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
                GwaTopHomeTheme.background.ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        // 좌측 정렬 hero 로고 — X.com 의 마크 위치와 동일 인상
                        Image("GwaTopLogo")
                            .renderingMode(.template)
                            .resizable()
                            .scaledToFit()
                            .foregroundStyle(GwaTopTheme.primary)
                            .frame(width: 56, height: 56)
                            .padding(.bottom, 44)

                        // 거대한 display 헤드라인 — bold rounded
                        Text("지금 시작되는\n새 학기.")
                            .font(.system(size: 44, weight: .black, design: .rounded))
                            .foregroundStyle(GwaTopTheme.textPrimary)
                            .lineSpacing(-4)
                            .padding(.bottom, 18)

                        Text("강의·과제·일정 한 번에.")
                            .font(.gwaTopSystem(size: 16, weight: .medium))
                            .foregroundStyle(GwaTopTheme.textSecondary)
                            .padding(.bottom, 40)

                        // 이메일 + 비밀번호 — 카드/타이틀 없이 pill 모양 단독
                        loginPillField(
                            placeholder: "이메일",
                            text: $email,
                            isSecure: false,
                            keyboardType: .emailAddress
                        )
                        .padding(.bottom, 12)

                        loginPillField(
                            placeholder: "비밀번호",
                            text: $password,
                            isSecure: !isPasswordVisible,
                            trailing: AnyView(
                                Button {
                                    isPasswordVisible.toggle()
                                } label: {
                                    Image(systemName: isPasswordVisible ? "eye.slash.fill" : "eye.fill")
                                        .font(.gwaTopSystem(size: 15, weight: .semibold))
                                        .foregroundStyle(GwaTopTheme.textSecondary)
                                }
                                .buttonStyle(.plain)
                            )
                        )
                        .padding(.bottom, 22)

                        // 메인 CTA — pill primary, full width
                        Button("로그인") {
                            handleEmailLogin()
                        }
                        .buttonStyle(GwaTopPillButtonStyle(variant: .primary))
                        .disabled(email.isEmpty || password.isEmpty || isLoading)
                        .opacity(email.isEmpty || password.isEmpty ? 0.55 : 1.0)
                        .padding(.bottom, 18)

                        // 또는 divider
                        HStack(spacing: 12) {
                            Rectangle().fill(GwaTopTheme.line).frame(height: 1)
                            Text("또는")
                                .font(.gwaTopSystem(size: 12, weight: .semibold))
                                .foregroundStyle(GwaTopTheme.textSecondary)
                            Rectangle().fill(GwaTopTheme.line).frame(height: 1)
                        }
                        .padding(.bottom, 18)

                        // Google CTA — pill outline
                        Button {
                            handleGoogleLogin()
                        } label: {
                            HStack(spacing: 10) {
                                Text("G")
                                    .font(.system(size: 16, weight: .heavy, design: .rounded))
                                    .foregroundStyle(GwaTopTheme.primary)
                                Text("Google로 계속하기")
                            }
                        }
                        .buttonStyle(GwaTopPillButtonStyle(variant: .outline))
                        .disabled(isLoading)
                        .padding(.bottom, 36)

                        // 가입 링크 — center, 작은 텍스트
                        HStack(spacing: 4) {
                            Text("계정이 없나요?")
                                .foregroundStyle(GwaTopTheme.textSecondary)
                            NavigationLink {
                                GwaTopSignUpView(onSignUpSuccess: onLoginSuccess)
                            } label: {
                                Text("가입하기")
                                    .foregroundStyle(GwaTopTheme.primary)
                            }
                        }
                        .font(.gwaTopSystem(size: 14, weight: .semibold))
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.bottom, 14)

                        // 약관 footer — fine print
                        Text("계속 진행하면 과탑의 이용약관과 개인정보처리방침에 동의합니다.")
                            .font(.gwaTopSystem(size: 11, weight: .medium))
                            .foregroundStyle(GwaTopHomeTheme.textTertiary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                    }
                    .padding(.horizontal, 28)
                    .padding(.top, 36)
                    .padding(.bottom, 36)
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

    // MARK: - Pill 입력 필드 (인라인 전용 — 다른 곳에선 GwaTopTextField 사용)

    @ViewBuilder
    private func loginPillField(
        placeholder: String,
        text: Binding<String>,
        isSecure: Bool,
        keyboardType: UIKeyboardType = .default,
        trailing: AnyView? = nil
    ) -> some View {
        HStack(spacing: 12) {
            Group {
                if isSecure {
                    SecureField(placeholder, text: text)
                } else {
                    TextField(placeholder, text: text)
                        .keyboardType(keyboardType)
                }
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled(true)
            .font(.gwaTopSystem(size: 16, weight: .semibold))
            .foregroundStyle(GwaTopTheme.textPrimary)

            if let trailing { trailing }
        }
        .padding(.horizontal, 20)
        .frame(height: 56)
        .background(GwaTopHomeTheme.surfaceMute)
        .clipShape(Capsule())
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

// MARK: - 로그인 전용 Pill 버튼 스타일

/// X.com 스타일의 둥근 pill 버튼 — primary(코랄 fill) / outline(흰+라인).
/// 전역 GwaTopButtonStyle 과 별개로 로그인/회원가입 입구 전용 hero CTA.
struct GwaTopPillButtonStyle: ButtonStyle {
    enum Variant { case primary, outline }
    let variant: Variant

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        return configuration.label
            .font(.gwaTopSystem(size: 16, weight: .heavy))
            .foregroundStyle(textColor)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(background)
            .overlay(borderOverlay)
            .clipShape(Capsule())
            .offset(y: pressed ? 1 : 0)
            .opacity(pressed ? 0.92 : 1.0)
            .animation(.easeOut(duration: 0.08), value: pressed)
    }

    private var textColor: Color {
        switch variant {
        case .primary: return .white
        case .outline: return GwaTopHomeTheme.textPrimary
        }
    }

    @ViewBuilder private var background: some View {
        switch variant {
        case .primary: GwaTopHomeTheme.primary
        case .outline: GwaTopHomeTheme.surface
        }
    }

    @ViewBuilder private var borderOverlay: some View {
        switch variant {
        case .primary: EmptyView()
        case .outline:
            Capsule().strokeBorder(GwaTopHomeTheme.line, lineWidth: 1)
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

/// 로그인/회원가입 화면 전용 테마. GwaTopHomeTheme(Claude warm) 와 통일.
/// 이제는 사실상 GwaTopHomeTheme alias — light/dark 자동 전환을 그대로 상속.
struct GwaTopTheme {
    static let primary       = GwaTopHomeTheme.primary
    static let primaryDark   = Color(red: 0.55, green: 0.30, blue: 0.22)  // 더 짙은 coral (정적)
    static let textPrimary   = GwaTopHomeTheme.textPrimary
    static let textSecondary = GwaTopHomeTheme.textSecondary
    static let line          = GwaTopHomeTheme.line

    /// 로그인/회원가입 화면 배경 — 평면 warm off-white (light) / warm dark (dark).
    static var backgroundGradient: Color {
        GwaTopHomeTheme.background
    }
}

// MARK: - 미리보기

#Preview {
    GwaTopLoginView()
}
