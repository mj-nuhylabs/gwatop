//
//  GwaTopCourseOrderStore.swift
//  GwaTop
//
//  사용자가 직접 정한 "과목 표시 순서" 를 보관하는 공유 스토어.
//  학습 탭과 Todo 탭이 같은 순서를 쓰도록 단일 소스로 둔다.
//
//  백엔드에 과목 정렬 필드가 없으므로 로컬(UserDefaults)에 과목 ID 배열로 영속한다.
//  - ordered(_:id:) : 임의의 항목 배열을 저장된 순서로 정렬 (새 과목은 뒤에 붙음).
//  - move(_:before:in:) : 드래그한 과목을 대상 과목 자리로 옮기고 즉시 저장.
//

import SwiftUI
import Combine

@MainActor
final class GwaTopCourseOrderStore: ObservableObject {
    static let shared = GwaTopCourseOrderStore()

    private let defaultsKey = "gwaTopCourseOrder"

    /// 사용자가 정한 과목 ID 순서. 목록에서 사라진 ID 가 남아 있어도 정렬 시 무시되므로 무해.
    @Published private(set) var order: [String]

    private init() {
        order = UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []
    }

    /// 주어진 항목들을 저장된 커스텀 순서로 정렬한다.
    /// 저장 순서에 없는(새로 추가된) 항목은 원래 입력 순서를 유지한 채 맨 뒤에 붙는다.
    func ordered<T>(_ items: [T], id: (T) -> String) -> [T] {
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return items.enumerated().sorted { a, b in
            switch (rank[id(a.element)], rank[id(b.element)]) {
            case let (ra?, rb?): return ra < rb
            case (.some, .none):  return true            // 순서 지정된 과목이 신규보다 앞
            case (.none, .some):  return false
            case (.none, .none):  return a.offset < b.offset  // 둘 다 신규 → 입력 순서 유지
            }
        }.map(\.element)
    }

    /// draggedId 과목을 targetId 과목 자리로 이동시킨다.
    /// displayedIds 는 현재 화면에 보이는(이미 정렬된) 과목 ID 의 전체 순서.
    func move(_ draggedId: String, before targetId: String, in displayedIds: [String]) {
        guard draggedId != targetId else { return }
        var ids = displayedIds
        guard let from = ids.firstIndex(of: draggedId) else { return }
        ids.remove(at: from)
        guard let to = ids.firstIndex(of: targetId) else { return }
        ids.insert(draggedId, at: to)
        persist(ids)
    }

    private func persist(_ ids: [String]) {
        order = ids
        UserDefaults.standard.set(ids, forKey: defaultsKey)
    }
}

// MARK: - 과목 카드 드래그 재정렬 모디파이어

/// 과목 카드에 iOS 홈 화면 편집 모드 같은 동작을 입힌다.
///  - 카드를 길게 누르면 편집 모드 진입(onEnterEdit) → 모든 카드가 살짝 흔들린다(jiggle).
///  - 편집 모드에서만 길게 눌러 드래그 → 다른 카드 위에 놓으면 순서 변경(onMove).
///  - 편집 모드를 끄면(상단 "완료") 흔들림이 멈추고 평소 탭 동작으로 돌아온다.
struct GwaTopCourseReorderModifier: ViewModifier {
    let courseId: String
    /// ForEach 안의 위치 — 카드마다 흔들림 주기를 어긋나게 해서 자연스럽게 보이게 한다.
    let index: Int
    /// 편집 모드 여부 — true 일 때만 흔들리고 드래그 재정렬이 가능하다.
    let isEditing: Bool
    /// 검색 중 등 일부 과목만 보일 때는 편집/재정렬을 막기 위한 플래그.
    let enabled: Bool
    /// 현재 끌고 있는 과목 id — 드롭 대상으로 들어왔을 때 강조 표시에 사용.
    @Binding var draggingId: String?
    /// 편집 모드가 아닐 때 카드를 길게 누르면 호출 — 편집 모드 진입.
    let onEnterEdit: () -> Void
    /// 끌어온 과목 id 를 이 카드 자리로 옮길 때 호출.
    let onMove: (String) -> Void

    @State private var isTargeted = false

    // 카드마다 살짝 다른 주기 → 모든 카드가 동시에 같은 각도가 되지 않아 홈 화면처럼 보인다.
    private var rotatePeriod: Double { 0.13 + Double(index % 4) * 0.013 }
    private let jiggleAngle: Double = 1.9   // 도

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            if isEditing {
                content
                    .disabled(true)   // 편집 중엔 카드 탭/내비 비활성 — 드래그만 허용.
                    .opacity(draggingId == courseId ? 0.4 : 1)
                    .overlay {
                        if isTargeted && draggingId != courseId {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(GwaTopHomeTheme.primary, lineWidth: 2)
                        }
                    }
                    // 홈 화면 아이콘 편집 모드 같은 흔들림 — phaseAnimator 가 두 각도를 무한 왕복.
                    .phaseAnimator([false, true]) { view, phase in
                        view.rotationEffect(.degrees(phase ? jiggleAngle : -jiggleAngle))
                    } animation: { _ in
                        .easeInOut(duration: rotatePeriod)
                    }
                    .draggable(courseId) {
                        // 드래그 프리뷰 — 살짝 가벼운 카드 플레이스홀더.
                        content
                            .frame(maxWidth: 320)
                            .opacity(0.9)
                            .onAppear { draggingId = courseId }
                    }
                    .dropDestination(for: String.self) { items, _ in
                        draggingId = nil
                        guard let dragged = items.first, dragged != courseId else { return false }
                        onMove(dragged)
                        return true
                    } isTargeted: { targeted in
                        isTargeted = targeted
                    }
            } else {
                // 평소 — 길게 누르면 편집 모드 진입. (짧은 탭은 카드 본래 동작이 처리)
                content
                    .onLongPressGesture(minimumDuration: 0.45) { onEnterEdit() }
            }
        } else {
            content
        }
    }
}
