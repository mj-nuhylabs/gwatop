//
//  GwaTopLoginView.swift
//  GwaTop
//
//  Created by hyunwoo on 5/19/26.
//

import SwiftUI
import GoogleSignIn

struct GwaTopLoginView: View {
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

                        valueCardSection

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
                Circle()
                    .fill(.white.opacity(0.18))
                    .frame(width: 96, height: 96)
                    .blur(radius: 1)

                Circle()
                    .fill(.white)
                    .frame(width: 78, height: 78)
                    .shadow(color: .black.opacity(0.08), radius: 20, x: 0, y: 10)

                Image(systemName: "graduationcap.fill")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(GwaTopTheme.primary)
            }

            VStack(spacing: 8) {
                Text("GwaTop")
                    .font(.system(size: 38, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)

                Text("강의계획서부터 학습 자료까지\nAI가 정리해주는 대학생 학습 플래너")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white.opacity(0.88))
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
            }
        }
    }

    // MARK: - 핵심 가치 카드 영역

    private var valueCardSection: some View {
        HStack(spacing: 10) {
            FeaturePill(iconName: "calendar.badge.clock", title: "일정 자동화")
            FeaturePill(iconName: "doc.text.magnifyingglass", title: "자료 정리")
            FeaturePill(iconName: "sparkles", title: "AI 요약")
        }
    }

    // MARK: - 로그인 카드 영역

    private var loginCardSection: some View {
        VStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text("로그인")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(GwaTopTheme.textPrimary)

                Text("계정에 로그인하고 나만의 학기와 과목을 설정해보세요.")
                    .font(.system(size: 14, weight: .medium))
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

            Button {
                handleEmailLogin()
            } label: {
                Text("이메일로 로그인")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .background(GwaTopTheme.primary)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .shadow(color: GwaTopTheme.primary.opacity(0.28), radius: 12, x: 0, y: 8)
            }
            .disabled(email.isEmpty || password.isEmpty || isLoading)
            .opacity(email.isEmpty || password.isEmpty ? 0.55 : 1.0)

            HStack(spacing: 12) {
                Rectangle().fill(GwaTopTheme.line).frame(height: 1)
                Text("또는")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(GwaTopTheme.textSecondary)
                Rectangle().fill(GwaTopTheme.line).frame(height: 1)
            }

            Button {
                handleGoogleLogin()
            } label: {
                HStack(spacing: 10) {
                    Text("G")
                        .font(.system(size: 18, weight: .heavy, design: .rounded))
                        .foregroundStyle(.blue)
                        .frame(width: 26, height: 26)
                        .background(.white)
                        .clipShape(Circle())

                    Text("Google로 계속하기")
                        .font(.system(size: 16, weight: .bold))
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
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(GwaTopTheme.textSecondary)

                NavigationLink(destination: GwaTopSignUpView()) {
                    Text("회원가입")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(GwaTopTheme.primary)
                }
            }
            .padding(.top, 2)
        }
        .padding(22)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 24, x: 0, y: 16)
    }

    private var policyText: some View {
        Text("로그인 또는 회원가입을 진행하면 GwaTop의 이용약관과 개인정보처리방침에 동의한 것으로 간주됩니다.")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white.opacity(0.72))
            .multilineTextAlignment(.center)
            .lineSpacing(3)
            .padding(.horizontal, 8)
    }

    // MARK: - 액션

    private func handleEmailLogin() {
        guard email.contains("@") else {
            errorMessage = "이메일 형식이 올바르지 않습니다."
            return
        }
        guard password.count >= 6 else {
            errorMessage = "비밀번호는 최소 6자 이상으로 입력해 주세요."
            return
        }
        // TODO: 이메일 로그인 백엔드 연결
        errorMessage = "이메일 로그인은 아직 준비 중입니다."
    }

    private func handleGoogleLogin() {
        guard let windowScene = UIApplication.shared.connectedScenes
            .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
              let rootVC = windowScene.windows.first(where: { $0.isKeyWindow })?.rootViewController
        else {
            errorMessage = "화면을 찾을 수 없습니다."
            return
        }

        isLoading = true

        Task {
            defer { Task { @MainActor in isLoading = false } }

            do {
                let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: rootVC)
                guard let idToken = result.user.idToken?.tokenString else {
                    throw AuthError.noIdToken
                }

                let auth = try await AuthService.shared.googleLogin(idToken: idToken)

                await MainActor.run {
                    accessToken  = auth.accessToken
                    refreshToken = auth.refreshToken
                }
            } catch let error as GIDSignInError where error.code == .canceled {
                // 사용자가 직접 취소한 경우 — 에러 표시 안 함
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                }
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
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(GwaTopTheme.textPrimary)

            HStack(spacing: 12) {
                Image(systemName: iconName)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(GwaTopTheme.primary)
                    .frame(width: 22)

                TextField(placeholder, text: $text)
                    .keyboardType(keyboardType)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .font(.system(size: 15, weight: .semibold))
            }
            .padding(.horizontal, 14)
            .frame(height: 52)
            .background(Color(red: 0.96, green: 0.97, blue: 1.0))
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
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(GwaTopTheme.textPrimary)

            HStack(spacing: 12) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 15, weight: .bold))
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
                .font(.system(size: 15, weight: .semibold))

                Button {
                    isVisible.toggle()
                } label: {
                    Image(systemName: isVisible ? "eye.slash.fill" : "eye.fill")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(GwaTopTheme.textSecondary)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 52)
            .background(Color(red: 0.96, green: 0.97, blue: 1.0))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }
}

struct FeaturePill: View {
    let iconName: String
    let title: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: iconName)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white)

            Text(title)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 78)
        .background(.white.opacity(0.16))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(.white.opacity(0.18), lineWidth: 1)
        )
    }
}

// MARK: - 테마

struct GwaTopTheme {
    static let primary       = Color(red: 0.24, green: 0.36, blue: 0.96)
    static let primaryDark   = Color(red: 0.12, green: 0.20, blue: 0.72)
    static let textPrimary   = Color(red: 0.10, green: 0.12, blue: 0.18)
    static let textSecondary = Color(red: 0.43, green: 0.46, blue: 0.56)
    static let line          = Color(red: 0.88, green: 0.90, blue: 0.95)

    static var backgroundGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 0.34, green: 0.45, blue: 1.0),
                Color(red: 0.16, green: 0.25, blue: 0.78),
                Color(red: 0.10, green: 0.13, blue: 0.36),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

// MARK: - 미리보기

#Preview {
    GwaTopLoginView()
}
