import Foundation

/// Centralised blocklist for apps that should be ignored by Sidey's
/// docking/icon and text-selection features.
///
/// Add bundle IDs here when an app:
///   - has no meaningful selectable text (system UI, remote desktop, games)
///   - shows only transient / ephemeral windows (screen savers, lock screen)
///   - would be disrupted by simulated keyboard events (remote desktop sessions)
enum AppBlocklist {

    // MARK: - Bundle IDs to block

    /// Apps that should NOT trigger the floating selection button.
    /// Usually apps with no real text content the user would want to send to AI.
    private static let selectionBlockedIDs: Set<String> = [
        // System UI & utilities
        "com.apple.systempreferences",          // System Settings
        "com.apple.Preferences",               // older name
        "com.apple.controlcenter",
        "com.apple.notificationcenterui",
        "com.apple.loginwindow",
        "com.apple.screensaver.engine",
        "com.apple.ScreenSaver.Engine",
        "com.apple.systemevents",
        "com.apple.SecurityAgent",
        "com.apple.universalaccessd",
        "com.apple.accessibility.universalAccessAuthWarn",
        "com.apple.ScreenReader",
        "com.apple.QuickLookUIService",
        "com.apple.quicklook.ui.helper",

        // Clock / time
        "com.apple.clock",
        "com.sindresorhus.Lungo",               // Lungo (keep-awake)

        // Remote desktop / screen sharing (Cmd+C would fire on the REMOTE machine)
        "com.apple.ScreenSharing",
        "com.apple.remotedesktop",
        "com.microsoft.rdc.macos",             // Microsoft Remote Desktop
        "com.microsoft.rdc",
        "com.royalapplications.royaltsx",      // Royal TSX
        "com.parallels.desktop.console",       // Parallels (VM console)
        "com.vmware.fusion",                   // VMware Fusion
        "com.utmapp.UTM",                      // UTM VMs

        // Media / games  (no text to select)
        "com.apple.QuickTimePlayerX",
        "com.apple.DVDPlayer",
        "com.apple.TV",
        "com.apple.Music",
        "com.apple.Podcasts",
        "com.apple.iBooks",                    // Books (DRM-locked)
    ]

    /// Apps that should NOT receive the docking icon / window companion.
    /// Superset of selectionBlockedIDs plus system-level processes.
    private static let dockingBlockedIDs: Set<String> = selectionBlockedIDs.union([
        "com.apple.Dock",
        "com.apple.Spotlight",
        "com.apple.Alfred",
        "com.runningwithcrayons.Alfred",
        "com.raycast.macos",
    ])

    /// Process-name substrings to block for docking (catches variants /
    /// processes that don't have a stable bundle ID).
    private static let dockingBlockedNameSubstrings: [String] = [
        "universalaccess",
        "quicklook",
        "screensaver",
        "loginwindow",
    ]

    // MARK: - Public API

    static func isBlockedForSelection(_ bundleID: String) -> Bool {
        selectionBlockedIDs.contains(bundleID)
    }

    static func isBlockedForDocking(_ identifier: String) -> Bool {
        let lower = identifier.lowercased()
        if dockingBlockedIDs.contains(identifier) { return true }
        return dockingBlockedNameSubstrings.contains { lower.contains($0) }
    }
}
