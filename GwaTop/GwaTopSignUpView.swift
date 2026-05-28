//
//  GwaTopSignUpView.swift
//  GwaTop
//
//  Created by hyunwoo on 5/19/26.
//

import SwiftUI

// MARK: - GwaTop 독립형 회원가입 화면
// 이 파일은 기존 GwaTopLoginView.swift와 함께 사용하는 것을 기준으로 만들었습니다.
// 기존 파일에 있는 GwaTopTheme, GwaTopTextField, GwaTopPasswordField를 그대로 재사용합니다.
// 백엔드는 아직 연결하지 않고, 입력 검증과 Mock 성공 팝업만 동작합니다.

struct GwaTopSignUpView: View {
    var onSignUpSuccess: (GwaTopSignedInUser) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss

    @AppStorage("accessToken")  private var accessToken:  String = ""
    @AppStorage("refreshToken") private var refreshToken: String = ""

    @State private var name: String = ""
    @State private var email: String = ""
    @State private var password: String = ""
    @State private var confirmPassword: String = ""
    @State private var schoolName: String = ""

    @State private var isPasswordVisible: Bool = false
    @State private var isConfirmPasswordVisible: Bool = false
    @State private var errorMessage: String? = nil
    @State private var isLoading: Bool = false

    var body: some View {
        NavigationStack {
            ZStack {
                GwaTopTheme.backgroundGradient
                    .ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 24) {
                        headerSection
                            .padding(.top, 24)

                        signUpCardSection

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
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.left")
                                .font(.gwaTopSystem(size: 14, weight: .bold))
                            Text("로그인")
                                .font(.gwaTopSystem(size: 15, weight: .bold))
                        }
                        .foregroundStyle(GwaTopTheme.primary)
                    }
                }
            }
        }
    }

    // MARK: - 상단 영역

    private var headerSection: some View {
        VStack(spacing: 16) {
            Image("GwaTopLogo")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .foregroundStyle(GwaTopTheme.primary)
                .frame(width: 88, height: 88)

            VStack(spacing: 8) {
                Text("계정 만들기")
                    .font(.system(size: 34, weight: .heavy, design: .rounded))
                    .foregroundStyle(GwaTopTheme.textPrimary)

                Text("과탑에서 학기와 과목을 정리하고\nAI 학습 플래너를 시작해보세요.")
                    .font(.gwaTopSystem(size: 16, weight: .medium))
                    .foregroundStyle(GwaTopTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
            }
        }
    }

    // MARK: - 회원가입 카드 영역

    private var signUpCardSection: some View {
        VStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text("회원가입 정보")
                    .font(.gwaTopSystem(size: 24, weight: .bold))
                    .foregroundStyle(GwaTopTheme.textPrimary)

                Text("처음에는 최소 정보만 받고, 학기와 과목은 다음 온보딩 단계에서 설정합니다.")
                    .font(.gwaTopSystem(size: 14, weight: .medium))
                    .foregroundStyle(GwaTopTheme.textSecondary)
                    .lineSpacing(3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 14) {
                GwaTopTextField(
                    title: "이름",
                    placeholder: "홍길동",
                    text: $name,
                    iconName: "person.fill",
                    keyboardType: .default
                )

                GwaTopTextField(
                    title: "이메일",
                    placeholder: "example@gwatop.com",
                    text: $email,
                    iconName: "envelope.fill",
                    keyboardType: .emailAddress
                )

                GwaTopTextField(
                    title: "학교 이름",
                    placeholder: "예: 한국대학교",
                    text: $schoolName,
                    iconName: "building.columns.fill",
                    keyboardType: .default
                )

                GwaTopPasswordField(
                    title: "비밀번호",
                    placeholder: "6자 이상 입력하세요",
                    text: $password,
                    isVisible: $isPasswordVisible
                )

                GwaTopPasswordField(
                    title: "비밀번호 확인",
                    placeholder: "비밀번호를 한 번 더 입력하세요",
                    text: $confirmPassword,
                    isVisible: $isConfirmPasswordVisible
                )
            }

            if let errorMessage {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.gwaTopSystem(size: 14, weight: .bold))
                        .foregroundStyle(GwaTopHomeTheme.danger)

                    Text(errorMessage)
                        .font(.gwaTopSystem(size: 13, weight: .semibold))
                        .foregroundStyle(GwaTopHomeTheme.danger)
                        .lineSpacing(3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 2)
            }

            Button("회원가입하기") {
                handleSignUp()
            }
            .gwaTopPrimaryButton(size: .large)
            .disabled(isButtonDisabled || isLoading)
            .opacity(isButtonDisabled ? 0.55 : 1.0)
            .padding(.top, 4)

            Button {
                dismiss()
            } label: {
                HStack(spacing: 4) {
                    Text("이미 계정이 있나요?")
                        .font(.gwaTopSystem(size: 14, weight: .medium))
                        .foregroundStyle(GwaTopTheme.textSecondary)

                    Text("로그인하기")
                        .font(.gwaTopSystem(size: 14, weight: .bold))
                        .foregroundStyle(GwaTopTheme.primary)
                }
            }
        }
        .padding(22)
        // 매트 코랄 카드 — Login 과 동일 톤. 테두리 없음.
        .background(GwaTopTheme.primary.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
    }

    private var policyText: some View {
        Text("회원가입을 진행하면 과탑의 이용약관과 개인정보처리방침에 동의한 것으로 간주됩니다.")
            .font(.gwaTopSystem(size: 12, weight: .medium))
            .foregroundStyle(GwaTopTheme.textSecondary)
            .multilineTextAlignment(.center)
            .lineSpacing(3)
            .padding(.horizontal, 8)
    }

    private var isButtonDisabled: Bool {
        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
        email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
        schoolName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
        password.isEmpty ||
        confirmPassword.isEmpty
    }

    // MARK: - 회원가입 처리

    private func handleSignUp() {
        errorMessage = nil

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSchoolName = schoolName.trimmingCharacters(in: .whitespacesAndNewlines)

        guard trimmedName.count >= 2 else {
            errorMessage = "이름은 2자 이상 입력해 주세요."
            return
        }

        guard trimmedEmail.contains("@") && trimmedEmail.contains(".") else {
            errorMessage = "올바른 이메일 형식으로 입력해 주세요."
            return
        }

        guard trimmedSchoolName.isEmpty == false else {
            errorMessage = "학교 이름을 입력해 주세요."
            return
        }

        guard password.count >= 6 else {
            errorMessage = "비밀번호는 최소 6자 이상이어야 합니다."
            return
        }

        guard password == confirmPassword else {
            errorMessage = "비밀번호와 비밀번호 확인이 일치하지 않습니다."
            return
        }

        Task { @MainActor in
            isLoading = true
            defer { isLoading = false }

            do {
                let authResponse = try await AuthService.shared.register(
                    email: trimmedEmail,
                    password: password,
                    name: trimmedName
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
                onSignUpSuccess(signedInUser)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

#Preview {
    GwaTopSignUpView()
}
