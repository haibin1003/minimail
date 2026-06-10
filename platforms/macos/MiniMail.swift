import Cocoa
import WebKit
import SwiftUI

/// 文件日志（总能看到输出）
private let logQueue = DispatchQueue(label: "log")
private func logToFile(_ msg: String) {
    let ts = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
    logQueue.async {
        if let handle = FileHandle(forWritingAtPath: "/tmp/MiniMail_debug.log") {
            handle.seekToEndOfFile()
            handle.write("[\(ts)] \(msg)\n".data(using: .utf8)!)
            handle.closeFile()
        } else {
            try? "[\(ts)] \(msg)\n".write(toFile: "/tmp/MiniMail_debug.log", atomically: true, encoding: .utf8)
        }
    }
}

// MARK: - 全局桥接（不受 SwiftUI / AppDelegate 初始化顺序影响）
private var globalWebView: WKWebView?  // strong 引用，确保菜单能访问

// MARK: - 配置
enum AppConfig {
    static let targetURL = "https://mail.chinamobile.com/webmail/se/mail/m.do?sid=01vLltoqtt9MTNTClrSMgJHTtOOx770M000004&from=ADDR&r=0.5574358567391762"
    static let windowTitle = "中国移动邮箱"
    static let windowWidth: CGFloat = 1200
    static let windowHeight: CGFloat = 800
    static let showNavigationBar = false
    static let customUserAgent: String? = nil
}

// MARK: - 跨启动共享的进程池
private let sharedProcessPool: WKProcessPool = {
    let pool = WKProcessPool()
    return pool
}()

// MARK: - 键盘快捷键设置
class KeyboardShortcutSettings: ObservableObject {
    static let shared = KeyboardShortcutSettings()

    enum Preset: String, CaseIterable, Identifiable {
        case cmdBracket = "cmd_bracket"
        case cmdArrow   = "cmd_arrow"
        case cmdComma   = "cmd_comma"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .cmdBracket: return "Safari 风格"
            case .cmdArrow:   return "方向键风格"
            case .cmdComma:   return "相邻键风格"
            }
        }

        var backModifiers: NSEvent.ModifierFlags { [.command] }
        var backKeyCode: UInt16 {
            switch self {
            case .cmdBracket: return 33   // [
            case .cmdArrow:   return 123  // ←
            case .cmdComma:   return 43   // ,
            }
        }
        var forwardKeyCode: UInt16 {
            switch self {
            case .cmdBracket: return 30   // ]
            case .cmdArrow:   return 124  // →
            case .cmdComma:   return 47   // .
            }
        }
        var forwardModifiers: NSEvent.ModifierFlags { [.command] }

        var backLabel: String {
            switch self {
            case .cmdBracket: return "⌘ ["
            case .cmdArrow:   return "⌘ ←"
            case .cmdComma:   return "⌘ ,"
            }
        }
        var forwardLabel: String {
            switch self {
            case .cmdBracket: return "⌘ ]"
            case .cmdArrow:   return "⌘ →"
            case .cmdComma:   return "⌘ ."
            }
        }
    }

    @Published var preset: Preset {
        didSet { save() }
    }

    private let presetKey = "shortcut_preset"

    init() {
        if let raw = UserDefaults.standard.string(forKey: presetKey),
           let p = Preset(rawValue: raw) {
            preset = p
        } else {
            preset = .cmdBracket
        }
    }

    func save() {
        UserDefaults.standard.set(preset.rawValue, forKey: presetKey)
    }
}

// MARK: - 键盘快捷键监听
class KeyboardShortcutManager {
    private var monitor: Any?

    init() {}

    func start() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let settings = KeyboardShortcutSettings.shared
            guard let webView = globalWebView else { return event }

            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let expected = NSEvent.ModifierFlags.command

            // 只处理 Cmd 组合键
            guard flags == expected else { return event }

            if event.keyCode == settings.preset.backKeyCode {
                if webView.canGoBack {
                    webView.goBack()
                    logToFile("[快捷键] 后退")
                    return nil
                }
            }

            if event.keyCode == settings.preset.forwardKeyCode {
                if webView.canGoForward {
                    webView.goForward()
                    logToFile("[快捷键] 前进")
                    return nil
                }
            }

            return event
        }
    }

    func stop() {
        if let m = monitor {
            NSEvent.removeMonitor(m)
            monitor = nil
        }
    }

    deinit { stop() }
}

struct CookieManager {
    static let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("MiniMail")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("cookies.json")
    }()

    static let urlFileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("MiniMail")
        return dir.appendingPathComponent("last_url.txt")
    }()

    /// 保存 cookies（给无过期时间的 session cookie 加上 30 天过期，确保跨进程持久化）
    static func saveCookies(from store: WKHTTPCookieStore) {
        store.getAllCookies { cookies in
            guard !cookies.isEmpty else { return }
            let thirtyDays: TimeInterval = 30 * 24 * 3600
            let dicts = cookies.map { cookie -> [String: Any] in
                var d: [String: Any] = [:]
                d["name"] = cookie.name
                d["value"] = cookie.value
                d["domain"] = cookie.domain
                d["path"] = cookie.path
                d["secure"] = cookie.isSecure
                d["httpOnly"] = cookie.isHTTPOnly
                d["expiresDate"] = (cookie.expiresDate ?? Date(timeIntervalSinceNow: thirtyDays)).timeIntervalSince1970
                d["sameSitePolicy"] = cookie.sameSitePolicy?.rawValue ?? "strict"
                return d
            }
            if let data = try? JSONSerialization.data(withJSONObject: dicts, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: fileURL, options: .atomic)
                print("[CookieManager] 已保存 \(cookies.count) 个 cookies")
            }
        }
    }

    /// 从 JSON 恢复 cookies
    static func loadCookies() -> [HTTPCookie] {
        guard let data = try? Data(contentsOf: fileURL),
              let dicts = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }

        var cookies: [HTTPCookie] = []
        for d in dicts {
            var props: [HTTPCookiePropertyKey: Any] = [:]
            props[.name] = d["name"] as? String ?? ""
            props[.value] = d["value"] as? String ?? ""
            props[.domain] = d["domain"] as? String ?? ""
            props[.path] = d["path"] as? String ?? "/"
            props[.secure] = (d["secure"] as? Bool) ?? false
            props[.init("HttpOnly")] = (d["httpOnly"] as? Bool) ?? false
            if let ts = d["expiresDate"] as? TimeInterval {
                props[.expires] = Date(timeIntervalSince1970: ts)
            }
            if let cookie = HTTPCookie(properties: props) {
                cookies.append(cookie)
            }
        }
        print("[CookieManager] 读取到 \(cookies.count) 个 cookies")
        return cookies
    }

    /// 注入 cookies 到 WKHTTPCookieStore
    static func restoreCookies(into store: WKHTTPCookieStore, completion: @escaping () -> Void) {
        let cookies = loadCookies()
        guard !cookies.isEmpty else {
            completion()
            return
        }
        let group = DispatchGroup()
        for cookie in cookies {
            group.enter()
            store.setCookie(cookie) { group.leave() }
        }
        group.notify(queue: .main) {
            print("[CookieManager] 已注入 \(cookies.count) 个 cookies")
            completion()
        }
    }

    static func saveLastURL(_ url: URL) {
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            try? url.absoluteString.write(to: urlFileURL, atomically: true, encoding: .utf8)
            return
        }
        if let queryItems = comps.queryItems {
            comps.queryItems = queryItems.filter { $0.name != "r" }
        }
        let cleanURL = comps.url ?? url
        try? cleanURL.absoluteString.write(to: urlFileURL, atomically: true, encoding: .utf8)
    }

    static func loadLastURL() -> String? {
        guard let data = try? String(contentsOf: urlFileURL, encoding: .utf8),
              !data.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return data.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
        try? FileManager.default.removeItem(at: urlFileURL)
    }
}

// MARK: - WKWebView 封装
struct WebView: NSViewRepresentable {
    let url: URL
    let navigationDelegate: WebViewNavigationDelegate?
    let uiDelegate: WebViewUIDelegate?
    let webViewRef: ((WKWebView) -> Void)?
    let onNewWebView: ((WKWebView) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.processPool = sharedProcessPool
        config.websiteDataStore = WKWebsiteDataStore.default()
        config.allowsAirPlayForMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

        // 启用 Web Inspector（macOS 上右键可检查元素）
        if #available(macOS 13.3, *) {
            config.preferences.isElementFullscreenEnabled = true
        }
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.customUserAgent = AppConfig.customUserAgent

        if let navDelegate = navigationDelegate {
            webView.navigationDelegate = navDelegate
        }
        if let uiDel = uiDelegate {
            webView.uiDelegate = uiDel
        }

        DispatchQueue.main.async { [weak webView] in
            guard let wv = webView else { return }
            self.webViewRef?(wv)
            self.onNewWebView?(wv)
        }

        // 先恢复 cookies，等 300ms 让网络进程同步，再加载页面
        CookieManager.restoreCookies(into: config.websiteDataStore.httpCookieStore) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                webView.load(URLRequest(url: url))
            }
        }

        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    class Coordinator: NSObject {}
}

// MARK: - 导航代理
class WebViewNavigationDelegate: NSObject, WKNavigationDelegate {
    var onTitleChange: ((String) -> Void)?
    var onLoadingChange: ((Bool) -> Void)?
    var onProgressChange: ((Double) -> Void)?

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        onLoadingChange?(false)
        if let title = webView.title {
            onTitleChange?(title)
        }

        // 保存 URL 和 cookies
        if let url = webView.url,
           url.absoluteString.contains("/webmail/se/mail/") {
            CookieManager.saveLastURL(url)
            CookieManager.saveCookies(from: webView.configuration.websiteDataStore.httpCookieStore)
        }

        // 开始轮询未读邮件数量
        if let statusBar = StatusBarController.shared {
            statusBar.webView = webView
            statusBar.startUnreadPolling()
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        onLoadingChange?(false)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        onLoadingChange?(false)
        let html = """
        <html><body style="display:flex;align-items:center;justify-content:center;font-family:-apple-system;background:#f5f5f7">
        <div style="text-align:center;color:#666">
        <h2>⚠️ 加载失败</h2>
        <p>\(error.localizedDescription)</p>
        </div></body></html>
        """
        webView.loadHTMLString(html, baseURL: nil)
    }

    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(.performDefaultHandling, nil)
    }
}

// MARK: - UI 代理
class WebViewUIDelegate: NSObject, WKUIDelegate {
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            DispatchQueue.main.async {
                webView.load(URLRequest(url: url))
            }
        }
        return nil
    }

    // 处理 JS alert() — 否则 alert 会静默失败
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "网页提示"
            alert.informativeText = message
            alert.addButton(withTitle: "确定")
            alert.runModal()
            completionHandler()
        }
    }
}

// MARK: - 导航栏
struct NavigationBar: View {
    @ObservedObject var state: WebViewState
    let reloadAction: () -> Void
    let goBackAction: () -> Void
    let goForwardAction: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: goBackAction) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .medium))
            }
            .buttonStyle(.borderless)
            .disabled(!state.canGoBack)

            Button(action: goForwardAction) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .medium))
            }
            .buttonStyle(.borderless)
            .disabled(!state.canGoForward)

            Button(action: reloadAction) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 14, weight: .medium))
            }
            .buttonStyle(.borderless)

            Text(state.isLoading ? "加载中..." : state.pageTitle)
                .lineLimit(1)
                .truncationMode(.middle)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)

            if state.isLoading {
                ProgressView()
                    .scaleEffect(0.7)
                    .frame(width: 16, height: 16)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }
}

// MARK: - WebView 状态
class WebViewState: ObservableObject {
    @Published var pageTitle: String = AppConfig.windowTitle
    @Published var isLoading: Bool = false
    @Published var canGoBack: Bool = false
    @Published var canGoForward: Bool = false
}

// MARK: - 主视图
struct ContentView: View {
    @StateObject private var state = WebViewState()
    @State private var webView: WKWebView?
    @State private var navDelegate = WebViewNavigationDelegate()
    @State private var uiDelegate = WebViewUIDelegate()

    private var launchURL: URL {
        if let saved = CookieManager.loadLastURL(),
           let url = URL(string: saved) {
            return url
        }
        return URL(string: AppConfig.targetURL)!
    }

    var body: some View {
        VStack(spacing: 0) {
            if AppConfig.showNavigationBar {
                NavigationBar(
                    state: state,
                    reloadAction: { webView?.reload() },
                    goBackAction: { webView?.goBack() },
                    goForwardAction: { webView?.goForward() }
                )
                Divider()
            }

            WebView(
                url: launchURL,
                navigationDelegate: navDelegate,
                uiDelegate: uiDelegate,
                webViewRef: { wv in
                    self.webView = wv
                    globalWebView = wv  // 全局桥接，不受初始化顺序影响
                    StatusBarController.shared?.webView = wv
                    self.state.canGoBack = wv.canGoBack
                    self.state.canGoForward = wv.canGoForward
                },
                onNewWebView: { wv in
                    wv.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                        print("[启动诊断] WKWebView 初始化后有 \(cookies.count) 个 cookies")
                        for c in cookies {
                            print("  - \(c.name)=\(c.value.prefix(20))...  domain=\(c.domain)")
                        }
                    }
                }
            )
        }
        .onAppear {
            navDelegate.onTitleChange = { title in
                DispatchQueue.main.async { state.pageTitle = title }
            }
            navDelegate.onLoadingChange = { loading in
                DispatchQueue.main.async { state.isLoading = loading }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            if let wv = webView {
                CookieManager.saveCookies(from: wv.configuration.websiteDataStore.httpCookieStore)
            }
        }
    }
}

// MARK: - 菜单栏图标控制器
class StatusBarController: NSObject, NSMenuDelegate {
    static weak var shared: StatusBarController?
    private var statusBarItem: NSStatusItem!
    weak var webView: WKWebView?
    private var unreadCount: Int = 0
    private var unreadPollTimer: Timer?
    /// 菜单项的引用，方便动态更新
    private var unreadMenuItem: NSMenuItem?
    /// 显示/隐藏菜单项的引用，方便动态更新文字
    private var toggleMenuItem: NSMenuItem?
    /// 跟踪窗口可见状态（不依赖 NSApp.windows 的时序）
    private var windowVisible: Bool = false

    override init() {
        super.init()
        StatusBarController.shared = self
        createStatusItem()
        // 监听窗口状态变化，同步菜单文字
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidMiniaturize(_:)),
            name: NSWindow.didMiniaturizeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidDeminiaturize(_:)),
            name: NSWindow.didDeminiaturizeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidBecomeKey(_:)),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )
    }

    /// 当状态栏菜单即将打开时，同步当前窗口状态
    func menuWillOpen(_ menu: NSMenu) {
        updateMenuItemsState()
    }

    /// 根据当前窗口可见状态，更新所有菜单项
    private func updateMenuItemsState() {
        let windowVisible = NSApp.windows.first?.isVisible ?? false
        if windowVisible {
            toggleMenuItem?.title = "隐藏窗口"
            toggleMenuItem?.image = NSImage(systemSymbolName: "macwindow", accessibilityDescription: "隐藏窗口")
        } else {
            toggleMenuItem?.title = "显示窗口"
            toggleMenuItem?.image = NSImage(systemSymbolName: "macwindow", accessibilityDescription: "显示窗口")
        }
    }

    private func createStatusItem() {
        statusBarItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusBarButton()

        let menu = NSMenu()
        menu.delegate = self

        let toggleItem = NSMenuItem(title: "显示窗口", action: #selector(toggleWindow), keyEquivalent: "")
        toggleItem.target = self
        toggleItem.image = NSImage(systemSymbolName: "macwindow", accessibilityDescription: "显示窗口")
        menu.addItem(toggleItem)
        toggleMenuItem = toggleItem

        menu.addItem(NSMenuItem.separator())

        // 未读邮件（保留引用以便动态更新标题）
        let unreadItem = NSMenuItem(title: "未读邮件", action: #selector(goToUnread), keyEquivalent: "3")
        unreadItem.target = self
        unreadItem.image = NSImage(systemSymbolName: "envelope.badge", accessibilityDescription: "未读邮件")
        menu.addItem(unreadItem)
        unreadMenuItem = unreadItem

        // 收件箱
        let inboxItem = NSMenuItem(title: "收件箱", action: #selector(goToInbox), keyEquivalent: "1")
        inboxItem.target = self
        inboxItem.image = NSImage(systemSymbolName: "tray.full", accessibilityDescription: "收件箱")
        menu.addItem(inboxItem)

        // 已发送
        let sentItem = NSMenuItem(title: "已发送", action: #selector(goToSent), keyEquivalent: "2")
        sentItem.target = self
        sentItem.image = NSImage(systemSymbolName: "paperplane", accessibilityDescription: "已发送")
        menu.addItem(sentItem)

        menu.addItem(NSMenuItem.separator())

        let refreshItem = NSMenuItem(title: "刷新", action: #selector(refreshCurrentPage), keyEquivalent: "r")
        refreshItem.target = self
        refreshItem.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "刷新")
        menu.addItem(refreshItem)

        menu.addItem(NSMenuItem.separator())

        // 快捷键设置
        let shortcutSettingsItem = NSMenuItem(title: "快捷键设置...", action: #selector(showShortcutSettings), keyEquivalent: "")
        shortcutSettingsItem.target = self
        shortcutSettingsItem.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "快捷键设置")
        menu.addItem(shortcutSettingsItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "退出", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        quitItem.image = NSImage(systemSymbolName: "power", accessibilityDescription: "退出")
        menu.addItem(quitItem)

        statusBarItem.menu = menu
    }

    /// 更新状态栏按钮文字（图标 + 未读数）
    private func updateStatusBarButton() {
        guard let button = statusBarItem?.button else { return }
        if unreadCount > 0 {
            button.title = "\(unreadCount)"
            // 有未读时用 filled 图标
            button.image = NSImage(systemSymbolName: "envelope.badge.fill", accessibilityDescription: "有 \(unreadCount) 封未读邮件")
        } else {
            button.title = ""
            button.image = NSImage(systemSymbolName: "envelope.fill", accessibilityDescription: "邮箱 - 无未读")
        }
    }

    /// 更新菜单中"未读邮件"项的标题
    private func updateUnreadMenuItem() {
        if unreadCount > 0 {
            unreadMenuItem?.title = "未读邮件 (\(unreadCount))"
        } else {
            unreadMenuItem?.title = "未读邮件"
        }
    }

    /// 如果图标丢了，重新创建（外部调用）
    func ensureVisible() {
        if statusBarItem == nil || statusBarItem.button == nil {
            createStatusItem()
        }
    }

    // MARK: - 未读邮件数量查询

    /// 开始定时轮询未读邮件数（页面加载完成后调用）
    func startUnreadPolling() {
        stopUnreadPolling()
        // 首次快速查询
        queryUnreadCount()
        // 之后每 30 秒查一次
        unreadPollTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.queryUnreadCount()
        }
    }

    func stopUnreadPolling() {
        unreadPollTimer?.invalidate()
        unreadPollTimer = nil
    }


    /// 注入 JS 查询未读邮件数量
    func queryUnreadCount() {
        guard let wv = webView ?? globalWebView else { return }

        let js = """
        (function() {
            // 精确匹配 data-unread 属性
            var el = document.querySelector('[data-unread]');
            if (el) {
                var n = parseInt(el.getAttribute('data-unread'));
                if (!isNaN(n)) return String(n);
            }
            return '0';
        })()
        """

        wv.evaluateJavaScript(js) { [weak self] result, error in
            guard let self = self else { return }
            if let s = result as? String, let count = Int(s) {
                if count != self.unreadCount {
                    self.unreadCount = count
                    logToFile("[未读] 更新未读数: \(count)")
                    DispatchQueue.main.async {
                        self.updateStatusBarButton()
                        self.updateUnreadMenuItem()
                    }
                }
            } else if let err = error {
                logToFile("[未读] 查询失败: \(err.localizedDescription)")
            }
        }
    }

    private func clickFolder(id: String, name: String) {
        logToFile("[导航] clickFolder 被调用: id=\(id), name=\(name)")
        // 优先用 self.webView，如果 nil 则用全局桥接
        guard let wv = webView ?? globalWebView else {
            logToFile("[导航] webView 为 nil（全局桥接也 nil）")
            print("[导航] webView 为 nil（全局桥接也 nil）")
            return
        }
        // 同步到 self.webView，以便后续快速访问
        if webView == nil { webView = wv }
        logToFile("[导航] 开始点击 \(name)(id=\(id))")
        print("[导航] 开始点击 \(name)(id=\(id))")
        let js = """
        document.getElementById('span_\(id)').click();
        """
        print("[导航] 注入 JS (len=\(js.count))")
        logToFile("[导航] 注入 JS (len=\(js.count))")
        wv.evaluateJavaScript(js) { result, error in
            if let r = result as? String {
                print("[导航] \(name): \(r)")
                logToFile("[导航] \(name): \(r)")
            } else if let err = error {
                print("[导航] \(name) 失败: \(err.localizedDescription)")
                logToFile("[导航] \(name) 失败: \(err.localizedDescription)")
            }
            // 导航后查询一次未读数（页面可能已更新）
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.queryUnreadCount()
            }
        }
    }

    @objc func goToInbox() {
        showWindow()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.clickFolder(id: "1", name: "收件箱")
        }
    }

    @objc func goToSent() {
        showWindow()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.clickFolder(id: "3", name: "已发送")
        }
    }

    @objc func goToUnread() {
        showWindow()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.clickFolder(id: "0", name: "未读邮件")
        }
    }

    @objc func toggleWindow() {
        logToFile("[toggleWindow] 被调用，当前 windowVisible=\(windowVisible)")
        if windowVisible {
            // 窗口可见 → 隐藏
            if let window = NSApp.windows.first {
                window.orderOut(nil)
            }
            windowVisible = false
            toggleMenuItem?.title = "显示窗口"
            toggleMenuItem?.image = NSImage(systemSymbolName: "macwindow", accessibilityDescription: "显示窗口")
            logToFile("[toggleWindow] 窗口已隐藏")
        } else {
            // 窗口不可见 → 显示
            showWindow()
            logToFile("[toggleWindow] 窗口已显示")
        }
    }

    @objc func showWindow() {
        logToFile("[showWindow] 被调用")
        if let window = NSApp.windows.first {
            logToFile("[showWindow] 找到窗口: \(window.title)")
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        } else if let appDelegate = NSApp.delegate as? AppDelegate,
                  let window = appDelegate.mainWindow {
            logToFile("[showWindow] 通过 AppDelegate 找到窗口: \(window.title)")
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        } else {
            logToFile("[showWindow] 未找到窗口！")
        }
        NSApp.activate(ignoringOtherApps: true)
        windowVisible = true
        toggleMenuItem?.title = "隐藏窗口"
        toggleMenuItem?.image = NSImage(systemSymbolName: "macwindow", accessibilityDescription: "隐藏窗口")
    }

    @objc func refreshCurrentPage() {
        guard let wv = webView ?? globalWebView else { return }
        wv.reload()
        logToFile("[导航] 刷新页面")
    }

    // MARK: - 窗口状态同步

    @objc func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window == NSApp.windows.first else { return }
        windowVisible = false
        toggleMenuItem?.title = "显示窗口"
        toggleMenuItem?.image = NSImage(systemSymbolName: "macwindow", accessibilityDescription: "显示窗口")
    }

    @objc func windowDidMiniaturize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window == NSApp.windows.first else { return }
        windowVisible = false
        toggleMenuItem?.title = "显示窗口"
        toggleMenuItem?.image = NSImage(systemSymbolName: "macwindow", accessibilityDescription: "显示窗口")
    }

    @objc func windowDidDeminiaturize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window == NSApp.windows.first else { return }
        windowVisible = true
        toggleMenuItem?.title = "隐藏窗口"
        toggleMenuItem?.image = NSImage(systemSymbolName: "macwindow", accessibilityDescription: "隐藏窗口")
    }

    @objc func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window == NSApp.windows.first else { return }
        windowVisible = true
        toggleMenuItem?.title = "隐藏窗口"
        toggleMenuItem?.image = NSImage(systemSymbolName: "macwindow", accessibilityDescription: "隐藏窗口")
    }

    @objc func quitApp() {
        // 退出前保存 cookies
        NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)
        NSApp.terminate(nil)
    }

    // MARK: - 快捷键设置弹窗

    private lazy var settingsPopover: NSPopover = {
        let popover = NSPopover()
        popover.contentViewController = NSHostingController(rootView: ShortcutSettingsView())
        popover.behavior = .transient
        // 预热：提前加载视图，确保布局就绪
        _ = popover.contentViewController?.view
        return popover
    }()

    @objc func showShortcutSettings() {
        guard let button = statusBarItem?.button, !button.isHiddenOrHasHiddenAncestor else { return }

        if settingsPopover.isShown {
            settingsPopover.close()
            return
        }

        settingsPopover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        settingsPopover.contentViewController?.view.window?.makeKey()
    }
}

// MARK: - 快捷键设置视图
struct ShortcutSettingsView: View {
    @StateObject private var settings = KeyboardShortcutSettings.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 标题
            HStack(spacing: 6) {
                Image(systemName: "keyboard")
                    .foregroundColor(.accentColor)
                    .font(.system(size: 13))
                Text("快捷键设置")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
            }
            .padding(.bottom, 14)

            // 方案列表
            VStack(spacing: 0) {
                ForEach(KeyboardShortcutSettings.Preset.allCases) { preset in
                    presetCard(preset)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            settings.preset = preset
                            dismiss()
                        }
                }
            }
        }
        .padding()
        .frame(width: 280)
    }

    @ViewBuilder
    private func presetCard(_ preset: KeyboardShortcutSettings.Preset) -> some View {
        let isSelected = settings.preset == preset
        VStack(alignment: .leading, spacing: 6) {
            // 第一行：选中标记 + 方案名
            HStack(spacing: 6) {
                Image(systemName: isSelected ? "record.circle" : "circle")
                    .font(.system(size: 11))
                    .foregroundColor(isSelected ? .accentColor : Color(.separatorColor))
                Text(preset.displayName)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(isSelected ? .primary : .secondary)
            }

            // 第二行：后退 + 前进 按键（仿 macOS 键盘键帽风格）
            HStack(spacing: 16) {
                HStack(spacing: 4) {
                    Text("后退")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    keycapBadge(preset.backLabel)
                }
                HStack(spacing: 4) {
                    Text("前进")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    keycapBadge(preset.forwardLabel)
                }
            }
            .padding(.leading, 18)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
    }

    /// 仿 macOS 键盘键帽：浅灰底色 + 细边框 + 微阴影
    @ViewBuilder
    private func keycapBadge(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color(.controlBackgroundColor))
                    .shadow(color: .black.opacity(0.08), radius: 0.5, y: 0.5)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(Color(.separatorColor).opacity(0.4), lineWidth: 0.5)
            )
    }
}

// MARK: - App Delegate
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBar: StatusBarController?
    private var keyboardShortcutManager = KeyboardShortcutManager()
    fileprivate var mainWindow: NSWindow?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // 在 SwiftUI 接管之前就设好无 Dock 模式
        NSApp.setActivationPolicy(.accessory)

        // 单实例保护：PID 文件锁
        let lockFile = "/tmp/MiniMail.lock"
        if let oldPID = try? String(contentsOfFile: lockFile).trimmingCharacters(in: .whitespacesAndNewlines),
           let pid = pid_t(oldPID) {
            if kill(pid, 0) == 0 {
                // 旧进程还在运行，激活它并退出
                if let app = NSRunningApplication(processIdentifier: pid) {
                    if #available(macOS 14.0, *) {
                        app.activate()
                    } else {
                        app.activate(options: .activateIgnoringOtherApps)
                    }
                }
                NSApp.terminate(nil)
                return
            }
        }
        // 写入当前 PID
        try? "\(ProcessInfo.processInfo.processIdentifier)".write(toFile: lockFile, atomically: true, encoding: .utf8)

        // 注册退出时清理锁文件
        atexit {
            try? FileManager.default.removeItem(atPath: "/tmp/MiniMail.lock")
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 启动键盘快捷键监听
        keyboardShortcutManager.start()
        logToFile("keyboardShortcutManager started")
        // 立即隐藏所有已存在的窗口（同步执行，避免白屏闪烁）
        for window in NSApp.windows {
            window.title = "小邮箱"
            if window.isVisible {
                window.orderOut(nil)
                logToFile("  已隐藏窗口: \(window.title)")
            }
        }
        logToFile("applicationDidFinishLaunching: 开始")
        logToFile("  窗口数: \(NSApp.windows.count)")

        // 强制创建窗口：activation 会触发 SwiftUI WindowGroup 创建窗口
        // 再立即隐藏，确保后面 NSApp.windows 和 mainWindow 不为空
        if NSApp.windows.isEmpty {
            logToFile("  窗口为空，尝试激活以触发 SwiftUI 创建窗口")
            NSApp.activate(ignoringOtherApps: true)
            // 给 SwiftUI 一个 runloop 去创建窗口
            DispatchQueue.main.async {
                logToFile("  激活后窗口数: \(NSApp.windows.count), 窗口: \(NSApp.windows.map { $0.title })")
                // 强制创建后立即隐藏
                for window in NSApp.windows where window.isVisible {
                    window.orderOut(nil)
                    logToFile("  已隐藏窗口: \(window.title)")
                }
            }
        }

        logToFile("  → 调度创建 StatusBarController")
        DispatchQueue.main.async { [weak self] in
            logToFile("  → 创建 StatusBarController")
            self?.statusBar = StatusBarController()
            // 如果 webView 已经初始化了，同步过去（解决跨模块初始化 race）
            if let wv = globalWebView {
                self?.statusBar?.webView = wv
                logToFile("  → globalWebView 已存在，同步到 statusBar")
            }
            // 首次查询未读数（延迟等页面加载）
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                self?.statusBar?.startUnreadPolling()
            }
            // 1 秒后检查 status bar 是否可见，不可见则重试（菜单栏初始化 race 防护）
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self?.statusBar?.ensureVisible()
            }
        }

        // 启动后隐藏窗口
        DispatchQueue.main.async {
            for window in NSApp.windows where window.isVisible {
                window.orderOut(nil)
            }
        }

        // 监听窗口创建，保存引用
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidOpen(_:)),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )
    }

    @objc func windowDidOpen(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              mainWindow == nil else { return }
        window.title = "小邮箱"
        // 初始大小 = 屏幕的 60%
        if let screen = window.screen ?? NSScreen.main {
            let screenFrame = screen.visibleFrame
            let w = screenFrame.width * 0.6
            let h = screenFrame.height * 0.6
            let x = screenFrame.origin.x + (screenFrame.width - w) / 2
            let y = screenFrame.origin.y + (screenFrame.height - h) / 2
            window.setFrame(NSRect(x: x, y: y, width: w, height: h), display: true)
        }
        // 保存引用 + 窗口关闭时不销毁对象
        window.isReleasedWhenClosed = false
        mainWindow = window
    }

    // MARK: - NSApplicationDelegate
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false // 窗口关闭不退出应用
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            if let window = mainWindow ?? NSApp.windows.first {
                window.makeKeyAndOrderFront(nil)
                window.orderFrontRegardless()
            }
        }
        return true
    }
}

// MARK: - 应用入口
@main
struct MiniMailApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 600, minHeight: 400)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
