import Foundation

@main struct MessagePresentationProbe {
    static func main() {
        let raw = "<command-name>/model</command-name>\n<command-message>model</command-message>\n<command-args></command-args>"
        assert(MessagePresentation.parse(raw) == .command(name: "/model", arguments: ""))
        assert(MessagePresentation.parse(raw.replacingOccurrences(of: "<command-args></command-args>", with: "<command-args>模型 A</command-args>")) == .command(name: "/model", arguments: "模型 A"))
        for literal in ["示例：\n" + raw, "```xml\n" + raw + "\n```", "<example>literal</example>", raw + " trailing text"] {
            assert(MessagePresentation.parse(literal) == .markdown(literal))
        }
        assert(MessagePresentation.parse("<local-command-stdout>\u{1b}[32mModel changed\u{1b}[0m</local-command-stdout>") == .output("Model changed", isError: false))
        let blocks = MarkdownSection.parse("**说明**\n\n```swift\nlet value = 1\n```\n\n继续")
        assert(blocks.count == 3 && blocks[1].text == "let value = 1")
        if case .code("swift") = blocks[1].kind {} else { fatalError("Code language lost") }
        assert(MarkdownSection.parse("```swift\npartial").first?.text == "partial")
        let id = "12345678-1234-4234-8234-123456789abc"
        let envelope = "{\"attachments\":[{\"id\":\"\(id)\",\"name\":\"设计图.png\",\"size\":128,\"mime_type\":\"image/png\",\"path\":\"/tmp/agentmux/\(id)/content/设计图.png\"}]}"
        let parsed = AttachmentContent.parse("看看图片" + AttachmentContent.marker + envelope)
        assert(parsed.text == "看看图片" && parsed.files.first?.name == "设计图.png")
        assert(AttachmentContent.parse("ordinary text" + AttachmentContent.marker + "not JSON").files.isEmpty)
        assert(AttachmentContent.parse("text" + AttachmentContent.marker + envelope.replacingOccurrences(of: "/tmp/agentmux/\(id)/content/", with: "/etc/")).files.isEmpty)
        print("PASS: CLI command envelopes, literal XML/code preservation, ANSI output, Markdown fences/streaming and upload-card metadata")
    }
}
