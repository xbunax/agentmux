import SwiftUI
import PhotosUI
import Vision
import VisionKit
import AVFoundation

struct AddConnectionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var ssh = false
    @State private var iroh = false
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button { iroh = true } label: { Label("扫码连接 · iroh", systemImage: "qrcode.viewfinder") }
                    Button { ssh = true } label: { Label("通过 SSH 连接", systemImage: "terminal") }
                } footer: {
                    Text("iroh 可通过点对点直连或加密中继连接 Mac，无需开启远程登录。SSH 连接方式继续保留。")
                }
            }.appList().navigationTitle("添加 Mac").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("完成") { dismiss() } }
                .sheet(isPresented: $ssh, onDismiss: { dismiss() }) { SSHConnectionSheet() }
                .sheet(isPresented: $iroh, onDismiss: { dismiss() }) { IrohConnectionSheet() }
        }
    }
}

struct IrohConnectionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var client: Client
    @State private var text = ""
    @State private var photo: PhotosPickerItem?
    @State private var scanning = false
    @State private var busy = false
    @State private var error: String?
    @State private var operation: Task<Void, Never>?
    private var code: IrohPairCode? { try? IrohPairCode.parse(text) }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("在 Mac 上运行以下命令，再扫描生成的二维码。二维码 5 分钟内有效，只能使用一次。")
                    Text("agentmuxd pair --transport iroh").font(.footnote.monospaced()).textSelection(.enabled)
                }
                Section("读取配对码") {
                    Button { startCamera() } label: { Label("扫描二维码", systemImage: "qrcode.viewfinder") }
                    PhotosPicker(selection: $photo, matching: .images) { Label("从照片读取", systemImage: "photo") }
                    PasteButton(payloadType: String.self) { strings in text = strings.first ?? ""; error = nil }
                    TextEditor(text: $text).font(.caption.monospaced()).frame(minHeight: 80)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Text("也可以粘贴 Mac 生成的 pair-iroh.json 内容。").font(.caption).foregroundStyle(.secondary)
                }.disabled(busy)
                if let code {
                    Section("确认 Mac") {
                        LabeledContent("名称", value: code.name)
                        Text(code.endpointID).font(.caption.monospaced()).textSelection(.enabled)
                        Text("请核对这张二维码来自你的 Mac。连接后固定此设备身份，凭据保存在 iPhone 钥匙串。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section {
                    Button {
                        guard let code else { return }
                        busy = true; error = nil
                        operation = Task {
                            defer { busy = false }
                            do { try await client.connectIroh(code); dismiss() }
                            catch is CancellationError {} catch { self.error = error.localizedDescription }
                        }
                    } label: {
                        HStack { if busy { ProgressView() }; Text(busy ? "正在配对…" : "配对并连接") }
                    }.disabled(code == nil || busy)
                    if let error { Text(error).foregroundStyle(.red).font(.caption) }
                    if !text.isEmpty && code == nil { Text("配对码无效或已过期，请在 Mac 上重新生成。").font(.caption).foregroundStyle(.secondary) }
                }
            }.appList().navigationTitle("iroh 配对").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("关闭") { dismiss() } }
                .onDisappear { operation?.cancel() }
                .sheet(isPresented: $scanning) {
                    NavigationStack {
                        QRScanner { text = $0; error = nil; scanning = false }
                            .ignoresSafeArea(edges: .bottom).navigationTitle("扫描 Mac 配对码")
                            .toolbar { Button("取消") { scanning = false } }
                    }
                }
                .task(id: photo) {
                    guard let photo else { return }
                    do {
                        guard let data = try await photo.loadTransferable(type: Data.self), data.count <= 20 * 1024 * 1024 else {
                            throw IrohError.message("请选择不超过 20 MiB 的二维码图片")
                        }
                        let result = try await Task.detached {
                            let request = VNDetectBarcodesRequest(); request.symbologies = [.qr]
                            try VNImageRequestHandler(data: data).perform([request])
                            return request.results?.compactMap(\.payloadStringValue).first { (try? IrohPairCode.parse($0)) != nil }
                        }.value
                        guard let result else { throw IrohError.message("图片中没有有效的 AgentMux 配对码") }
                        text = result; error = nil
                    } catch { self.error = error.localizedDescription }
                }
        }
    }
    private func startCamera() {
        operation = Task {
            guard DataScannerViewController.isSupported else { error = "此设备不支持扫码，请从照片读取或粘贴配对码"; return }
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            guard granted else { error = "请在系统设置中允许相机访问，或从照片读取配对码"; return }
            guard DataScannerViewController.isAvailable else { error = "相机暂不可用，请从照片读取配对码"; return }
            scanning = true
        }
    }
}

private struct QRScanner: UIViewControllerRepresentable {
    var found: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(found) }
    func makeUIViewController(context: Context) -> DataScannerViewController {
        let controller = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], recognizesMultipleItems: false, isGuidanceEnabled: true, isHighlightingEnabled: true)
        controller.delegate = context.coordinator
        do { try controller.startScanning() } catch { controller.stopScanning() }
        return controller
    }
    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}
    static func dismantleUIViewController(_ controller: DataScannerViewController, coordinator: Coordinator) { controller.stopScanning() }
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let found: (String) -> Void
        var delivered = false
        init(_ found: @escaping (String) -> Void) { self.found = found }
        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !delivered else { return }
            for item in addedItems {
                if case .barcode(let code) = item, let payload = code.payloadStringValue, (try? IrohPairCode.parse(payload)) != nil {
                    delivered = true; dataScanner.stopScanning(); found(payload); return
                }
            }
        }
    }
}
