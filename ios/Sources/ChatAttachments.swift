import SwiftUI
import UniformTypeIdentifiers
import ImageIO
import UIKit

struct PendingAttachment: Identifiable {
    let id: String
    let name: String
    let url: URL
    let size: Int
    let isImage: Bool
    var uploaded: RemoteAttachment?

    static func store(data: Data, name: String) throws -> PendingAttachment {
        guard data.count <= 8 * 1024 * 1024 else { throw attachmentError("单个附件不能超过 8 MiB。") }
        let id = UUID().uuidString.lowercased()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("chat-drafts", isDirectory: true).appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent((name as NSString).lastPathComponent)
        try data.write(to: url, options: .atomic)
        let image = CGImageSourceCreateWithData(data as CFData, nil).map { CGImageSourceGetCount($0) > 0 } ?? false
        return PendingAttachment(id: id, name: url.lastPathComponent, url: url, size: data.count, isImage: image)
    }
    static func photo(data: Data) throws -> PendingAttachment {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 2560, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary),
              let jpeg = UIImage(cgImage: image).jpegData(compressionQuality: 0.9) else { throw attachmentError("无法读取这张照片，请尝试从文件中选择。") }
        return try store(data: jpeg, name: "照片-" + String(UUID().uuidString.prefix(8)) + ".jpg")
    }
}
func attachmentError(_ text: String) -> NSError { NSError(domain: "AgentMux", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }

struct AttachmentThumbnail: View {
    @Environment(\.appTheme) private var theme
    let url: URL
    var body: some View {
        Group {
            if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
               let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 480, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) {
                Image(uiImage: UIImage(cgImage: image)).resizable().scaledToFill()
            } else { Image(systemName: "photo").font(.title).foregroundStyle(theme.secondary) }
        }.accessibilityHidden(true)
    }
}

struct PendingAttachmentsStrip: View {
    @Environment(\.appTheme) private var theme
    let files: [PendingAttachment]
    let disabled: Bool
    let remove: (String) -> Void
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(files) { file in
                    HStack(spacing: 9) {
                        if file.isImage { AttachmentThumbnail(url: file.url).frame(width: 50, height: 50).clipped().clipShape(RoundedRectangle(cornerRadius: 8)) }
                        else { Image(systemName: "doc.fill").font(.title3).foregroundStyle(theme.accent).frame(width: 36) }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(file.name).font(.caption.weight(.semibold)).lineLimit(1)
                            Text(ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file)).font(.caption2).foregroundStyle(theme.secondary)
                        }.frame(maxWidth: 140, alignment: .leading)
                        Button { remove(file.id) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(theme.secondary) }
                            .frame(width: 44, height: 44).disabled(disabled).accessibilityLabel("移除附件 \(file.name)")
                    }.padding(8).background(theme.surface, in: RoundedRectangle(cornerRadius: 12))
                }
            }.padding(.horizontal, 12).padding(.top, 10)
        }
    }
}

struct RemoteAttachmentCard: View {
    @Environment(\.appTheme) private var theme
    @EnvironmentObject var client: Client
    let file: RemoteAttachment
    @State private var local: URL?
    @State private var loading = false
    @State private var preview = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if file.isImage, let local {
                Button { preview = true } label: { AttachmentThumbnail(url: local).frame(height: 170).frame(maxWidth: .infinity).clipped().clipShape(RoundedRectangle(cornerRadius: 10)) }
                    .accessibilityLabel("预览图片 \(file.name)")
            }
            HStack(spacing: 10) {
                Image(systemName: file.isImage ? "photo" : "doc.fill").font(.title3).foregroundStyle(theme.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text(file.name).font(.subheadline.weight(.medium)).lineLimit(2)
                    Text(ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file)).font(.caption).foregroundStyle(theme.secondary)
                }
                Spacer(minLength: 8)
                if loading { ProgressView() }
                else if let local { ShareLink(item: local) { Image(systemName: "square.and.arrow.up") }.frame(minWidth: 44, minHeight: 44).accessibilityLabel("保存或分享附件") }
                else { Button { Task { await fetch(showError: true) } } label: { Image(systemName: "arrow.down.circle") }.frame(minWidth: 44, minHeight: 44).accessibilityLabel("下载附件") }
            }
        }.padding(10).background(theme.background.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
            .task(id: file.id) { if file.isImage { await fetch() } }
            .sheet(isPresented: $preview) {
                NavigationStack {
                    Group {
                        if let local, let image = UIImage(contentsOfFile: local.path) { Image(uiImage: image).resizable().scaledToFit() }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity).background(AppBackdrop())
                        .navigationTitle(file.name).navigationBarTitleDisplayMode(.inline)
                        .toolbar { Button("关闭") { preview = false } }
                }
            }
    }
    private func fetch(showError: Bool = false) async {
        guard !loading, local == nil else { return }
        if let cached = client.attachmentURLs[file.id], FileManager.default.fileExists(atPath: cached.path) { local = cached; return }
        loading = true; defer { loading = false }
        do {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("received-attachments").appendingPathComponent(file.id)
            let url = folder.appendingPathComponent((file.name as NSString).lastPathComponent)
            if !FileManager.default.fileExists(atPath: url.path) {
                let data = try await client.request("/v1/attachments/" + file.id)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
            }
            local = url
            client.attachmentURLs[file.id] = url
        } catch is CancellationError {} catch { if showError { client.error = error.localizedDescription } }
    }
}
