import AppKit
import OpenStreamCore
import WebKit

/// Opens a source's web player out of sight and reports the streams it starts.
///
/// WebKit gives an app no view of a page's network traffic, so a script injected into every
/// frame (cross-origin ones included, which is where players usually sit) reports what the page
/// asks for: XHR and fetch requests, their JSON answers, and media elements' sources. hls.js and
/// the like fetch their playlist that way, so the stream shows up as soon as the player starts.
/// This relies on third-party pages that change without notice.
nonisolated struct WebPlayerSniffer: WebPlayerSniffing {
    func streams(at page: URL, timeout: Duration) async -> [SniffedStream] {
        await SniffLimiter.shared.run {
            await SniffSession(page: page).run(timeout: timeout)
        }
    }
}

/// Whole web pages are heavy: at most five load at once.
actor SniffLimiter {
    static let shared = SniffLimiter(limit: 5)
    private let limit: Int
    private var running = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.limit = limit }

    func run<T: Sendable>(_ work: @Sendable () async -> T) async -> T {
        if running >= limit {
            await withCheckedContinuation { waiting.append($0) }
        } else {
            running += 1
        }
        defer {
            if waiting.isEmpty { running -= 1 } else { waiting.removeFirst().resume() }
        }
        return await work()
    }
}

@MainActor
private final class SniffSession: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
    private let page: URL
    private var webView: WKWebView?
    private var window: NSWindow?
    private var found: [URL: SniffedStream] = [:]
    private var continuation: CheckedContinuation<[SniffedStream], Never>?
    private var settleTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var pageLoaded = false

    init(page: URL) {
        self.page = page
    }

    func run(timeout: Duration) async -> [SniffedStream] {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                start(timeout: timeout)
            }
        } onCancel: {
            Task { @MainActor in self.finish() }
        }
    }

    private func start(timeout: Duration) {
        let configuration = WKWebViewConfiguration()
        // Nothing a source page stores outlives the search.
        configuration.websiteDataStore = .nonPersistent()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let controller = configuration.userContentController
        controller.add(WeakHandler(self), name: "openstream")
        controller.addUserScript(WKUserScript(source: Self.script, injectionTime: .atDocumentStart, forMainFrameOnly: false))

        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 960, height: 540), configuration: configuration)
        webView.customUserAgent = SourceHTTP.userAgent
        webView.navigationDelegate = self
        webView.uiDelegate = self
        self.webView = webView

        // Players only start in a page that's on screen somewhere; this window is, but far off
        // every display, fully transparent and never key.
        let window = NSWindow(contentRect: CGRect(x: -20000, y: -20000, width: 960, height: 540),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.transient, .ignoresCycle, .stationary]
        window.contentView = webView
        window.orderBack(nil)
        self.window = window

        var request = URLRequest(url: page)
        request.setValue("\(page.scheme ?? "https")://\(page.host() ?? "")/", forHTTPHeaderField: "Referer")
        webView.load(request)

        timeoutTask = Task {
            try? await Task.sleep(for: timeout)
            finish()
        }
    }

    private func finish() {
        guard let continuation else { return }
        self.continuation = nil
        settleTask?.cancel()
        timeoutTask?.cancel()
        webView?.stopLoading()
        webView?.configuration.userContentController.removeAllScriptMessageHandlers()
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView?.loadHTMLString("", baseURL: nil)
        window?.contentView = nil
        window?.close()
        webView = nil
        window = nil
        continuation.resume(returning: Array(found.values))
    }

    // MARK: Reports from the page

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        let frame = (body["frame"] as? String).flatMap(URL.init(string:))
        #if DEBUG
        if ProcessInfo.processInfo.environment["OPENSTREAM_PROBE_TRACE"] != nil {
            let what = (body["url"] as? String) ?? "body \(((body["body"] as? String) ?? "").prefix(400))"
            FileHandle.standardError.write(Data("trace: [\(frame?.host() ?? "?")] \(what.prefix(400))\n".utf8))
        }
        #endif
        if let link = body["url"] as? String {
            add(link, frame: frame, quality: nil)
        }
        if let text = body["body"] as? String, text.first == "{" || text.first == "[",
           let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) {
            walk(json, frame: frame, quality: nil)
        }
    }

    /// Players often get their sources as JSON ({ file, label } and the like) before asking.
    private func walk(_ value: Any, frame: URL?, quality: String?) {
        if let object = value as? [String: Any] {
            let quality = (object["quality"] as? String) ?? (object["label"] as? String) ?? quality
            // Headers a page's data says its stream needs: vidlink's CloudFront cookies.
            let headers = ((object["playlistHeaders"] ?? object["headers"]) as? [String: Any])?
                .compactMapValues { $0 as? String } ?? [:]
            for key in ["url", "file", "src", "source", "playlist"] {
                if let link = object[key] as? String { add(link, frame: frame, quality: quality, headers: headers) }
            }
            for child in object.values { walk(child, frame: frame, quality: quality) }
        } else if let array = value as? [Any] {
            for child in array { walk(child, frame: frame, quality: quality) }
        }
    }

    private func add(_ link: String, frame: URL?, quality: String?, headers: [String: String] = [:]) {
        guard continuation != nil, let url = URL(string: link, relativeTo: frame)?.absoluteURL,
              Self.isStream(url)
        else { return }
        // The same link seen again with the headers it needs (from the page's data) gets them.
        if var known = found[url] {
            if known.headers.isEmpty, !headers.isEmpty { known.headers = headers; found[url] = known }
            return
        }
        found[url] = SniffedStream(url: url, frame: frame, qualityHint: quality, headers: headers)
        // Pages often ask for several renditions in a row; wait a moment for the rest.
        settleTask?.cancel()
        settleTask = Task {
            try? await Task.sleep(for: .milliseconds(1500))
            guard !Task.isCancelled else { return }
            finish()
        }
    }

    static func isStream(_ url: URL) -> Bool {
        guard url.scheme == "https" || url.scheme == "http" else { return false }
        let text = url.absoluteString.lowercased()
        if ["googleads", "doubleclick", "/ads/", "vast", "telemetry", "analytics"].contains(where: text.contains) {
            return false
        }
        let path = url.path.lowercased()
        // Players load short placeholder clips before the film; those are never the stream.
        if ["demo", "sample", "preroll", "placeholder", "intro.mp4"].contains(where: path.contains) { return false }
        return path.hasSuffix(".m3u8") || path.hasSuffix(".mp4") || path.hasSuffix(".mpd") || text.contains(".m3u8?")
    }

    // MARK: Keeping to the player

    /// Ads navigate the page away or open windows. Until the first page has loaded, redirects
    /// (some players move to their own domain) are followed; after it, the page stays on its site.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard action.targetFrame?.isMainFrame == true, let host = action.request.url?.host() else { return .allow }
        if !pageLoaded { return .allow }
        return Self.root(host) == Self.root(webView.url?.host() ?? page.host() ?? "") ? .allow : .cancel
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageLoaded = true
    }

    #if DEBUG
    /// Debug trace of every frame the page loads (OPENSTREAM_PROBE_TRACE).
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        if ProcessInfo.processInfo.environment["OPENSTREAM_PROBE_TRACE"] != nil {
            let status = (navigationResponse.response as? HTTPURLResponse)?.statusCode ?? 0
            FileHandle.standardError.write(Data("trace: frame \(navigationResponse.isForMainFrame ? "main" : "sub") \(status) \(navigationResponse.response.url?.absoluteString.prefix(160) ?? "")\n".utf8))
        }
        return .allow
    }
    #endif

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        nil
    }

    private static func root(_ host: String) -> String {
        host.split(separator: ".").suffix(2).joined(separator: ".")
    }

    /// Reports every request, JSON answer and media source to the app, in every frame; mutes
    /// whatever plays and nudges players that wait for a click.
    private static let script = """
    (function() {
      if (window.__openstream) return; window.__openstream = true;
      // The page sits in a window nobody sees; players that wait for a visible tab, and frames
      // that load lazily, would never start.
      try {
        Object.defineProperty(document, 'visibilityState', { get: function() { return 'visible'; }, configurable: true });
        Object.defineProperty(document, 'hidden', { get: function() { return false; }, configurable: true });
        document.hasFocus = function() { return true; };
      } catch (_) {}
      new MutationObserver(function() {
        document.querySelectorAll('iframe[loading="lazy"]').forEach(function(f) { f.loading = 'eager'; });
      }).observe(document, { childList: true, subtree: true });
      const post = (data) => { try { data.frame = location.href; window.webkit.messageHandlers.openstream.postMessage(data); } catch (_) {} };
      const absolute = (u) => { try { return new URL(u, location.href).href; } catch (_) { return null; } };
      const open = XMLHttpRequest.prototype.open;
      XMLHttpRequest.prototype.open = function(method, url) {
        const link = absolute(url); if (link) post({ url: link });
        this.addEventListener('load', function() {
          try { if (typeof this.responseText === 'string' && this.responseText.length < 400000) post({ body: this.responseText }); } catch (_) {}
        });
        return open.apply(this, arguments);
      };
      const originalFetch = window.fetch;
      window.fetch = function(input) {
        const link = absolute(typeof input === 'string' ? input : (input && input.url));
        if (link) post({ url: link });
        return originalFetch.apply(this, arguments).then(function(response) {
          try {
            const type = response.headers.get('content-type') || '';
            if (type.includes('json') || type.includes('text')) response.clone().text().then(function(t) { if (t.length < 400000) post({ body: t }); }).catch(function() {});
          } catch (_) {}
          return response;
        });
      };
      const media = HTMLMediaElement.prototype;
      const srcSetter = Object.getOwnPropertyDescriptor(media, 'src').set;
      Object.defineProperty(media, 'src', { set: function(v) { const link = absolute(v); if (link) post({ url: link }); this.muted = true; return srcSetter.call(this, v); },
        get: Object.getOwnPropertyDescriptor(media, 'src').get, configurable: true });
      const play = media.play;
      media.play = function() { this.muted = true; return play.apply(this, arguments); };
      window.open = function() { return null; };
      let attempts = 0;
      const timer = setInterval(function() {
        attempts++;
        document.querySelectorAll('video, video source').forEach(function(el) {
          const link = absolute(el.currentSrc || el.src); if (link) post({ url: link });
        });
        document.querySelectorAll('video').forEach(function(v) { v.muted = true; const p = v.play(); if (p && p.catch) p.catch(function() {}); });
        const button = document.querySelector('.vjs-big-play-button, .jw-display-icon-container, .plyr__control--overlaid, #play, .play-button, .play-btn, [aria-label="Play"], button[class*="play"]');
        if (button) { try { button.click(); } catch (_) {} }
        if (attempts >= 12) clearInterval(timer);
      }, 1000);
    })();
    """
}

/// WKUserContentController keeps its handlers strongly; this breaks the cycle.
private final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: (any WKScriptMessageHandler)?

    init(_ target: any WKScriptMessageHandler) { self.target = target }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}
