import Foundation
import WebKit
import WebUI

@MainActor
public final class BrowserEnvironment {
    public static let shared = BrowserEnvironment()

    private weak var webView: WKWebView?

    private init() {}

    public func setActiveWebView(_ webView: WKWebView?) {
        self.webView = webView
    }

    public func updateActiveWebView(from proxy: WebViewProxy) {
        if let extracted = extractWebView(from: proxy) {
            webView = extracted
        }
    }

    public var activeWebView: WKWebView? {
        webView
    }

    private func extractWebView(from proxy: WebViewProxy) -> WKWebView? {
        let mirror = Mirror(reflecting: proxy)
        for child in mirror.children {
            if child.label == "webView", let container = child.value as? AnyObject {
                let innerMirror = Mirror(reflecting: container)
                for grandChild in innerMirror.children {
                    if grandChild.label == "wrappedValue", let wk = grandChild.value as? WKWebView {
                        return wk
                    }
                }
            }
        }
        return nil
    }
}
