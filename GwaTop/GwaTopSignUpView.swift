//
//  GwaTopSignUpView.swift
//  GwaTop
//
//  회원가입 화면 — X.com 스타일 (Login 과 동일 톤).
//
//  필드 8 개:
//    1. 이름           (필수, 2 자 이상)
//    2. 이메일         (필수, 형식 검증)
//    3. 이메일 인증 코드 (필수, 발송 후 표시 — 현재는 클라이언트 mock)
//    4. 비밀번호       (필수, 6 자 이상)
//    5. 비밀번호 확인   (필수, 일치)
//    6. 학교           (KoreanUniversities 검색 picker)
//    7. 학번           (필수, 숫자 2 자리 — 예: "24")
//    8. 추천인 코드     (선택)
//
//  백엔드 (/v1/auth/register) 는 현재 email/password/name 만 받음.
//  학교/학번/추천인/인증코드는 UI 에서 수집하지만 백엔드 스키마 확장 전까지는
//  보낼 수 없음 — 향후 백엔드와 함께 추가될 예정 (TODO 주석 표시).
//

import SwiftUI

struct GwaTopSignUpView: View {
    var onSignUpSuccess: (GwaTopSignedInUser) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss

    @AppStorage("accessToken")  private var accessToken:  String = ""
    @AppStorage("refreshToken") private var refreshToken: String = ""

    @State private var name: String = ""
    @State private var email: String = ""
    @State private var emailCode: String = ""
    @State private var password: String = ""
    @State private var confirmPassword: String = ""
    @State private var school: KoreanUniversity? = nil
    @State private var studentId: String = ""        // 학번 (yy)
    @State private var referralCode: String = ""    // 선택

    @State private var isPasswordVisible: Bool = false
    @State private var isConfirmPasswordVisible: Bool = false
    @State private var errorMessage: String? = nil
    @State private var isLoading: Bool = false

    /// 이메일 인증 상태 — false=미발송, true=발송됨 → 코드 입력 필드 노출.
    @State private var emailCodeSent: Bool = false
    /// 재발송 cooldown 카운트다운 (초).
    @State private var resendCooldown: Int = 0

    /// 학교 검색 시트 열림 여부.
    @State private var showSchoolPicker: Bool = false

    var body: some View {
        NavigationStack {
            ZStack {
                GwaTopHomeTheme.background.ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        // Hero
                        Image("GwaTopLogo")
                            .renderingMode(.template)
                            .resizable()
                            .scaledToFit()
                            .foregroundStyle(GwaTopTheme.primary)
                            .frame(width: 56, height: 56)
                            .padding(.bottom, 32)

                        Text("계정 만들기.")
                            .font(.system(size: 38, weight: .black, design: .rounded))
                            .foregroundStyle(GwaTopTheme.textPrimary)
                            .padding(.bottom, 8)

                        Text("처음 한 번만 적어두면\n학기 내내 자동으로 정리돼요.")
                            .font(.gwaTopSystem(size: 15, weight: .medium))
                            .foregroundStyle(GwaTopTheme.textSecondary)
                            .lineSpacing(2)
                            .padding(.bottom, 32)

                        // Fields
                        VStack(spacing: 12) {
                            GwaTopPillField(placeholder: "이름", text: $name)

                            // 이메일 + 발송 버튼 trailing
                            GwaTopPillField(
                                placeholder: "이메일",
                                text: $email,
                                keyboard: .emailAddress
                            ) {
                                Button {
                                    sendEmailCode()
                                } label: {
                                    Text(emailCodeButtonLabel)
                                        .font(.gwaTopSystem(size: 13, weight: .heavy))
                                        .foregroundStyle(canSendCode ? GwaTopTheme.primary : GwaTopHomeTheme.textTertiary)
                                }
                                .buttonStyle(.plain)
                                .disabled(!canSendCode)
                            }

                            // 인증코드 — 발송 후에만 노출
                            if emailCodeSent {
                                GwaTopPillField(
                                    placeholder: "인증코드 6 자리",
                                    text: $emailCode,
                                    keyboard: .numberPad
                                )
                                .transition(.asymmetric(
                                    insertion: .opacity.combined(with: .move(edge: .top)),
                                    removal: .opacity
                                ))
                            }

                            // 비밀번호 + eye toggle
                            GwaTopPillField(
                                placeholder: "비밀번호 (8 자 이상)",
                                text: $password,
                                isSecure: !isPasswordVisible
                            ) {
                                Button { isPasswordVisible.toggle() } label: {
                                    Image(systemName: isPasswordVisible ? "eye.slash.fill" : "eye.fill")
                                        .font(.gwaTopSystem(size: 15, weight: .semibold))
                                        .foregroundStyle(GwaTopTheme.textSecondary)
                                }
                                .buttonStyle(.plain)
                            }

                            // 비밀번호 확인 + 인라인 불일치 경고
                            VStack(alignment: .leading, spacing: 6) {
                                GwaTopPillField(
                                    placeholder: "비밀번호 확인",
                                    text: $confirmPassword,
                                    isSecure: !isConfirmPasswordVisible
                                ) {
                                    Button { isConfirmPasswordVisible.toggle() } label: {
                                        Image(systemName: isConfirmPasswordVisible ? "eye.slash.fill" : "eye.fill")
                                            .font(.gwaTopSystem(size: 15, weight: .semibold))
                                            .foregroundStyle(GwaTopTheme.textSecondary)
                                    }
                                    .buttonStyle(.plain)
                                }
                                if showPasswordMismatch {
                                    Text("비밀번호가 일치하지 않아요")
                                        .font(.gwaTopSystem(size: 12, weight: .semibold))
                                        .foregroundStyle(GwaTopHomeTheme.danger)
                                        .padding(.leading, 6)
                                        .transition(.opacity)
                                }
                            }

                            // 학교 — readonly + sheet picker
                            GwaTopPillField(
                                placeholder: "학교 선택",
                                text: Binding(get: { school?.name ?? "" }, set: { _ in }),
                                readonly: true,
                                onTap: { showSchoolPicker = true }
                            ) {
                                Image(systemName: "chevron.down")
                                    .font(.gwaTopSystem(size: 13, weight: .bold))
                                    .foregroundStyle(GwaTopTheme.textSecondary)
                            }

                            // 학번 — Menu dropdown (현재 연도 부터 10 년 전까지)
                            studentIdMenu

                            // 추천인 (선택)
                            GwaTopPillField(
                                placeholder: "추천인 코드 (선택)",
                                text: $referralCode
                            )
                        }
                        .animation(.easeInOut(duration: 0.2), value: emailCodeSent)
                        .padding(.bottom, 20)

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
                            .padding(.bottom, 16)
                        }

                        // CTA
                        Button("가입하기") {
                            handleSignUp()
                        }
                        .buttonStyle(GwaTopPillButtonStyle(variant: .primary))
                        .disabled(isButtonDisabled || isLoading)
                        .opacity(isButtonDisabled ? 0.55 : 1.0)
                        .padding(.bottom, 24)

                        HStack(spacing: 4) {
                            Text("이미 계정이 있나요?")
                                .foregroundStyle(GwaTopTheme.textSecondary)
                            Button {
                                dismiss()
                            } label: {
                                Text("로그인")
                                    .foregroundStyle(GwaTopTheme.primary)
                            }
                        }
                        .font(.gwaTopSystem(size: 14, weight: .semibold))
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.bottom, 14)

                        Text("계속 진행하면 과탑의 이용약관과 개인정보처리방침에 동의합니다.")
                            .font(.gwaTopSystem(size: 11, weight: .medium))
                            .foregroundStyle(GwaTopHomeTheme.textTertiary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                    }
                    .padding(.horizontal, 28)
                    .padding(.top, 28)
                    .padding(.bottom, 36)
                }

                if isLoading {
                    Color.black.opacity(0.35).ignoresSafeArea()
                    ProgressView().progressViewStyle(.circular).tint(.white).scaleEffect(1.6)
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
            .sheet(isPresented: $showSchoolPicker) {
                GwaTopUniversityPickerSheet(selected: $school)
                    .presentationDetents([.large])
            }
        }
    }

    // MARK: - 학번 선택 메뉴

    /// 현재 연도 → 10 년 전까지 yy 2 자리 리스트 (2026 → 26, 25, 24, …, 16).
    private var studentIdOptions: [String] {
        let yy = Calendar.current.component(.year, from: Date()) % 100
        return (0...10).map { String(format: "%02d", yy - $0) }
    }

    private var studentIdMenu: some View {
        Menu {
            ForEach(studentIdOptions, id: \.self) { y in
                Button {
                    studentId = y
                } label: {
                    HStack {
                        Text("\(y)학번")
                        if studentId == y {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 12) {
                Text(studentId.isEmpty ? "학번 선택" : "\(studentId)학번")
                    .font(.gwaTopSystem(size: 16, weight: .semibold))
                    .foregroundStyle(
                        studentId.isEmpty
                            ? GwaTopHomeTheme.textTertiary
                            : GwaTopHomeTheme.textPrimary
                    )
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.gwaTopSystem(size: 13, weight: .bold))
                    .foregroundStyle(GwaTopTheme.textSecondary)
            }
            .padding(.horizontal, 20)
            .frame(height: 56)
            .background(GwaTopHomeTheme.surfaceMute)
            .clipShape(Capsule())
        }
    }

    // MARK: - 비밀번호 불일치 경고

    private var showPasswordMismatch: Bool {
        !confirmPassword.isEmpty && password != confirmPassword
    }

    // MARK: - 이메일 인증 (현재는 클라이언트 mock)

    private var canSendCode: Bool {
        guard resendCooldown == 0 else { return false }
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.contains("@") && trimmed.contains(".")
    }

    private var emailCodeButtonLabel: String {
        if resendCooldown > 0 { return "재발송 (\(resendCooldown))" }
        return emailCodeSent ? "재발송" : "인증"
    }

    private func sendEmailCode() {
        // TODO: 백엔드 /v1/auth/email-code 엔드포인트 연결 시 실제 API 호출로 교체.
        withAnimation(.easeInOut(duration: 0.2)) { emailCodeSent = true }
        resendCooldown = 30
        Task { @MainActor in
            while resendCooldown > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                resendCooldown -= 1
            }
        }
    }

    // MARK: - 유효성

    private var isButtonDisabled: Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedName.isEmpty
            || trimmedEmail.isEmpty
            || password.isEmpty
            || confirmPassword.isEmpty
            || school == nil
            || studentId.isEmpty
            || !emailCodeSent || emailCode.count < 4
    }

    // MARK: - 가입 액션

    private func handleSignUp() {
        errorMessage = nil

        let trimmedName  = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)

        guard trimmedName.count >= 2 else {
            errorMessage = "이름은 2자 이상 입력해 주세요."
            return
        }
        guard trimmedEmail.contains("@") && trimmedEmail.contains(".") else {
            errorMessage = "올바른 이메일 형식으로 입력해 주세요."
            return
        }
        guard emailCodeSent, emailCode.count >= 4 else {
            errorMessage = "이메일 인증을 완료해 주세요."
            return
        }
        guard password.count >= 8 else {
            errorMessage = "비밀번호는 최소 8자 이상이어야 합니다."
            return
        }
        guard password == confirmPassword else {
            errorMessage = "비밀번호와 비밀번호 확인이 일치하지 않습니다."
            return
        }
        guard school != nil else {
            errorMessage = "학교를 선택해 주세요."
            return
        }
        guard !studentId.trimmingCharacters(in: .whitespaces).isEmpty else {
            errorMessage = "학번을 입력해 주세요."
            return
        }

        Task { @MainActor in
            isLoading = true
            defer { isLoading = false }

            do {
                // TODO: 백엔드 스키마에 school/studentId/referralCode/emailCode 가 추가되면
                //       AuthService.register 시그니처도 함께 확장. 현재는 핵심 3 종만 전송.
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

// MARK: - 학교 검색 시트

struct GwaTopUniversityPickerSheet: View {
    @Binding var selected: KoreanUniversity?
    @Environment(\.dismiss) private var dismiss
    @State private var query: String = ""

    var body: some View {
        NavigationStack {
            ZStack {
                GwaTopHomeTheme.background.ignoresSafeArea()
                VStack(spacing: 0) {
                    // 검색 바
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass")
                            .font(.gwaTopSystem(size: 14, weight: .semibold))
                            .foregroundStyle(GwaTopHomeTheme.textSecondary)
                        TextField("학교 이름 또는 약칭으로 검색", text: $query)
                            .font(.gwaTopSystem(size: 15, weight: .medium))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled(true)
                        if !query.isEmpty {
                            Button { query = "" } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(GwaTopHomeTheme.textTertiary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 50)
                    .background(GwaTopHomeTheme.surfaceMute)
                    .clipShape(Capsule())
                    .padding(.horizontal, 18)
                    .padding(.top, 8)
                    .padding(.bottom, 10)

                    // 결과 리스트
                    let results = KoreanUniversities.search(query)
                    if results.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "magnifyingglass")
                                .font(.gwaTopSystem(size: 28, weight: .light))
                                .foregroundStyle(GwaTopHomeTheme.textTertiary)
                            Text("\"\(query)\" 검색 결과가 없어요.")
                                .font(.gwaTopSystem(size: 13, weight: .medium))
                                .foregroundStyle(GwaTopHomeTheme.textSecondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView(showsIndicators: false) {
                            LazyVStack(spacing: 0) {
                                ForEach(results) { u in
                                    Button {
                                        selected = u
                                        dismiss()
                                    } label: {
                                        HStack(spacing: 12) {
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(u.name)
                                                    .font(.gwaTopSystem(size: 15, weight: .semibold))
                                                    .foregroundStyle(GwaTopHomeTheme.textPrimary)
                                                Text(u.region)
                                                    .font(.gwaTopSystem(size: 12, weight: .medium))
                                                    .foregroundStyle(GwaTopHomeTheme.textTertiary)
                                            }
                                            Spacer()
                                            if selected?.id == u.id {
                                                Image(systemName: "checkmark.circle.fill")
                                                    .foregroundStyle(GwaTopHomeTheme.primary)
                                            }
                                        }
                                        .padding(.horizontal, 20)
                                        .padding(.vertical, 14)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    Divider().opacity(0.4)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("학교 선택")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("닫기") { dismiss() }
                        .foregroundStyle(GwaTopHomeTheme.primary)
                }
            }
        }
    }
}

#Preview {
    GwaTopSignUpView()
}
