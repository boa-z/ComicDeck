import SwiftUI
import UIKit

#if targetEnvironment(macCatalyst)
struct ReaderKeyboardHost: UIViewRepresentable {
    let onLeftArrow: () -> Void
    let onRightArrow: () -> Void
    let onUpArrow: (() -> Void)?
    let onDownArrow: (() -> Void)?

    func makeUIView(context: Context) -> ReaderKeyboardView {
        let view = ReaderKeyboardView()
        view.updateHandlers(
            onLeftArrow: onLeftArrow,
            onRightArrow: onRightArrow,
            onUpArrow: onUpArrow,
            onDownArrow: onDownArrow
        )
        return view
    }

    func updateUIView(_ view: ReaderKeyboardView, context: Context) {
        view.updateHandlers(
            onLeftArrow: onLeftArrow,
            onRightArrow: onRightArrow,
            onUpArrow: onUpArrow,
            onDownArrow: onDownArrow
        )
        view.activate()
    }
}

final class ReaderKeyboardView: UIView {
    private var onLeftArrow: (() -> Void)?
    private var onRightArrow: (() -> Void)?
    private var onUpArrow: (() -> Void)?
    private var onDownArrow: (() -> Void)?
    private var activationScheduled = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var canBecomeFirstResponder: Bool { true }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        activate()
    }

    override var keyCommands: [UIKeyCommand]? {
        var commands: [UIKeyCommand] = [
            UIKeyCommand(input: UIKeyCommand.inputLeftArrow, modifierFlags: [], action: #selector(handleLeftArrow)),
            UIKeyCommand(input: UIKeyCommand.inputRightArrow, modifierFlags: [], action: #selector(handleRightArrow)),
        ]
        if onUpArrow != nil {
            commands.append(UIKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: [], action: #selector(handleUpArrow)))
        }
        if onDownArrow != nil {
            commands.append(UIKeyCommand(input: UIKeyCommand.inputDownArrow, modifierFlags: [], action: #selector(handleDownArrow)))
        }
        return commands
    }

    func updateHandlers(
        onLeftArrow: @escaping () -> Void,
        onRightArrow: @escaping () -> Void,
        onUpArrow: (() -> Void)?,
        onDownArrow: (() -> Void)?
    ) {
        self.onLeftArrow = onLeftArrow
        self.onRightArrow = onRightArrow
        self.onUpArrow = onUpArrow
        self.onDownArrow = onDownArrow
    }

    func activate() {
        guard window != nil else { return }
        guard !isFirstResponder else { return }
        guard !activationScheduled else { return }
        activationScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.activationScheduled = false
            guard self.window != nil, !self.isFirstResponder else { return }
            _ = self.becomeFirstResponder()
        }
    }

    @objc private func handleLeftArrow() {
        onLeftArrow?()
    }

    @objc private func handleRightArrow() {
        onRightArrow?()
    }

    @objc private func handleUpArrow() {
        onUpArrow?()
    }

    @objc private func handleDownArrow() {
        onDownArrow?()
    }
}
#endif
