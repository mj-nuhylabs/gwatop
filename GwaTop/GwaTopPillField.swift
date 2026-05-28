//
//  GwaTopPillField.swift
//  GwaTop
//
//  로그인/회원가입 진입 화면의 X.com 스타일 pill 입력 필드.
//  - capsule shape, 56pt 높이, surfaceMute 배경
//  - placeholder only (라벨 없음 — X 미니멀 패턴)
//  - secure / keyboard / trailing 슬롯 옵션
//
//  사용 예:
//      GwaTopPillField(placeholder: "이메일", text: $email, keyboard: .emailAddress)
//      GwaTopPillField(placeholder: "비밀번호", text: $pwd, isSecure: true) {
//          Button { ... } label: { Image(systemName: "eye.fill") }
//      }
//      GwaTopPillField(placeholder: "학교", text: .constant(school), readonly: true, onTap: { showPicker = true }) {
//          Image(systemName: "chevron.down")
//      }
//

import SwiftUI

struct GwaTopPillField<Trailing: View>: View {
    let placeholder: String
    @Binding var text: String
    let isSecure: Bool
    let keyboard: UIKeyboardType
    /// true 면 TextField 비활성화 + 전체 영역 탭 → onTap 호출 (학교/대학 picker 용).
    let readonly: Bool
    let onTap: (() -> Void)?
    @ViewBuilder let trailing: () -> Trailing

    init(
        placeholder: String,
        text: Binding<String>,
        isSecure: Bool = false,
        keyboard: UIKeyboardType = .default,
        readonly: Bool = false,
        onTap: (() -> Void)? = nil,
        @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }
    ) {
        self.placeholder = placeholder
        self._text = text
        self.isSecure = isSecure
        self.keyboard = keyboard
        self.readonly = readonly
        self.onTap = onTap
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if readonly {
                    HStack(spacing: 0) {
                        Text(text.isEmpty ? placeholder : text)
                            .foregroundStyle(
                                text.isEmpty
                                    ? GwaTopHomeTheme.textTertiary
                                    : GwaTopHomeTheme.textPrimary
                            )
                        Spacer()
                    }
                } else if isSecure {
                    SecureField(placeholder, text: $text)
                } else {
                    TextField(placeholder, text: $text)
                        .keyboardType(keyboard)
                }
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled(true)
            .font(.gwaTopSystem(size: 16, weight: .semibold))
            .foregroundStyle(GwaTopHomeTheme.textPrimary)

            trailing()
        }
        .padding(.horizontal, 20)
        .frame(height: 56)
        .background(GwaTopHomeTheme.surfaceMute)
        .clipShape(Capsule())
        .contentShape(Capsule())
        .onTapGesture {
            if readonly { onTap?() }
        }
    }
}
