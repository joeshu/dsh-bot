import Foundation
import Combine
#if canImport(WebKit) && canImport(UIKit)
import WebKit
import UIKit
#endif
#if canImport(Vision)
import Vision
#endif

public struct BrowserActionLogEntry: Identifiable, Sendable {
    public enum Actor: String, Sendable {
        case bot
        case user
        case system
    }

    public let id: UUID
    public let timestamp: Date
    public let actor: Actor
    public let summary: String

    public init(id: UUID = UUID(), timestamp: Date = Date(), actor: Actor, summary: String) {
        self.id = id
        self.timestamp = timestamp
        self.actor = actor
        self.summary = summary
    }
}

/// Native iOS in-app browser controller driven by DSH `browser_*` tools and
/// inspectable / manually takeover-able by the user via `AgentBrowserSheet`.
@MainActor
public final class AgentBrowserController: NSObject, ObservableObject {
    public static let shared = AgentBrowserController()

    private static let mobileUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
    private static let desktopUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    /// Shared JS helper injected into browser action scripts to pierce open Shadow DOM trees.
    private static let shadowDOMHelperJS = """
    function __dsbotCollectRoots(root, out, depth) {
      if (!root || depth > 6) return;
      out.push(root);
      const all = root.querySelectorAll ? root.querySelectorAll('*') : [];
      for (let i = 0; i < all.length; i++) {
        if (all[i].shadowRoot) __dsbotCollectRoots(all[i].shadowRoot, out, depth + 1);
      }
    }
    function __dsbotQueryAll(selector) {
      const roots = [];
      __dsbotCollectRoots(document, roots, 0);
      const results = [];
      for (const r of roots) {
        try {
          const found = r.querySelectorAll(selector);
          for (let i = 0; i < found.length; i++) results.push(found[i]);
        } catch (_) {}
      }
      return results;
    }
    function __dsbotQueryOne(selector) {
      const roots = [];
      __dsbotCollectRoots(document, roots, 0);
      for (const r of roots) {
        try {
          const el = r.querySelector(selector);
          if (el) return el;
        } catch (_) {}
      }
      return null;
    }
    """

    @Published public private(set) var currentURL: String = ""
    @Published public private(set) var pageTitle: String = ""
    @Published public private(set) var isLoading: Bool = false
    @Published public private(set) var estimatedProgress: Double = 0
    @Published public private(set) var canGoBack: Bool = false
    @Published public private(set) var canGoForward: Bool = false
    @Published public private(set) var lastActionSummary: String = ""
    @Published public private(set) var lastDownloadedFile: String = ""
    @Published public private(set) var actionHistory: [BrowserActionLogEntry] = []
    @Published public var useDesktopUserAgent: Bool = false {
        didSet {
            #if canImport(WebKit) && canImport(UIKit)
            webView.customUserAgent = useDesktopUserAgent ? Self.desktopUA : Self.mobileUA
            recordLog(useDesktopUserAgent ? "已切换为桌面版网页 (Desktop UA)" : "已切换为移动版网页 (Mobile UA)", actor: .user)
            if webView.url != nil { webView.reload() }
            #endif
        }
    }
    @Published public var needsHumanTakeover: Bool = false
    @Published public var humanTakeoverReason: String = ""
    /// When true, mutating/navigating Bot tool calls yield immediately instead of fighting the user.
    @Published public var isHumanControlling: Bool = false

    public var workspaceDirectory: URL?

    #if canImport(WebKit) && canImport(UIKit)
    public let webView: WKWebView
    private var progressObs: NSKeyValueObservation?
    private var urlObs: NSKeyValueObservation?
    private var titleObs: NSKeyValueObservation?
    private var loadingObs: NSKeyValueObservation?
    private var backObs: NSKeyValueObservation?
    private var forwardObs: NSKeyValueObservation?
    private var navigationContinuation: CheckedContinuation<Void, Error>?
    private var navigationTimeoutTask: Task<Void, Never>?
    private var activeDownloads: [ObjectIdentifier: String] = [:]
    #endif

    // FIFO serial gate so concurrent Bot/subagent browser_* tool calls never race each other.
    private var isExecutingAction: Bool = false
    private var actionWaiters: [CheckedContinuation<Void, Never>] = []

    private override init() {
        #if canImport(WebKit) && canImport(UIKit)
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.allowsInlineMediaPlayback = true
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: config)
        view.customUserAgent = Self.mobileUA
        view.allowsBackForwardNavigationGestures = true
        self.webView = view
        super.init()
        view.navigationDelegate = self
        view.uiDelegate = self
        observeWebView()
        #else
        super.init()
        #endif
    }

    private func recordLog(_ summary: String, actor: BrowserActionLogEntry.Actor) {
        lastActionSummary = summary
        actionHistory.insert(BrowserActionLogEntry(actor: actor, summary: summary), at: 0)
        if actionHistory.count > 40 {
            actionHistory.removeLast(actionHistory.count - 40)
        }
    }

    private func acquireActionSlot() async {
        if !isExecutingAction {
            isExecutingAction = true
            return
        }
        await withCheckedContinuation { continuation in
            actionWaiters.append(continuation)
        }
    }

    private func releaseActionSlot() {
        if let next = actionWaiters.first {
            actionWaiters.removeFirst()
            next.resume()
        } else {
            isExecutingAction = false
        }
    }

    #if canImport(WebKit) && canImport(UIKit)
    private func observeWebView() {
        progressObs = webView.observe(\.estimatedProgress, options: [.new]) { [weak self] _, change in
            let v = change.newValue ?? 0
            Task { @MainActor in self?.estimatedProgress = v }
        }
        urlObs = webView.observe(\.url, options: [.new]) { [weak self] _, change in
            let s = change.newValue??.absoluteString ?? ""
            Task { @MainActor in self?.currentURL = s }
        }
        titleObs = webView.observe(\.title, options: [.new]) { [weak self] _, change in
            let t = change.newValue??.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            Task { @MainActor in self?.pageTitle = t }
        }
        loadingObs = webView.observe(\.isLoading, options: [.new]) { [weak self] _, change in
            let l = change.newValue ?? false
            Task { @MainActor in self?.isLoading = l }
        }
        backObs = webView.observe(\.canGoBack, options: [.new]) { [weak self] _, change in
            let b = change.newValue ?? false
            Task { @MainActor in self?.canGoBack = b }
        }
        forwardObs = webView.observe(\.canGoForward, options: [.new]) { [weak self] _, change in
            let f = change.newValue ?? false
            Task { @MainActor in self?.canGoForward = f }
        }
    }

    public func validatePublicHTTPS(_ raw: String) throws -> URL {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            throw IPCFrameError.remoteError(code: -32602, message: "请输入有效的网页地址。")
        }
        if !text.contains("://") {
            text = "https://" + text
        } else if text.lowercased().hasPrefix("http://") {
            text = "https://" + text.dropFirst("http://".count)
        }
        guard let url = URL(string: text),
              url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(), !host.isEmpty,
              url.user == nil, url.password == nil else {
            throw IPCFrameError.remoteError(code: -32602, message: "内置浏览器仅支持无凭据的公开 HTTPS 网址。")
        }
        if SafeHTTPSRedirects.isPrivateOrLoopbackHost(host) {
            throw IPCFrameError.remoteError(code: -32602, message: "安全策略已拦截内网或本机回环地址：\(host)")
        }
        return url
    }

    public func loadManualURL(_ raw: String) {
        guard let url = try? validatePublicHTTPS(raw) else { return }
        recordLog("手动打开 \(url.host ?? url.absoluteString)", actor: .user)
        webView.load(URLRequest(url: url))
    }

    public func clearBrowsingData() {
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        webView.configuration.websiteDataStore.removeData(ofTypes: types, modifiedSince: .distantPast) {}
        recordLog("已清除内置浏览器 Cookie 与缓存", actor: .user)
    }

    public func toggleHumanControl() {
        isHumanControlling.toggle()
        if isHumanControlling {
            recordLog("已开启人工接管锁（暂停 Bot 操作页面）", actor: .user)
        } else {
            needsHumanTakeover = false
            humanTakeoverReason = ""
            recordLog("已解除人工接管锁（允许 Bot 控制页面）", actor: .user)
        }
    }

    public func clearTakeoverFlag() {
        needsHumanTakeover = false
        humanTakeoverReason = ""
        isHumanControlling = false
        recordLog("已交回 Bot 继续控制", actor: .user)
    }

    public func handleAction(_ action: String, args: [String: Any], workspace: URL) async throws -> [String: Any] {
        workspaceDirectory = workspace
        await acquireActionSlot()
        defer { releaseActionSlot() }

        let mutatingOrNavActions: Set<String> = ["open", "click", "type", "select", "press_key", "back", "eval"]
        if isHumanControlling && mutatingOrNavActions.contains(action) {
            return [
                "pausedForHuman": true,
                "url": webView.url?.absoluteString ?? currentURL,
                "title": webView.title ?? pageTitle,
                "reason": humanTakeoverReason,
                "message": "用户正在内置浏览器中手动接管操作（已锁定暂停 Bot 控制），请等待用户点击「我已完成，交回 Bot 继续」后再继续操作。",
            ]
        }

        switch action {
        case "open":
            let rawUrl = args["url"] as? String ?? ""
            let url = try validatePublicHTTPS(rawUrl)
            needsHumanTakeover = false
            humanTakeoverReason = ""
            recordLog("Bot 正在打开 \(url.host ?? url.absoluteString)…", actor: .bot)
            try await navigateAndWait(url: url, timeoutSeconds: 20)
            try? await Task.sleep(nanoseconds: 450_000_000)
            recordLog("Bot 已打开 \(webView.title ?? url.host ?? url.absoluteString)", actor: .bot)
            return try await captureSnapshot(maxChars: args["maxChars"] as? Int ?? 8_000)

        case "snapshot":
            let maxChars = max(500, min(args["maxChars"] as? Int ?? 10_000, 16_000))
            recordLog("Bot 正在读取页面内容与可交互元素", actor: .bot)
            var snap = try await captureSnapshot(maxChars: maxChars)
            if isHumanControlling { snap["humanControlling"] = true }
            if !lastDownloadedFile.isEmpty { snap["lastDownloadedFile"] = lastDownloadedFile }
            return snap

        case "back":
            guard webView.canGoBack else {
                return ["ok": false, "message": "当前没有可返回的上一页。"]
            }
            recordLog("Bot 正在返回上一页…", actor: .bot)
            webView.goBack()
            await waitForLoadSettle(initialDelayMs: 350, maxSeconds: 8)
            recordLog("Bot 已返回 \(webView.title ?? webView.url?.host ?? "上一页")", actor: .bot)
            return try await captureSnapshot(maxChars: 6_000)

        case "wait":
            let selector = (args["selector"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let text = (args["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let seconds = max(1, min(args["timeoutSeconds"] as? Int ?? 8, 20))
            recordLog("Bot 正在等待页面加载…", actor: .bot)
            let deadline = Date().addingTimeInterval(Double(seconds))
            while Date() < deadline {
                if !selector.isEmpty || !text.isEmpty {
                    let payloadJSON = try Self.encodeJSON(["selector": selector, "text": text])
                    let checkScript = """
                    (function() {
                      \(Self.shadowDOMHelperJS)
                      const args = \(payloadJSON);
                      let found = false;
                      if (args.selector) {
                        found = Boolean(__dsbotQueryOne(args.selector));
                      }
                      if (!found && args.text) {
                        const body = (document.body ? document.body.innerText : '').toLowerCase();
                        found = body.includes(args.text.toLowerCase());
                      }
                      return JSON.stringify({ found });
                    })();
                    """
                    let res = try await evalJSONString(checkScript)
                    if res["found"] as? Bool == true {
                        var snap = try await captureSnapshot(maxChars: 6_000)
                        snap["matched"] = true
                        return snap
                    }
                } else if !webView.isLoading {
                    break
                }
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
            var snap = try await captureSnapshot(maxChars: 6_000)
            snap["matched"] = selector.isEmpty && text.isEmpty
            return snap

        case "click":
            let index = args["index"] as? Int
            let selector = (args["selector"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let text = (args["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard index != nil || !selector.isEmpty || !text.isEmpty else {
                throw IPCFrameError.remoteError(code: -32602, message: "browser_click 需要提供 index、selector 或 text 之一。")
            }
            let payloadJSON = try Self.encodeJSON([
                "index": index as Any,
                "selector": selector,
                "text": text,
            ])
            let script = """
            (function() {
              \(Self.shadowDOMHelperJS)
              const args = \(payloadJSON);
              let el = null;
              if (typeof args.index === 'number') {
                el = __dsbotQueryOne('[data-dsbot-idx="' + args.index + '"]');
              }
              if (!el && args.selector) {
                el = __dsbotQueryOne(args.selector);
              }
              if (!el && args.text) {
                const needle = args.text.toLowerCase();
                const candidates = __dsbotQueryAll('a,button,[role="button"],input[type="submit"],input[type="button"],summary,label');
                el = candidates.find(node => {
                  const t = (node.innerText || node.textContent || node.getAttribute('aria-label') || node.value || '').trim().toLowerCase();
                  return t === needle || t.includes(needle);
                }) || null;
              }
              if (!el) return JSON.stringify({ ok: false, error: '未在当前页面找到匹配的可点击元素。' });
              el.scrollIntoView({ behavior: 'instant', block: 'center' });
              const prevOutline = el.style.outline;
              const prevShadow = el.style.boxShadow;
              el.style.outline = '3px solid #2563eb';
              el.style.boxShadow = '0 0 0 6px rgba(37,99,235,0.28)';
              setTimeout(() => { el.style.outline = prevOutline; el.style.boxShadow = prevShadow; }, 1200);
              const label = (el.innerText || el.textContent || el.getAttribute('aria-label') || el.value || el.tagName).trim().slice(0, 80);
              el.click();
              return JSON.stringify({ ok: true, clicked: label, tag: el.tagName.toLowerCase() });
            })();
            """
            let raw = try await evalJSONString(script)
            if raw["ok"] as? Bool != true {
                throw IPCFrameError.remoteError(code: -32000, message: raw["error"] as? String ?? "点击失败。")
            }
            let clickedLabel = raw["clicked"] as? String ?? "元素"
            recordLog("Bot 点击了「\(clickedLabel)」", actor: .bot)
            await waitForLoadSettle(initialDelayMs: 450, maxSeconds: 8)
            var snap = try await captureSnapshot(maxChars: 6_000)
            snap["clicked"] = clickedLabel
            if !lastDownloadedFile.isEmpty { snap["lastDownloadedFile"] = lastDownloadedFile }
            return snap

        case "type":
            let index = args["index"] as? Int
            let selector = (args["selector"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let value = args["text"] as? String ?? ""
            let submit = args["submit"] as? Bool ?? false
            guard index != nil || !selector.isEmpty else {
                throw IPCFrameError.remoteError(code: -32602, message: "browser_type 需要提供 index 或 selector。")
            }
            let payloadJSON = try Self.encodeJSON([
                "index": index as Any,
                "selector": selector,
                "value": value,
                "submit": submit,
            ])
            let script = """
            (function() {
              \(Self.shadowDOMHelperJS)
              const args = \(payloadJSON);
              let el = null;
              if (typeof args.index === 'number') {
                el = __dsbotQueryOne('[data-dsbot-idx="' + args.index + '"]');
              }
              if (!el && args.selector) {
                el = __dsbotQueryOne(args.selector);
              }
              if (!el) return JSON.stringify({ ok: false, error: '未找到目标输入框。' });
              el.scrollIntoView({ behavior: 'instant', block: 'center' });
              const prevOutline = el.style.outline;
              el.style.outline = '3px solid #2563eb';
              setTimeout(() => { el.style.outline = prevOutline; }, 1200);
              el.focus();
              const proto = el.tagName === 'TEXTAREA' ? window.HTMLTextAreaElement.prototype : window.HTMLInputElement.prototype;
              const setter = Object.getOwnPropertyDescriptor(proto, 'value')?.set;
              if (setter) setter.call(el, args.value);
              else if (el.isContentEditable) el.innerText = args.value;
              else el.value = args.value;
              el.dispatchEvent(new Event('input', { bubbles: true }));
              el.dispatchEvent(new Event('change', { bubbles: true }));
              if (args.submit) {
                if (el.form && typeof el.form.requestSubmit === 'function') el.form.requestSubmit();
                else if (el.form) el.form.submit();
                else el.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', code: 'Enter', keyCode: 13, bubbles: true }));
              }
              return JSON.stringify({ ok: true, typedLength: args.value.length, submitted: args.submit });
            })();
            """
            let raw = try await evalJSONString(script)
            if raw["ok"] as? Bool != true {
                throw IPCFrameError.remoteError(code: -32000, message: raw["error"] as? String ?? "输入失败。")
            }
            recordLog(submit ? "Bot 输入内容并提交了表单" : "Bot 在输入框中填入了 \(value.count) 字", actor: .bot)
            if submit {
                await waitForLoadSettle(initialDelayMs: 450, maxSeconds: 8)
            } else {
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            var snap = try await captureSnapshot(maxChars: 5_000)
            snap["typedLength"] = value.count
            snap["submitted"] = submit
            return snap

        case "select":
            let index = args["index"] as? Int
            let selector = (args["selector"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let value = args["value"] as? String ?? ""
            let label = args["label"] as? String ?? ""
            let optionIndex = args["optionIndex"] as? Int
            guard index != nil || !selector.isEmpty else {
                throw IPCFrameError.remoteError(code: -32602, message: "browser_select 需要提供 index 或 selector。")
            }
            let payloadJSON = try Self.encodeJSON([
                "index": index as Any,
                "selector": selector,
                "value": value,
                "label": label,
                "optionIndex": optionIndex as Any,
            ])
            let script = """
            (function() {
              \(Self.shadowDOMHelperJS)
              const args = \(payloadJSON);
              let el = null;
              if (typeof args.index === 'number') el = __dsbotQueryOne('[data-dsbot-idx="' + args.index + '"]');
              if (!el && args.selector) el = __dsbotQueryOne(args.selector);
              if (!el || el.tagName !== 'SELECT') return JSON.stringify({ ok: false, error: '未找到目标 <select> 下拉框。' });
              const options = Array.from(el.options || []);
              let target = null;
              if (typeof args.optionIndex === 'number' && options[args.optionIndex]) {
                target = options[args.optionIndex];
              }
              if (!target && args.value) {
                target = options.find(o => o.value === args.value) || null;
              }
              if (!target && args.label) {
                const needle = args.label.toLowerCase();
                target = options.find(o => (o.text || '').trim().toLowerCase() === needle || (o.text || '').trim().toLowerCase().includes(needle)) || null;
              }
              if (!target) return JSON.stringify({ ok: false, error: '未在下拉框中找到匹配的选项。' });
              el.scrollIntoView({ behavior: 'instant', block: 'center' });
              const prevOutline = el.style.outline;
              el.style.outline = '3px solid #2563eb';
              setTimeout(() => { el.style.outline = prevOutline; }, 1200);
              el.value = target.value;
              el.dispatchEvent(new Event('input', { bubbles: true }));
              el.dispatchEvent(new Event('change', { bubbles: true }));
              return JSON.stringify({ ok: true, selectedValue: target.value, selectedText: (target.text || '').trim() });
            })();
            """
            let raw = try await evalJSONString(script)
            if raw["ok"] as? Bool != true {
                throw IPCFrameError.remoteError(code: -32000, message: raw["error"] as? String ?? "选择下拉项失败。")
            }
            let selectedText = raw["selectedText"] as? String ?? value
            recordLog("Bot 选择了下拉项「\(selectedText)」", actor: .bot)
            await waitForLoadSettle(initialDelayMs: 300, maxSeconds: 5)
            var snap = try await captureSnapshot(maxChars: 5_000)
            snap["selected"] = selectedText
            return snap

        case "press_key":
            let key = (args["key"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !key.isEmpty else {
                throw IPCFrameError.remoteError(code: -32602, message: "browser_press_key 需要提供 key（如 Enter、Escape、Tab、ArrowDown）。")
            }
            let payloadJSON = try Self.encodeJSON(["key": key])
            let script = """
            (function() {
              const args = \(payloadJSON);
              const k = args.key;
              const keyCodeMap = { Enter: 13, Escape: 27, Tab: 9, ArrowDown: 40, ArrowUp: 38, Backspace: 8, Space: 32, ' ': 32 };
              const codeMap = { Enter: 'Enter', Escape: 'Escape', Tab: 'Tab', ArrowDown: 'ArrowDown', ArrowUp: 'ArrowUp', Backspace: 'Backspace', Space: 'Space', ' ': 'Space' };
              const actualKey = k === 'Space' ? ' ' : k;
              const kc = keyCodeMap[k] || 0;
              const target = document.activeElement || document.body || document;
              const init = { key: actualKey, code: codeMap[k] || k, keyCode: kc, which: kc, bubbles: true, cancelable: true };
              target.dispatchEvent(new KeyboardEvent('keydown', init));
              target.dispatchEvent(new KeyboardEvent('keypress', init));
              target.dispatchEvent(new KeyboardEvent('keyup', init));
              if (k === 'Enter' && target && target.form) {
                if (typeof target.form.requestSubmit === 'function') target.form.requestSubmit();
                else target.form.submit();
              }
              return JSON.stringify({ ok: true, key: k, targetTag: target && target.tagName ? target.tagName.toLowerCase() : 'document' });
            })();
            """
            let raw = try await evalJSONString(script)
            if raw["ok"] as? Bool != true {
                throw IPCFrameError.remoteError(code: -32000, message: "按键发送失败。")
            }
            recordLog("Bot 按下了按键 \(key)", actor: .bot)
            if key == "Enter" {
                await waitForLoadSettle(initialDelayMs: 400, maxSeconds: 8)
            } else {
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            var snap = try await captureSnapshot(maxChars: 5_000)
            snap["key"] = key
            return snap

        case "scroll":
            let rawDirection = (args["direction"] as? String ?? "down").lowercased()
            let direction = ["up", "down", "top", "bottom"].contains(rawDirection) ? rawDirection : "down"
            let amount = max(120, min(args["amount"] as? Int ?? 600, 3_000))
            let script = """
            (function() {
              const dir = '\(direction)';
              const amt = \(amount);
              if (dir === 'top') window.scrollTo(0, 0);
              else if (dir === 'bottom') window.scrollTo(0, document.body.scrollHeight);
              else if (dir === 'up') window.scrollBy(0, -amt);
              else window.scrollBy(0, amt);
              return JSON.stringify({
                scrollY: Math.round(window.scrollY),
                scrollHeight: Math.round(document.body.scrollHeight),
                innerHeight: Math.round(window.innerHeight)
              });
            })();
            """
            let metrics = try await evalJSONString(script)
            recordLog("Bot 滚动页面（\(direction)）", actor: .bot)
            try? await Task.sleep(nanoseconds: 250_000_000)
            var snap = try await captureSnapshot(maxChars: 6_000)
            snap["scroll"] = metrics
            return snap

        case "eval":
            let expr = (args["script"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !expr.isEmpty, expr.utf8.count <= 16_384 else {
                throw IPCFrameError.remoteError(code: -32602, message: "browser_eval 脚本不能为空且不能超过 16 KB。")
            }
            recordLog("Bot 正在页面内提取结构化数据", actor: .bot)
            let wrapped = """
            (function() {
              try {
                const value = (function() { return (\(expr)); })();
                const text = typeof value === 'string' ? value : JSON.stringify(value ?? null, null, 2);
                return JSON.stringify({ ok: true, result: String(text ?? '').slice(0, 12000) });
              } catch (e) {
                try {
                  const value = (function() { \(expr) })();
                  const text = typeof value === 'string' ? value : JSON.stringify(value ?? null, null, 2);
                  return JSON.stringify({ ok: true, result: String(text ?? '').slice(0, 12000) });
                } catch (err) {
                  return JSON.stringify({ ok: false, error: String(err && err.message ? err.message : err) });
                }
              }
            })();
            """
            let out = try await evalJSONString(wrapped)
            if out["ok"] as? Bool != true {
                throw IPCFrameError.remoteError(code: -32000, message: out["error"] as? String ?? "页面脚本执行失败。")
            }
            return [
                "url": webView.url?.absoluteString ?? currentURL,
                "result": out["result"] as? String ?? "",
            ]

        case "handoff":
            let reason = (args["reason"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "请在内置浏览器中完成登录或人机验证，完成后点击「我已完成，交回 Bot 继续」。"
            needsHumanTakeover = true
            isHumanControlling = true
            humanTakeoverReason = reason
            recordLog("等待人工接管：\(reason)", actor: .system)
            return [
                "handedOff": true,
                "url": webView.url?.absoluteString ?? currentURL,
                "reason": reason,
                "hint": "已通知用户在 App 内置浏览器接管操作并锁定防冲突；请暂停进一步页面操作并等待用户回复继续。",
            ]

        case "screenshot":
            if webView.bounds.width < 10 || webView.bounds.height < 10 {
                webView.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
            }
            let config = WKSnapshotConfiguration()
            config.afterScreenUpdates = webView.window != nil
            let image = try await webView.takeSnapshot(configuration: config)
            guard let jpeg = image.jpegData(compressionQuality: 0.78) else {
                throw IPCFrameError.remoteError(code: -32000, message: "无法生成页面截图。")
            }
            let filesDir = workspace.appendingPathComponent("files", isDirectory: true)
            try FileManager.default.createDirectory(at: filesDir, withIntermediateDirectories: true)
            let name = "browser-shot-\(Int(Date().timeIntervalSince1970)).jpg"
            let dest = filesDir.appendingPathComponent(name)
            try jpeg.write(to: dest, options: .atomic)
            let cgImage = image.cgImage
            let ocr = await Task.detached(priority: .userInitiated) {
                cgImage.flatMap { Self.recognizeText(in: $0, maxChars: 6_000) }
            }.value
            recordLog("Bot 已保存页面截图 files/\(name)", actor: .bot)
            var result: [String: Any] = [
                "path": "files/\(name)",
                "byteCount": jpeg.count,
                "url": webView.url?.absoluteString ?? currentURL,
                "title": webView.title ?? pageTitle,
            ]
            if let ocr, !ocr.isEmpty {
                result["ocrText"] = ocr
            }
            return result

        default:
            throw IPCFrameError.remoteError(code: -32601, message: "不支持的浏览器操作：\(action)")
        }
    }

    private func waitForLoadSettle(initialDelayMs: UInt64, maxSeconds: Double) async {
        try? await Task.sleep(nanoseconds: initialDelayMs * 1_000_000)
        if !webView.isLoading { return }
        let deadline = Date().addingTimeInterval(maxSeconds)
        while webView.isLoading && Date() < deadline {
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        try? await Task.sleep(nanoseconds: 300_000_000)
    }

    private func navigateAndWait(url: URL, timeoutSeconds: Double) async throws {
        navigationTimeoutTask?.cancel()
        if let existing = navigationContinuation {
            navigationContinuation = nil
            existing.resume(throwing: CancellationError())
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.navigationContinuation = continuation
            self.navigationTimeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                guard let self, let pending = self.navigationContinuation else { return }
                self.navigationContinuation = nil
                pending.resume(throwing: IPCFrameError.remoteError(code: -32000, message: "页面加载超时（\(Int(timeoutSeconds))s）。"))
            }
            self.webView.load(URLRequest(url: url))
        }
    }

    private func captureSnapshot(maxChars: Int) async throws -> [String: Any] {
        let script = """
        (function() {
          \(Self.shadowDOMHelperJS)
          const maxChars = \(maxChars);
          const selectors = 'a[href], button, input:not([type="hidden"]), textarea, select, [role="button"], [role="link"], [role="textbox"], [contenteditable="true"]';
          const nodes = __dsbotQueryAll(selectors);
          const interactive = [];
          let idx = 0;
          let hasPasswordField = false;
          for (const el of nodes) {
            const rect = el.getBoundingClientRect();
            if (rect.width <= 0 && rect.height <= 0) continue;
            const style = window.getComputedStyle(el);
            if (style.visibility === 'hidden' || style.display === 'none') continue;
            el.setAttribute('data-dsbot-idx', String(idx));
            const tag = el.tagName.toLowerCase();
            const type = (el.getAttribute('type') || '').toLowerCase();
            if (type === 'password') hasPasswordField = true;
            const label = (el.innerText || el.getAttribute('aria-label') || el.getAttribute('placeholder') || el.getAttribute('name') || '').replace(/\\s+/g, ' ').trim().slice(0, 80);
            const href = tag === 'a' ? (el.getAttribute('href') || '').slice(0, 120) : '';
            let currentValue = '';
            if (tag === 'input' || tag === 'textarea' || tag === 'select') {
              currentValue = type === 'password' ? (el.value ? '***' : '') : String(el.value || '').slice(0, 80);
            }
            const item = {
              index: idx,
              tag: type ? (tag + '[' + type + ']') : tag,
              label: label || '(无文本)'
            };
            if (currentValue) item.value = currentValue;
            if (href) item.href = href;
            if (type === 'checkbox' || type === 'radio') item.checked = Boolean(el.checked);
            if (tag === 'select') {
              item.options = Array.from(el.options || []).slice(0, 15).map((o, oi) => ({
                optionIndex: oi,
                value: o.value,
                text: (o.text || '').trim().slice(0, 40),
                ...(o.selected ? { selected: true } : {})
              }));
            }
            if (label || tag === 'input' || tag === 'textarea' || tag === 'select' || el.isContentEditable) {
              interactive.push(item);
            }
            idx += 1;
            if (interactive.length >= 80) break;
          }
          const hasDialog = Boolean(document.querySelector('dialog[open], [role="dialog"], [aria-modal="true"]'));
          const bodyText = (document.body ? document.body.innerText : '')
            .replace(/\\n{3,}/g, '\\n\\n')
            .trim();
          const captchaSelector = 'iframe[src*="recaptcha"], iframe[src*="hcaptcha"], iframe[src*="turnstile"], .g-recaptcha, .h-captcha, #cf-turnstile, #challenge-running';
          const captchaDetected = Boolean(document.querySelector(captchaSelector))
            || /verify you are human|just a moment|cloudflare|人机验证|安全验证|拖动滑块/i.test(document.title + ' ' + bodyText.slice(0, 800));
          const result = {
            url: window.location.href,
            title: document.title || '',
            hasDialog,
            hasPasswordField,
            captchaDetected,
            text: bodyText.slice(0, maxChars),
            truncated: bodyText.length > maxChars,
            interactiveCount: interactive.length,
            interactive: interactive
          };
          if (captchaDetected) {
            result.handoffHint = '检测到人机验证或安全挑战，请立即调用 browser_handoff 请用户在 App 内置浏览器中手动完成验证。';
          }
          return JSON.stringify(result);
        })();
        """
        return try await evalJSONString(script)
    }

    private func evalJSONString(_ script: String) async throws -> [String: Any] {
        let result = try await webView.evaluateJavaScript(script)
        guard let str = result as? String,
              let data = str.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ["ok": false, "error": "页面脚本未返回有效 JSON。"]
        }
        return dict
    }

    nonisolated private static func recognizeText(in cgImage: CGImage, maxChars: Int) -> String? {
        #if canImport(Vision)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
            let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            let joined = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return joined.isEmpty ? nil : String(joined.prefix(maxChars))
        } catch {
            return nil
        }
        #else
        return nil
        #endif
    }

    private static func sanitizeDownloadFilename(_ raw: String) -> String {
        let base = URL(fileURLWithPath: raw).lastPathComponent
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let cleaned = base.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let name = String(cleaned).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return name.isEmpty ? "download-\(Int(Date().timeIntervalSince1970)).bin" : String(name.prefix(120))
    }

    private static func encodeJSON(_ obj: [String: Any]) throws -> String {
        let cleaned = obj.compactMapValues { value -> Any? in
            if case Optional<Any>.none = value { return nil }
            return value
        }
        let data = try JSONSerialization.data(withJSONObject: cleaned)
        return String(decoding: data, as: UTF8.self)
    }
    #else
    public func handleAction(_ action: String, args: [String: Any], workspace: URL) async throws -> [String: Any] {
        throw IPCFrameError.remoteError(code: -32601, message: "当前平台不支持内置 WebKit 浏览器。")
    }
    #endif
}

#if canImport(WebKit) && canImport(UIKit)
extension AgentBrowserController: WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    public func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        // Handle target="_blank" links seamlessly inside the same Bot-controlled WebView (HTTPS-only)
        if let url = navigationAction.request.url,
           url.scheme?.lowercased() == "https",
           let host = url.host,
           !SafeHTTPSRedirects.isPrivateOrLoopbackHost(host) {
            webView.load(navigationAction.request)
        }
        return nil
    }

    public func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping () -> Void
    ) {
        recordLog("页面提示：\(String(message.prefix(60)))", actor: .system)
        completionHandler()
    }

    public func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (Bool) -> Void
    ) {
        recordLog("已自动取消页面确认弹窗", actor: .system)
        completionHandler(false)
    }

    public func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let target = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        let scheme = target.scheme?.lowercased() ?? ""
        if scheme == "about" && target.absoluteString.lowercased().hasPrefix("about:blank") {
            decisionHandler(.allow)
            return
        }
        if scheme == "https" {
            if let host = target.host, SafeHTTPSRedirects.isPrivateOrLoopbackHost(host) {
                decisionHandler(.cancel)
                return
            }
            if navigationAction.shouldPerformDownload {
                decisionHandler(.download)
                return
            }
            decisionHandler(.allow)
            return
        }
        decisionHandler(.cancel)
    }

    public func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        if let http = navigationResponse.response as? HTTPURLResponse {
            let disposition = (http.value(forHTTPHeaderField: "Content-Disposition") ?? "").lowercased()
            if disposition.contains("attachment") {
                decisionHandler(.download)
                return
            }
        }
        if !navigationResponse.canShowMIMEType {
            decisionHandler(.download)
            return
        }
        decisionHandler(.allow)
    }

    public func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
        if let pending = navigationContinuation {
            navigationContinuation = nil
            pending.resume(returning: ())
        }
    }

    public func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
        if let pending = navigationContinuation {
            navigationContinuation = nil
            pending.resume(returning: ())
        }
    }

    public func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping (URL?) -> Void
    ) {
        guard let workspace = workspaceDirectory else {
            recordLog("下载失败：未绑定工作区目录", actor: .system)
            completionHandler(nil)
            return
        }
        if response.expectedContentLength > 50 * 1024 * 1024 {
            recordLog("已拦截超过 50 MB 的网页下载", actor: .system)
            completionHandler(nil)
            return
        }
        let downloadsDir = workspace.appendingPathComponent("files/downloads", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: downloadsDir, withIntermediateDirectories: true)
            let safeName = Self.sanitizeDownloadFilename(suggestedFilename)
            var dest = downloadsDir.appendingPathComponent(safeName)
            var counter = 1
            let stem = dest.deletingPathExtension().lastPathComponent
            let ext = dest.pathExtension
            while FileManager.default.fileExists(atPath: dest.path) && counter < 100 {
                let numbered = ext.isEmpty ? "\(stem)-\(counter)" : "\(stem)-\(counter).\(ext)"
                dest = downloadsDir.appendingPathComponent(numbered)
                counter += 1
            }
            let relPath = "files/downloads/\(dest.lastPathComponent)"
            activeDownloads[ObjectIdentifier(download)] = relPath
            recordLog("正在下载 \(dest.lastPathComponent)…", actor: .system)
            completionHandler(dest)
        } catch {
            recordLog("无法创建下载目录：\(error.localizedDescription)", actor: .system)
            completionHandler(nil)
        }
    }

    public func downloadDidFinish(_ download: WKDownload) {
        if let relPath = activeDownloads.removeValue(forKey: ObjectIdentifier(download)) {
            lastDownloadedFile = relPath
            recordLog("已下载文件到 \(relPath)", actor: .system)
        }
    }

    public func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        activeDownloads.removeValue(forKey: ObjectIdentifier(download))
        recordLog("网页下载失败：\(error.localizedDescription)", actor: .system)
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        navigationTimeoutTask?.cancel()
        navigationTimeoutTask = nil
        if let pending = navigationContinuation {
            navigationContinuation = nil
            pending.resume()
        }
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        navigationTimeoutTask?.cancel()
        navigationTimeoutTask = nil
        if let pending = navigationContinuation {
            navigationContinuation = nil
            pending.resume(throwing: error)
        }
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        navigationTimeoutTask?.cancel()
        navigationTimeoutTask = nil
        if let pending = navigationContinuation {
            navigationContinuation = nil
            pending.resume(throwing: error)
        }
    }
}
#endif
