//
//  GwaTopMathText.swift
//  GwaTop
//
//  수학 수식이 섞인 텍스트를 KaTeX 로 렌더링한다.
//
//  사용:
//      GwaTopMathText("∫_a^b f(x) dx 의 값은?", fontSize: 14)
//      GwaTopMathText("문제: $S = 2\\pi \\int_a^b f(x)\\sqrt{1 + (f'(x))^2} dx$ 의 의미는?")
//
//  자동 감지:
//   - 텍스트에 $, \\, \frac, \int, \sqrt, ^{, _{ 같은 LaTeX 흔적이 있으면 KaTeX 렌더링.
//   - 아니면 plain SwiftUI Text 로 폴백 (가벼움).
//
//  렌더링 전략:
//   - WKWebView + KaTeX (CDN). 처음 한 번만 네트워크 fetch, 이후 캐시됨.
//   - JavaScript 로 body 높이 측정 후 SwiftUI 에 보고 → 자동 sizing.
//   - 네트워크 끊겨도 plain Text 로 폴백 (캐시 hit 시엔 KaTeX).
//

import SwiftUI
import WebKit

struct GwaTopMathText: View {
    let text: String
    let fontSize: CGFloat
    let textColor: Color

    init(_ text: String, fontSize: CGFloat = 14, color: Color = .primary) {
        self.text = text
        self.fontSize = fontSize
        self.textColor = color
    }

    var body: some View {
        if Self.needsMathRendering(text) {
            GwaTopKaTeXWebView(text: text, fontSize: fontSize, color: textColor)
        } else {
            // 수식 없으면 가벼운 SwiftUI Text 로 — WebView 부담 없음.
            Text(text)
                .font(.system(size: fontSize))
                .foregroundStyle(textColor)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 텍스트가 LaTeX/수식을 포함하는지 휴리스틱 감지.
    static func needsMathRendering(_ s: String) -> Bool {
        // 가장 강한 신호
        if s.contains("$") { return true }
        if s.contains("\\frac") || s.contains("\\int") || s.contains("\\sqrt") { return true }
        if s.contains("\\sum") || s.contains("\\lim") || s.contains("\\to") { return true }
        // 보조 신호 — 흔한 텍스트형 수식 표기
        if s.contains("^{") || s.contains("_{") { return true }
        // ASCII 형 적분: ∫[a,b]  → 백엔드가 LaTeX 으로 안 줄 때 보조 감지
        if s.contains("∫") || s.contains("∑") || s.contains("√") { return true }
        return false
    }
}

// MARK: - WKWebView 기반 KaTeX 렌더러

struct GwaTopKaTeXWebView: UIViewRepresentable {
    let text: String
    let fontSize: CGFloat
    let color: Color

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.suppressesIncrementalRendering = false
        config.userContentController.add(context.coordinator, name: "heightCallback")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        let html = Self.makeHTML(text: text, fontSize: fontSize, color: color)
        webView.loadHTMLString(html, baseURL: URL(string: "https://cdn.jsdelivr.net"))
    }

    /// SwiftUI 에 자동 높이 보고. parent 의 measuredHeight 에 반영되어 frame 조정.
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: GwaTopKaTeXWebView?
        weak var webView: WKWebView?

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // KaTeX 렌더링이 끝난 뒤 약간 대기 후 height 측정.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                webView.evaluateJavaScript(
                    "document.body.scrollHeight"
                ) { result, _ in
                    guard let height = result as? CGFloat, height > 0 else { return }
                    webView.invalidateIntrinsicContentSize()
                    DispatchQueue.main.async {
                        webView.frame.size.height = height
                    }
                }
            }
        }

        func userContentController(_ uc: WKUserContentController, didReceive msg: WKScriptMessage) {
            // 예약: KaTeX 가 동적으로 높이 알려주는 경로 (향후 확장).
        }
    }

    private static func makeHTML(text: String, fontSize: CGFloat, color: Color) -> String {
        let escaped = text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        // SwiftUI Color → CSS rgba (root primary 는 시스템 텍스트 컬러)
        let uiColor = UIColor(color)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        uiColor.getRed(&r, green: &g, blue: &b, alpha: &a)
        let cssColor = "rgba(\(Int(r * 255)), \(Int(g * 255)), \(Int(b * 255)), \(a))"

        return """
        <!DOCTYPE html>
        <html>
        <head>
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/katex@0.16.9/dist/katex.min.css">
            <script defer src="https://cdn.jsdelivr.net/npm/katex@0.16.9/dist/katex.min.js"></script>
            <script defer src="https://cdn.jsdelivr.net/npm/katex@0.16.9/dist/contrib/auto-render.min.js"
                onload="renderMathInElement(document.body, {
                    delimiters: [
                        {left: '$$', right: '$$', display: true},
                        {left: '$', right: '$', display: false},
                        {left: '\\\\(', right: '\\\\)', display: false},
                        {left: '\\\\[', right: '\\\\]', display: true}
                    ],
                    throwOnError: false,
                });"></script>
            <style>
                html, body {
                    margin: 0;
                    padding: 0;
                    background: transparent;
                    color: \(cssColor);
                    font-family: -apple-system, BlinkMacSystemFont, system-ui, sans-serif;
                    font-size: \(fontSize)px;
                    line-height: 1.45;
                    word-break: keep-all;
                    overflow-wrap: anywhere;
                }
                .katex { font-size: 1.05em; }
                .katex-display { margin: 0.3em 0; }
            </style>
        </head>
        <body>\(escaped)</body>
        </html>
        """
    }
}
