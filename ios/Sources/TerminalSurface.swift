import SwiftUI
import UIKit
import SwiftTerm

/// The terminal is output-only. A separate IME-aware receiver owns direct input;
/// terminal replies, mouse reports and clipboard requests never become user input.
private final class ReadOnlyTerminal: TerminalView {
    override var canBecomeFirstResponder: Bool { false }
}
private final class TerminalViewport: UIScrollView {
    var resized: ((CGSize) -> Void)?
    private var previousSize = CGSize.zero
    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != previousSize {
            previousSize = bounds.size
            resized?(bounds.size)
        }
    }
}
struct TerminalSurface: UIViewRepresentable {
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var solid
    let model: TerminalSessionModel
    var onBrowse: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(model: model, onBrowse: onBrowse) }
    func makeUIView(context: Context) -> UIScrollView {
        let scroll = TerminalViewport()
        scroll.backgroundColor = .clear
        scroll.alwaysBounceVertical = true
        scroll.minimumZoomScale = 0.5; scroll.maximumZoomScale = 2
        scroll.contentInsetAdjustmentBehavior = .never
        let terminal = ReadOnlyTerminal(frame: CGRect(x: 0, y: 0, width: 640, height: 420), font: .monospacedSystemFont(ofSize: 13, weight: .regular))
        terminal.terminalDelegate = context.coordinator
        terminal.isUserInteractionEnabled = false
        scroll.addSubview(terminal)
        context.coordinator.terminal = terminal
        context.coordinator.scroll = scroll
        scroll.delegate = context.coordinator
        scroll.resized = { [weak coordinator = context.coordinator] size in
            coordinator?.reportViewport(size)
        }
        model.bindOutput { [weak coordinator = context.coordinator] data, cols, rows in
            guard let coordinator, let terminal = coordinator.terminal, let scroll = coordinator.scroll else { return }
            let offset = scroll.contentOffset
            if let cols, let rows {
                let scale = scroll.zoomScale
                scroll.setZoomScale(1, animated: false)
                terminal.resize(cols: cols, rows: rows)
                terminal.frame = terminal.getOptimalFrameSize()
                terminal.layoutIfNeeded()
                scroll.contentSize = terminal.frame.size
                scroll.setZoomScale(scale, animated: false)
                scroll.contentOffset = offset
            }
            terminal.feed(byteArray: Array(data)[...])
            if coordinator.followCursor { coordinator.showCursor() }
            coordinator.reportViewport(scroll.bounds.size)
        }
        model.browse = { [weak coordinator = context.coordinator] dx, dy in
            guard let coordinator, let scroll = coordinator.scroll else { return false }
            coordinator.followCursor = false
            let x = min(max(0, scroll.contentOffset.x + dx), max(0, scroll.contentSize.width - scroll.bounds.width))
            let y = min(max(0, scroll.contentOffset.y + dy), max(0, scroll.contentSize.height - scroll.bounds.height))
            let moved = abs(x - scroll.contentOffset.x) + abs(y - scroll.contentOffset.y) > 0.5
            scroll.setContentOffset(CGPoint(x: x, y: y), animated: false)
            return moved
        }
        model.returnToCursor = { [weak coordinator = context.coordinator] in
            coordinator?.followCursor = true; coordinator?.showCursor()
        }
        scroll.accessibilityLabel = "实时终端，可滚动浏览或双指缩放"
        applyTheme(terminal)
        context.coordinator.themeKey = themeKey
        return scroll
    }
    func updateUIView(_ uiView: UIScrollView, context: Context) {
        context.coordinator.onBrowse = onBrowse
        if context.coordinator.themeKey != themeKey, let terminal = context.coordinator.terminal {
            applyTheme(terminal); context.coordinator.themeKey = themeKey
        }
    }
    private var themeKey: String { "\(theme.palette.rawValue)-\(scheme)-\(solid)" }
    private func applyTheme(_ terminal: TerminalView) {
        let colors = theme.palette.colors(dark: scheme == .dark)
        func native(_ value: UInt32, alpha: CGFloat = 1) -> UIColor {
            UIColor(red: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: alpha)
        }
        terminal.isOpaque = solid
        terminal.nativeBackgroundColor = native(colors[0], alpha: solid ? 1 : 0.78)
        terminal.nativeForegroundColor = native(colors[2])
        terminal.caretColor = native(colors[4])
        terminal.selectedTextBackgroundColor = native(colors[4], alpha: 0.3)
        terminal.selectedTextForegroundColor = native(colors[2])
        terminal.installColors(theme.palette.ansi(dark: scheme == .dark).map { value in
            SwiftTerm.Color(red8: UInt16((value >> 16) & 255), green8: UInt16((value >> 8) & 255), blue8: UInt16(value & 255))
        })
    }
    final class Coordinator: NSObject, TerminalViewDelegate, UIScrollViewDelegate {
        weak var terminal: TerminalView?
        weak var scroll: UIScrollView?
        let model: TerminalSessionModel
        var onBrowse: () -> Void
        var followCursor = true
        var themeKey = ""
        private var lastViewport = CGSize.zero
        private var dragOrigin = CGPoint.zero
        private var didBrowse = false
        init(model: TerminalSessionModel, onBrowse: @escaping () -> Void) { self.model = model; self.onBrowse = onBrowse }
        func reportViewport(_ size: CGSize) {
            guard size.width > 0, size.height > 0, size != lastViewport, let terminal else { return }
            lastViewport = size
            let frame = terminal.getOptimalFrameSize()
            let grid = terminal.getTerminal()
            let cellWidth = frame.width / CGFloat(max(1, grid.cols))
            let cellHeight = frame.height / CGFloat(max(1, grid.rows))
            guard cellWidth > 0, cellHeight > 0 else { return }
            let cols = Int(size.width / cellWidth), rows = Int(size.height / cellHeight)
            DispatchQueue.main.async { [weak self] in
                self?.model.setViewport(cols: cols, rows: rows)
                if self?.followCursor == true { self?.showCursor() }
            }
        }
        func showCursor() {
            guard let terminal, let scroll else { return }
            let grid = terminal.getTerminal(), frame = terminal.getOptimalFrameSize()
            let cursor = grid.getCursorLocation()
            let w = frame.width / CGFloat(max(1, grid.cols)), h = frame.height / CGFloat(max(1, grid.rows))
            let scale = scroll.zoomScale
            scroll.scrollRectToVisible(CGRect(x: CGFloat(cursor.x) * w * scale, y: CGFloat(cursor.y) * h * scale, width: w * scale, height: h * scale), animated: false)
        }
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { terminal }
        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { followCursor = false; dragOrigin = scrollView.contentOffset; didBrowse = false }
        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            if scrollView.isDragging && abs(scrollView.contentOffset.x - dragOrigin.x) + abs(scrollView.contentOffset.y - dragOrigin.y) > 8 { didBrowse = true }
        }
        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate { finishBrowse(scrollView) }
        }
        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { finishBrowse(scrollView) }
        private func finishBrowse(_ scrollView: UIScrollView) {
            if didBrowse { didBrowse = false; onBrowse() }
        }
        func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) { followCursor = false }
        func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) { onBrowse() }
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {} // Only viewport layout requests remote size changes.
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
    var keepKeyboard = false
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
        let acceptsFocus = enabled || keepKeyboard
        view.isEditable = acceptsFocus
        if acceptsFocus && focused && !view.isFirstResponder { view.becomeFirstResponder() }
        if (!acceptsFocus || !focused) && view.isFirstResponder { view.resignFirstResponder() }
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
