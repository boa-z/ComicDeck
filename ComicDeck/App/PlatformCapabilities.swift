import Foundation

enum PlatformCapabilities {
    #if os(iOS)
    static let supportsLiveActivity = true
    static let supportsPhotosSave = true
    static let supportsHardwareKeyboardMonitoring = true
    static let supportsIdleTimerControl = true
    static let supportsBackgroundTasks = true
    static let supportsDisplayScaleQuery = true
    static let supportsTabBar = true
    static let supportsStatusBar = true
    static let supportsMemoryPressureNotification = true
    #elseif os(macOS)
    static let supportsLiveActivity = false
    static let supportsPhotosSave = false
    static let supportsHardwareKeyboardMonitoring = false
    static let supportsIdleTimerControl = false
    static let supportsBackgroundTasks = false
    static let supportsDisplayScaleQuery = false
    static let supportsTabBar = false
    static let supportsStatusBar = false
    static let supportsMemoryPressureNotification = true
    #endif
}
