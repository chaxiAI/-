import AppKit
import ConverterCore
import ServiceManagement
import SwiftUI

/// One pane of the settings window: launch at login and the wheel,
/// favourite formats, and the quality settings the converters use.
/// `SettingsWindowController` shows each pane as a toolbar tab.
struct SettingsView: View {
    enum Tab: String, CaseIterable {
        case general, formats, images, media, documents

        var title: String {
            switch self {
            case .general: return "通用"
            case .formats: return "格式"
            case .images: return "图像"
            case .media: return "视频与音频"
            case .documents: return "文档"
            }
        }

        var symbol: String {
            switch self {
            case .general: return "gearshape"
            case .formats: return "star"
            case .images: return "photo"
            case .media: return "film"
            case .documents: return "doc.text"
            }
        }
    }

    @ObservedObject var settings: AppSettings
    @ObservedObject var shiftDrag: ShiftDragController
    let registry: ConverterRegistry
    let tab: Tab

    var body: some View {
        Group {
            switch tab {
            case .general: general
            case .formats: formats
            case .images: images
            case .media: media
            case .documents: documents
            }
        }
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: General

    private var general: some View {
        Form {
            Section {
                Toggle("登录时打开 Swivel", isOn: Binding(
                    get: { settings.launchAtLogin },
                    set: { settings.setLaunchAtLogin($0) }))
                if settings.loginStatus == .requiresApproval {
                    HStack {
                        Text("请在“登录项”中允许 Swivel 完成此设置。")
                            .font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        Button("打开“登录项”…") { settings.openLoginItemsSettings() }
                    }
                }
                if let error = settings.loginError {
                    Text(error).font(.callout).foregroundStyle(.red)
                }
            }
            Section {
                Toggle("拖动文件时打开转盘", isOn: Binding(
                    get: { shiftDrag.isEnabled },
                    set: { shiftDrag.isEnabled = $0 }))
                ForEach(RingMode.allCases) { mode in
                    Picker(ringLabel(mode), selection: keyBinding(mode)) {
                        Text("未设置按键").tag(ModifierKey?.none)
                        ForEach(ModifierKey.allCases) { key in
                            Text("\(key.symbol)  \(key.title)").tag(ModifierKey?.some(key))
                        }
                    }
                    .disabled(!shiftDrag.isEnabled)
                }
            } header: {
                Text("转盘")
            } footer: {
                Text("开始拖动文件后，轻按一个按键即可打开相应转盘。轻按其他按键或滚动鼠标可切换转盘；直到放下文件前，转盘都会保持打开。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section {
                Toggle("在菜单栏中显示图标", isOn: $settings.showMenuBarIcon)
                Toggle("在访达中显示转换后的文件", isOn: $settings.revealAfterConverting)
                Picker("使用以下应用打开文件夹", selection: $settings.terminalApp) {
                    ForEach(TerminalApp.allCases) { app in
                        Text(app.isInstalled ? app.title : "\(app.title)（未安装）").tag(app)
                    }
                }
            } footer: {
                Text("Swivel 可离线使用。转换结果会保存在原文件旁，原文件不会被改动。隐藏菜单栏图标后，请重新打开 Swivel 以查看这些设置。")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func ringLabel(_ mode: RingMode) -> String {
        switch mode {
        case .formats: return "转换格式"
        case .tools: return "文件工具"
        case .actions: return "文件操作"
        }
    }

    /// Choosing a key another ring uses swaps the two.
    private func keyBinding(_ mode: RingMode) -> Binding<ModifierKey?> {
        Binding(
            get: { settings.ringKeys.key(for: mode) },
            set: { key in
                var keys = settings.ringKeys
                keys.assign(key, to: mode)
                settings.ringKeys = keys
            })
    }

    // MARK: Formats

    private var formats: some View {
        Form {
            Section {
                ForEach(FormatKind.allCases) { kind in
                    Picker(kind.title, selection: preferredBinding(kind)) {
                        Text("默认顺序").tag("")
                        Divider()
                        ForEach(kind.choices(in: registry), id: \.id) { converter in
                            Text(converter.title).tag(converter.id)
                        }
                    }
                }
            } footer: {
                Text("所选格式会排在菜单最前方，并显示在拖动转盘的顶部。")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func preferredBinding(_ kind: FormatKind) -> Binding<String> {
        Binding(
            get: { settings.preferredFormats[kind.rawValue] ?? "" },
            set: { settings.preferredFormats[kind.rawValue] = $0.isEmpty ? nil : $0 })
    }

    // MARK: Images

    private var images: some View {
        Form {
            Section {
                LabeledContent("JPEG、HEIC 和 AVIF 质量") {
                    percentSlider($settings.options.imageQuality, in: 0.5...1)
                }
                LabeledContent("压缩图像") {
                    percentSlider($settings.options.compressionQuality, in: 0.1...0.9)
                }
            } footer: {
                Text("质量越高，文件越大。“压缩图像”会使用单独且更低的质量设置。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section {
                Toggle("保留相机与位置信息（EXIF、GPS）", isOn: $settings.options.keepMetadata)
            }
        }
        .formStyle(.grouped)
    }

    private func percentSlider(_ value: Binding<Double>, in range: ClosedRange<Double>) -> some View {
        HStack {
            Slider(value: value, in: range, step: 0.05)
                .frame(width: 180)
            Text("\(Int((value.wrappedValue * 100).rounded())) %")
                .monospacedDigit()
                .frame(width: 44, alignment: .trailing)
        }
    }

    // MARK: Video & audio

    private var media: some View {
        Form {
            Section("视频") {
                Picker("压缩视频", selection: $settings.options.videoCompression) {
                    Text("文件更小").tag(ConversionOptions.VideoCompression.smaller)
                    Text("均衡").tag(ConversionOptions.VideoCompression.balanced)
                    Text("质量更好").tag(ConversionOptions.VideoCompression.better)
                }
                Picker("GIF 帧率", selection: $settings.options.gifFrameRate) {
                    ForEach([5.0, 10, 15, 20, 30], id: \.self) { Text("\(Int($0)) fps").tag($0) }
                }
                Picker("GIF 尺寸", selection: $settings.options.gifMaxSide) {
                    ForEach([320, 480, 640, 800, 1080], id: \.self) { Text("\($0) px").tag($0) }
                }
            }
            Section {
                Picker("AAC 比特率", selection: $settings.options.audioBitRate) {
                    ForEach([128, 192, 256, 320], id: \.self) { Text("\($0) kbit/s").tag($0) }
                }
                Picker("压缩音频", selection: $settings.options.compressionAudioBitRate) {
                    ForEach(ConversionOptions.compressionAudioBitRates, id: \.self) { Text("\($0) kbit/s").tag($0) }
                }
            } header: {
                Text("音频")
            } footer: {
                Text("转换为 M4A 或 AAC 时会使用第一个比特率；“压缩音频”会以第二个较低的比特率生成 M4A。")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Documents

    private var documents: some View {
        Form {
            Section {
                Picker("将 PDF 页面转换为图像", selection: $settings.options.pdfRenderDPI) {
                    Text("72 dpi（屏幕）").tag(72.0)
                    Text("150 dpi").tag(150.0)
                    Text("300 dpi（打印）").tag(300.0)
                }
            } footer: {
                Text("用于 PDF → PNG、JPEG、HEIC 和 TIFF。")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// Owns the one settings window: a Mac-style settings window with a
/// toolbar tab per pane. The window takes the selected tab's name and
/// resizes to fit it; on macOS 26 and later the toolbar is Liquid Glass.
@MainActor
final class SettingsWindowController {
    static let selectedTabKey = "SettingsSelectedTab"

    private let settings: AppSettings
    private let shiftDrag: ShiftDragController
    private let registry: ConverterRegistry
    private var window: NSWindow?

    init(settings: AppSettings, shiftDrag: ShiftDragController, registry: ConverterRegistry) {
        self.settings = settings
        self.shiftDrag = shiftDrag
        self.registry = registry
    }

    func show() {
        settings.refreshLoginStatus()
        if window == nil { window = makeWindow() }
        // A menu bar app isn't active until asked.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let tabs = RememberingTabViewController()
        tabs.tabStyle = .toolbar
        for tab in SettingsView.Tab.allCases {
            let pane = NSHostingController(rootView: SettingsView(settings: settings, shiftDrag: shiftDrag,
                                                                   registry: registry, tab: tab))
            pane.sizingOptions = [.preferredContentSize]
            let item = NSTabViewItem(viewController: pane)
            item.label = tab.title
            item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title)
            tabs.addTabViewItem(item)
        }
        tabs.selectedTabViewItemIndex = min(UserDefaults.standard.integer(forKey: Self.selectedTabKey),
                                            SettingsView.Tab.allCases.count - 1)

        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("ConverterSettings")
        if !window.setFrameUsingName("ConverterSettings") { window.center() }
        return window
    }
}

/// Reopens on the tab that was last used.
private final class RememberingTabViewController: NSTabViewController {
    override var selectedTabViewItemIndex: Int {
        didSet { UserDefaults.standard.set(selectedTabViewItemIndex, forKey: SettingsWindowController.selectedTabKey) }
    }
}
