import AppKit
import Common

@MainActor private var focusFollowsMouseMonitor: Any? = nil
@MainActor private var focusFollowsMouseTask: Task<(), any Error>? = nil

@MainActor
func installFocusFollowsMouseMonitor() {
    if let monitor = focusFollowsMouseMonitor {
        NSEvent.removeMonitor(monitor)
        focusFollowsMouseMonitor = nil
    }
    focusFollowsMouseTask?.cancel()
    focusFollowsMouseTask = nil

    if !config.focusFollowsMouse { return }

    focusFollowsMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { _ in
        Task { @MainActor in
            handleMouseMoveForFocusFollows()
        }
    }
}

@MainActor
private func handleMouseMoveForFocusFollows() {
    guard let token: RunSessionGuard = .isServerEnabled else { return }
    guard !isLeftMouseButtonDown else { return }

    let mouseLocation = mouseLocation
    let workspace = mouseLocation.monitorApproximation.activeWorkspace

    // Fast sync path: check tiled window without async work
    let tiledWindow = mouseLocation.findIn(tree: workspace.rootTilingContainer, virtual: false)
    if let tiledWindow, tiledWindow.windowId == focus.windowOrNil?.windowId {
        return // Already focused
    }

    // Async path: cancel previous task and start new one
    focusFollowsMouseTask?.cancel()
    focusFollowsMouseTask = Task {
        try checkCancellation()

        // Check floating windows first (they render on top)
        var targetWindow: Window? = nil
        for window in workspace.floatingWindows {
            if let rect = try await window.getAxRect() {
                let point = CGPoint(x: mouseLocation.x, y: mouseLocation.y)
                if rect.contains(point) {
                    targetWindow = window
                    break
                }
            }
        }

        // Fall back to tiled window
        if targetWindow == nil {
            targetWindow = tiledWindow
        }

        try checkCancellation()

        guard let targetWindow else { return } // Cursor over empty space
        guard targetWindow.windowId != focus.windowOrNil?.windowId else { return } // Already focused
        guard targetWindow.visualWorkspace != nil else { return } // Window in a hidden/unconventional container

        try await runLightSession(.focusFollowsMouse, token) {
            _ = targetWindow.focusWindow()
            targetWindow.nativeFocus()
        }
    }
}
