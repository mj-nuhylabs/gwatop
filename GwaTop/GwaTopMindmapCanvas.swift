//
//  GwaTopMindmapCanvas.swift
//  GwaTop
//
//  AI 가 만든 트리(root + children) 데이터를 받아 방사형 마인드맵으로 렌더링한다.
//  레이아웃은 100% 클라이언트 계산 — AI 호출 없이 좌표·곡선·색상을 모두 결정.
//
//  알고리즘:
//   1) root 를 캔버스 중심에 배치
//   2) 1단계 children N개를 360°/N 간격으로 동심원(R1)에 배치
//   3) 각 1단계 child 가 차지하는 angular wedge 안에 2단계 grandchildren 배치 (R2)
//   4) 부모 → 자식 연결은 quadratic Bezier 곡선으로 부드럽게
//   5) 1단계 branch 별 색상 팔레트 순환, 자식은 같은 색상 유지
//

import SwiftUI

// MARK: - 색상 팔레트 (1단계 branch 별)

private let kBranchColors: [Color] = [
    Color(red: 0.50, green: 0.80, blue: 0.45),  // green
    Color(red: 0.99, green: 0.85, blue: 0.30),  // yellow
    Color(red: 0.55, green: 0.85, blue: 0.95),  // cyan
    Color(red: 0.75, green: 0.50, blue: 0.95),  // purple
    Color(red: 0.98, green: 0.60, blue: 0.45),  // coral
    Color(red: 0.40, green: 0.70, blue: 0.95),  // blue
    Color(red: 0.95, green: 0.55, blue: 0.75),  // pink
    Color(red: 0.65, green: 0.85, blue: 0.55),  // lime
]

// MARK: - 내부 좌표 모델

private struct PositionedNode: Identifiable {
    let id = UUID()
    let label: String
    let position: CGPoint
    let parentPosition: CGPoint?
    let color: Color
    let level: Int  // 0=root, 1=branch, 2=leaf
}

private struct LaidOutMindmap {
    let nodes: [PositionedNode]
    let bounds: CGRect   // 모든 노드를 감싸는 최소 박스
}

// MARK: - 레이아웃 계산

private func layoutMindmap(
    _ map: GwaTopMindmapContent,
    radiusLevel1: CGFloat = 180,
    radiusLevel2: CGFloat = 320,
    center: CGPoint = .zero
) -> LaidOutMindmap {
    var result: [PositionedNode] = []
    let firstLevel = map.children
    let n = max(1, firstLevel.count)

    // root 노드
    result.append(PositionedNode(
        label: map.root, position: center, parentPosition: nil,
        color: Color.white, level: 0
    ))

    // 1단계 children: 360° 를 N 등분.
    // -π/2 (위쪽) 부터 시작해 시계 방향으로 배치 (사용자 사진처럼 자연스러운 분포).
    let baseAngle = -CGFloat.pi / 2
    for (i, branch) in firstLevel.enumerated() {
        let angle = baseAngle + CGFloat(i) * (2 * .pi / CGFloat(n))
        let pos = CGPoint(
            x: center.x + cos(angle) * radiusLevel1,
            y: center.y + sin(angle) * radiusLevel1
        )
        let color = kBranchColors[i % kBranchColors.count]
        result.append(PositionedNode(
            label: branch.label, position: pos, parentPosition: center,
            color: color, level: 1
        ))

        // 2단계 grandchildren: 부모 슬라이스 안에서 fan-out.
        // 슬라이스 폭: 360° / N (예: 8개면 45°). 그 안에서 grandchild 들을 균등 분포.
        let sliceWidth = (2 * .pi / CGFloat(n)) * 0.85  // 약간 좁혀서 이웃 가지와 겹침 방지
        let grandchildren = branch.children
        let m = grandchildren.count
        for (j, gc) in grandchildren.enumerated() {
            // m=1 이면 부모 각도 그대로. m>1 이면 슬라이스 안에서 등분.
            let subAngle: CGFloat
            if m == 1 {
                subAngle = angle
            } else {
                let t = CGFloat(j) / CGFloat(m - 1) - 0.5  // -0.5 ~ +0.5
                subAngle = angle + t * sliceWidth
            }
            let pos = CGPoint(
                x: center.x + cos(subAngle) * radiusLevel2,
                y: center.y + sin(subAngle) * radiusLevel2
            )
            result.append(PositionedNode(
                label: gc.label,
                position: pos,
                parentPosition: result.first(where: { $0.label == branch.label && $0.level == 1 })?.position,
                color: color,
                level: 2
            ))
        }
    }

    // bounds 계산 (노드 텍스트 패딩까지 여유)
    let padding: CGFloat = 80
    let xs = result.map { $0.position.x }
    let ys = result.map { $0.position.y }
    let minX = (xs.min() ?? 0) - padding
    let maxX = (xs.max() ?? 0) + padding
    let minY = (ys.min() ?? 0) - padding
    let maxY = (ys.max() ?? 0) + padding

    return LaidOutMindmap(
        nodes: result,
        bounds: CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    )
}

// MARK: - 캔버스 뷰

struct GwaTopMindmapCanvas: View {
    let mindmap: GwaTopMindmapContent

    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        let layout = layoutMindmap(mindmap)

        // bounds 의 크기에 맞춘 캔버스. ScrollView 로 감싸지 않고 매니퓰레이션 제스처(팬/줌) 사용.
        GeometryReader { geo in
            let canvasSize = CGSize(width: layout.bounds.width, height: layout.bounds.height)
            // 모든 노드 위치를 bounds 좌상단 기준으로 보정.
            let shifted = layout.nodes.map { n in
                PositionedNode(
                    label: n.label,
                    position: CGPoint(
                        x: n.position.x - layout.bounds.minX,
                        y: n.position.y - layout.bounds.minY
                    ),
                    parentPosition: n.parentPosition.map {
                        CGPoint(x: $0.x - layout.bounds.minX, y: $0.y - layout.bounds.minY)
                    },
                    color: n.color,
                    level: n.level
                )
            }

            ZStack {
                Color.clear

                // 1) 가지 (Bezier)
                Path { path in
                    for node in shifted where node.level > 0 {
                        guard let parent = node.parentPosition else { continue }
                        let p1 = parent
                        let p2 = node.position
                        // 컨트롤 포인트: 두 점 중간에서 살짝 안쪽으로 (중심 방향).
                        let mid = CGPoint(x: (p1.x + p2.x) / 2, y: (p1.y + p2.y) / 2)
                        path.move(to: p1)
                        path.addQuadCurve(to: p2, control: mid)
                    }
                }
                .stroke(Color.gray.opacity(0.45), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))

                // 2) 노드 (root 먼저 그리지 않고 ZStack 순서로 — 그릴 때 level 순으로)
                ForEach(shifted.sorted { $0.level < $1.level }) { node in
                    nodeView(node)
                        .position(node.position)
                }
            }
            .frame(width: canvasSize.width, height: canvasSize.height)
            .scaleEffect(scale)
            .offset(offset)
            // 캔버스 중심을 geo 중심에 맞춰 평행이동.
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
            .gesture(
                SimultaneousGesture(
                    MagnificationGesture()
                        .onChanged { value in scale = max(0.4, min(3.0, lastScale * value)) }
                        .onEnded { _ in lastScale = scale },
                    DragGesture()
                        .onChanged { v in
                            offset = CGSize(
                                width: lastOffset.width + v.translation.width,
                                height: lastOffset.height + v.translation.height
                            )
                        }
                        .onEnded { _ in lastOffset = offset }
                )
            )
            .onTapGesture(count: 2) {
                // 더블탭으로 초기 위치 리셋
                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                    scale = 1.0
                    lastScale = 1.0
                    offset = .zero
                    lastOffset = .zero
                }
            }
        }
        .frame(minHeight: 480)
        .background(Color(white: 0.985))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // 노드 캡슐
    @ViewBuilder
    private func nodeView(_ node: PositionedNode) -> some View {
        if node.level == 0 {
            // 중앙 root — 강조된 sunburst 스타일
            ZStack {
                Circle()
                    .fill(LinearGradient(
                        colors: [Color.orange.opacity(0.95), Color.orange],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ))
                    .frame(width: 100, height: 100)
                    .shadow(color: Color.orange.opacity(0.35), radius: 16, x: 0, y: 6)

                Text(node.label)
                    .font(.system(size: 14, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 10)
            }
        } else if node.level == 1 {
            Text(node.label)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(textColor(on: node.color))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(node.color)
                .clipShape(Capsule())
                .shadow(color: node.color.opacity(0.30), radius: 8, x: 0, y: 3)
        } else {
            Text(node.label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(textColor(on: node.color.opacity(0.85)))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(node.color.opacity(0.75))
                .clipShape(Capsule())
        }
    }

    /// 배경색이 밝으면 검정 글자, 어두우면 흰 글자.
    private func textColor(on color: Color) -> Color {
        let uiColor = UIColor(color)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        uiColor.getRed(&r, green: &g, blue: &b, alpha: &a)
        let luminance = 0.299 * r + 0.587 * g + 0.114 * b
        return luminance > 0.65 ? .black.opacity(0.85) : .white
    }
}
