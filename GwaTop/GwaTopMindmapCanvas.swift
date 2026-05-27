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

// MARK: - 색상 팔레트 (차분한 톤)

private let kBranchColors: [Color] = [
    Color(red: 0.40, green: 0.52, blue: 0.66),  // muted slate blue
    Color(red: 0.58, green: 0.54, blue: 0.42),  // muted olive
    Color(red: 0.55, green: 0.45, blue: 0.55),  // muted plum
    Color(red: 0.40, green: 0.58, blue: 0.55),  // muted teal
    Color(red: 0.62, green: 0.50, blue: 0.45),  // muted brick
    Color(red: 0.45, green: 0.56, blue: 0.45),  // muted moss
    Color(red: 0.52, green: 0.52, blue: 0.60),  // muted lavender
    Color(red: 0.56, green: 0.48, blue: 0.42),  // muted tan
]

private let kRootColor = Color(red: 0.22, green: 0.27, blue: 0.36)   // deep slate
private let kLineColor = Color(white: 0.55)
private let kSurface   = Color.white
private let kLeafText  = Color(white: 0.22)

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

            ZStack {
                Color.clear

                // 1) 연결선 — 직각(L자) 라우팅.
                Path { path in
                    for node in shifted where node.level > 0 {
                        guard let parent = node.parentPosition else { continue }
                        let p1 = parent
                        let p2 = node.position
                        let midX = (p1.x + p2.x) / 2
                        path.move(to: p1)
                        path.addLine(to: CGPoint(x: midX, y: p1.y))
                        path.addLine(to: CGPoint(x: midX, y: p2.y))
                        path.addLine(to: p2)
                    }
                }
                .stroke(kLineColor.opacity(0.55),
                        style: StrokeStyle(lineWidth: 1.0, lineCap: .square, lineJoin: .miter))

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
            .scaleEffect(scale)
            .offset(offset)
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
            .gesture(
                SimultaneousGesture(
                    MagnificationGesture()
                        .onChanged { value in
                            scale = max(minScale, min(maxScale, lastScale * value))
                        }
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
                withAnimation(.easeInOut(duration: 0.25)) {
                    resetView()
                }
            }
        }
        .frame(minHeight: 480)
        .background(Color(white: 0.985))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color(white: 0.88), lineWidth: 0.5)
        )
        .overlay(alignment: .bottomTrailing) { zoomControls }
    }

    // MARK: - 줌 컨트롤

    private var zoomControls: some View {
        VStack(spacing: 1) {
            zoomButton(systemName: "plus") {
                withAnimation(.easeInOut(duration: 0.15)) {
                    let next = min(maxScale, scale + 0.25)
                    scale = next; lastScale = next
                }
            }
            Divider().frame(width: 28)
            zoomButton(systemName: "minus") {
                withAnimation(.easeInOut(duration: 0.15)) {
                    let next = max(minScale, scale - 0.25)
                    scale = next; lastScale = next
                }
            }
            Divider().frame(width: 28)
            zoomButton(systemName: "arrow.up.left.and.arrow.down.right") {
                withAnimation(.easeInOut(duration: 0.25)) { resetView() }
            }
        }
        .gwaTopCard(radius: 4)
        .padding(10)
    }

    private func zoomButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.gwaTopSystem(size: 12, weight: .semibold))
                .foregroundStyle(Color(white: 0.30))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func resetView() {
        scale = 1.0; lastScale = 1.0
        offset = .zero; lastOffset = .zero
    }

    // MARK: - 노드 시각

    @ViewBuilder
    private func nodeView(_ node: PositionedNode) -> some View {
        switch node.level {
        case 0:
            // root — 다크 슬레이트, 살짝만 둥근 사각.
            Text(node.label)
                .font(.gwaTopSystem(size: 17, weight: .heavy))
                .foregroundStyle(.white)
                .lineLimit(3)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .frame(maxWidth: 220)
                .background(kRootColor)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

        case 1:
            // 1단계 — 흰 배경 + 컬러 보더 + 컬러 라벨. 자식 수 뱃지.
            HStack(spacing: 8) {
                Rectangle()
                    .fill(node.color)
                    .frame(width: 4, height: 22)
                Text(node.label)
                    .font(.gwaTopSystem(size: 16, weight: .bold))
                    .foregroundStyle(Color(white: 0.12))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                if node.childCount > 0 {
                    HStack(spacing: 3) {
                        Image(systemName: node.isExpanded ? "chevron.up" : "chevron.down")
                            .font(.gwaTopSystem(size: 10, weight: .bold))
                        Text("\(node.childCount)")
                            .font(.gwaTopSystem(size: 12, weight: .bold))
                    }
                    .foregroundStyle(node.color)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(node.color.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: 230)
            .background(kSurface)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(node.color.opacity(0.65), lineWidth: 1.4)
            )

        default:
            // 2단계 leaf — 더 옅은 톤, 동일한 살짝 둥근 사각.
            Text(node.label)
                .font(.gwaTopSystem(size: 14, weight: .bold))
                .foregroundStyle(Color(white: 0.15))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: 210)
                .background(kSurface)
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .stroke(node.color.opacity(0.45), lineWidth: 1.0)
                )
        }
    }
}
