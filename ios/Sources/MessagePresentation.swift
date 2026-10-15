import Foundation

/// Interpret only complete CLI envelopes. User code/XML examples remain literal text.
enum MessagePresentation: Equatable {
    case command(name: String, arguments: String)
    case output(String, isError: Bool)
    case notice(String)
    case markdown(String)

    static func parse(_ source: String) -> MessagePresentation {
        let text = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if text == "[Request interrupted by user]" || text == "[Request interrupted by user for tool use]" {
            return .notice("操作已取消")
        }
        let tags = ["command-name", "command-message", "command-args", "local-command-stdout", "local-command-stderr", "local-command-caveat"]
        guard text.hasPrefix("<"), !text.contains("```"),
              let regex = try? NSRegularExpression(pattern: "<([a-z-]+)>([\\s\\S]*?)</\\1>") else { return .markdown(source) }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return .markdown(source) }
        var values: [String: String] = [:]
        var position = 0
        for match in matches {
            let tag = ns.substring(with: match.range(at: 1))
            let gap = ns.substring(with: NSRange(location: position, length: match.range.location - position))
            guard tags.contains(tag), values[tag] == nil, gap.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .markdown(source) }
            values[tag] = ns.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
            position = NSMaxRange(match.range)
        }
        guard ns.substring(from: position).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .markdown(source) }
        if let name = values["command-name"] ?? values["command-message"], !name.isEmpty,
           values.keys.allSatisfy({ ["command-name", "command-message", "command-args"].contains($0) }) {
            return .command(name: name.hasPrefix("/") ? name : "/" + name, arguments: values["command-args"] ?? "")
        }
        if values.count == 1 {
            if let output = values["local-command-stdout"] { return .output(cleanANSI(output), isError: false) }
            if let output = values["local-command-stderr"] { return .output(cleanANSI(output), isError: true) }
            if values["local-command-caveat"] != nil { return .notice("本地命令记录") }
        }
        return .markdown(source)
    }
    private static func cleanANSI(_ source: String) -> String {
        source.replacingOccurrences(of: "\u{1b}\\[[0-?]*[ -/]*[@-~]", with: "", options: .regularExpression)
    }
}

struct MarkdownSection: Identifiable {
    enum Kind { case text, code(String) }
    let id: Int
    let kind: Kind
    let text: String
    static func parse(_ source: String) -> [MarkdownSection] {
        var result: [MarkdownSection] = []
        var lines: [String] = []
        var language: String?
        func flush() {
            guard !lines.isEmpty else { return }
            result.append(MarkdownSection(id: result.count, kind: language.map { .code($0) } ?? .text, text: lines.joined(separator: "\n")))
            lines = []
        }
        for line in source.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                flush()
                if language != nil { language = nil }
                else { language = String(line.trimmingCharacters(in: .whitespaces).dropFirst(3)) }
            } else { lines.append(line) }
        }
        flush()
        return result
    }
}

struct RemoteAttachment: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let size: Int
    let mimeType: String
    var path: String?
    var isImage: Bool { mimeType.hasPrefix("image/") }
    enum CodingKeys: String, CodingKey { case id, name, size, path; case mimeType = "mime_type" }
}
struct AttachmentContent {
    static let marker = "\n\n附件（AgentMux，已上传至 Mac）：\n"
    let text: String
    let files: [RemoteAttachment]
    static func parse(_ text: String) -> AttachmentContent {
        guard let range = text.range(of: marker, options: .backwards),
              let data = String(text[range.upperBound...]).data(using: .utf8),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data), !envelope.attachments.isEmpty,
              envelope.attachments.count <= 6, envelope.attachments.allSatisfy({ UUID(uuidString: $0.id) != nil && ($0.path?.contains("/\($0.id)/content/") ?? false) }) else { return AttachmentContent(text: text, files: []) }
        return AttachmentContent(text: String(text[..<range.lowerBound]), files: envelope.attachments)
    }
    private struct Envelope: Decodable { let attachments: [RemoteAttachment] }
}
