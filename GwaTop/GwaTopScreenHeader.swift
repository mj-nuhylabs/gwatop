//
//  GwaTopScreenHeader.swift
//  GwaTop
//
//  메인 화면 공통 상단 헤더 — 굵은 제목(좌) + 액션 버튼(우).
//
//  이전엔 `.navigationTitle(.large)` 를 썼지만 큰 제목이 nav bar 아래로 떨어져
//  오른쪽 toolbar 버튼과 세로 정렬이 안 맞았다.
//  ToolbarItem(placement: .topBarLeading) 에 Text 를 넣으면 iOS toolbar 시스템이
//  공간 부족 시 "..." 오버플로 메뉴로 collapse 시키는 부작용도 있었다.
//
//  따라서 nav bar 를 숨기고(.toolbar(.hidden, for: .navigationBar)) 화면 상단에
//  custom HStack 으로 직접 그린다. 항상 같은 height, 같은 정렬, overflow 없음.
//
//  사용 예:
//      GwaTopScreenHeader(title: "캘린더") {
//          Button { ... } label: { /* + circle */ }
//      }
//      // trailing 액션이 없을 땐:
//      GwaTopScreenHeader(title: "과제")
//

import SwiftUI

struct GwaTopScreenHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder let trailing: () -> Trailing

    init(
        title: String,
        @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }
    ) {
        self.title = title
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .center) {
            Text(title)
                .font(.gwaTopSystem(size: 26, weight: .heavy))
                .foregroundStyle(GwaTopHomeTheme.textPrimary)

            Spacer()

            trailing()
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }
}
