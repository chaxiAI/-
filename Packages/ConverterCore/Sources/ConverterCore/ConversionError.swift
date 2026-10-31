import Foundation

public enum ConversionError: LocalizedError, Sendable, Equatable {
    case unreadableInput(URL)
    case unsupported(String)
    case encoderFailed(String)
    case nothingToDo(String)
    case destinationNotWritable(URL, reason: String)
    case outputMissing

    public var errorDescription: String? {
        switch self {
        case .unreadableInput(let url):
            return "无法读取 \(url.lastPathComponent)。"
        case .unsupported(let message):
            return message
        case .encoderFailed(let message):
            return "转换失败：\(message)"
        case .nothingToDo(let message):
            return message
        case .destinationNotWritable(let folder, let reason):
            return "无法保存到 \(folder.lastPathComponent)：\(reason)"
        case .outputMissing:
            return "转换已完成，但没有生成文件。"
        }
    }
}
