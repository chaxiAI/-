import AppKit
import ConverterCore
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// The window shown on first launch, since a menu bar app otherwise starts
/// with nothing on screen: how the gesture works, a practice wheel that
/// answers the ring keys, scrolling and the pointer (it converts nothing),
/// where the menu bar icon is, and launch at login. "How to Use Swivel…" in
/// the menu bar menu shows it again.
@MainActor
final class WelcomeWindowController {
    static let shownKey = "WelcomeShown"

    private let settings: AppSettings
    private let registry: ConverterRegistry
    private let defaults: UserDefaults
    private let showSettings: () -> Void
    private var window: NSWindow?
    private var input: PracticeWheelInput?

    init(settings: AppSettings, registry: ConverterRegistry, defaults: UserDefaults = .standard,
         showSettings: @escaping () -> Void) {
        self.settings = settings
        self.registry = registry
        self.defaults = defaults
        self.showSettings = showSettings
    }

    /// Shows the window the first time the app runs, and never again by
    /// itself. Returns whether it showed.
    @discardableResult
    func showIfFirstLaunch() -> Bool {
        guard !defaults.bool(forKey: Self.shownKey) else { return false }
        defaults.set(true, forKey: Self.shownKey)
        show()
        return true
    }

    func close() {
        window?.close()
    }

    func show() {
        settings.refreshLoginStatus()
        if window == nil { window = makeWindow() }
        input?.start()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let settings = settings
        let model = RadialMenuModel(registry: registry, preferred: { settings.preferredFormatIDs })
        model.ringKeys = { settings.ringKeys }
        model.isPresented = true
        if let photo = PracticeWheel.samplePhoto() { model.load([photo]) }
        let input = PracticeWheelInput(model: model, ringKeys: { settings.ringKeys })
        self.input = input

        let view = WelcomeView(settings: settings, wheel: model,
                               close: { [weak self] in self?.window?.close() },
                               openSettings: { [weak self] in
                                   self?.window?.close()
                                   self?.showSettings()
                               })
        let host = NSHostingController(rootView: view)
        host.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: host)
        window.title = "Welcome to Swivel"
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.center()
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window,
                                               queue: .main) { [weak input] _ in
            MainActor.assumeIsolated { input?.stop() }
        }
        return window
    }
}

/// The practice wheel's file: a generated photo in a temporary folder, so
/// the rings show what they would for a real HEIC photo.
enum PracticeWheel {
    static func samplePhoto() -> URL? {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Swivel Welcome", isDirectory: true)
        let url = folder.appendingPathComponent("IMG_2041.heic")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let width = 1200, height = 900
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        // An evening sky over a hill.
        let sky = CGGradient(colorsSpace: nil, colors: [
            CGColor(red: 0.98, green: 0.62, blue: 0.36, alpha: 1),
            CGColor(red: 0.36, green: 0.42, blue: 0.78, alpha: 1),
        ] as CFArray, locations: [0, 1])!
        context.drawLinearGradient(sky, start: .zero, end: CGPoint(x: 0, y: height), options: [])
        context.setFillColor(CGColor(red: 0.18, green: 0.32, blue: 0.24, alpha: 1))
        context.fillEllipse(in: CGRect(x: -300, y: -700, width: 1800, height: 1100))
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.heic.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? url : nil
    }
}

/// Ring keys and scrolling for the practice wheel, while its window is open.
@MainActor
final class PracticeWheelInput {
    private let model: RadialMenuModel
    private let ringKeys: () -> RingKeys
    private var monitors: [Any] = []
    private var heldKeys: Set<ModifierKey> = []
    private var scroller = RingScroller()

    init(model: RadialMenuModel, ringKeys: @escaping () -> RingKeys) {
        self.model = model
        self.ringKeys = ringKeys
    }

    func start() {
        guard monitors.isEmpty else { return }
        heldKeys = ModifierKey.pressed(in: NSEvent.modifierFlags)
        if let keys = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.flagsChanged(event) }
            return event
        }) { monitors.append(keys) }
        if let scroll = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.scrolled(event) }
            return event
        }) { monitors.append(scroll) }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
    }

    private func flagsChanged(_ event: NSEvent) {
        let held = ModifierKey.pressed(in: event.modifierFlags)
        let tapped = held.subtracting(heldKeys)
        heldKeys = held
        let keys = ringKeys()
        if let mode = ModifierKey.allCases.filter(tapped.contains).lazy.compactMap(keys.mode(for:)).first {
            model.setMode(mode)
        }
    }

    private func scrolled(_ event: NSEvent) {
        guard let steps = scroller.steps(for: ScrollSample(event)) else { return }
        model.setMode(model.mode.advanced(by: steps))
    }
}

struct WelcomeView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var wheel: RadialMenuModel
    let close: () -> Void
    let openSettings: () -> Void
    @State private var dwell: Task<Void, Never>?

    var body: some View {
        HStack(alignment: .top, spacing: 28) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("欢迎使用 Swivel").font(.title.weight(.semibold))
                        Text("在原文件所在位置转换、裁剪、压缩和共享文件。")
                            .foregroundStyle(.secondary)
                    }
                }
                step(1, symbol: "hand.point.up.left", title: "开始拖动文件",
                     detail: "像平常一样在访达或桌面中拖动文件。")
                step(2, symbol: "keyboard", title: "轻按一个按键", detail: keyHint)
                step(3, symbol: "smallcircle.filled.circle", title: "放到一个扇区上",
                     detail: "结果会保存在原文件旁，原文件不会被修改。放到中间即可取消。")
                Divider()
                HStack(alignment: .top, spacing: 10) {
                    Image(nsImage: StatusIcon.image(progress: nil))
                        .frame(width: 22)
                    Text("Swivel 位于菜单栏中。把文件拖到它的图标上，或点按图标选择“转换文件…”和“设置”。")
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.callout)
                Toggle("登录时打开 Swivel", isOn: Binding(
                    get: { settings.launchAtLogin },
                    set: { settings.setLaunchAtLogin($0) }))
                Spacer(minLength: 0)
                HStack {
                    Button("设置…", action: openSettings)
                    Spacer()
                    Button("开始使用", action: close)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .frame(width: 340)

            VStack(spacing: 8) {
                practiceWheel
                Text("可在此练习：按 \(keySymbols) 或滚动以切换转盘。不会转换任何文件。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(width: wheel.geometry.panelSide)
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 36)
        .padding(.bottom, 24)
        .fixedSize()
    }

    private var practiceWheel: some View {
        let side = wheel.geometry.panelSide
        return RadialMenuView(model: wheel)
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    // Relative to the centre, y up, as the wheel's geometry expects.
                    let point = CGPoint(x: location.x - side / 2, y: side / 2 - location.y)
                    if let group = wheel.hover(at: point) {
                        dwell?.cancel()
                        dwell = Task { @MainActor in
                            try? await Task.sleep(nanoseconds: RadialDropView.dwellNanoseconds)
                            guard !Task.isCancelled else { return }
                            wheel.openGroup(group)
                        }
                    }
                case .ended:
                    dwell?.cancel()
                    wheel.clearHover()
                }
            }
            .accessibilityHint("这是练习转盘。使用转盘按键或滚动来切换转盘。")
    }

    private var keyHint: String {
        let keys = settings.ringKeys
        let parts = [RingMode.formats, .tools, .actions].compactMap { mode in
            // No break between a key's symbol and its name.
            keys.key(for: mode).map { "\($0.symbol)\u{00A0}\($0.title)：\(mode.title)" }
        }
        return parts.isEmpty ? "尚未设置转盘按键。请在“设置”中选择。" : parts.joined(separator: "，") + "。"
    }

    private var keySymbols: String {
        let keys = settings.ringKeys
        return [RingMode.formats, .tools, .actions].compactMap { keys.key(for: $0)?.symbol }.joined(separator: " ")
    }

    private func step(_ number: Int, symbol: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(Color.accentColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(number). \(title)").font(.headline)
                Text(detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
