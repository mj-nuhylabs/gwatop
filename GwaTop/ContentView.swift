//
//  ContentView.swift
//  GwaTop
//
//  Created by MJ Kwon on 5/18/26.
//

import SwiftUI

struct ContentView: View {
    @AppStorage("accessToken") private var accessToken: String = ""

    var body: some View {
        if accessToken.isEmpty {
            GwaTopLoginView()
        } else {
            HomeView()
        }
    }
}

// TODO: 실제 메인 화면으로 교체
struct HomeView: View {
    @AppStorage("accessToken") private var accessToken: String = ""

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 72))
                .foregroundStyle(.green)

            Text("로그인 완료!")
                .font(.system(size: 28, weight: .bold))

            Text("메인 화면을 개발 중입니다.")
                .foregroundStyle(.secondary)

            Button("로그아웃", role: .destructive) {
                accessToken = ""
            }
            .buttonStyle(.borderedProminent)
        }
    }
}
