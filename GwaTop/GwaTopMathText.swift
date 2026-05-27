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
    let weight: Font.Weight
    /// KaTeX WebView 가 자기 실제 높이를 보고하면 SwiftUI 가 그 높이로 frame 을 잡아준다.
    /// 이 값이 없으면 WebView 가 0 또는 임의의 초기 frame 으로 그려져 형제 뷰와 겹친다.
    @State private var measuredHeight: CGFloat = 22

    init(
        _ text: String,
        fontSize: CGFloat = 14,
        weight: Font.Weight = .regular,
        color: Color = .primary
    ) {
        self.text = text
        self.fontSize = fontSize
        self.weight = weight
        self.textColor = color
    }

    var body: some View {
        if Self.needsMathRendering(text) {
            GwaTopKaTeXWebView(
                text: Self.preprocessForKaTeX(text),
                fontSize: fontSize, weight: weight, color: textColor,
                measuredHeight: $measuredHeight
            )
            .frame(height: measuredHeight)
        } else {
            // 수식 없으면 가벼운 SwiftUI Text 로 — WebView 부담 없음.
            Text(text)
                .font(.gwaTopSystem(size: fontSize, weight: weight))
                .foregroundStyle(textColor)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 텍스트가 LaTeX/수식을 포함하는지 휴리스틱 감지.
    static func needsMathRendering(_ s: String) -> Bool {
        // 가장 강한 신호
        if s.contains("$") { return true }
        // 백슬래시 + 영문자 — LaTeX 명령 일반 패턴 (\pi, \int, \frac, \alpha 등 전부 포함)
        if s.range(of: #"\\[A-Za-z]"#, options: .regularExpression) != nil { return true }
        // 보조 신호 — 흔한 텍스트형 수식 표기
        if s.contains("^{") || s.contains("_{") { return true }
        // ^숫자/문자, _숫자/문자 (예: x^2, a_1) — 거의 항상 수식 표기.
        if s.range(of: #"[\^_][A-Za-z0-9]"#, options: .regularExpression) != nil { return true }
        // ASCII 형 적분/합/근호/원주율 — 백엔드가 유니코드로 줄 때
        if s.contains("∫") || s.contains("∑") || s.contains("√") || s.contains("π") { return true }
        return false
    }

    /// KaTeX 가 인식할 수 있도록 텍스트를 사전 가공.
    /// GPT 가 보기 텍스트(예: 객관식 선택지) 에서 `$` 를 빠뜨려도 화면에 raw LaTeX 가 안 보이도록,
    /// 수식 신호가 감지됐고 delimiter 가 전혀 없으면 전체 문자열을 `$...$` 로 감싸 KaTeX 에 넘긴다.
    static func preprocessForKaTeX(_ s: String) -> String {
        // 이미 $ 가 있으면 사용자가 delimiter 를 직접 박은 것이라 그대로 사용.
        if s.contains("$") { return s }
        if s.contains("\\(") || s.contains("\\[") { return s }
        // delimiter 없는 raw LaTeX/수식 — 전체를 인라인 수식으로 처리.
        return "$\(s)$"
    }
}

// MARK: - WKWebView 기반 KaTeX 렌더러

struct GwaTopKaTeXWebView: UIViewRepresentable {
    let text: String
    let fontSize: CGFloat
    let weight: Font.Weight
    let color: Color
    @Binding var measuredHeight: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.suppressesIncrementalRendering = false
        config.userContentController.add(context.coordinator, name: "heightCallback")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        // 세로 스크롤은 끄되, 가로는 긴 수식(예: 정적분 ∫_a^b f(x)\sqrt{...} dx) 대응을 위해 inner div 가 스크롤.
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.scrollView.showsHorizontalScrollIndicator = false
        webView.scrollView.showsVerticalScrollIndicator = false
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        // 측정 height 가 바뀌어 SwiftUI 가 re-render 할 때 HTML 을 재로드하면
        // 무한 reload → 깜빡임/높이 폭주 루프. 콘텐츠가 실제 바뀐 경우에만 reload.
        let key = "\(fontSize)|\(weight.hashValue)|\(text)"
        if context.coordinator.lastLoadKey == key { return }
        context.coordinator.lastLoadKey = key

        let html = Self.makeHTML(text: text, fontSize: fontSize, weight: weight, color: color)
        webView.loadHTMLString(html, baseURL: URL(string: "https://cdn.jsdelivr.net"))
    }

    /// SwiftUI 에 자동 높이 보고. parent 의 measuredHeight 에 반영되어 frame 조정.
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: GwaTopKaTeXWebView?
        weak var webView: WKWebView?
        /// 마지막으로 로드한 콘텐츠 key — 동일 내용 재로드 방지.
        var lastLoadKey: String?
        /// 마지막으로 보고된 높이 — 동일 높이 재할당 방지.
        private var lastHeight: CGFloat = 0

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // KaTeX 렌더링이 끝난 뒤 약간 대기 후 height 측정.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                webView.evaluateJavaScript("document.body.scrollHeight") { [weak self] result, _ in
                    guard let self else { return }
                    guard let h = (result as? NSNumber).map({ CGFloat(truncating: $0) }) ?? (result as? CGFloat),
                          h > 0 else { return }
                    self.applyHeight(h)
                }
            }
        }

        func userContentController(_ uc: WKUserContentController, didReceive msg: WKScriptMessage) {
            // KaTeX 가 inline-scroll wrapper 추가 후 재측정한 높이를 받음.
            guard msg.name == "heightCallback" else { return }
            let h: CGFloat
            if let n = msg.body as? NSNumber { h = CGFloat(truncating: n) }
            else if let d = msg.body as? Double { h = CGFloat(d) }
            else if let c = msg.body as? CGFloat { h = c }
            else { return }
            applyHeight(h)
        }

        /// 측정 높이를 SwiftUI @State 에 반영. 1px 미만 변화는 무시.
        private func applyHeight(_ h: CGFloat) {
            guard h > 0, abs(h - lastHeight) > 1 else { return }
            lastHeight = h
            DispatchQueue.main.async { [weak self] in
                self?.parent?.measuredHeight = h
            }
        }
    }

    private static func makeHTML(
        text: String, fontSize: CGFloat, weight: Font.Weight, color: Color
    ) -> String {
        let escaped = text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        // SwiftUI Color → CSS rgba (root primary 는 시스템 텍스트 컬러)
        let uiColor = UIColor(color)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        uiColor.getRed(&r, green: &g, blue: &b, alpha: &a)
        let cssColor = "rgba(\(Int(r * 255)), \(Int(g * 255)), \(Int(b * 255)), \(a))"
        let cssWeight = Self.cssFontWeight(for: weight)

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
                });
                // 렌더 완료 후 inline 수식이 컨테이너 폭을 넘으면 스크롤 가능한 wrapper 로 감싸기.
                requestAnimationFrame(function() {
                    document.querySelectorAll('.katex:not(.katex-display .katex)').forEach(function(el) {
                        if (el.scrollWidth > el.clientWidth + 1) {
                            var wrap = document.createElement('span');
                            wrap.className = 'katex-inline-scroll';
                            el.parentNode.insertBefore(wrap, el);
                            wrap.appendChild(el);
                        }
                    });
                    // 높이 재측정.
                    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.heightCallback) {
                        window.webkit.messageHandlers.heightCallback.postMessage(document.body.scrollHeight);
                    }
                });"></script>
            <style>
                html, body {
                    margin: 0;
                    padding: 0;
                    background: transparent;
                    color: \(cssColor);
                    font-family: -apple-system, BlinkMacSystemFont, system-ui, sans-serif;
                    font-size: \(fontSize)px;
                    font-weight: \(cssWeight);
                    line-height: 1.5;
                    word-break: keep-all;
                    overflow-wrap: anywhere;
                    /* WebView 폭을 절대 넘지 않게 */
                    max-width: 100%;
                    overflow-x: hidden;
                }
                /* 디스플레이 수식 ($$...$$): 폭 초과 시 가로 스크롤 + 잘림 방지 */
                .katex-display {
                    margin: 0.5em 0;
                    overflow-x: auto;
                    overflow-y: hidden;
                    -webkit-overflow-scrolling: touch;
                    padding: 2px 1px 6px 1px;
                    /* 우측에 스크롤 가능 힌트 — 잘려보이지 않게 */
                    mask-image: linear-gradient(to right, black calc(100% - 12px), transparent);
                    -webkit-mask-image: linear-gradient(to right, black calc(100% - 12px), transparent);
                }
                /* 인라인 수식: 줄바꿈 허용 + 폭 초과 시 스크롤 가능한 inline-block 으로 자동 변환 */
                .katex {
                    font-size: 1.05em;
                    max-width: 100%;
                }
                .katex-inline-scroll {
                    display: inline-block;
                    max-width: 100%;
                    overflow-x: auto;
                    overflow-y: hidden;
                    vertical-align: middle;
                    -webkit-overflow-scrolling: touch;
                }
                /* 분수/근호 등 박스가 큰 요소는 줄바꿈 허용 */
                .katex .mfrac, .katex .msqrt { white-space: normal; }
            </style>
        </head>
        <body>\(escaped)</body>
        </html>
        """
    }

    /// SwiftUI Font.Weight → CSS font-weight 숫자 매핑.
    private static func cssFontWeight(for weight: Font.Weight) -> Int {
        switch weight {
        case .ultraLight: return 100
        case .thin:       return 200
        case .light:      return 300
        case .regular:    return 400
        case .medium:     return 500
        case .semibold:   return 600
        case .bold:       return 700
        case .heavy:      return 800
        case .black:      return 900
        default:          return 400
        }
    }
}

// MARK: - 마크다운 + KaTeX 통합 렌더러 (AI 튜터 답변용)

/// AI 튜터 답변처럼 헤더/리스트/굵게/코드/표 + LaTeX 수식이 섞인 긴 텍스트를 렌더한다.
///
/// 구현: WKWebView 한 번에 marked.js (마크다운 → HTML) + KaTeX (수식 → MathML).
/// 마크다운이 먼저 변환된 뒤 auto-render 가 `$...$` 를 KaTeX 로 처리 →
/// 마크다운 안에 들어 있는 수식까지 안전하게 렌더.
///
/// 높이는 ResizeObserver 로 본문 크기가 바뀔 때마다 SwiftUI 에 보고 (스트리밍 도중 자라남).
struct GwaTopRichText: View {
    let markdown: String
    let fontSize: CGFloat
    let textColor: Color
    let accentColor: Color
    /// WebView 가 JS scrollHeight 로 보고한 실제 높이 — SwiftUI 가 그대로 frame 에 반영해서
    /// 다음 형제 뷰(action bar / 다음 메시지)와 겹치지 않게 한다.
    @State private var measuredHeight: CGFloat = 24

    init(
        _ markdown: String,
        fontSize: CGFloat = 15,
        color: Color = .primary,
        accent: Color = GwaTopHomeTheme.primary
    ) {
        self.markdown = markdown
        self.fontSize = fontSize
        self.textColor = color
        self.accentColor = accent
    }

    var body: some View {
        GwaTopRichTextWebView(
            markdown: markdown,
            fontSize: fontSize,
            color: textColor,
            accent: accentColor,
            measuredHeight: $measuredHeight
        )
        .frame(height: measuredHeight)
    }
}

private struct GwaTopRichTextWebView: UIViewRepresentable {
    let markdown: String
    let fontSize: CGFloat
    let color: Color
    let accent: Color
    @Binding var measuredHeight: CGFloat

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
        // 외부 링크는 사파리로.
        webView.uiDelegate = context.coordinator
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        // 동일 내용으로 측정된 height 가 바뀌어 SwiftUI 가 re-render 할 때 HTML 을 재로드하면
        // 무한 reload → 깜빡임/겹침 루프에 빠진다. 콘텐츠가 실제로 바뀐 경우에만 reload.
        let key = "\(fontSize)|\(markdown)"
        if context.coordinator.lastLoadKey == key { return }
        context.coordinator.lastLoadKey = key

        let html = Self.makeHTML(
            markdown: markdown,
            fontSize: fontSize,
            color: color,
            accent: accent
        )
        // baseURL 을 cdn.jsdelivr.net 으로 설정 → KaTeX/marked CDN 캐시 활용.
        webView.loadHTMLString(html, baseURL: URL(string: "https://cdn.jsdelivr.net"))
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler, WKUIDelegate {
        var parent: GwaTopRichTextWebView?
        weak var webView: WKWebView?
        /// 마지막으로 로드한 콘텐츠 key — 동일 내용 재로드 방지.
        var lastLoadKey: String?
        /// 마지막으로 보고된 높이 — 동일 높이 재할당 방지로 SwiftUI re-layout 최소화.
        private var lastHeight: CGFloat = 0

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                webView.evaluateJavaScript("document.body.scrollHeight") { [weak self] result, _ in
                    guard let self else { return }
                    guard let h = (result as? NSNumber).map({ CGFloat(truncating: $0) }) ?? (result as? CGFloat),
                          h > 0 else { return }
                    self.applyHeight(h)
                }
            }
        }

        func userContentController(
            _ uc: WKUserContentController, didReceive msg: WKScriptMessage
        ) {
            guard msg.name == "heightCallback" else { return }
            let h: CGFloat
            if let n = msg.body as? NSNumber { h = CGFloat(truncating: n) }
            else if let c = msg.body as? CGFloat { h = c }
            else { return }
            applyHeight(h)
        }

        /// 측정 높이를 SwiftUI @State 에 반영. 1px 미만 변화는 무시 (re-layout 폭주 방지).
        private func applyHeight(_ h: CGFloat) {
            guard h > 0, abs(h - lastHeight) > 1 else { return }
            lastHeight = h
            DispatchQueue.main.async { [weak self] in
                self?.parent?.measuredHeight = h
            }
        }

        // 마크다운 안 링크 클릭 시 사파리로.
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url {
                UIApplication.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }

    private static func cssColor(from color: Color) -> String {
        let ui = UIColor(color)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        return "rgba(\(Int(r * 255)), \(Int(g * 255)), \(Int(b * 255)), \(a))"
    }

    /// 마크다운 본문을 JS 문자열 리터럴로 안전하게 인코딩.
    private static func jsLiteral(_ s: String) -> String {
        // `\` → `\\`, 줄바꿈 → `\n`, 백틱 → `\``, $ → `\$` (template literal interpolation 차단).
        var out = ""
        out.reserveCapacity(s.count + 32)
        for ch in s {
            switch ch {
            case "\\": out += "\\\\"
            case "`":  out += "\\`"
            case "$":  out += "\\$"
            case "\r": continue
            case "\n": out += "\\n"
            case "\u{2028}", "\u{2029}": out += "\\n"
            default:   out.append(ch)
            }
        }
        return out
    }

    static func makeHTML(
        markdown: String, fontSize: CGFloat, color: Color, accent: Color
    ) -> String {
        let cssTextColor = cssColor(from: color)
        let cssAccent = cssColor(from: accent)
        let md = jsLiteral(markdown)

        return """
        <!DOCTYPE html>
        <html>
        <head>
            <meta name="viewport" content="width=device-width, initial-scale=1, user-scalable=no">
            <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/katex@0.16.9/dist/katex.min.css">
            <script src="https://cdn.jsdelivr.net/npm/marked@11.1.1/marked.min.js"></script>
            <script src="https://cdn.jsdelivr.net/npm/katex@0.16.9/dist/katex.min.js"></script>
            <script src="https://cdn.jsdelivr.net/npm/katex@0.16.9/dist/contrib/auto-render.min.js"></script>
            <style>
                html, body {
                    margin: 0; padding: 0;
                    background: transparent;
                    color: \(cssTextColor);
                    font-family: -apple-system, BlinkMacSystemFont, system-ui, sans-serif;
                    font-size: \(fontSize)px;
                    line-height: 1.55;
                    word-break: keep-all;
                    overflow-wrap: anywhere;
                    max-width: 100%;
                }
                /* 렌더 끝나기 전 raw 마크다운/HTML 이 잠깐 보이는 FOUC 차단.
                   marked + KaTeX 처리가 끝나면 JS 가 .ready 클래스를 추가하며 페이드인. */
                #content { padding: 0; opacity: 0; transition: opacity 0.08s ease-out; }
                #content.ready { opacity: 1; }
                h1, h2, h3, h4 {
                    margin: 0.9em 0 0.35em;
                    line-height: 1.3;
                    color: \(cssTextColor);
                    font-weight: 800;
                }
                h1 { font-size: 1.25em; }
                h2 {
                    font-size: 1.12em;
                    color: \(cssAccent);
                    border-bottom: 1px solid rgba(127,127,127,0.18);
                    padding-bottom: 0.18em;
                }
                h3 { font-size: 1.04em; }
                h4 { font-size: 1em; }
                p { margin: 0.45em 0; }
                ul, ol { margin: 0.4em 0 0.6em; padding-left: 1.35em; }
                li { margin: 0.18em 0; }
                strong, b { font-weight: 800; }
                em, i { font-style: italic; }
                code {
                    font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
                    font-size: 0.92em;
                    background: rgba(127,127,127,0.14);
                    padding: 0.08em 0.32em;
                    border-radius: 4px;
                }
                pre {
                    background: rgba(127,127,127,0.12);
                    padding: 10px 12px;
                    border-radius: 8px;
                    overflow-x: auto;
                    margin: 0.6em 0;
                }
                pre code { background: transparent; padding: 0; }
                blockquote {
                    border-left: 3px solid \(cssAccent);
                    margin: 0.5em 0;
                    padding: 0.2em 0.7em;
                    color: \(cssTextColor);
                    opacity: 0.86;
                    background: rgba(127,127,127,0.06);
                    border-radius: 0 6px 6px 0;
                }
                hr { border: none; border-top: 1px solid rgba(127,127,127,0.25); margin: 0.8em 0; }
                table {
                    border-collapse: collapse;
                    margin: 0.6em 0;
                    width: 100%;
                    font-size: 0.95em;
                }
                th, td {
                    border: 1px solid rgba(127,127,127,0.3);
                    padding: 6px 8px;
                    text-align: left;
                }
                th { background: rgba(127,127,127,0.1); font-weight: 700; }
                a { color: \(cssAccent); text-decoration: none; }
                a:hover { text-decoration: underline; }
                .katex { font-size: 1.04em; }
                .katex-display { margin: 0.45em 0; overflow-x: auto; overflow-y: hidden; }
                /* Step 시각화 — `## 1. 핵심 한 줄` 같은 인덱스 헤더 강조 */
                h2:first-child { margin-top: 0.1em; }
            </style>
        </head>
        <body>
            <div id="content"></div>
            <script>
                const RAW_MD = `\(md)`;
                function render() {
                    try {
                        // marked: GFM, breaks(줄바꿈 그대로), no mangle.
                        if (window.marked) {
                            marked.use({ gfm: true, breaks: true });
                            document.getElementById('content').innerHTML = marked.parse(RAW_MD);
                        } else {
                            // marked 로드 실패 시 plain text 폴백
                            const pre = document.createElement('pre');
                            pre.textContent = RAW_MD;
                            document.getElementById('content').appendChild(pre);
                        }
                    } catch (e) {
                        const pre = document.createElement('pre');
                        pre.textContent = RAW_MD;
                        document.getElementById('content').appendChild(pre);
                    }
                    if (window.renderMathInElement) {
                        try {
                            renderMathInElement(document.body, {
                                delimiters: [
                                    {left: '$$', right: '$$', display: true},
                                    {left: '$', right: '$', display: false},
                                    {left: '\\\\(', right: '\\\\)', display: false},
                                    {left: '\\\\[', right: '\\\\]', display: true}
                                ],
                                throwOnError: false,
                            });
                        } catch (e) { /* ignore */ }
                    }
                    // 렌더 끝났음을 표시 → CSS 가 opacity 0 → 1 로 페이드인.
                    document.getElementById('content').classList.add('ready');
                    reportHeight();
                }
                function reportHeight() {
                    const h = document.body.scrollHeight;
                    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.heightCallback) {
                        window.webkit.messageHandlers.heightCallback.postMessage(h);
                    }
                }
                // CDN 비동기 로딩이 늦을 수 있어, 모든 스크립트 로드 후 render.
                function tryRender() {
                    if (document.readyState === 'complete') { render(); }
                    else { window.addEventListener('load', render); }
                }
                tryRender();
                // 이미지/폰트가 늦게 로드되며 높이 변할 때마다 보고.
                new ResizeObserver(() => reportHeight()).observe(document.body);
            </script>
        </body>
        </html>
        """
    }
}
