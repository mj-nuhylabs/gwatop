//
//  GwaTopNetworkMonitor.swift
//  GwaTop
//
//  앱 전역 네트워크 상태 모니터. 두 가지 신호로 'slow' / 'offline' 판단:
//
//   1) NWPathMonitor — 시스템 레벨 연결 상태 (offline / constrained / expensive)
//   2) HTTP 요청 latency rolling average — 5건 평균 > 3000ms 면 slow
//
//  GwaTopNetworkBanner 가 이 상태를 관찰해 상단에 노란 배너 표시.
//

import Combine
import Foundation
import Network
import SwiftUI

@MainActor
final class GwaTopNetworkMonitor: ObservableObject {
    static let shared = GwaTopNetworkMonitor()

    enum Status: Equatable {
        case good
        case slow
        case offline
    }

    @Published private(set) var status: Status = .good
    @Published private(set) var avgLatencyMs: Double = 0

    private let pathMonitor = NWPathMonitor()
    private let pathQueue = DispatchQueue(label: "gwatop.network.path")

    private var latencies: [Double] = []
    private let latencyWindow = 5

    private let slowThresholdMs: Double = 3000
    private let recoverThresholdMs: Double = 1500

    /// 시스템 path 가 unsatisfied 이면 즉시 offline.
    private var pathOffline = false
    /// 시스템 path 가 constrained/expensive 일 때.
    private var pathConstrained = false

    private init() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.pathOffline = (path.status != .satisfied)
                self.pathConstrained = path.isExpensive || path.isConstrained
                self.recompute()
            }
        }
        pathMonitor.start(queue: pathQueue)
    }

    /// GwaTopAPIClient 가 매 요청 후 호출. ms 단위.
    func recordLatency(_ ms: Double) {
        // 너무 빠른 캐시 hit(< 50ms) 은 신호로 약하니 그대로 기록. 너무 느린 outlier 는 30s 캡.
        let capped = min(max(ms, 0), 30_000)
        latencies.append(capped)
        if latencies.count > latencyWindow {
            latencies.removeFirst(latencies.count - latencyWindow)
        }
        avgLatencyMs = latencies.reduce(0, +) / Double(latencies.count)
        recompute()
    }

    private func recompute() {
        if pathOffline {
            status = .offline
            return
        }
        // 시스템이 expensive/constrained 라고 알려주면 (보통 모바일 데이터) 그것만으로도 slow 처리.
        if pathConstrained {
            status = .slow
            return
        }
        if avgLatencyMs >= slowThresholdMs {
            status = .slow
        } else if status == .slow, avgLatencyMs <= recoverThresholdMs {
            status = .good
        } else if status != .slow {
            status = .good
        }
    }
}

// MARK: - 배너 뷰

struct GwaTopNetworkBanner: View {
    @ObservedObject private var monitor = GwaTopNetworkMonitor.shared

    var body: some View {
        Group {
            switch monitor.status {
            case .offline:
                row(icon: "wifi.slash",
                    text: "오프라인 상태에요. 와이파이 또는 데이터 연결을 확인해 주세요.",
                    bg: Color.red.opacity(0.12),
                    fg: Color.red)
            case .slow:
                row(icon: "wifi.exclamationmark",
                    text: "네트워크가 느려요. AI 응답이 평소보다 늦어질 수 있어요.",
                    bg: Color.orange.opacity(0.15),
                    fg: Color.orange)
            case .good:
                EmptyView()
            }
        }
        .animation(.easeInOut(duration: 0.25), value: monitor.status)
    }

    private func row(icon: String, text: String, bg: Color, fg: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(fg)
            Text(text)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(fg)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(bg)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 16)
    }
}
