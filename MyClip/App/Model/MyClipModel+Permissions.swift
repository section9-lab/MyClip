import AppKit
import MyClipCore

extension MyClipModel {
    func refreshPermissions() {
        let screen = captureService.hasScreenPermission
        let accessibility = captureService.hasAccessibilityPermission
        if screenPermission != screen { screenPermission = screen }
        if accessibilityPermission != accessibility { accessibilityPermission = accessibility }
        // The preview runs as a differently signed build, so a folder read there would prompt again.
        if !preview {
            let folder = PermissionCoordinator.hasFolderAccess()
            if folderPermission != folder { folderPermission = folder }
        }
        guard !preview, worker != nil else { return }
        if capturing != captureService.isRunning { capturing = captureService.isRunning }
        if !screenPermission || !accessibilityPermission {
            if capturing { captureService.stop() }
            if capturing { capturing = false }
            let status = String(localized: "等待屏幕录制和辅助功能权限，授权后将自动开始采集")
            if captureStatus != status { captureStatus = status }
        } else if !capturing {
            applyCaptureSettings()
            capturing = captureService.start()
        }
    }

    func requestScreenPermission() {
        if screenPermission { PermissionCoordinator.openScreenCaptureSettings() }
        else { captureService.requestScreenPermission(); refreshPermissions() }
    }

    func requestAccessibilityPermission() {
        if accessibilityPermission { PermissionCoordinator.openAccessibilitySettings() }
        else { captureService.requestAccessibilityPermission(); refreshPermissions() }
    }

    func requestFolderPermission() {
        guard !preview else { return }
        if folderPermission { PermissionCoordinator.openFilesAndFoldersSettings(); return }
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
