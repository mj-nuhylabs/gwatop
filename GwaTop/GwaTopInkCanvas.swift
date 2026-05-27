//
//  GwaTopInkCanvas.swift
//  GwaTop
//
//  손글씨 노트 — PencilKit (Apple Pencil + 손가락) 기반 캔버스 + 직렬화 유틸.
//
//  저장 포맷:
//   - body 필드는 단일 문자열. 손글씨 노트는 다음 마커로 시작.
//        [[INK_V1]]<base64 PKDrawing data>
//        [[INK_V1]]<base64>\n---\n<plain text caption>
//   - 텍스트만 있는 노트는 마커 없이 그대로 저장 → 하위 호환 100%.
//

import SwiftUI
import PencilKit

// MARK: - 노트 본문 직렬화

enum GwaTopNoteContent: Equatable {
    case text(String)
    case ink(drawing: PKDrawing, caption: String)

    static let inkMarker = "[[INK_V1]]"
    static let inkSeparator = "\n---\n"

    /// 저장된 body 문자열을 파싱한다. 마커가 없으면 text 케이스로 폴백.
    static func decode(_ body: String) -> GwaTopNoteContent {
        guard body.hasPrefix(inkMarker) else { return .text(body) }
        let payload = String(body.dropFirst(inkMarker.count))
        let parts = payload.components(separatedBy: inkSeparator)
        let base64 = parts.first ?? ""
        let caption = parts.count > 1 ? parts.dropFirst().joined(separator: inkSeparator) : ""
        guard let data = Data(base64Encoded: base64),
              let drawing = try? PKDrawing(data: data) else {
            // 손상된 ink 데이터는 텍스트로 폴백.
            return .text(body)
        }
        return .ink(drawing: drawing, caption: caption)
    }

    /// 서버 저장용 body 문자열로 직렬화.
    func encode() -> String {
        switch self {
        case .text(let s): return s
        case .ink(let drawing, let caption):
            let base64 = drawing.dataRepresentation().base64EncodedString()
            if caption.isEmpty { return Self.inkMarker + base64 }
            return Self.inkMarker + base64 + Self.inkSeparator + caption
        }
    }

    /// 노트 목록 미리보기용 — 손글씨면 캡션 또는 안내 문구, 텍스트면 그대로.
    var previewText: String {
        switch self {
        case .text(let s): return s
        case .ink(_, let caption):
            return caption.isEmpty ? "손글씨 노트" : caption
        }
    }

    var isInk: Bool {
        if case .ink = self { return true }
        return false
    }

    /// 검색용 — 텍스트 + (있다면) 캡션 결합.
    var searchableText: String {
        switch self {
        case .text(let s): return s
        case .ink(_, let caption): return caption
        }
    }
}

// MARK: - PencilKit 캔버스 (SwiftUI 래퍼)

struct GwaTopInkCanvasView: UIViewRepresentable {
    @Binding var drawing: PKDrawing
    @Binding var tool: PKTool
    let isEditable: Bool

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView()
        canvas.drawing = drawing
        canvas.tool = tool
        canvas.drawingPolicy = .anyInput   // Apple Pencil 없어도 손가락으로 OK.
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.isScrollEnabled = false
        canvas.delegate = context.coordinator
        canvas.alwaysBounceVertical = false
        return canvas
    }

    func updateUIView(_ uiView: PKCanvasView, context: Context) {
        // 외부에서 drawing 이 교체되면 반영. (사용자 입력으로 인한 업데이트는 무시.)
        if !context.coordinator.isApplyingExternal && uiView.drawing != drawing {
            context.coordinator.isApplyingExternal = true
            uiView.drawing = drawing
            context.coordinator.isApplyingExternal = false
        }
        if uiView.tool as? PKInkingTool != tool as? PKInkingTool ||
           uiView.tool as? PKEraserTool != tool as? PKEraserTool {
            uiView.tool = tool
        }
        uiView.isUserInteractionEnabled = isEditable
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        var parent: GwaTopInkCanvasView
        var isApplyingExternal = false

        init(parent: GwaTopInkCanvasView) { self.parent = parent }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            guard !isApplyingExternal else { return }
            DispatchQueue.main.async {
                self.parent.drawing = canvasView.drawing
            }
        }
    }
}

// MARK: - 손글씨 썸네일 렌더링 (노트 목록 미리보기)

extension PKDrawing {
    /// 노트 카드 미리보기에 쓸 작은 비트맵. 비어 있으면 nil.
    func gwaTopThumbnail(size: CGSize, scale: CGFloat = 2.0) -> UIImage? {
        guard !bounds.isEmpty else { return nil }
        let inset: CGFloat = 8
        let target = bounds.insetBy(dx: -inset, dy: -inset)
        return image(from: target, scale: scale)
    }
}
