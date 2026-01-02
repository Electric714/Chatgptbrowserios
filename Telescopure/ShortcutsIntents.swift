import AppIntents
import Foundation
import UniformTypeIdentifiers
import UserInterface
import WebKit

struct GetBrowserSnapshotIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Telescopure Snapshot"
    static var description = IntentDescription("Capture the visible Telescopure page with optional text context.")

    @Parameter(title: "Include Text Snippet")
    var includeTextSnippet: Bool = true

    func perform() async throws -> some IntentResult {
        guard let webView = await MainActor.run(body: { BrowserEnvironment.shared.activeWebView }) else {
            return GetBrowserSnapshotIntentResult(error: "No active browser view is available.")
        }

        try Task.checkCancellation()

        guard let urlString = await MainActor.run(body: { webView.url?.absoluteString }), !urlString.isEmpty else {
            return GetBrowserSnapshotIntentResult(error: "No page is currently loaded.")
        }

        let viewport = await MainActor.run(body: { webView.bounds.size })
        let snapshotImage = try await MainActor.run {
            try Task.checkCancellation()
            return try await webView.takeSnapshot(with: nil)
        }
        guard let imageData = snapshotImage.pngData() else {
            return GetBrowserSnapshotIntentResult(error: "Unable to encode snapshot image.")
        }

        let pageContext = await fetchPageContext(from: webView, includeText: includeTextSnippet)
        let intentFile = IntentFile(data: imageData, filename: "telescopure-snapshot.png", type: .png)

        return GetBrowserSnapshotIntentResult(
            image: intentFile,
            url: urlString,
            title: pageContext.title,
            viewportWidth: Double(viewport.width),
            viewportHeight: Double(viewport.height),
            textSnippet: pageContext.snippet,
            error: nil
        )
    }
}

struct GetBrowserSnapshotIntentResult: IntentResult {
    @Output var image: IntentFile?
    @Output var url: String?
    @Output var title: String?
    @Output var viewportWidth: Double?
    @Output var viewportHeight: Double?
    @Output var textSnippet: String?
    @Output var error: String?
}

struct ExecuteBrowserActionsIntent: AppIntent {
    static var title: LocalizedStringResource = "Execute Telescopure Browser Actions"
    static var description = IntentDescription("Run scripted browser actions against the active Telescopure tab.")

    @Parameter(title: "Actions JSON")
    var actionsJson: String

    @Parameter(title: "Require Confirmation on Risky Pages")
    var requireConfirmationOnRisky: Bool = true

    @Parameter(title: "Max Actions")
    var maxActions: Int = 10

    func perform() async throws -> some IntentResult {
        guard let webView = await MainActor.run(body: { BrowserEnvironment.shared.activeWebView }) else {
            return ExecuteBrowserActionsIntentResult(errors: ["No active browser view is available."])
        }

        try Task.checkCancellation()

        guard let data = actionsJson.data(using: .utf8) else {
            return ExecuteBrowserActionsIntentResult(errors: ["actionsJson is not valid UTF-8."])
        }
        guard let envelope = try? JSONDecoder().decode(BrowserActionEnvelope.self, from: data) else {
            return ExecuteBrowserActionsIntentResult(errors: ["actionsJson is not valid according to the schema."])
        }

        let actions = Array((envelope.actions ?? []).prefix(max(1, maxActions)))
        if actions.isEmpty {
            return ExecuteBrowserActionsIntentResult(warnings: ["No actions to execute."])
        }

        var result = ExecuteBrowserActionsIntentResult()
        let executor = BrowserActionExecutor(webView: webView)

        if requireConfirmationOnRisky, let matched = await executor.scanForRisk() {
            result.errors.append("Paused for confirmation. Detected keywords: \(matched)")
            result.warnings.append("Execution paused for confirmation.")
            return result
        }

        result = try await executor.execute(actions: actions)
        return result
    }
}

struct ExecuteBrowserActionsIntentResult: IntentResult {
    @Output var executedCount: Int = 0
    @Output var skippedCount: Int = 0
    @Output var errors: [String] = []
    @Output var warnings: [String] = []
    @Output var finalURL: String?
    @Output var finalTitle: String?
    @Output var didNavigate: Bool = false
}

struct TelescopureShortcutsProvider: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        [
            AppShortcut(
                intent: GetBrowserSnapshotIntent(),
                phrases: ["Get Telescopure Snapshot", "Capture Telescopure page"],
                shortTitle: "Get Snapshot",
                systemImageName: "camera"
            ),
            AppShortcut(
                intent: ExecuteBrowserActionsIntent(),
                phrases: ["Execute Telescopure Browser Actions", "Run Telescopure actions"],
                shortTitle: "Execute Actions",
                systemImageName: "sparkles.rectangle.stack"
            ),
        ]
    }

    static var shortcutTileColor: ShortcutTileColor { .indigo }
}

// MARK: - Helpers

private struct PageContext: Codable {
    let title: String
    let snippet: String?
}

private struct BrowserActionEnvelope: Decodable {
    let actions: [BrowserActionDTO]?
    let done: Bool?
    let note: String?
}

private struct BrowserActionDTO: Decodable {
    let type: String
    let url: URL?
    let x: Double?
    let y: Double?
    let deltaY: Double?
    let text: String?
    let ms: Int?
}

private enum BrowserAction {
    case navigate(URL)
    case clickAt(Double, Double)
    case scroll(Double)
    case type(String)
    case wait(Int)
}

private struct ActionExecutionResult {
    let success: Bool
    let warning: String?
}

private struct BrowserActionExecutor {
    let webView: WKWebView

    func scanForRisk() async -> String? {
        let keywords = ["purchase", "buy", "pay", "checkout", "send", "post", "delete", "confirm", "submit order", "authorize", "install"]
        let context = await fetchPageContext(from: webView, includeText: true)
        let lowered = (context.title + " " + (context.snippet ?? "")).lowercased()
        let matched = keywords.filter { lowered.contains($0) }
        guard !matched.isEmpty else { return nil }
        return matched.joined(separator: ", ")
    }

    func execute(actions: [BrowserActionDTO]) async throws -> ExecuteBrowserActionsIntentResult {
        var result = ExecuteBrowserActionsIntentResult()
        var didNavigate = false
        let initialURL = await MainActor.run { webView.url?.absoluteString }

        for action in actions {
            try Task.checkCancellation()
            guard let browserAction = validate(action: action) else {
                result.skippedCount += 1
                result.warnings.append("Skipped unsupported or invalid action: \(action.type)")
                continue
            }

            let outcome = try await perform(browserAction: browserAction)
            if let warning = outcome.warning {
                result.warnings.append(warning)
            }
            if outcome.success {
                result.executedCount += 1
            } else {
                result.errors.append("Failed to execute action: \(describe(action: action))")
            }

            if case .navigate = browserAction { didNavigate = true }
        }

        let finalMeta = await MainActor.run { (webView.url?.absoluteString, webView.title) }
        result.finalURL = finalMeta.0
        result.finalTitle = finalMeta.1
        result.didNavigate = didNavigate || (initialURL != finalMeta.0)

        return result
    }

    private func validate(action: BrowserActionDTO) -> BrowserAction? {
        switch action.type {
        case "navigate":
            if let url = action.url { return .navigate(url) }
        case "click_at":
            if let x = action.x, let y = action.y { return .clickAt(x, y) }
        case "scroll":
            if let delta = action.deltaY { return .scroll(delta) }
        case "type":
            if let text = action.text { return .type(text) }
        case "wait":
            if let ms = action.ms { return .wait(ms) }
        default:
            return nil
        }
        return nil
    }

    private func perform(browserAction: BrowserAction) async throws -> ActionExecutionResult {
        switch browserAction {
        case .navigate(let url):
            try Task.checkCancellation()
            await MainActor.run {
                let request = URLRequest(url: url)
                webView.load(request)
            }
            await waitForReadyState(timeout: 5)
            return .init(success: true, warning: nil)

        case .clickAt(let x, let y):
            try Task.checkCancellation()
            let viewport = await MainActor.run { webView.bounds.size }
            let px = max(0, min(1000, x)) / 1000.0 * viewport.width
            let py = max(0, min(1000, y)) / 1000.0 * viewport.height
            let script = """
            (() => {
                const element = document.elementFromPoint(\(px), \(py));
                if (!element) { return false; }
                try { element.click(); } catch {}
                const events = ['pointerdown', 'mousedown', 'mouseup', 'click'];
                for (const name of events) {
                    const evt = new Event(name, { bubbles: true, cancelable: true });
                    element.dispatchEvent(evt);
                }
                return true;
            })();
            """
            let found = try await MainActor.run { (try? await webView.evaluateJavaScript(script) as? Bool) ?? false }
            if found {
                await waitForReadyState(timeout: 3)
                return .init(success: true, warning: nil)
            } else {
                return .init(success: false, warning: "No element found at the requested point.")
            }

        case .scroll(let delta):
            try Task.checkCancellation()
            let script = "window.scrollBy(0, \(delta)); return true;"
            let ok = try await MainActor.run { (try? await webView.evaluateJavaScript(script) as? Bool) ?? false }
            return .init(success: ok, warning: ok ? nil : "Scroll request failed to run.")

        case .type(let text):
            try Task.checkCancellation()
            let literal = javascriptLiteral(text)
            let script = """
            (() => {
                const candidates = [];
                const center = document.elementFromPoint(window.innerWidth / 2, window.innerHeight / 2);
                if (center) candidates.push(center);
                const top = document.elementFromPoint(window.innerWidth / 2, 20);
                if (top) candidates.push(top);
                let target = document.activeElement && document.activeElement !== document.body ? document.activeElement : null;
                if (!target) {
                    target = candidates.find(el => typeof el.focus === 'function') || null;
                    if (target && typeof target.focus === 'function') { target.focus(); }
                }
                if (!target || typeof target.value === 'undefined') { return false; }
                const currentValue = target.value ?? '';
                target.value = currentValue + \(literal);
                target.dispatchEvent(new Event('input', { bubbles: true }));
                target.dispatchEvent(new Event('change', { bubbles: true }));
                return true;
            })();
            """
            let ok = try await MainActor.run { (try? await webView.evaluateJavaScript(script) as? Bool) ?? false }
            if ok {
                await waitForReadyState(timeout: 1)
                return .init(success: true, warning: nil)
            } else {
                return .init(success: false, warning: "No active form field to type into.")
            }

        case .wait(let ms):
            try Task.checkCancellation()
            if ms > 0 { try await Task.sleep(for: .milliseconds(ms)) }
            return .init(success: true, warning: nil)
        }
    }

    private func describe(action: BrowserActionDTO) -> String {
        switch action.type {
        case "navigate": return "navigate(\(action.url?.absoluteString ?? ""))"
        case "click_at": return "click_at(\(action.x ?? 0),\(action.y ?? 0))"
        case "scroll": return "scroll(\(action.deltaY ?? 0))"
        case "type": return "type(\(action.text ?? ""))"
        case "wait": return "wait(\(action.ms ?? 0))"
        default: return action.type
        }
    }

    private func javascriptLiteral(_ text: String) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: text, options: []),
           let literal = String(data: data, encoding: .utf8) {
            return literal
        }
        return "\"\""
    }

    private func waitForReadyState(timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try? Task.checkCancellation()
            let ready = await MainActor.run { () -> Bool in
                let script = "document.readyState"
                guard let state = try? await webView.evaluateJavaScript(script) as? String else { return false }
                return state == "interactive" || state == "complete"
            }
            if ready { break }
            try? await Task.sleep(for: .milliseconds(200))
        }
    }
}

@MainActor
private func fetchPageContext(from webView: WKWebView, includeText: Bool) async -> PageContext {
    let script = #"""
    (() => {
        const text = (document.body?.innerText || '').replace(/\s+/g, ' ').trim();
        return JSON.stringify({
            title: document.title || '',
            snippet: text.slice(0, 2000)
        });
    })();
    """#

    var title = webView.title ?? ""
    var snippet: String? = nil

    if includeText {
        if let jsonString = try? await webView.evaluateJavaScript(script) as? String,
           let data = jsonString.data(using: .utf8),
           let context = try? JSONDecoder().decode(PageContext.self, from: data) {
            title = context.title
            snippet = context.snippet
        }
    }

    return PageContext(title: title, snippet: snippet)
}
