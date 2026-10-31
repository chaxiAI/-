import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// One labelled value, e.g. "Aperture: f/2.8".
public struct MetadataField: Sendable, Hashable, Identifiable {
    public let label: String
    public let value: String
    public var id: String { label }

    public init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }
}

/// A titled group of fields, e.g. "Camera".
public struct MetadataSection: Sendable, Hashable, Identifiable {
    public let title: String
    public let fields: [MetadataField]
    public var id: String { title }

    public init(_ title: String, _ fields: [MetadataField]) {
        self.title = title
        self.fields = fields
    }

    public subscript(label: String) -> String? {
        fields.first { $0.label == label }?.value
    }
}

/// What a file records about itself, for the metadata window: file facts,
/// then image (EXIF, GPS, IPTC), audio and video, or PDF details. Only file
/// headers are read, and nothing leaves the Mac.
public enum FileMetadata {
    public static func sections(for url: URL) async -> [MetadataSection] {
        var sections = [fileSection(url)]
        if let input = try? InputFile(url: url), !input.isDirectory {
            if PDFFiles.isPDF(input) {
                sections += pdfSections(url)
            } else if let info = input.image, let source = ImageCodec.makeSource(url: url, contentType: input.contentType) {
                sections += imageSections(source, info: info)
            } else if MediaTypes.isMovie(input) || MediaTypes.isAudio(input) {
                sections += await mediaSections(url)
            }
        }
        return sections.filter { !$0.fields.isEmpty }
    }

    /// The sections as plain text, for copying.
    public static func text(_ sections: [MetadataSection]) -> String {
        sections.map { section in
            ([section.title] + section.fields.map { "\($0.label): \($0.value)" }).joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    // MARK: - File

    static func fileSection(_ url: URL) -> MetadataSection {
        let keys: Set<URLResourceKey> = [.localizedTypeDescriptionKey, .fileSizeKey, .creationDateKey,
                                         .contentModificationDateKey, .isDirectoryKey, .tagNamesKey]
        let values = try? url.resourceValues(forKeys: keys)
        var list = Fields()
        list.add("种类", values?.localizedTypeDescription)
        if values?.isDirectory == true {
            let count = (try? FileManager.default.contentsOfDirectory(atPath: url.path).count) ?? 0
            list.add("内容", count == 1 ? "1 个项目" : "\(count) 个项目")
        } else if let size = values?.fileSize {
            let bytes = NumberFormatter.localizedString(from: NSNumber(value: size), number: .decimal)
            list.add("大小", "\(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))（\(bytes) 字节）")
        }
        list.add("创建时间", values?.creationDate.map(format))
        list.add("修改时间", values?.contentModificationDate.map(format))
        list.add("位置", (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
        list.add("标签", values?.tagNames?.joined(separator: ", "))
        list.add("下载来源", whereFroms(url).joined(separator: "\n"))
        return MetadataSection("文件", list.fields)
    }

    /// The web pages a downloaded file came from, as recorded by the browser.
    static func whereFroms(_ url: URL) -> [String] {
        let name = "com.apple.metadata:kMDItemWhereFroms"
        let length = getxattr(url.path, name, nil, 0, 0, 0)
        guard length > 0 else { return [] }
        var data = Data(count: length)
        let read = data.withUnsafeMutableBytes { getxattr(url.path, name, $0.baseAddress, length, 0, 0) }
        guard read == length else { return [] }
        let list = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String]
        return (list ?? []).filter { !$0.isEmpty }
    }

    // MARK: - Images

    static func imageSections(_ source: CGImageSource, info: ImageInfo) -> [MetadataSection] {
        let props = ImageCodec.properties(source, info.primaryIndex)
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let aux = props[kCGImagePropertyExifAuxDictionary] as? [CFString: Any] ?? [:]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any] ?? [:]
        let iptc = props[kCGImagePropertyIPTCDictionary] as? [CFString: Any] ?? [:]

        var image = Fields()
        image.add("尺寸", "\(info.width) × \(info.height) 像素")
        if info.orientation != 1 { image.add("方向", orientationNames[info.orientation]) }
        if info.frameCount > 1 { image.add(info.isAnimated ? "帧数" : "图像数", "\(info.frameCount)") }
        image.add("色彩模型", props[kCGImagePropertyColorModel] as? String)
        image.add("色彩配置文件", props[kCGImagePropertyProfileName] as? String)
        image.add("色深", number(props[kCGImagePropertyDepth]).map { "\(Int($0)) 位/通道" })
        image.add("透明度", info.hasAlpha ? "有" : "无")
        if let x = number(props[kCGImagePropertyDPIWidth]), let y = number(props[kCGImagePropertyDPIHeight]) {
            image.add("分辨率", x == y ? "\(trimmed(x)) dpi" : "\(trimmed(x)) × \(trimmed(y)) dpi")
        }

        var camera = Fields()
        camera.add("制造商", tiff[kCGImagePropertyTIFFMake] as? String)
        camera.add("型号", tiff[kCGImagePropertyTIFFModel] as? String)
        camera.add("镜头", (exif[kCGImagePropertyExifLensModel] ?? aux[kCGImagePropertyExifAuxLensModel]) as? String)
        if let focal = number(exif[kCGImagePropertyExifFocalLength]) {
            let film = number(exif[kCGImagePropertyExifFocalLenIn35mmFilm]).map { " (\(Int($0)) mm in 35 mm terms)" } ?? ""
            camera.add("焦距", "\(trimmed(focal)) mm" + film)
        }
        camera.add("光圈", number(exif[kCGImagePropertyExifFNumber]).map { "f/\(trimmed($0))" })
        camera.add("曝光时间", number(exif[kCGImagePropertyExifExposureTime]).map(exposure))
        camera.add("ISO", ((exif[kCGImagePropertyExifISOSpeedRatings] as? [NSNumber])?.first).map { "ISO \($0.intValue)" })
        if let bias = number(exif[kCGImagePropertyExifExposureBiasValue]), bias != 0 {
            camera.add("曝光补偿", String(format: "%+.1f EV", bias))
        }
        camera.add("闪光灯", number(exif[kCGImagePropertyExifFlash]).map { Int($0) & 1 == 1 ? "已闪光" : "未闪光" })
        camera.add("拍摄时间", (exif[kCGImagePropertyExifDateTimeOriginal] as? String).map {
            exifDate($0, offset: exif[kCGImagePropertyExifOffsetTimeOriginal] as? String)
        })
        camera.add("软件", tiff[kCGImagePropertyTIFFSoftware] as? String)

        var location = Fields()
        if let lat = number(gps[kCGImagePropertyGPSLatitude]), let lon = number(gps[kCGImagePropertyGPSLongitude]) {
            let north = (gps[kCGImagePropertyGPSLatitudeRef] as? String)?.uppercased() != "S"
            let east = (gps[kCGImagePropertyGPSLongitudeRef] as? String)?.uppercased() != "W"
            location.add("纬度", String(format: "%.6f° %@", lat, north ? "N" : "S"))
            location.add("经度", String(format: "%.6f° %@", lon, east ? "E" : "W"))
            // Signed decimal degrees, the form maps and search boxes accept.
            location.add("坐标", String(format: "%.6f, %.6f", north ? lat : -lat, east ? lon : -lon))
        }
        if let altitude = number(gps[kCGImagePropertyGPSAltitude]) {
            let below = number(gps[kCGImagePropertyGPSAltitudeRef]) == 1
            location.add("海拔", String(format: "%.0f m", below ? -altitude : altitude))
        }
        location.add("方向", number(gps[kCGImagePropertyGPSImgDirection]).map { String(format: "%.0f°", $0) })

        var description = Fields()
        description.add("标题", iptc[kCGImagePropertyIPTCObjectName] as? String)
        description.add("说明", (iptc[kCGImagePropertyIPTCCaptionAbstract] ?? tiff[kCGImagePropertyTIFFImageDescription]) as? String)
        description.add("创作者", strings(iptc[kCGImagePropertyIPTCByline]) ?? tiff[kCGImagePropertyTIFFArtist] as? String)
        description.add("版权", (tiff[kCGImagePropertyTIFFCopyright] ?? iptc[kCGImagePropertyIPTCCopyrightNotice]) as? String)
        description.add("关键词", strings(iptc[kCGImagePropertyIPTCKeywords]))

        return [MetadataSection("图像", image.fields), MetadataSection("相机", camera.fields),
                MetadataSection("位置", location.fields), MetadataSection("描述", description.fields)]
    }

    static let orientationNames: [Int: String] = [
        2: "镜像", 3: "旋转 180°", 4: "镜像后旋转 180°",
        5: "镜像后逆时针旋转 90°", 6: "顺时针旋转 90°",
        7: "镜像后顺时针旋转 90°", 8: "逆时针旋转 90°",
    ]

    /// "1/250 s" for short exposures, "2 s" for long ones.
    static func exposure(_ seconds: Double) -> String {
        guard seconds > 0 else { return "—" }
        return seconds < 1 ? "1/\(Int((1 / seconds).rounded())) s" : "\(trimmed(seconds)) s"
    }

    /// EXIF's "2024:05:01 10:00:00" (with its offset, when recorded) as a date.
    static func exifDate(_ text: String, offset: String?) -> String {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = offset == nil ? "yyyy:MM:dd HH:mm:ss" : "yyyy:MM:dd HH:mm:ssxxx"
        return parser.date(from: offset.map { text + $0 } ?? text).map(format) ?? text
    }

    // MARK: - Audio and video

    static func mediaSections(_ url: URL) async -> [MetadataSection] {
        let asset = AVURLAsset(url: url)
        guard let loaded = try? await asset.load(.duration, .tracks, .commonMetadata) else { return [] }
        let (duration, tracks, metadata) = loaded
        let seconds = duration.seconds.isFinite ? duration.seconds : 0
        var sections: [MetadataSection] = []

        var media = Fields()
        media.add("时长", seconds > 0 ? self.duration(seconds) : nil)
        if seconds > 0, let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
            media.add("比特率", bitRate(Double(size) * 8 / seconds))
        }
        sections.append(MetadataSection("媒体", media.fields))

        if let track = tracks.first(where: { $0.mediaType == .video }),
           let loaded = try? await track.load(
               .naturalSize, .preferredTransform, .nominalFrameRate, .estimatedDataRate, .formatDescriptions) {
            let (size, transform, fps, rate, formats) = loaded
            var video = Fields()
            let shown = CGRect(origin: .zero, size: size).applying(transform)
            video.add("尺寸", "\(Int(abs(shown.width).rounded())) × \(Int(abs(shown.height).rounded())) 像素")
            video.add("编解码器", formats.first.map { codecName(CMFormatDescriptionGetMediaSubType($0)) })
            video.add("帧率", fps > 0 ? "\(trimmed(Double(fps))) fps" : nil)
            video.add("比特率", rate > 0 ? bitRate(Double(rate)) : nil)
            sections.append(MetadataSection("视频", video.fields))
        }

        if let track = tracks.first(where: { $0.mediaType == .audio }),
           let loaded = try? await track.load(.estimatedDataRate, .formatDescriptions) {
            let (rate, formats) = loaded
            var audio = Fields()
            if let format = formats.first {
                audio.add("编解码器", codecName(CMFormatDescriptionGetMediaSubType(format)))
                if let basic = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee {
                    audio.add("采样率", basic.mSampleRate > 0 ? "\(trimmed(basic.mSampleRate / 1000)) kHz" : nil)
                    let channels = Int(basic.mChannelsPerFrame)
                    audio.add("声道", channels == 1 ? "单声道" : channels == 2 ? "立体声" : channels > 0 ? "\(channels)" : nil)
                }
            }
            audio.add("比特率", rate > 0 ? bitRate(Double(rate)) : nil)
            sections.append(MetadataSection("音频", audio.fields))
        }

        var details = Fields()
        let labels: [(AVMetadataKey, String)] = [
            (.commonKeyTitle, "标题"), (.commonKeyArtist, "艺人"), (.commonKeyAlbumName, "专辑"),
            (.commonKeyCreator, "创作者"), (.commonKeyDescription, "说明"), (.commonKeyCopyrights, "版权"),
            (.commonKeyCreationDate, "录制时间"), (.commonKeyMake, "制造商"), (.commonKeyModel, "型号"),
            (.commonKeySoftware, "软件"), (.commonKeyLocation, "位置"),
        ]
        for (key, label) in labels {
            guard let item = metadata.first(where: { $0.commonKey == key }) else { continue }
            details.add(label, try? await item.load(.stringValue))
        }
        sections.append(MetadataSection("详细信息", details.fields))
        return sections
    }

    static func codecName(_ code: FourCharCode) -> String {
        let names: [String: String] = [
            "avc1": "H.264", "hvc1": "HEVC", "hev1": "HEVC", "av01": "AV1", "vp09": "VP9", "mp4v": "MPEG-4",
            "jpeg": "Motion JPEG", "apch": "ProRes 422 HQ", "apcn": "ProRes 422", "apcs": "ProRes 422 LT",
            "apco": "ProRes 422 Proxy", "ap4h": "ProRes 4444", "ap4x": "ProRes 4444 XQ",
            "aac ": "AAC", "lpcm": "PCM", "alac": "Apple Lossless", "fLaC": "FLAC", ".mp3": "MP3",
            "opus": "Opus", "ac-3": "Dolby Digital", "ec-3": "Dolby Digital Plus",
        ]
        let fourCC = String(bytes: [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }, encoding: .macOSRoman) ?? "\(code)"
        return names[fourCC] ?? fourCC.trimmingCharacters(in: .whitespaces)
    }

    /// "0:05", "3:07" or "1:02:03".
    static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let (h, m, s) = (total / 3600, total / 60 % 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    static func bitRate(_ bitsPerSecond: Double) -> String {
        bitsPerSecond >= 1_000_000 ? String(format: "%.1f Mbit/s", bitsPerSecond / 1_000_000)
                                   : String(format: "%.0f kbit/s", bitsPerSecond / 1000)
    }

    // MARK: - PDF

    static func pdfSections(_ url: URL) -> [MetadataSection] {
        guard let document = PDFDocument(url: url) else { return [] }
        let attributes = document.documentAttributes ?? [:]
        func text(_ key: PDFDocumentAttribute) -> String? {
            strings(attributes[key]) ?? (attributes[key] as? String)
        }
        var pdf = Fields()
        pdf.add("页数", "\(document.pageCount)")
        if let page = document.page(at: 0) {
            let box = page.bounds(for: .mediaBox)
            let metric = Locale.current.measurementSystem != .us
            let (w, h) = metric ? (box.width / 72 * 25.4, box.height / 72 * 25.4) : (box.width / 72, box.height / 72)
            pdf.add("页面大小", String(format: metric ? "%.0f × %.0f mm" : "%.2f × %.2f in", w, h))
        }
        pdf.add("PDF 版本", "\(document.majorVersion).\(document.minorVersion)")
        pdf.add("标题", text(.titleAttribute))
        pdf.add("作者", text(.authorAttribute))
        pdf.add("主题", text(.subjectAttribute))
        pdf.add("关键词", text(.keywordsAttribute))
        pdf.add("应用程序", text(.creatorAttribute))
        pdf.add("PDF 生成器", text(.producerAttribute))
        pdf.add("创建时间", (attributes[PDFDocumentAttribute.creationDateAttribute] as? Date).map(format))
        pdf.add("修改时间", (attributes[PDFDocumentAttribute.modificationDateAttribute] as? Date).map(format))
        pdf.add("安全性", document.isLocked ? "需要密码才能打开"
                                              : document.isEncrypted ? "已加密" : "无")
        if !document.isLocked {
            var limits: [String] = []
            if !document.allowsPrinting { limits.append("打印") }
            if !document.allowsCopying { limits.append("复制") }
            if !limits.isEmpty { pdf.add("限制", "不允许" + limits.joined(separator: "或")) }
        }
        return [MetadataSection("PDF", pdf.fields)]
    }

    // MARK: - Helpers

    private struct Fields {
        var fields: [MetadataField] = []

        mutating func add(_ label: String, _ value: String?) {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return }
            fields.append(MetadataField(label, value))
        }
    }

    private static func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }

    /// A list of strings (IPTC keywords, PDF keywords) joined with commas.
    private static func strings(_ value: Any?) -> String? {
        guard let list = value as? [Any] else { return nil }
        let joined = list.compactMap { $0 as? String }.joined(separator: ", ")
        return joined.isEmpty ? nil : joined
    }

    /// "2.8" rather than "2.80", "50" rather than "50.0".
    private static func trimmed(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.2f", value)
            .replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression)
    }

    private static func format(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}
