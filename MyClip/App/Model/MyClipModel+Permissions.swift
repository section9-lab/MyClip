import AppKit
import MyClipCore

extension MyClipModel {
    func refreshPermissions() {
        screenPermission = captureService.hasScreenPermission
        accessibilityPermission = captureService.hasAccessibilityPermission
        // The preview runs as a differently signed build, so a folder read there would prompt again.
        if !preview { folderPermission = PermissionCoordinator.hasFolderAccess() }
        guard !preview, worker != nil else { return }
        capturing = captureService.isRunning
        if !screenPermission || !accessibilityPermission {
            if capturing { captureService.stop() }
            capturing = false
            captureStatus = String(localized: "等待屏幕录制和辅助功能权限，授权后将自动开始采集")
        } else if !capturing {
            applyCaptureSettings()
            capturing = captureService.start()
        }
    }

    func requestScreenPermission() { captureService.requestScreenPermission(); refreshPermissions() }
    func requestAccessibilityPermission() { captureService.requestAccessibilityPermission(); refreshPermissions() }

    func requestFolderPermission() {
        guard !preview else { return }
        PermissionCoordinator.markFolderAccessRequested()
        let manager = FileManager.default
        let home = manager.homeDirectoryForCurrentUser
        for name in ["Desktop", "Documents"] { _ = try? manager.contentsOfDirectory(at: home.appendingPathComponent(name), includingPropertiesForKeys: nil) }
        refreshPermissions()
        if !folderPermission { PermissionCoordinator.openFilesAndFoldersSettings() }
    }

    func applyCaptureSettings() {
        let excluded = Set(preferences.excludedApps.split(whereSeparator: { $0.isNewline || $0 == "," }).map {
            $0.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty })
        captureService.configure(settings: preferences.captureSettings, excludedBundleIDs: excluded)
    }
}
