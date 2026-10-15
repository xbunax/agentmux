import SwiftUI
import UIKit
import SwiftTerm

/// The terminal is output-only. A separate IME-aware receiver owns direct input;
/// terminal replies, mouse reports and clipboard requests never become user input.
private final class ReadOnlyTerminal: TerminalView {
    override var canBecomeFirstResponder: Bool { false }
}
struct TerminalSurface: UIViewRepresentable {
    let model: TerminalSessionModel
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> UIScrollView {
        let scroll = UIScrollView()
        scroll.backgroundColor = .systemBackground
        scroll.minimumZoomScale = 0.5; scroll.maximumZoomScale = 2
        let terminal = ReadOnlyTerminal(frame: CGRect(x: 0, y: 0, width: 640, height: 420), font: .monospacedSystemFont(ofSize: 13, weight: .regular))
        terminal.terminalDelegate = context.coordinator
        terminal.isUserInteractionEnabled = false
        terminal.nativeBackgroundColor = UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.035, green: 0.045, blue: 0.06, alpha: 1) : .white }
        terminal.nativeForegroundColor = .label
        scroll.addSubview(terminal)
        context.coordinator.terminal = terminal
        scroll.delegate = context.coordinator
        model.bindOutput { [weak terminal, weak scroll] data, cols, rows in
            guard let terminal, let scroll else { return }
            if let cols, let rows {
                terminal.resize(cols: cols, rows: rows)
                terminal.frame = terminal.getOptimalFrameSize()
                scroll.contentSize = terminal.frame.size
                terminal.layoutIfNeeded()
                scroll.setContentOffset(.zero, animated: false)
            }
            terminal.feed(byteArray: Array(data)[...])
        }
        model.browse = { [weak scroll] dx, dy in
            guard let scroll else { return }
            let x = min(max(0, scroll.contentOffset.x + dx), max(0, scroll.contentSize.width - scroll.bounds.width))
            let y = min(max(0, scroll.contentOffset.y + dy), max(0, scroll.contentSize.height - scroll.bounds.height))
            scroll.setContentOffset(CGPoint(x: x, y: y), animated: false)
        }
        scroll.accessibilityLabel = "原始终端现场，可双指缩放或在滑控浏览模式移动视口"
        return scroll
    }
    func updateUIView(_ uiView: UIScrollView, context: Context) {}
    final class Coordinator: NSObject, TerminalViewDelegate, UIScrollViewDelegate {
        weak var terminal: TerminalView?
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { terminal }
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {} // Never resize Mac.
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func send(source: TerminalView, data: ArraySlice<UInt8>) {} // Not a user action.
        func scrolled(source: TerminalView, position: Double) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
        func clipboardCopy(source: TerminalView, content: Data) {}
        func clipboardRead(source: TerminalView) -> Data? { nil }
        func bell(source: TerminalView) {}
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}

/// UITextView keeps Chinese marked text local. Only committed contents cross SSH.
/// A sentinel lets deleteBackward reach the remote editor when local storage is empty.
struct TerminalKeyboard: UIViewRepresentable {
    var enabled: Bool
    @Binding var focused: Bool
    let commit: (String) -> Void
    let key: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UITextView {
        let view = KeyReceiver()
        view.delegate = context.coordinator
        view.key = { [weak coordinator = context.coordinator] name in
            guard coordinator?.enabled == true else { return }
            coordinator?.parent.key(name)
        }
        view.text = Coordinator.sentinel
        view.selectedRange = NSRange(location: 1, length: 0)
        view.font = .preferredFont(forTextStyle: .body)
        view.backgroundColor = .clear; view.textColor = .label
        view.autocorrectionType = .no; view.autocapitalizationType = .none
        view.smartQuotesType = .no; view.smartDashesType = .no; view.smartInsertDeleteType = .no
        view.accessibilityLabel = "正在输入到终端，回车发送 Enter"
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self; context.coordinator.enabled = enabled && focused
        view.isEditable = enabled
        if enabled && focused && !view.isFirstResponder { view.becomeFirstResponder() }
        if (!enabled || !focused) && view.isFirstResponder { view.resignFirstResponder() }
    }
    static func dismantleUIView(_ view: UITextView, coordinator: Coordinator) {
        coordinator.enabled = false; view.resignFirstResponder(); view.delegate = nil
    }
    final class Coordinator: NSObject, UITextViewDelegate {
        static let sentinel = "\u{200B}"
        var parent: TerminalKeyboard
        var enabled = false
        var resetting = false
        init(_ parent: TerminalKeyboard) { self.parent = parent; enabled = parent.enabled }
        func textViewDidBeginEditing(_ textView: UITextView) {
            enabled = parent.enabled; parent.focused = true
        }
        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            guard enabled else { return false }
            if textView.markedTextRange == nil && text.isEmpty && range.location == 0 && textView.text == Self.sentinel {
                parent.key("BSpace"); return false
            }
            return true
        }
        func textViewDidChange(_ textView: UITextView) {
            guard enabled, !resetting, textView.markedTextRange == nil else { return }
            let committed = textView.text.hasPrefix(Self.sentinel) ? String(textView.text.dropFirst()) : textView.text ?? ""
            resetting = true
            textView.text = Self.sentinel; textView.selectedRange = NSRange(location: 1, length: 0)
            resetting = false
            if !committed.isEmpty { parent.commit(committed) }
        }
    }
    private final class KeyReceiver: UITextView {
        var key: ((String) -> Void)?
        override var keyCommands: [UIKeyCommand]? {
            [(UIKeyCommand.inputUpArrow,"Up"),(UIKeyCommand.inputDownArrow,"Down"),(UIKeyCommand.inputLeftArrow,"Left"),(UIKeyCommand.inputRightArrow,"Right"),(UIKeyCommand.inputEscape,"Escape"),("\t","Tab")].map { input, title in
                let command = UIKeyCommand(title: title, action: #selector(special(_:)), input: input)
                command.wantsPriorityOverSystemBehavior = markedTextRange == nil
                return command
            }
        }
        @objc private func special(_ command: UIKeyCommand) { if markedTextRange == nil { key?(command.title) } }
    }
}
