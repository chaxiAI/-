import AppIntents

/// Swivel's App Shortcuts: ready-made in the Shortcuts app and Spotlight,
/// each with its conversion fixed so there's nothing to set up. Spoken or
/// typed as "Convert to JPEG with Swivel".
struct SwivelShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ConvertToJPEGIntent(), phrases: ["使用 \(.applicationName) 转换为 JPEG"],
                    shortTitle: "转换为 JPEG", systemImageName: "photo")
        AppShortcut(intent: CompressIntent(), phrases: ["使用 \(.applicationName) 压缩"],
                    shortTitle: "压缩", systemImageName: "arrow.down.right.and.arrow.up.left")
        AppShortcut(intent: ConvertToPDFIntent(), phrases: ["使用 \(.applicationName) 转换为 PDF"],
                    shortTitle: "转换为 PDF", systemImageName: "doc.richtext")
    }
}

/// Images → JPEG, beside the originals.
struct ConvertToJPEGIntent: AppIntent {
    static let title: LocalizedStringResource = "转换为 JPEG"
    static let description = IntentDescription("在每张原图旁保存一份 JPEG 副本。", categoryName: "图像")

    @Parameter(title: "图像", supportedTypeIdentifiers: ["public.image"], requestValueDialog: "要转换哪些图像？")
    var files: [IntentFile]

    static var parameterSummary: some ParameterSummary {
        Summary("将 \(\.$files) 转换为 JPEG")
    }

    init() {}

    init(files: [IntentFile]) {
        self.files = files
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        .result(value: try await IntentConversion.run(files, firstOf: ["image.jpeg"], label: "转换为 JPEG"))
    }
}

/// Smaller copies of images, videos, audio and PDFs, with the tool that fits each file.
struct CompressIntent: AppIntent {
    static let title: LocalizedStringResource = "压缩"
    static let description = IntentDescription(
        "按 Swivel 中设定的质量，在每个图像、视频、音频或 PDF 原文件旁保存体积更小的副本。",
        categoryName: "文件")

    @Parameter(title: "文件", supportedTypeIdentifiers: ["public.item"], requestValueDialog: "要压缩哪些文件？")
    var files: [IntentFile]

    static var parameterSummary: some ParameterSummary {
        Summary("压缩 \(\.$files)")
    }

    init() {}

    init(files: [IntentFile]) {
        self.files = files
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        .result(value: try await IntentConversion.run(
            files, firstOf: ["image.compress", "video.compress", "audio.compress", "pdf.compress"], label: "压缩"))
    }
}

/// Images and text documents → PDF, beside the originals.
struct ConvertToPDFIntent: AppIntent {
    static let title: LocalizedStringResource = "转换为 PDF"
    static let description = IntentDescription(
        "在每个图像或文档（文本、RTF、HTML、Word、OpenDocument）原文件旁保存一份 PDF。",
        categoryName: "文件")

    @Parameter(title: "文件", supportedTypeIdentifiers: ["public.item"], requestValueDialog: "要转换哪些文件？")
    var files: [IntentFile]

    static var parameterSummary: some ParameterSummary {
        Summary("将 \(\.$files) 转换为 PDF")
    }

    init() {}

    init(files: [IntentFile]) {
        self.files = files
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        .result(value: try await IntentConversion.run(files, firstOf: ["image.pdf", "document.pdf"], label: "转换为 PDF"))
    }
}
