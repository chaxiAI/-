import AppKit
import ConverterCore
import ImageIO
import SwiftUI
import XCTest
@testable import ConverterApp

/// The metadata window's model, Copy All, and stepping through a selection.
@MainActor
final class MetadataWindowTests: XCTestCase {
    var folder: URL!

    override func setUp() async throws {
        folder = try makeTemporaryFolder("MetadataWindow")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// A JPEG with a camera, a place and a caption.
    private func taggedPhoto() throws -> URL {
        let plain = try makeImage("plain.png", in: folder)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(plain.url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let url = folder.appendingPathComponent("IMG_0042.jpg")
        let props: [CFString: Any] = [
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Apple", kCGImagePropertyTIFFModel: "iPhone 17 Pro"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifFNumber: 1.8, kCGImagePropertyExifExposureTime: 0.01,
                                             kCGImagePropertyExifISOSpeedRatings: [64]],
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 51.5007, kCGImagePropertyGPSLatitudeRef: "N",
                                            kCGImagePropertyGPSLongitude: 0.1246, kCGImagePropertyGPSLongitudeRef: "W"],
            kCGImagePropertyIPTCDictionary: [kCGImagePropertyIPTCCaptionAbstract: "Evening walk"],
        ]
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, props as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    func testPlainImage() async throws {
        let png = try makeImage("photo.png", in: folder).url
        let model = MetadataModel(urls: [png], loadsThumbnails: false)
        await model.loaded()
        XCTAssertFalse(model.isLoading)
        XCTAssertEqual(model.sections.map(\.title), ["文件", "图像"])
        XCTAssertTrue(model.summary.contains(" · "), "kind and size: \(model.summary)")
        XCTAssertFalse(model.canRemoveMetadata, "nothing to remove")
        XCTAssertTrue(model.text.hasPrefix("photo.png\n\n文件\n种类: "))
    }

    func testTaggedPhotoCanBeCleaned() async throws {
        let model = MetadataModel(urls: [try taggedPhoto()], loadsThumbnails: false)
        await model.loaded()
        XCTAssertEqual(model.sections.map(\.title), ["文件", "图像", "相机", "位置", "描述"])
        XCTAssertEqual(model.sections.first { $0.title == "位置" }?["坐标"], "51.500700, -0.124600")
        XCTAssertTrue(model.canRemoveMetadata)
        XCTAssertEqual(model.metadataRemover?.id, "image.stripMetadata")
    }

    /// A three-page PDF with a title and an author.
    private func taggedPDF() throws -> URL {
        let url = folder.appendingPathComponent("report.pdf")
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        let info: [CFString: Any] = [kCGPDFContextTitle: "Quarterly Report", kCGPDFContextAuthor: "Sam"]
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, info as CFDictionary))
        for _ in 0..<3 { context.beginPDFPage(nil); context.endPDFPage() }
        context.closePDF()
        return url
    }

    func testTaggedPDFCanBeCleaned() async throws {
        let model = MetadataModel(urls: [try taggedPDF()], loadsThumbnails: false)
        await model.loaded()
        XCTAssertEqual(model.sections.first { $0.title == "PDF" }?["作者"], "Sam")
        XCTAssertEqual(model.metadataRemover?.id, "pdf.stripMetadata")
    }

    func testEachKindOfFileGetsItsOwnCleaner() throws {
        let movie = folder.appendingPathComponent("clip.mov"), pdf = folder.appendingPathComponent("plain.pdf")
        try Data().write(to: movie) // the choice only looks at the type and the sections
        try Data().write(to: pdf)
        let file = MetadataSection("文件", [MetadataField("种类", "QuickTime movie")])
        let details = MetadataSection("详细信息", [MetadataField("位置", "+51.5007-000.1246/")])
        let remover = { (sections: [MetadataSection], url: URL) throws in
            MetadataModel.remover(for: sections, input: try InputFile(url: url))?.id
        }
        XCTAssertEqual(try remover([file, details], movie), "video.stripMetadata")
        XCTAssertNil(try remover([file, MetadataSection("视频", [MetadataField("编解码器", "H.264")])], movie), "nothing recorded")
        XCTAssertNil(try remover([file, details], pdf), "a PDF has no recorder details")

        let producer = MetadataSection("PDF", [MetadataField("页数", "2"), MetadataField("PDF 生成器", "Quartz PDFContext")])
        XCTAssertNil(try remover([file, producer], pdf), "every PDF names its producer; that's not worth a button")
        let authored = MetadataSection("PDF", [MetadataField("页数", "2"), MetadataField("作者", "Sam")])
        XCTAssertEqual(try remover([file, authored], pdf), "pdf.stripMetadata")
        XCTAssertNil(try remover([file, authored], movie), "the sections and the file must agree")
    }

    func testSteppingThroughASelection() async throws {
        let png = try makeImage("photo.png", in: folder).url
        let jpeg = try taggedPhoto()
        let model = MetadataModel(urls: [png, jpeg], loadsThumbnails: false)
        await model.loaded()
        model.show(1)
        XCTAssertEqual(model.url, jpeg)
        await model.loaded()
        XCTAssertNotNil(model.sections.first { $0.title == "相机" })
        model.show(5)
        XCTAssertEqual(model.index, 1, "out of range is ignored")
    }

    func testCopyAllAndRemoveMetadata() async throws {
        let jpeg = try taggedPhoto()
        var removed: [InputFile] = []
        let controller = MetadataWindowController { _, input in removed.append(input) }
        controller.showsWindow = false
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("ConverterTests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        controller.pasteboard = pasteboard
        controller.show([jpeg])
        let model = try XCTUnwrap(controller.model)
        await model.loaded()
        controller.copy(model.text)
        let copied = try XCTUnwrap(pasteboard.string(forType: .string))
        XCTAssertTrue(copied.contains("相机\n制造商: Apple\n型号: iPhone 17 Pro"))
        XCTAssertTrue(copied.contains("说明: Evening walk"))
        XCTAssertTrue(removed.isEmpty)
    }

    func testRenderWindow() async throws {
        let model = MetadataModel(urls: [try taggedPhoto(), try makeImage("photo.png", in: folder).url])
        await model.loaded()
        let view = MetadataView(model: model, onCopy: {}, onRemoveMetadata: {})
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 760),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 440, height: 760)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: snapshotFolder().appendingPathComponent("metadata.png"))
    }
}
