import SwiftUI
import AVFoundation
import CryptoKit
import PhotosUI
import Vision

struct PairingStatus: View {
    @EnvironmentObject var client: Client
    @State private var scanning = false
    @State private var connectingSSH = false
    @State private var forget = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let mac = client.paired {
                Label(mac.host, systemImage: "lock.shield.fill").foregroundStyle(.green)
                Text(mac.sshLogin == nil ? "SSH 加密 · 主机密钥已固定" : "\(mac.username)@\(mac.host):\(mac.port) · SSH 加密").font(.caption).foregroundStyle(.secondary)
                Button("断开并移除此设备", role: .destructive) { forget = true }
            } else {
                Text("使用 Mac 的 SSH 登录信息连接，自动发现 AgentMux 服务。无需生成二维码。").font(.subheadline)
                Button { connectingSSH = true } label: { Label("通过 SSH 连接 Mac", systemImage: "terminal") }.buttonStyle(.borderedProminent)
                Button { scanning = true } label: { Label("使用二维码连接", systemImage: "qrcode.viewfinder") }
            }
        }
        .sheet(isPresented: $scanning) { PairingSheet() }
        .sheet(isPresented: $connectingSSH) { SSHConnectionSheet() }
        .confirmationDialog("移除此设备的 AgentMux 凭据并断开连接？", isPresented: $forget) {
            Button("移除并断开", role: .destructive) { Task { await client.forget() } }
        }
    }
}
struct PairingSheet: View {
    @EnvironmentObject var client: Client
    @Environment(\.dismiss) var dismiss
    @State private var candidate: PairCode?
    @State private var error: String?
    @State private var busy = false
    @State private var photo: PhotosPickerItem?
    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                if let code = candidate {
                    Image(systemName: "lock.shield").font(.system(size: 64)).foregroundStyle(.blue)
                    Text("连接到 \(code.host)").font(.title2)
                    Text("请确认二维码来自你自己的 Mac。配对将允许此手机操作授权目录中的 Agent 和文件。").padding(.horizontal)
                    Text(sshFingerprint(code.hostKey)).font(.caption.monospaced()).textSelection(.enabled)
                    Button(busy ? "正在校验主机并配对…" : "确认配对") {
                        busy = true
                        Task {
                            do { try await client.pair(code); dismiss() }
                            catch { self.error = error.localizedDescription }
                            busy = false
                        }
                    }.buttonStyle(.borderedProminent).disabled(busy)
                    Button("重新扫描") { candidate = nil; error = nil }.disabled(busy)
                } else {
                    CameraScanner { parse($0) }.frame(maxHeight: 420).clipShape(RoundedRectangle(cornerRadius: 20))
                    Text("扫描 Mac 上的 AgentMux 二维码").font(.headline)
                    PhotosPicker("从二维码图片配对", selection: $photo, matching: .images)
                }
                if let error { Text(error).font(.caption).foregroundStyle(.red).padding() }
                Spacer()
            }
            .padding()
            .navigationTitle("安全配对")
            .toolbar { Button("关闭") { dismiss() }.disabled(busy) }
            .onChange(of: photo) { _, item in
                Task {
                    do {
                        guard let data = try await item?.loadTransferable(type: Data.self) else { return }
                        let request = VNDetectBarcodesRequest(); request.symbologies = [.qr]
                        try VNImageRequestHandler(data: data).perform([request])
                        guard let payload = request.results?.first?.payloadStringValue else { throw URLError(.cannotDecodeContentData) }
                        parse(payload)
                    } catch { self.error = "图片中未找到有效的配对二维码" }
                }
            }
        }
    }
    func parse(_ value: String) {
        do {
            guard value.utf8.count < 4096 else { throw URLError(.dataLengthExceedsMaximum) }
            let code = try JSONDecoder().decode(PairCode.self, from: Data(value.utf8))
            guard code.version == 1, code.expires > UInt64(Date().timeIntervalSince1970) else { throw URLError(.timedOut) }
            candidate = code; error = nil
        } catch { self.error = "二维码无效或已过期，请在 Mac 重新运行 agentmuxd pair" }
    }
}
func sshFingerprint(_ key: String) -> String {
    let pieces = key.split(separator: " ")
    guard pieces.count >= 2, let data = Data(base64Encoded: String(pieces[1])) else { return "无效主机公钥" }
    return "SHA256:" + Data(SHA256.hash(data: data)).base64EncodedString().replacingOccurrences(of: "=", with: "")
}
struct CameraScanner: UIViewControllerRepresentable {
    let onCode: (String) -> Void
    func makeUIViewController(context: Context) -> ScannerController { ScannerController(onCode: onCode) }
    func updateUIViewController(_ controller: ScannerController, context: Context) {}
    static func dismantleUIViewController(_ controller: ScannerController, coordinator: ()) { controller.stop() }
}
final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    private let capture = AVCaptureSession()
    private let queue = DispatchQueue(label: "dev.agentmux.camera")
    private let onCode: (String) -> Void
    private var preview: AVCaptureVideoPreviewLayer?
    private var found = false
    // Access only on queue, including permission callbacks and teardown.
    private var stopped = false
    init(onCode: @escaping (String) -> Void) { self.onCode = onCode; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { nil }
    override func viewDidLoad() {
        super.viewDidLoad()
        let preview = AVCaptureVideoPreviewLayer(session: capture)
        preview.videoGravity = .resizeAspectFill
        view.layer.addSublayer(preview)
        self.preview = preview
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard granted else { return }
            self?.queue.async { [weak self] in self?.configure() }
        }
    }
    private func configure() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !stopped, configureSession() else { return }
        capture.startRunning()
    }
    private func configureSession() -> Bool {
        capture.beginConfiguration()
        defer { capture.commitConfiguration() }
        guard let device = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: device), capture.canAddInput(input) else { return false }
        capture.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard capture.canAddOutput(output) else { return false }
        capture.addOutput(output); output.setMetadataObjectsDelegate(self, queue: .main); output.metadataObjectTypes = [.qr]
        return true
    }
    override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); preview?.frame = view.bounds }
    func stop() {
        queue.async { [self] in
            stopped = true
            if capture.isRunning { capture.stopRunning() }
        }
    }
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard !found, let code = objects.first as? AVMetadataMachineReadableCodeObject, let value = code.stringValue else { return }
        found = true; stop(); onCode(value)
    }
}
