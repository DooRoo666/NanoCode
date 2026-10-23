import SwiftUI
import WebKit

/// Mermaid 渲染：用原版随包的 `Mermaid/mermaid.min.js` + `render.html`（离线，CSP 已限死网络）。
///
/// `render.html` 的约定：加载前注入 `window.__MT_MERMAID_ARGS = { source, dark }`，
/// 渲染完成后通过 `webkit.messageHandlers.mtMermaid` 回传尺寸。
struct NanoMuseMermaidView: UIViewRepresentable {

    let source: String
    var dark: Bool = false

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(context.coordinator, name: "mtMermaid")
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.navigationDelegate = context.coordinator
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        guard let directory = NanoMuseCodexAssets.mermaidDirectory else {
            webView.loadHTMLString("<p style=\"font-family:-apple-system;color:#888;padding:16px\">未随包 Mermaid 资源</p>",
                                   baseURL: nil)
            return
        }
        let html = URL(fileURLWithPath: directory + "/render.html")
        guard context.coordinator.renderedSource != source else { return }
        context.coordinator.renderedSource = source

        // 注入参数后再加载页面
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        let payload: [String: Any] = ["source": source, "dark": dark]
        if let data = try? JSONSerialization.data(withJSONObject: payload),
           let json = String(data: data, encoding: .utf8) {
            let script = "window.__MT_MERMAID_ARGS = \(json);"
            controller.addUserScript(WKUserScript(source: script,
                                                 injectionTime: .atDocumentStart,
                                                 forMainFrameOnly: true))
        }
        webView.loadFileURL(html, allowingReadAccessTo: URL(fileURLWithPath: directory))
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "mtMermaid")
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var renderedSource: String?

        func userContentController(_ controller: WKUserContentController,
                                  didReceive message: WKScriptMessage) {
            // render.html 会回传 { type, width, height }；这里只做日志意义的上报
            guard let body = message.body as? [String: Any] else { return }
            if let type = body["type"] as? String {
                NSLog("[Mermaid] %@ %@x%@", type,
                      String(describing: body["width"] ?? "-"),
                      String(describing: body["height"] ?? "-"))
            }
        }
    }
}

/// 自检预览：点一下就渲染一张示例图，用来确认随包资源可用。
struct NanoMuseMermaidPreviewPage: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    private let sample = """
    flowchart LR
      A[手机] -->|codex_exec| B(Alpine aarch64)
      B --> C{codex 已装?}
      C -->|是| D[执行任务]
      C -->|否| E[先安装]
    """

    var body: some View {
        NavigationStack {
            NanoMuseMermaidView(source: sample, dark: colorScheme == .dark)
                .navigationTitle("Mermaid 预览")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("关闭") { dismiss() }
                    }
                }
        }
    }
}
