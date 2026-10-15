import SwiftUI
import UIKit

struct AgentMenuCard: View {
    let menu: AgentMenu
    let disabled: Bool
    let act: (String, Int?) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("请选择", systemImage: "list.bullet.circle").font(.caption.weight(.semibold)).foregroundStyle(AppTheme.accent)
            Text(menu.title).font(.subheadline.bold())
            if !menu.detail.isEmpty, menu.detail != menu.title {
                DisclosureGroup("查看操作内容") { Text(menu.detail).font(.caption).textSelection(.enabled) }
            }
            ForEach(menu.options) { option in
                Button { act("menu_select", option.id) } label: {
                    HStack { Image(systemName: option.selected ? "checkmark.circle.fill" : "circle"); Text(option.label); Spacer() }
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain).padding(12).frame(minHeight: 48)
                    .background(option.selected ? AppTheme.accent.opacity(0.12) : AppTheme.elevated.opacity(0.6), in: RoundedRectangle(cornerRadius: 11))
                    .foregroundStyle(option.selected ? AppTheme.accent : AppTheme.text)
            }
            if let selected = menu.options.first(where: \.selected) {
                Button("确认：" + selected.label) { act("menu_confirm", nil) }.buttonStyle(PrimaryButtonStyle())
            }
            Button("取消", role: .cancel) { act("menu_cancel", nil) }.frame(maxWidth: .infinity, minHeight: 44)
        }.padding(16).appPanel().disabled(disabled)
    }
}
struct MessageCard: View {
    let message: ChatMessage
    let agent: String
    var command = "codex"
    private var outgoing: Bool { message.role == "user" }
    private var content: AttachmentContent { outgoing ? AttachmentContent.parse(message.text) : AttachmentContent(text: message.text, files: []) }
    private var files: [RemoteAttachment] { message.attachments ?? content.files }
    var body: some View {
        Group {
            if let tool = message.tool {
                ToolMessageCard(tool: tool)
            } else {
                switch MessagePresentation.parse(content.text) {
                case let .command(name, arguments):
                    HStack(spacing: 9) {
                        Image(systemName: "command").foregroundStyle(AppTheme.accent)
                        Text(name).font(.subheadline.monospaced().weight(.semibold))
                        if !arguments.isEmpty { Text(arguments).font(.subheadline).lineLimit(3) }
                    }.padding(.horizontal, 14).padding(.vertical, 10).background(AppTheme.surface.opacity(0.9), in: Capsule())
                        .frame(maxWidth: .infinity).contextMenu { copyButton }
                case let .notice(text):
                    Text(text).font(.caption).foregroundStyle(AppTheme.secondary).padding(.horizontal, 12).padding(.vertical, 7)
                        .background(AppTheme.surface.opacity(0.7), in: Capsule()).frame(maxWidth: .infinity)
                case let .output(text, isError):
                    VStack(alignment: .leading, spacing: 8) {
                        Label(isError ? "命令提示" : "命令结果", systemImage: isError ? "exclamationmark.circle" : "checkmark.circle")
                            .font(.caption.weight(.semibold)).foregroundStyle(isError ? AppTheme.warning : AppTheme.accent)
                        RichMessageBody(text: text)
                    }.padding(14).appPanel().contextMenu { copyButton }
                case .markdown:
                    bubble
                }
            }
        }.foregroundStyle(AppTheme.text)
    }
    private var bubble: some View {
        HStack(alignment: .bottom, spacing: 7) {
            if outgoing { Spacer(minLength: 42) }
            else { AgentAvatar(command: command, size: 28) }
            VStack(alignment: .leading, spacing: 7) {
                if !outgoing { Text(message.role == "assistant" ? agent : "会话动态").font(.caption.weight(.semibold)).foregroundStyle(AppTheme.provider(command)) }
                ForEach(files) { file in RemoteAttachmentCard(file: file) }
                if !content.text.isEmpty { RichMessageBody(text: content.text) }
            }.padding(.horizontal, 13).padding(.vertical, 10)
                .background(outgoing ? AppTheme.outgoing : AppTheme.surface)
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 18, bottomLeadingRadius: outgoing ? 18 : 5, bottomTrailingRadius: outgoing ? 5 : 18, topTrailingRadius: 18))
                .contextMenu { copyButton; ShareLink(item: message.text) { Label("分享", systemImage: "square.and.arrow.up") } }
            if !outgoing { Spacer(minLength: 30) }
        }
    }
    private var copyButton: some View {
        Button { UIPasteboard.general.string = message.text } label: { Label("复制", systemImage: "doc.on.doc") }
    }
}

struct RichMessageBody: View {
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(MarkdownSection.parse(text)) { section in
                switch section.kind {
                case .text:
                    ForEach(Array(section.text.components(separatedBy: "\n\n").enumerated()), id: \.offset) { _, paragraph in
                        if paragraph.hasPrefix("### ") { Text(.init(String(paragraph.dropFirst(4)))).font(.headline) }
                        else if paragraph.hasPrefix("## ") { Text(.init(String(paragraph.dropFirst(3)))).font(.title3.weight(.semibold)) }
                        else if paragraph.hasPrefix("# ") { Text(.init(String(paragraph.dropFirst(2)))).font(.title3.weight(.bold)) }
                        else if paragraph.hasPrefix("> ") {
                            HStack(spacing: 10) {
                                RoundedRectangle(cornerRadius: 2).fill(AppTheme.accent).frame(width: 3)
                                Text(.init(String(paragraph.dropFirst(2)))).font(.subheadline).foregroundStyle(AppTheme.secondary)
                            }.fixedSize(horizontal: false, vertical: true)
                        } else { Text(.init(paragraph)).font(.body).lineSpacing(3).fixedSize(horizontal: false, vertical: true) }
                    }.textSelection(.enabled)
                case let .code(language):
                    CodeBlock(code: section.text, language: language)
                }
            }
        }.tint(AppTheme.accent)
    }
}

struct CodeBlock: View {
    let code: String
    var language = ""
    @State private var copied = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "代码" : language).font(.caption.monospaced()).foregroundStyle(AppTheme.secondary)
                Spacer()
                Button {
                    UIPasteboard.general.string = code; copied = true
                    Task { try? await Task.sleep(for: .seconds(2)); copied = false }
                } label: { Label(copied ? "已复制" : "复制", systemImage: copied ? "checkmark" : "doc.on.doc").font(.caption) }
                    .frame(minHeight: 44).accessibilityLabel("复制代码")
            }.padding(.horizontal, 12)
            Divider().overlay(AppTheme.line)
            ScrollView(.horizontal) {
                Text(code).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false).padding(12)
            }
        }.background(AppTheme.background.opacity(0.8), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(AppTheme.line, lineWidth: 0.5))
    }
}

struct ToolMessageCard: View {
    let tool: ToolDetail
    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 12) {
                if !tool.input.isEmpty { Text("输入").font(.caption).foregroundStyle(AppTheme.secondary); CodeBlock(code: tool.input, language: "") }
                if !tool.output.isEmpty { Text("输出").font(.caption).foregroundStyle(AppTheme.secondary); CodeBlock(code: tool.output, language: "") }
            }.padding(.top, 12)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "wrench.and.screwdriver").foregroundStyle(AppTheme.secondary)
                Text(tool.name).font(.subheadline.weight(.medium)).lineLimit(1)
                Spacer()
                StatusBadge(title: tool.status == "running" ? "执行中" : tool.status == "error" ? "失败" : "已完成",
                            color: tool.status == "error" ? AppTheme.warning : AppTheme.secondary,
                            symbol: tool.status == "running" ? "clock" : tool.status == "error" ? "exclamationmark.circle" : "checkmark.circle")
            }
        }.padding(14).appPanel().tint(AppTheme.secondary)
    }
}

struct ApprovalView: View {
    let approval: AgentApproval
    let disabled: Bool
    let reply: (Bool, String, [String: [String]]) -> Void
    @State private var input = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(approval.title, systemImage: "hand.raised.fill").font(.headline).foregroundStyle(AppTheme.warning)
            if approval.kind != "questions" { Text(approval.detail).font(.caption).textSelection(.enabled) }
            if approval.kind == "questions" {
                QuestionForm(questions: approval.questions ?? []) { reply(true, "", $0) }
            } else if approval.kind == "unsupported" {
                Text("此请求暂不支持，请在 Mac 上处理或停止当前任务。").foregroundStyle(.orange)
            } else if approval.kind == "select" {
                ForEach(approval.options, id: \.self) { option in Button(option) { reply(true, option, [:]) } }
            } else if ["input", "editor"].contains(approval.kind) {
                TextField("回复", text: $input, axis: .vertical)
                Button("提交") { reply(true, input, [:]) }
            } else { Button("允许一次") { reply(true, "", [:]) }.buttonStyle(PrimaryButtonStyle()) }
            if approval.kind != "unsupported" { Button("拒绝 / 取消", role: .destructive) { reply(false, "", [:]) }.frame(maxWidth: .infinity, minHeight: 44) }
        }.padding(16).appPanel().overlay(RoundedRectangle(cornerRadius: 18).stroke(AppTheme.warning.opacity(0.55), lineWidth: 1)).disabled(disabled)
    }
}

struct QuestionForm: View {
    let questions: [AgentQuestion]
    let submit: ([String: [String]]) -> Void
    @State private var selected: [String: [String]] = [:]
    @State private var custom: [String: String] = [:]
    private var answers: [String: [String]] {
        questions.reduce(into: [:]) { result, question in
            let value = (custom[question.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            result[question.id] = value.isEmpty ? (selected[question.id] ?? []) : [value]
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(questions) { question in
                VStack(alignment: .leading, spacing: 8) {
                    Text(question.prompt).font(.subheadline.bold())
                    ForEach(question.options, id: \.label) { option in
                        Button {
                            custom[question.id] = ""
                            var values = selected[question.id] ?? []
                            if question.multiple {
                                if values.contains(option.label) { values.removeAll { $0 == option.label } }
                                else { values.append(option.label) }
                            } else { values = [option.label] }
                            selected[question.id] = values
                        } label: {
                            HStack(alignment: .top) {
                                Image(systemName: (selected[question.id] ?? []).contains(option.label) && (custom[question.id] ?? "").isEmpty ? "checkmark.circle.fill" : "circle")
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(option.label)
                                    if !option.description.isEmpty { Text(option.description).font(.caption).foregroundStyle(.secondary) }
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.bordered)
                    }
                    if question.other {
                        let binding = Binding(get: { custom[question.id] ?? "" }, set: { custom[question.id] = $0 })
                        if question.secret { SecureField("输入回复", text: binding).textFieldStyle(.roundedBorder) }
                        else { TextField("其他回复", text: binding, axis: .vertical).textFieldStyle(.roundedBorder) }
                    }
                }
            }
            Button("提交回答") { submit(answers) }.buttonStyle(.borderedProminent)
                .disabled(questions.isEmpty || answers.values.contains(where: \.isEmpty))
        }
    }
}
