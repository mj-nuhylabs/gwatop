//
//  GwaTopMindmapCanvas.swift
//  GwaTop
//
//  AI 가 만든 트리(root + children) 데이터를 받아 정렬된 수평 마인드맵으로 렌더링한다.
//  레이아웃은 100% 클라이언트 계산 — AI 호출 없이 좌표·연결선·색상을 모두 결정.
//
//  알고리즘:
//   1) root 를 캔버스 중심에 배치
//   2) 1단계 children 을 좌/우 두 컬럼으로 균형 배분 (짝수 인덱스→오른쪽, 홀수→왼쪽)
//   3) 각 컬럼 안에서 자식 수에 비례한 높이로 세로 정렬
//   4) 2단계 grandchildren 은 부모 옆 한 컬럼 더 바깥에 일정 간격으로 정렬
//   5) 부모 → 자식 연결은 직각(L자) 라인으로, 같은 부모를 공유하는 자식들은 같은 spine 을 공유
//

import SwiftUI

// MARK: - 색상 팔레트 (앱 공용 토큰 — 코랄 primary + 과목 파스텔)

/// 가지 색상 — 과목 카드와 동일한 파스텔 팔레트를 그대로 사용해 앱 전체 톤과 통일.
private let kBranchColors: [Color] = GwaTopCourseColorPalette.map(Color.gwaTopHex)

private let kRootColor = GwaTopHomeTheme.primary  // Claude coral #cc785c
private let kSurface   = GwaTopHomeTheme.surface  // 노드 배경 (다크 자동 전환)

// MARK: - 내부 좌표 모델

private struct PositionedNode: Identifiable {
    let id = UUID()
    let label: String
    let position: CGPoint
    let parentPosition: CGPoint?
    let color: Color
    let level: Int        // 0=root, 1=branch, 2=leaf
    let childCount: Int
    let isExpanded: Bool
    let onRight: Bool     // true=오른쪽 가지, false=왼쪽 가지 (root 는 임의)
}

private struct LaidOutMindmap {
    let nodes: [PositionedNode]
    let bounds: CGRect
}

// MARK: - 레이아웃 (수평 트리)

private func layoutMindmap(
    _ map: GwaTopMindmapContent,
    expandedBranches: Set<String>,
    columnWidth: CGFloat = 240,
    rowHeight: CGFloat = 60,
    branchGap: CGFloat = 22,
    center: CGPoint = .zero
) -> LaidOutMindmap {
    var result: [PositionedNode] = []

    // 좌우 균형 분배: 짝수 인덱스→오른쪽, 홀수→왼쪽 (원본 인덱스로 색상 결정).
    struct Item { let origIndex: Int; let node: GwaTopMindmapNode }
    var right: [Item] = []
    var left: [Item] = []
    for (i, b) in map.children.enumerated() {
        if i % 2 == 0 { right.append(Item(origIndex: i, node: b)) }
        else          { left.append(Item(origIndex: i, node: b)) }
    }

    func span(_ b: GwaTopMindmapNode) -> CGFloat {
        let expanded = expandedBranches.contains(b.label)
        let childRows = (expanded ? b.children.count : 0)
        // 펼쳐졌으면 자식 수에 비례, 아니면 한 줄 높이.
        return max(rowHeight, CGFloat(childRows) * rowHeight) + branchGap
    }

    func placeSide(_ items: [Item], onRight: Bool) {
        let totalHeight = items.map(\.node).map(span).reduce(0, +) - (items.isEmpty ? 0 : branchGap)
        var cursorY = center.y - totalHeight / 2
        let xSign: CGFloat = onRight ? 1 : -1
        for item in items {
            let s = span(item.node) - branchGap
            let branchCenterY = cursorY + s / 2
            let pos = CGPoint(x: center.x + xSign * columnWidth, y: branchCenterY)
            let color = kBranchColors[item.origIndex % kBranchColors.count]
            let expanded = expandedBranches.contains(item.node.label)
            result.append(PositionedNode(
                label: item.node.label, position: pos, parentPosition: center,
                color: color, level: 1,
                childCount: item.node.children.count,
                isExpanded: expanded, onRight: onRight
            ))
            if expanded {
                let m = item.node.children.count
                let block = CGFloat(m) * rowHeight
                var gcY = branchCenterY - block / 2 + rowHeight / 2
                for gc in item.node.children {
                    let gcPos = CGPoint(x: center.x + xSign * columnWidth * 2, y: gcY)
                    result.append(PositionedNode(
                        label: gc.label, position: gcPos, parentPosition: pos,
                        color: color, level: 2,
                        childCount: 0, isExpanded: false, onRight: onRight
                    ))
                    gcY += rowHeight
                }
            }
            cursorY += s + branchGap
        }
    }

    placeSide(right, onRight: true)
    placeSide(left,  onRight: false)

    // root 는 첫 번째 노드로 삽입 (드로잉 순서와 무관, 안정성을 위해 앞).
    result.insert(PositionedNode(
        label: map.root, position: center, parentPosition: nil,
        color: kRootColor, level: 0, childCount: 0, isExpanded: false, onRight: true
    ), at: 0)

    let padding: CGFloat = 120
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
    /// 자식이 펼쳐진 1단계 branch 라벨들. 초기엔 비어있어 root + branches 만 보임.
    @State private var expandedBranches: Set<String> = []

    private let minScale: CGFloat = 0.4
    private let maxScale: CGFloat = 3.0

    var body: some View {
        let layout = layoutMindmap(mindmap, expandedBranches: expandedBranches)

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
                    level: n.level,
                    childCount: n.childCount,
                    isExpanded: n.isExpanded,
                    onRight: n.onRight
                )
            }

            // root(마인드맵 중심)의 shifted 좌표 — 확대 anchor·화면 고정 기준점.
            let rootShifted = CGPoint(x: -layout.bounds.minX, y: -layout.bounds.minY)
            // 확대 anchor 를 root 로 맞춰, 핀치/줌이 캔버스 기하 중심이 아닌 root 기준으로 일어나게.
            let rootAnchor = UnitPoint(
                x: canvasSize.width  > 0 ? rootShifted.x / canvasSize.width  : 0.5,
                y: canvasSize.height > 0 ? rootShifted.y / canvasSize.height : 0.5
            )
            // 자식이 펼쳐져 bounds 가 바뀌어도 root 가 항상 화면 중앙에 고정되도록 보정.
            // (anchor 가 root 라 scale 과 무관 → 보정값은 스케일을 곱하지 않는다.)
            let baseOffset = CGSize(
                width:  canvasSize.width  / 2 - rootShifted.x,
                height: canvasSize.height / 2 - rootShifted.y
            )

            ZStack {
                // 전체 영역을 드래그/핀치 가능한 hit target 으로 — 노드 밖 빈 곳을 잡아도 이동.
                GwaTopHomeTheme.background

                // 변환(확대·이동)되는 캔버스 콘텐츠.
                ZStack {
                    // 1) 연결선 — 부모→자식 부드러운 곡선, 가지 색상으로.
                    ForEach(shifted.filter { $0.level > 0 }) { node in
                        if let parent = node.parentPosition {
                            connector(from: parent, to: node.position)
                                .stroke(
                                    node.color.opacity(0.7),
                                    style: StrokeStyle(lineWidth: 2.0, lineCap: .round, lineJoin: .round)
                                )
                        }
                    }

                    // 2) 노드 — level 순서로 그려서 자식이 부모 위로 안 가도록.
                    ForEach(shifted.sorted { $0.level < $1.level }) { node in
                        nodeView(node)
                            .position(node.position)
                            .onTapGesture {
                                guard node.level == 1, node.childCount > 0 else { return }
                                withAnimation(.easeInOut(duration: 0.22)) {
                                    if expandedBranches.contains(node.label) {
                                        expandedBranches.remove(node.label)
                                    } else {
                                        expandedBranches.insert(node.label)
                                    }
                                }
                            }
                    }
                }
                .frame(width: canvasSize.width, height: canvasSize.height)
                .scaleEffect(scale, anchor: rootAnchor)
                .offset(
                    x: offset.width  + baseOffset.width,
                    y: offset.height + baseOffset.height
                )
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(
                SimultaneousGesture(
                    MagnificationGesture()
                        .onChanged { value in
                            scale = max(minScale, min(maxScale, lastScale * value))
                        }
                        .onEnded { _ in lastScale = scale },
                    DragGesture(minimumDistance: 1)
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
                withAnimation(.easeInOut(duration: 0.25)) {
                    resetView()
                }
            }
        }
        .background(GwaTopHomeTheme.background)
    }

    /// 부모→자식 수평 cubic Bézier — 양 끝은 수평으로 빠져나가 부드러운 S 곡선.
    private func connector(from p1: CGPoint, to p2: CGPoint) -> Path {
        var path = Path()
        let midX = (p1.x + p2.x) / 2
        path.move(to: p1)
        path.addCurve(
            to: p2,
            control1: CGPoint(x: midX, y: p1.y),
            control2: CGPoint(x: midX, y: p2.y)
        )
        return path
    }

    // MARK: - 뷰 초기화 (더블탭)

    private func resetView() {
        scale = 1.0; lastScale = 1.0
        offset = .zero; lastOffset = .zero
    }

    // MARK: - 노드 시각

    @ViewBuilder
    private func nodeView(_ node: PositionedNode) -> some View {
        switch node.level {
        case 0:
            // root — 코랄 primary 알약, 흰 텍스트. 앱의 주요 버튼 톤과 통일.
            Text(node.label)
                .font(.gwaTopSystem(size: 17, weight: .heavy))
                .foregroundStyle(.white)
                .lineLimit(3)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 22)
                .padding(.vertical, 16)
                .frame(maxWidth: 220)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(GwaTopHomeTheme.primaryGradient)
                )
                .shadow(color: kRootColor.opacity(0.25), radius: 10, y: 4)

        case 1:
            // 1단계 — surface 카드 + 파스텔 좌측 액센트 + 자식 수 뱃지.
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(node.color)
                    .frame(width: 5, height: 24)
                Text(node.label)
                    .font(.gwaTopSystem(size: 16, weight: .bold))
                    .foregroundStyle(GwaTopHomeTheme.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                if node.childCount > 0 {
                    HStack(spacing: 3) {
                        Image(systemName: node.isExpanded ? "chevron.up" : "chevron.down")
                            .font(.gwaTopSystem(size: 10, weight: .bold))
                        Text("\(node.childCount)")
                            .font(.gwaTopSystem(size: 12, weight: .bold))
                    }
                    .foregroundStyle(GwaTopHomeTheme.textPrimary.opacity(0.8))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(node.color.opacity(0.30))
                    .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: 230)
            .background(kSurface)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(node.color.opacity(0.55), lineWidth: 1.5)
            )
            .shadow(color: GwaTopHomeTheme.cardShadow, radius: 6, y: 2)

        default:
            // 2단계 leaf — 파스텔 tint 배경, 둥근 카드.
            Text(node.label)
                .font(.gwaTopSystem(size: 14, weight: .semibold))
                .foregroundStyle(GwaTopHomeTheme.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .frame(maxWidth: 210)
                .background(node.color.opacity(0.16))
                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .stroke(node.color.opacity(0.40), lineWidth: 1.0)
                )
        }
    }
}
