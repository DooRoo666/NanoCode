import SwiftUI
import UIKit

/// 把 Markdown 里的 ```mermaid 代码块换成真实渲染图。
///
/// 挂载点：`SelectableMarkdownView.swift` 里 `CodeBlockAttachment.makeView(width:)` 顶部
/// （由 `Tools/patch_upstream.py` 注入一行判断，见 PATCH 说明）。
enum NanoMuseMermaidAttachment {

    /// 渲染高度上限；图本身在 WebView 内可滚动
    static let height: CGFloat = 300

    static func makeView(code: String, width: CGFloat) -> UIView? {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, NanoMuseCodexAssets.mermaidDirectory != nil else { return nil }

        let host = UIHostingController(rootView: MermaidBlockView(source: trimmed))
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false

        let container = UIView()
        container.backgroundColor = .clear
        container.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: container.topAnchor),
            host.view.heightAnchor.constraint(equalToConstant: height),
            host.view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    /// SwiftUI 侧的同款包装（预览页复用）
    struct MermaidBlockView: View {
        let source: String

        var body: some View {
            NanoMuseMermaidView(source: source, dark: true)
                .frame(maxWidth: .infinity)
                .frame(height: NanoMuseMermaidAttachment.height)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                )
        }
    }
}
