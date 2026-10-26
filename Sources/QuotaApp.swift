import AppKit
import QuartzCore
import SwiftUI
import ServiceManagement

@MainActor
final class QuotaStore: ObservableObject {
    @Published private(set) var snapshot: QuotaSnapshot?
    @Published private(set) var isRefreshing = false
    @Published private(set) var error: String?
    @Published var showUsed = UserDefaults.standard.bool(forKey: "showUsed") {
        didSet { UserDefaults.standard.set(showUsed, forKey: "showUsed"); onChange?() }
    }
    @Published private(set) var loginEnabled = SMAppService.mainApp.status == .enabled
    @Published private(set) var loginMessage: String?
    var onChange: (() -> Void)?
    private var timer: Timer?

    init(snapshot: QuotaSnapshot? = nil) {
        self.snapshot = snapshot
    }

    var needsSync: Bool { error != nil || snapshot?.hasExpiredWindow == true }
    var statusDescription: String {
        let five = snapshot?.fiveHour?.percentage(showUsed: showUsed) ?? "未知"
        let week = snapshot?.weekly?.percentage(showUsed: showUsed) ?? "未知"
        return "5 小时 \(five) · 每周 \(week)"
    }

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        onChange?()
        let customPath = UserDefaults.standard.string(forKey: "codexPath")
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Result { try CodexClient.fetch(customPath: customPath) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.isRefreshing = false
                switch result {
                case .success(let snapshot):
                    self.snapshot = snapshot
                    self.error = nil
                case .failure(let error):
                    self.error = error.localizedDescription
                }
                self.onChange?()
            }
        }
    }

    func setLogin(_ enabled: Bool) {
        defer { onChange?() }
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            loginEnabled = SMAppService.mainApp.status == .enabled
            loginMessage = SMAppService.mainApp.status == .requiresApproval
                ? "请到系统设置 → 通用 → 登录项中允许 Codex Quota Bar。" : nil
        } catch {
            loginMessage = "无法修改登录项：\(error.localizedDescription)"
        }
    }

    func chooseCodex() {
        let panel = NSOpenPanel()
        panel.title = "选择 Codex 可执行文件"
        panel.message = "通常位于 /opt/homebrew/bin/codex 或 Codex 应用的 Contents/Resources 中。"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: "/opt/homebrew/bin")
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            guard FileManager.default.isExecutableFile(atPath: url.path) else {
                error = "所选文件不可执行，请选择 Codex CLI 可执行文件。"
                onChange?()
                return
            }
            UserDefaults.standard.set(url.path, forKey: "codexPath")
            refresh()
        }
    }

    func useAutomaticPath() {
        UserDefaults.standard.removeObject(forKey: "codexPath")
        refresh()
    }
}

private struct WindowRingCard: View {
    let title: String
    let subtitle: String
    let window: LimitWindow?
    let showUsed: Bool

    private var color: Color {
        guard let remaining = window?.remaining else { return .secondary }
        return remaining <= 10 ? .red : remaining <= 25 ? .orange : Color(red: 0.12, green: 0.65, blue: 0.47)
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(title).font(.system(size: 13, weight: .medium))
            Text(subtitle)
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .padding(.top, 4)

            ZStack {
                Circle().stroke(Color.primary.opacity(0.08), lineWidth: 4)
                if let value = showUsed ? window?.used : window?.remaining, value > 0 {
                    Circle()
                        .trim(from: 0, to: value / 100)
                        .stroke(color, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                Text(verbatim: window?.percentage(showUsed: showUsed) ?? "—")
                    .font(.system(size: 31, weight: .regular))
                    .monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.65)
                    .frame(width: 74)
                    .padding(.horizontal, 6)
            }
            .padding(3)
            .frame(width: 92, height: 92)
            .padding(.top, 16)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(title)\(showUsed ? "已用" : "剩余") \(window?.percentage(showUsed: showUsed) ?? "未知")")

            TimelineView(.periodic(from: .now, by: 1)) { context in
                VStack(spacing: 6) {
                    if let reset = window?.resetDate {
                        Text(countdown(to: reset, now: context.date))
                            .font(.system(size: 10.5))
                        Text(reset, format: .dateTime.month(.twoDigits).day(.twoDigits).hour().minute())
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                            .help("本地时区的重置时间")
                    } else {
                        Text(window == nil ? "账户未提供此窗口" : "未提供重置时间")
                            .font(.system(size: 10.5)).foregroundStyle(.secondary)
                        Text("—").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 16)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, minHeight: 219, alignment: .top)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5))
    }

    private func countdown(to reset: Date, now: Date) -> String {
        let seconds = Int(ceil(reset.timeIntervalSince(now)))
        guard seconds > 0 else { return "重置时间已到，等待同步" }
        let minutes = (seconds + 59) / 60
        if minutes >= 1440 { return "\(minutes / 1440)天 \(minutes % 1440 / 60)小时后重置" }
        if minutes >= 60 { return "\(minutes / 60)小时 \(minutes % 60)分钟后重置" }
        return "\(minutes)分钟后重置"
    }
}

struct QuotaPopover: View {
    @ObservedObject var store: QuotaStore

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 9) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Codex 额度").font(.system(size: 17, weight: .medium))
                    Text("\(store.snapshot?.bucket.planType?.capitalized ?? "ChatGPT") · 每分钟自动刷新")
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
                Spacer()
                Button { store.refresh() } label: {
                    ZStack {
                        if store.isRefreshing { ProgressView().controlSize(.small).scaleEffect(0.75) }
                        else { Image(systemName: "arrow.clockwise").font(.system(size: 14)).foregroundStyle(.secondary) }
                    }.frame(width: 24, height: 24)
                }
                    .buttonStyle(.plain).disabled(store.isRefreshing).help("立即刷新")
                    .accessibilityLabel("立即刷新")
            }
            .padding(.horizontal, 20)
            Picker("显示", selection: $store.showUsed) {
                Text("剩余额度").tag(false)
                Text("已用额度").tag(true)
            }.pickerStyle(.segmented).labelsHidden()
                .padding(.horizontal, 20)

            HStack(alignment: .top, spacing: 12) {
                WindowRingCard(title: "5 小时限额", subtitle: store.showUsed ? "当前窗口已使用" : "当前窗口可用", window: store.snapshot?.fiveHour, showUsed: store.showUsed)
                WindowRingCard(title: "每周限额", subtitle: store.showUsed ? "本周已使用" : "本周可用", window: store.snapshot?.weekly, showUsed: store.showUsed)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 14)

            if let error = store.error {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(store.snapshot == nil ? "暂未取得额度" : "刷新失败，显示上次数据")
                        Text(error).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
                .padding(.horizontal, 16)
            }
            VStack(spacing: 12) {
                Divider().overlay(Color.primary.opacity(0.025))
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        if let snapshot = store.snapshot {
                            Text("\(store.needsSync ? "上次数据" : "更新于") \(snapshot.fetchedAt.formatted(date: .omitted, time: .standard))")
                        } else {
                            Text(store.isRefreshing ? "正在连接本机 Codex…" : "暂未取得额度")
                        }
                        Text("\(store.showUsed ? "已用" : "剩余")百分比 · 共用本机 Codex 登录")
                    }.font(.system(size: 10)).foregroundStyle(.secondary)
                    Spacer()
                    Menu {
                        Toggle("登录时启动", isOn: Binding(get: { store.loginEnabled }, set: { store.setLogin($0) }))
                        Button("打开 Codex") { openCodex() }
                        Divider()
                        Button("选择 Codex 可执行文件…") { store.chooseCodex() }
                        Button("恢复自动查找") { store.useAutomaticPath() }
                        Divider()
                        Button("退出 Codex Quota Bar") { NSApp.terminate(nil) }
                    } label: { Image(systemName: "gearshape") }
                    .menuStyle(.borderlessButton).fixedSize().help("设置")
                }
            }
            .padding(.horizontal, 20)
            if let message = store.loginMessage {
                Text(message).font(.system(size: 10)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 20)
            }
        }
        .padding(.vertical, 20)
        .frame(width: 340)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func openCodex() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }
}

@MainActor
final class StatusTextView: NSView {
    private let font = NSFont.systemFont(ofSize: 15, weight: .regular)
    private var values: [Double?] = [nil, nil]
    private var labels = ["—", "—"]
    private var needsSync = false

    private func textSize(_ text: String) -> NSSize {
        (text as NSString).size(withAttributes: [.font: font])
    }

    // Equal columns keep the divider steady; longer values still get padding.
    private var columnWidth: CGFloat {
        max(44, ceil(labels.map { textSize($0).width }.max() ?? 0) + 8)
    }

    private var syncWidth: CGFloat { needsSync ? ceil(textSize("!").width) + 6 : 0 }

    func update(fiveHour: LimitWindow?, weekly: LimitWindow?, showUsed: Bool, needsSync: Bool = false) {
        let windows = [fiveHour, weekly]
        values = windows.map { showUsed ? $0?.used : $0?.remaining }
        labels = windows.map { $0?.percentage(showUsed: showUsed) ?? "—" }
        self.needsSync = needsSync
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 2 + columnWidth * 2 + syncWidth, height: NSStatusBar.system.thickness)
    }

    // Leave the complete status button as the click and accessibility target.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let height = min(20.5, max(0, bounds.height - 2))
        let borderRect = NSRect(x: bounds.minX + 0.5, y: bounds.midY - height / 2, width: max(0, bounds.width - 1), height: height)
        let border = NSBezierPath(roundedRect: borderRect, xRadius: 3.5, yRadius: 3.5)
        NSColor.labelColor.withAlphaComponent(0.30).setStroke()
        border.lineWidth = 0.5
        border.stroke()

        let dividerX = bounds.minX + 1 + columnWidth
        let divider = NSBezierPath()
        divider.move(to: NSPoint(x: dividerX, y: bounds.midY - 5))
        divider.line(to: NSPoint(x: dividerX, y: bounds.midY + 5))
        divider.lineWidth = 0.5
        divider.lineCapStyle = .round
        NSColor.labelColor.withAlphaComponent(0.20).setStroke()
        divider.stroke()

        for index in labels.indices {
            let centerX = bounds.minX + 1 + columnWidth * (CGFloat(index) + 0.5)
            drawLabel(labels[index], centerX: centerX, color: metricColor(values[index]))
        }
        if needsSync {
            drawLabel("!", centerX: bounds.minX + 1 + columnWidth * 2 + syncWidth / 2, color: .labelColor)
        }
    }

    private func drawLabel(_ label: String, centerX: CGFloat, color: NSColor) {
        let size = textSize(label)
        (label as NSString).draw(at: NSPoint(x: centerX - size.width / 2, y: bounds.midY - size.height / 2),
                                 withAttributes: [.font: font, .foregroundColor: color])
    }

    private func metricColor(_ value: Double?) -> NSColor {
        guard let value, value <= 20 else { return .labelColor }
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let rgb: UInt32
        if value < 10 { rgb = dark ? 0xFF6961 : 0xD23536 }
        else { rgb = dark ? 0xFFD45C : 0x987600 }
        return NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255,
                       green: CGFloat((rgb >> 8) & 255) / 255,
                       blue: CGFloat(rgb & 255) / 255, alpha: 1)
    }
}

enum QuotaPanelLayout {
    static func frame(contentSize: NSSize, anchor: NSRect, visibleFrame: NSRect) -> NSRect {
        let margin: CGFloat = 8
        // Keep the whole panel below the menu bar, on the status item's screen.
        let top = min(anchor.minY - margin, visibleFrame.maxY - margin)
        let width = min(contentSize.width, max(1, visibleFrame.width - margin * 2))
        let height = min(contentSize.height, max(1, top - visibleFrame.minY - margin))
        let x = min(max(anchor.midX - width / 2, visibleFrame.minX + margin), visibleFrame.maxX - margin - width)
        return NSRect(x: x, y: top - height, width: width, height: height)
    }
}

private final class QuotaPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class RoundedPanelView: NSView {
    static let cornerRadius: CGFloat = 16
    let material = NSVisualEffectView()
    private let contentMask = CAShapeLayer()
    private var maskedSize = NSSize.zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.mask = contentMask
        material.frame = bounds
        material.autoresizingMask = [.width, .height]
        material.material = .popover
        material.blendingMode = .behindWindow
        material.state = .active
        addSubview(material)
        updateMasks()
    }

    required init?(coder: NSCoder) { nil }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateMasks()
    }

    override func layout() {
        super.layout()
        updateMasks()
    }

    private func updateMasks() {
        guard bounds.width > 0, bounds.height > 0, maskedSize != bounds.size else { return }
        maskedSize = bounds.size
        let rect = NSRect(origin: .zero, size: bounds.size)
        let radius = min(Self.cornerRadius, min(rect.width, rect.height) / 2)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contentMask.frame = rect
        contentMask.path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        CATransaction.commit()
        // The behind-window blur is composited separately from the view's layer.
        // Give it the same mask so it cannot leave square corners behind content.
        material.maskImage = NSImage(size: rect.size, flipped: false) { drawingRect in
            NSColor.white.setFill()
            NSBezierPath(roundedRect: drawingRect, xRadius: radius, yRadius: radius).fill()
            return true
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var item: NSStatusItem!
    private let statusText = StatusTextView()
    private var panel: QuotaPanel!
    private var measurementView: NSHostingView<QuotaPopover>!
    private var panelContent: NSHostingView<AnyView>!
    private let store = QuotaStore()
    private var wakeObserver: NSObjectProtocol?
    private var observers: [NSObjectProtocol] = []
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var menuIsTracking = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let duplicates = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "local.codex.quota-bar")
        if duplicates.contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            NSApp.terminate(nil)
            return
        }
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = nil
            button.title = ""
            statusText.frame = button.bounds
            statusText.autoresizingMask = [.width, .height]
            statusText.setAccessibilityElement(false)
            button.addSubview(statusText)
            button.target = self
            button.action = #selector(togglePopover)
        }
        configurePanel()
        store.onChange = { [weak self] in
            self?.updateStatus()
            if self?.panel.isVisible == true { self?.positionPanel() }
        }
        updateStatus()
        store.start()
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.store.refresh() }
        }
        observe(NSApplication.didResignActiveNotification) { [weak self] in self?.closePanel() }
        observe(NSApplication.didChangeScreenParametersNotification) { [weak self] in
            if self?.panel.isVisible == true { self?.positionPanel() }
        }
        observe(NSMenu.didBeginTrackingNotification) { [weak self] in self?.menuIsTracking = true }
        observe(NSMenu.didEndTrackingNotification) { [weak self] in self?.menuIsTracking = false }
    }

    private func updateStatus() {
        statusText.update(fiveHour: store.snapshot?.fiveHour, weekly: store.snapshot?.weekly, showUsed: store.showUsed, needsSync: store.needsSync)
        item.length = statusText.intrinsicContentSize.width
        let mode = store.showUsed ? "已用" : "剩余"
        item.button?.toolTip = "Codex \(mode)额度 · \(store.statusDescription)\(store.needsSync ? " · 数据待同步" : "")"
        item.button?.setAccessibilityLabel(item.button?.toolTip)
    }

    private func configurePanel() {
        panel = QuotaPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.animationBehavior = .none

        let surface = RoundedPanelView(frame: .zero)
        panel.contentView = surface

        measurementView = NSHostingView(rootView: QuotaPopover(store: store))
        panelContent = NSHostingView(rootView: AnyView(EmptyView()))
        panelContent.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(panelContent)
        NSLayoutConstraint.activate([
            panelContent.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
            panelContent.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
            panelContent.topAnchor.constraint(equalTo: surface.topAnchor),
            panelContent.bottomAnchor.constraint(equalTo: surface.bottomAnchor)
        ])
    }

    private func positionPanel() {
        guard let button = item.button, let statusWindow = button.window,
              let screen = statusWindow.screen else { return }
        let anchor = statusWindow.convertToScreen(button.convert(button.bounds, to: nil))
        measurementView.rootView = QuotaPopover(store: store)
        measurementView.layoutSubtreeIfNeeded()
        let size = measurementView.fittingSize
        let frame = QuotaPanelLayout.frame(contentSize: NSSize(width: 340, height: ceil(size.height)), anchor: anchor, visibleFrame: screen.visibleFrame)
        // A short display or a long error message can scroll instead of clipping.
        panelContent.rootView = AnyView(
            ScrollView(.vertical) { QuotaPopover(store: store) }
                .frame(width: frame.width, height: frame.height)
                .clipShape(RoundedRectangle(cornerRadius: RoundedPanelView.cornerRadius))
        )
        panel.setFrame(frame, display: true)
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.invalidateShadow()
    }

    @objc private func togglePopover() {
        if panel.isVisible { closePanel(); return }
        NSApp.activate(ignoringOtherApps: true)
        positionPanel()
        panel.makeKeyAndOrderFront(nil)
        installMonitors()
        store.refresh()
    }

    private func closePanel() {
        panel.orderOut(nil)
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
    }

    private func installMonitors() {
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53 && event.window === self.panel && !self.menuIsTracking { self.closePanel(); return nil }
            } else if !self.menuIsTracking && event.window !== self.panel && event.window !== self.item.button?.window {
                self.closePanel()
            }
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.closePanel() }
        }
    }

    private func observe(_ name: Notification.Name, action: @escaping @MainActor () -> Void) {
        observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { action() }
        })
    }
}
