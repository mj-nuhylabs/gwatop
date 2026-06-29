//
//  GwaTopFileThumbnail.swift
//  GwaTop
//
//  과목 학습 상세(GwaTopCourseStudyDetailView)의 강의자료 카드 썸네일.
//  gwatop-web 의 components/files/file-thumbnail.tsx 와 동일한 동작:
//    - PDF  → 1페이지를 PDFKit 으로 렌더한 이미지
//    - image→ 다운샘플한 이미지
//    - 그 외(pptx/docx) → 미리보기 불가, 파일타입 아이콘 placeholder
//  렌더 결과는 (id + updated_at) 키로 메모리 캐시 — 폴링/리마운트 시 재다운로드/재렌더 방지.
//

import SwiftUI
import PDFKit
import ImageIO
import UIKit

// MARK: - 썸네일 캐시

@MainActor
final class GwaTopThumbnailCache {
    static let shared = GwaTopThumbnailCache()
    private init() {}

    private var cache: [String: UIImage] = [:]
    private var inFlight: [String: Task<UIImage?, Never>] = [:]

    /// 렌더 목표 폭(px). devicePixelRatio 까진 안 가더라도 카드보다 크게 잡아 선명도 확보.
    private static let renderWidth: CGFloat = 600

    private func key(_ f: GwaTopFileSummary) -> String {
        "\(f.id):\(Int(f.updatedAt.timeIntervalSince1970))"
    }

    /// 동기 캐시 조회 — 있으면 즉시 표시(깜빡임 방지).
    func cached(_ file: GwaTopFileSummary) -> UIImage? { cache[key(file)] }

    /// 미리보기 생성. 진행 중이면 같은 Task 를 공유(중복 다운로드 방지).
    /// 미지원 타입/네트워크 실패는 nil → 호출부가 아이콘 placeholder 표시.
    func thumbnail(_ file: GwaTopFileSummary) async -> UIImage? {
        let k = key(file)
        if let img = cache[k] { return img }
        if let task = inFlight[k] { return await task.value }

        let task = Task { () -> UIImage? in await Self.generate(file) }
        inFlight[k] = task
        let result = await task.value
        inFlight[k] = nil
        if let result { cache[k] = result }
        return result
    }

    // MARK: 생성

    private static func generate(_ file: GwaTopFileSummary) async -> UIImage? {
        guard file.fileType == "pdf" || file.fileType == "image" else { return nil }
        guard
            let info = try? await GwaTopFileService.shared.presignedDownloadURL(fileId: file.id),
            let url = URL(string: info.url),
            let (data, _) = try? await URLSession.shared.data(from: url)
        else { return nil }

        let png: Data? = file.fileType == "pdf"
            ? await renderPDFFirstPage(data: data, maxWidth: renderWidth)
            : await downsampleImage(data: data, maxPixel: renderWidth)

        guard let png else { return nil }
        return UIImage(data: png)
    }

    /// PDF 1페이지를 렌더해 PNG 데이터로. PDFKit 작업은 백그라운드에서, 결과(Data) 만 반환.
    private nonisolated static func renderPDFFirstPage(data: Data, maxWidth: CGFloat) async -> Data? {
        await Task.detached(priority: .utility) {
            guard let doc = PDFDocument(data: data), let page = doc.page(at: 0) else { return nil }
            let bounds = page.bounds(for: .cropBox)
            guard bounds.width > 1, bounds.height > 1 else { return nil }
            let scale = min(maxWidth / bounds.width, 4)
            let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
            return page.thumbnail(of: size, for: .cropBox).pngData()
        }.value
    }

    /// 이미지 파일을 ImageIO 로 다운샘플해 PNG 데이터로.
    private nonisolated static func downsampleImage(data: Data, maxPixel: CGFloat) async -> Data? {
        await Task.detached(priority: .utility) {
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            ]
            guard
                let src = CGImageSourceCreateWithData(data as CFData, nil),
                let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
            else { return nil }
            return UIImage(cgImage: cg).pngData()
        }.value
    }
}

// MARK: - 썸네일 뷰

struct GwaTopFileThumbnail: View {
    let file: GwaTopFileSummary

    @State private var image: UIImage?
    @State private var didFinish = false

    private var previewable: Bool { file.fileType == "pdf" || file.fileType == "image" }
    private var taskKey: String { "\(file.id):\(file.updatedAt.timeIntervalSince1970)" }

    var body: some View {
        ZStack {
            GwaTopHomeTheme.surfaceMute

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else if previewable && !didFinish {
                ProgressView()
                    .scaleEffect(0.7)
                    .tint(GwaTopHomeTheme.textTertiary)
            } else {
                Image(systemName: placeholderIcon)
                    .font(.gwaTopSystem(size: 30, weight: .regular))
                    .foregroundStyle(file.fileType == "youtube" ? Color.red : GwaTopHomeTheme.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .task(id: taskKey) {
            if let cached = GwaTopThumbnailCache.shared.cached(file) {
                image = cached
                didFinish = true
                return
            }
            image = nil
            didFinish = false
            let img = await GwaTopThumbnailCache.shared.thumbnail(file)
            image = img
            didFinish = true
        }
    }

    private var placeholderIcon: String {
        switch file.fileType {
        case "pdf":   return "doc.richtext"
        case "pptx":  return "rectangle.stack"
        case "docx":  return "doc.text"
        case "image": return "photo"
        case "youtube": return "play.rectangle.fill"
        default:      return "doc"
        }
    }
}
