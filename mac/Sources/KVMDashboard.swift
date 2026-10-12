import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

// MARK: - Model

struct KVM: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var url: String
    var enabled = true
}

enum DashboardLayout: String, Codable, CaseIterable, Identifiable {
    case grid = "2 × 2", row = "1 row", column = "1 column", auto = "Auto"
    var id: String { rawValue }
}

enum Theme: String, Codable, CaseIterable, Identifiable {
    case dark = "Dark", light = "Light", system = "System"
    var id: String { rawValue }
}

struct Config: Codable {
    var kvms: [KVM]
    var layout: DashboardLayout = .grid
    var theme: Theme = .dark
    var showURL = true

    static let defaults = Config(kvms: [
        KVM(name: "ESX-01", url: "https://192.168.100.141/#/"),
        KVM(name: "ESX-02", url: "https://192.168.100.142/#/"),
        KVM(name: "ESX-03", url: "https://192.168.100.143/#/"),
        KVM(name: "ESX-04", url: "https://192.168.100.144/#/"),
    ])
}

// MARK: - Theme colors (VMware Clarity / Aria Operations)

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
                  green: CGFloat((hex >> 8) & 0xff) / 255,
                  blue: CGFloat(hex & 0xff) / 255, alpha: 1)
    }
}

extension Color {
    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(hex: dark) : NSColor(hex: light)
        })
    }
}

enum Clarity {
    static let bg = Color.dynamic(light: 0xfafafa, dark: 0x1b2a32)
    static let surface = Color.dynamic(light: 0xffffff, dark: 0x21333b)
    static let border = Color.dynamic(light: 0xcccccc, dark: 0x485764)
    static let text = Color.dynamic(light: 0x313131, dark: 0xe9ecef)
    static let muted = Color.dynamic(light: 0x666666, dark: 0xadbbc4)
    static let primary = Color.dynamic(light: 0x0072a3, dark: 0x49afd9)
    static let success = Color.dynamic(light: 0x3c8500, dark: 0x60b515)
    static let danger = Color.dynamic(light: 0xc21d00, dark: 0xf54f47)
}

// MARK: - Store

@MainActor
final class Store: ObservableObject {
    private static let key = "kvm-wall-config-v1"

    @Published var kvms: [KVM] { didSet { save() } }
    @Published var layout: DashboardLayout { didSet { save() } }
    @Published var theme: Theme { didSet { save(); applyAppearance() } }
    @Published var showURL: Bool { didSet { save() } }

    /// Pane shown alone in the window (maximize or full screen).
    @Published var maximized: UUID?
    /// Pane that put the window into full screen; cleared when full screen exits.
    @Published var fullScreenPane: UUID?

    private var webViews: [UUID: KVMWebView] = [:]

    init() {
        var cfg = Config.defaults
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode(Config.self, from: data) {
            cfg = saved
        }
        kvms = cfg.kvms
        layout = cfg.layout
        theme = cfg.theme
        showURL = cfg.showURL

        NotificationCenter.default.addObserver(forName: NSWindow.didExitFullScreenNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.fullScreenPane != nil else { return }
                self.fullScreenPane = nil
                self.maximized = nil
            }
        }
    }

    var config: Config {
        get { Config(kvms: kvms, layout: layout, theme: theme, showURL: showURL) }
        set { kvms = newValue.kvms; layout = newValue.layout; theme = newValue.theme; showURL = newValue.showURL }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    func applyAppearance() {
        switch theme {
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .system: NSApp.appearance = nil
        }
    }

    /// Web views are cached per KVM so re-ordering or changing layout never drops a session.
    func webView(for kvm: KVM) -> KVMWebView {
        if let existing = webViews[kvm.id], existing.homeURL == kvm.url { return existing }
        let view = KVMWebView(urlString: kvm.url)
        webViews[kvm.id] = view
        return view
    }

    func reloadAll() {
        webViews.values.forEach { $0.goHome() }
    }

    func pruneWebViews() {
        let live = Set(kvms.filter(\.enabled).map(\.id))
        for id in webViews.keys where !live.contains(id) { webViews[id] = nil }
    }

    func toggleMaximize(_ id: UUID) {
        maximized = maximized == id ? nil : id
    }

    func toggleFullScreen(_ id: UUID) {
        guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible }) else { return }
        if window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil) // exit; observer restores the grid
        } else {
            maximized = id
            fullScreenPane = id
            window.toggleFullScreen(nil)
        }
    }
}

// MARK: - Web view

final class KVMWebView: WKWebView, WKNavigationDelegate, WKUIDelegate, ObservableObject {
    let homeURL: String
    private let trustedHost: String?

    @Published var loaded = false
    @Published var errorText: String?

    init(urlString: String) {
        homeURL = urlString
        trustedHost = URL(string: urlString)?.host

        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default() // persists logins between launches
        cfg.mediaTypesRequiringUserActionForPlayback = []
        cfg.preferences.isElementFullscreenEnabled = true
        cfg.applicationNameForUserAgent = "Version/18.0 Safari/605.1.15"
        super.init(frame: .zero, configuration: cfg)

        navigationDelegate = self
        uiDelegate = self
        isInspectable = true // right-click → Inspect Element for debugging
        setValue(false, forKey: "drawsBackground")
        goHome()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func goHome() {
        loaded = false
        errorText = nil
        guard let url = URL(string: homeURL) else { errorText = "Invalid URL"; return }
        load(URLRequest(url: url))
    }

    // Accept the KVM's self-signed certificate, but only for the host this pane was configured with.
    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        if space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           space.host == trustedHost, let trust = space.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded = true
        errorText = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        fail(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        fail(error)
    }

    private func fail(_ error: Error) {
        if (error as NSError).code == NSURLErrorCancelled { return }
        loaded = false
        errorText = error.localizedDescription
    }

    // Microphone / camera requests from the KVM page itself.
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(origin.host == trustedHost ? .grant : .prompt)
    }

    // Links that open a new tab go to the default browser.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url { NSWorkspace.shared.open(url) }
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.runModal()
        completionHandler()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        completionHandler(alert.runModal() == .alertFirstButtonReturn)
    }
}

/// Hosts a cached web view; the web view is re-parented rather than recreated when SwiftUI rebuilds.
struct WebHost: NSViewRepresentable {
    let webView: KVMWebView

    func makeNSView(context: Context) -> NSView { attach(to: NSView()) }

    func updateNSView(_ container: NSView, context: Context) { _ = attach(to: container) }

    private func attach(to container: NSView) -> NSView {
        if webView.superview !== container {
            webView.removeFromSuperview()
            webView.frame = container.bounds
            webView.autoresizingMask = [.width, .height]
            container.addSubview(webView)
        }
        return container
    }
}

/// Stand-in for @State: the Command Line Tools ship without the SwiftUI macro plugin that @State needs.
final class Box<Value>: ObservableObject {
    @Published var value: Value
    init(_ value: Value) { self.value = value }
}

// MARK: - Dashboard

struct DashboardView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        let active = store.kvms.filter(\.enabled)
        Group {
            if active.isEmpty {
                VStack(spacing: 12) {
                    Text("No KVMs enabled").foregroundStyle(Clarity.muted)
                    SettingsLink { Text("Open Settings") }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let id = store.maximized, let kvm = active.first(where: { $0.id == id }) {
                PaneView(kvm: kvm, web: store.webView(for: kvm))
            } else {
                grid(active)
            }
        }
        .padding(store.fullScreenPane == nil ? 6 : 0)
        .background(Clarity.bg)
        .onChange(of: store.kvms) { store.pruneWebViews() }
    }

    private func columns(for count: Int) -> Int {
        switch store.layout {
        case .grid: return 2
        case .row: return count
        case .column: return 1
        case .auto: return count <= 1 ? 1 : count <= 4 ? 2 : count <= 9 ? 3 : 4
        }
    }

    private func grid(_ items: [KVM]) -> some View {
        let cols = max(1, columns(for: items.count))
        let rows = stride(from: 0, to: items.count, by: cols).map { Array(items[$0 ..< min($0 + cols, items.count)]) }
        return VStack(spacing: 6) {
            ForEach(rows.indices, id: \.self) { r in
                HStack(spacing: 6) {
                    ForEach(rows[r]) { kvm in PaneView(kvm: kvm, web: store.webView(for: kvm)) }
                    ForEach(0 ..< (cols - rows[r].count), id: \.self) { _ in Color.clear }
                }
            }
        }
    }
}

struct PaneView: View {
    @EnvironmentObject var store: Store
    let kvm: KVM
    @ObservedObject var web: KVMWebView
    @StateObject private var hovering = Box(false)
    @StateObject private var hoverLabel = Box<String?>(nil)

    private var isFullScreen: Bool { store.fullScreenPane == kvm.id }
    private var isMaximized: Bool { store.maximized == kvm.id }

    var body: some View {
        VStack(spacing: 0) {
            if !isFullScreen { header }
            ZStack(alignment: .topTrailing) {
                Color.black
                WebHost(webView: web)
                if let error = web.errorText { errorOverlay(error) }
                if isFullScreen && hovering.value {
                    Button { store.toggleFullScreen(kvm.id) } label: {
                        Label("Exit Full Screen", systemImage: "arrow.down.right.and.arrow.up.left")
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(10)
                }
            }
            .onHover { hovering.value = $0 }
        }
        .background(Clarity.surface)
        .clipShape(RoundedRectangle(cornerRadius: isFullScreen ? 0 : 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Clarity.border, lineWidth: isFullScreen ? 0 : 1))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(web.errorText != nil ? Clarity.danger : web.loaded ? Clarity.success : Clarity.muted)
                .frame(width: 8, height: 8)
            Text(kvm.name).fontWeight(.semibold).foregroundStyle(Clarity.text)
            if store.showURL {
                Text(kvm.url).font(.caption).foregroundStyle(Clarity.muted).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if let label = hoverLabel.value {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(Clarity.primary)
                    .lineLimit(1)
                    .fixedSize()
                    .transition(.opacity)
            }
            iconButton("arrow.clockwise", "Reload") { web.goHome() }
            iconButton("arrow.up.right.square", "Open in browser") {
                if let url = URL(string: kvm.url) { NSWorkspace.shared.open(url) }
            }
            iconButton(isMaximized ? "rectangle.grid.2x2" : "square", isMaximized ? "Back to grid" : "Maximize in window") {
                store.toggleMaximize(kvm.id)
            }
            iconButton("arrow.up.left.and.arrow.down.right", "Full screen") { store.toggleFullScreen(kvm.id) }
        }
        .padding(.leading, 10).padding(.trailing, 4)
        .frame(height: 30)
        .background(Clarity.surface)
        .overlay(alignment: .bottom) { Rectangle().fill(Clarity.border).frame(height: 1) }
    }

    private func iconButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        HeaderIconButton(symbol: symbol, help: help, action: action) { inside in
            withAnimation(.easeOut(duration: 0.12)) {
                if inside { hoverLabel.value = help } else if hoverLabel.value == help { hoverLabel.value = nil }
            }
        }
    }

    private func errorOverlay(_ error: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle").font(.title).foregroundStyle(Clarity.danger)
            Text(error).foregroundStyle(.white).multilineTextAlignment(.center)
            Button("Retry") { web.goHome() }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Pane header icon: highlights on mouse-over, reports hover so the pane can show the action name,
/// and keeps the standard macOS tooltip.
struct HeaderIconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    let onHover: (Bool) -> Void
    @StateObject private var hovering = Box(false)

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(hovering.value ? Clarity.primary : Clarity.text)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(Clarity.primary.opacity(hovering.value ? 0.18 : 0))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(Clarity.primary.opacity(hovering.value ? 0.6 : 0), lineWidth: 1)
        )
        .help(help)
        .accessibilityLabel(help)
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.12)) { hovering.value = inside }
            onHover(inside)
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject var store: Store
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("KVM consoles").font(.headline)
            List {
                ForEach($store.kvms) { $kvm in
                    KVMRow(kvm: $kvm,
                           index: store.kvms.firstIndex(where: { $0.id == kvm.id }) ?? 0,
                           count: store.kvms.count)
                }
                .onMove { store.kvms.move(fromOffsets: $0, toOffset: $1) }
            }
            .frame(minHeight: 280)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            Text("Drag rows or use the arrows to change the order on the dashboard. URL changes apply when you press Return.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Add KVM") {
                store.kvms.append(KVM(name: "KVM-\(store.kvms.count + 1)", url: "https://"))
            }

            Divider()

            Picker("Layout", selection: $store.layout) {
                ForEach(DashboardLayout.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            Picker("Theme", selection: $store.theme) {
                ForEach(Theme.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            Toggle("Show URL in pane header", isOn: $store.showURL)

            Divider()

            HStack {
                Button("Export…", action: exportConfig)
                Button("Import…", action: importConfig)
                Spacer()
                Button("Reset to Defaults", role: .destructive) { store.config = .defaults }
            }
        }
        .padding(20)
        .frame(width: 620, height: 640)
    }

    private func exportConfig() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "kvm-dashboard-config.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(store.config).write(to: url)
    }

    private func importConfig() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            store.config = try JSONDecoder().decode(Config.self, from: Data(contentsOf: url))
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not import settings"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
}

struct KVMRow: View {
    @EnvironmentObject var store: Store
    @Binding var kvm: KVM
    let index: Int
    let count: Int
    @StateObject private var urlDraft = Box("")
    @FocusState private var urlFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                TextField("Name", text: $kvm.name)
                TextField("https://192.168.x.x/", text: $urlDraft.value)
                    .focused($urlFocused)
                    .onSubmit(commitURL)
                    .onChange(of: urlFocused) { if !urlFocused { commitURL() } }
            }
            .textFieldStyle(.roundedBorder)
            Toggle("Show", isOn: $kvm.enabled)
            Button { move(-1) } label: { Image(systemName: "chevron.up") }.disabled(index == 0)
            Button { move(1) } label: { Image(systemName: "chevron.down") }.disabled(index >= count - 1)
            Button(role: .destructive) { store.kvms.removeAll { $0.id == kvm.id } } label: { Image(systemName: "trash") }
        }
        .buttonStyle(.borderless)
        .padding(.vertical, 4)
        .onAppear { urlDraft.value = kvm.url }
    }

    private func commitURL() {
        let trimmed = urlDraft.value.trimmingCharacters(in: .whitespaces)
        if trimmed != kvm.url { kvm.url = trimmed }
    }

    private func move(_ delta: Int) {
        let target = index + delta
        guard store.kvms.indices.contains(target) else { return }
        store.kvms.swapAt(index, target)
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct KVMDashboardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var store = Store()

    var body: some Scene {
        Window("KVM Dashboard", id: "dashboard") {
            DashboardView()
                .environmentObject(store)
                .frame(minWidth: 800, minHeight: 500)
                .onAppear { store.applyAppearance() }
                .toolbar {
                    ToolbarItemGroup(placement: .primaryAction) {
                        Picker("Theme", selection: $store.theme) {
                            ForEach(Theme.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .help("Theme")
                        Button { store.reloadAll() } label: { Label("Reload All", systemImage: "arrow.clockwise") }
                            .help("Reload all KVMs")
                        SettingsLink { Label("Settings", systemImage: "gearshape") }
                            .help("Settings (⌘,)")
                    }
                }
        }
        .defaultSize(width: 1600, height: 1000)
        .commands {
            CommandGroup(after: .toolbar) {
                Button("Reload All KVMs") { store.reloadAll() }.keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView().environmentObject(store)
        }
    }
}
