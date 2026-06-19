import Foundation
#if os(iOS)
import UIKit
import GameController
#endif

@MainActor
@Observable
final class ReaderPlatformMonitor {
    var onMemoryPressure: (() -> Void)?

    private var onKeyboardLeft: (() -> Void)?
    private var onKeyboardRight: (() -> Void)?
    private var onKeyboardUp: (() -> Void)?
    private var onKeyboardDown: (() -> Void)?

    #if os(iOS)
    private var keyboardDidConnectObserver: NSObjectProtocol?
    private var keyboardDidDisconnectObserver: NSObjectProtocol?
    #endif
    private var memoryPressureObserver: NSObjectProtocol?
    #if os(macOS)
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    #endif

    func install(
        onLeft: @escaping () -> Void,
        onRight: @escaping () -> Void,
        onUp: @escaping () -> Void,
        onDown: @escaping () -> Void,
        onMemoryPressure: @escaping () -> Void
    ) {
        self.onKeyboardLeft = onLeft
        self.onKeyboardRight = onRight
        self.onKeyboardUp = onUp
        self.onKeyboardDown = onDown
        self.onMemoryPressure = onMemoryPressure

        installKeyboardMonitoring()
        installMemoryPressureMonitoring()
    }

    func uninstall() {
        uninstallKeyboardMonitoring()
        uninstallMemoryPressureMonitoring()
    }

    func setKeepScreenOn(_ enabled: Bool) {
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = enabled
        #endif
    }

    func disableKeepScreenOn() {
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = false
        #endif
    }

    private func installKeyboardMonitoring() {
        #if os(iOS)
        attachKeyboardHandler()
        keyboardDidConnectObserver = NotificationCenter.default.addObserver(
            forName: .GCKeyboardDidConnect,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.attachKeyboardHandler()
            }
        }
        keyboardDidDisconnectObserver = NotificationCenter.default.addObserver(
            forName: .GCKeyboardDidDisconnect,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.clearKeyboardHandler()
            }
        }
        #endif
    }

    private func installMemoryPressureMonitoring() {
        #if os(iOS)
        memoryPressureObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleMemoryPressure()
            }
        }
        #elseif os(macOS)
        memoryPressureSource = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        memoryPressureSource?.setEventHandler { [weak self] in
            Task { @MainActor in
                self?.handleMemoryPressure()
            }
        }
        memoryPressureSource?.resume()
        #endif
    }

    private func uninstallKeyboardMonitoring() {
        #if os(iOS)
        clearKeyboardHandler()
        if let observer = keyboardDidConnectObserver {
            NotificationCenter.default.removeObserver(observer)
            keyboardDidConnectObserver = nil
        }
        if let observer = keyboardDidDisconnectObserver {
            NotificationCenter.default.removeObserver(observer)
            keyboardDidDisconnectObserver = nil
        }
        #endif
    }

    private func uninstallMemoryPressureMonitoring() {
        if let observer = memoryPressureObserver {
            NotificationCenter.default.removeObserver(observer)
            memoryPressureObserver = nil
        }
        #if os(macOS)
        memoryPressureSource?.cancel()
        memoryPressureSource = nil
        #endif
    }

    #if os(iOS)
    private func attachKeyboardHandler() {
        GCKeyboard.coalesced?.keyboardInput?.keyChangedHandler = { [weak self] _, _, keyCode, pressed in
            guard pressed else { return }
            Task { @MainActor in
                self?.handleKeyboardKey(keyCode)
            }
        }
    }

    private func clearKeyboardHandler() {
        GCKeyboard.coalesced?.keyboardInput?.keyChangedHandler = nil
    }

    private func handleKeyboardKey(_ keyCode: GCKeyCode) {
        switch keyCode {
        case GCKeyCode.leftArrow, GCKeyCode.keypad4:
            onKeyboardLeft?()
        case GCKeyCode.rightArrow, GCKeyCode.keypad6:
            onKeyboardRight?()
        case GCKeyCode.upArrow, GCKeyCode.keypad8:
            onKeyboardUp?()
        case GCKeyCode.downArrow, GCKeyCode.keypad2:
            onKeyboardDown?()
        default:
            break
        }
    }
    #endif

    private func handleMemoryPressure() {
        onMemoryPressure?()
    }
}
