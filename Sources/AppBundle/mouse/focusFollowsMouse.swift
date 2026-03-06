import AppKit
import Common

@MainActor private var mouseMoveMonitor: Any? = nil
@MainActor private var lastMousePosition: CGPoint = .zero
@MainActor private var focusFollowsMouseTask: Task<(), any Error>? = nil
@MainActor private var lastFocusSource: FocusSource = .unknown
@MainActor private var keyboardFocusedWindowRect: Rect? = nil

// Debouncing to avoid excessive focus changes
private let focusFollowsMouseDebounceMs: Int = 50

enum FocusSource {
    case mouse
    case keyboard
    case unknown
}

@MainActor
func initFocusFollowsMouse() {
    print("Focus-follows-mouse: Initializing with config.focusFollowsMouse = \(config.focusFollowsMouse)")
    print("Focus-follows-mouse: Behavior = \(config.focusFollowsMouseBehavior)")
    print("Focus-follows-mouse: Ignore menu bar = \(config.focusFollowsMouseIgnoreMenuBar)")

    guard config.focusFollowsMouse else {
        print("Focus-follows-mouse: Disabled, not initializing")
        return
    }

    deinitFocusFollowsMouse() // Clean up any existing monitor

    mouseMoveMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { _ in
        handleMouseMoved()
    }

    print("Focus-follows-mouse: Mouse monitor initialized")
}

@MainActor
func deinitFocusFollowsMouse() {
    if let monitor = mouseMoveMonitor {
        NSEvent.removeMonitor(monitor)
        mouseMoveMonitor = nil
    }
    focusFollowsMouseTask?.cancel()
}

@MainActor
private func handleMouseMoved() {
    let currentMousePosition = mouseLocation
    print("Focus-follows-mouse: Mouse moved to \(currentMousePosition)")

    // Skip if mouse hasn't moved significantly
    guard currentMousePosition.distance(to: lastMousePosition) > 1 else { 
        print("Focus-follows-mouse: Movement too small, skipping")
        return 
    }

    // For immediate mode, always proceed
    // For cross-boundary mode, check for boundary crossing
    var shouldProceed = true
    if config.focusFollowsMouseBehavior == .crossBoundary {
        shouldProceed = hasMouseCrossedWindowBoundary(currentMousePosition)
        if !shouldProceed {
            print("Focus-follows-mouse: No boundary crossing detected")
            // Always update position even if no boundary crossing for next comparison
            lastMousePosition = currentMousePosition
            return
        }
    }

    print("Focus-follows-mouse: Proceeding with focus change")
    lastMousePosition = currentMousePosition

    // Debounce rapid mouse movements
    focusFollowsMouseTask?.cancel()
    focusFollowsMouseTask = Task {
        try await Task.sleep(for: .milliseconds(focusFollowsMouseDebounceMs))
        try checkCancellation()

        await focusWindowUnderMouse(at: currentMousePosition)
    }
}

@MainActor
private func hasMouseCrossedWindowBoundary(_ point: CGPoint) -> Bool {
    // Check if mouse moved from one window area to another
    let currentWindowUnderMouse = findWindowUnderMouse(at: point)
    let previousWindowUnderMouse = findWindowUnderMouse(at: lastMousePosition)

    print("Focus-follows-mouse: Current window under mouse: \(currentWindowUnderMouse?.windowId ?? 0), Previous window under mouse: \(previousWindowUnderMouse?.windowId ?? 0)")

    // If we moved from a window to empty space, that's a boundary crossing
    if previousWindowUnderMouse != nil && currentWindowUnderMouse == nil {
        print("Focus-follows-mouse: Boundary crossed - window to empty space")
        return true
    }

    // If we moved from empty space to a window, that's a boundary crossing
    if previousWindowUnderMouse == nil && currentWindowUnderMouse != nil {
        print("Focus-follows-mouse: Boundary crossed - empty space to window")
        return true
    }

    // If we moved from one window to a different window, that's a boundary crossing
    let boundaryChanged = currentWindowUnderMouse?.windowId != previousWindowUnderMouse?.windowId
    if boundaryChanged {
        print("Focus-follows-mouse: Boundary crossed - different windows")
    } else {
        print("Focus-follows-mouse: No boundary crossing - same window or both empty")
    }
    return boundaryChanged
}

@MainActor
private func isActuallyManipulatingWindow() -> Bool {
    // Check if the user is actually manipulating a window (dragging/resizing)
    // vs just clicking or interacting with app content

    // If no window is being manipulated, we're safe to focus
    guard currentlyManipulatedWithMouseWindowId != nil else { return false }

    // If left mouse button is still down, user is likely still manipulating
    guard isLeftMouseButtonDown else {
        // Mouse button is up but manipulation state hasn't been cleared yet
        // This is likely the VS Code scenario - give it a moment to clear
        return false
    }

    // User is actively manipulating a window
    return true
}

@MainActor
private func focusWindowUnderMouse(at point: CGPoint) async {
    print("Focus-follows-mouse: focusWindowUnderMouse called at \(point)")
    
    guard let token: RunSessionGuard = .isServerEnabled else { 
        print("Focus-follows-mouse: Server not enabled, exiting")
        return 
    }

    // Only block focus-follows-mouse during actual window manipulation (resize/move)
    // rather than any mouse interaction (like clicking in VS Code)
    guard !isActuallyManipulatingWindow() else { 
        print("Focus-follows-mouse: Window manipulation detected, skipping")
        return 
    }

    // Check if we should ignore this mouse position
    guard !shouldIgnoreMousePosition(point) else { 
        print("Focus-follows-mouse: Position should be ignored (menu bar/dock)")
        return 
    }

    print("Focus-follows-mouse: Starting runSession")
    try? await runSession(.focusFollowsMouse, token) {
        let windowUnderMouse = findWindowUnderMouse(at: point)

        if let windowUnderMouse = windowUnderMouse {
            // Only focus if different from current focus
            if windowUnderMouse.windowId != focus.windowOrNil?.windowId {
                print("Focus-follows-mouse: Focusing window \(windowUnderMouse.windowId)")
                lastFocusSource = .mouse
                _ = windowUnderMouse.focusWindow()
            } else {
                print("Focus-follows-mouse: Window \(windowUnderMouse.windowId) already focused")
            }
        } else {
            print("Focus-follows-mouse: No window under mouse at \(point)")
        }
        // Note: We don't actively unfocus when mouse moves to empty space
        // This preserves the current focus when mouse moves to desktop/empty areas
    }
}

@MainActor
private func shouldIgnoreMousePosition(_ point: CGPoint) -> Bool {
    guard config.focusFollowsMouseIgnoreMenuBar else { return false }

    // Get the main screen's menu bar area
    let mainScreen = NSScreen.main ?? NSScreen.screens.first!
    let menuBarHeight: CGFloat = mainScreen.frame.height - mainScreen.visibleFrame.height - mainScreen.visibleFrame.origin.y

    // Check if mouse is in menu bar area (top of main screen)
    if point.y <= menuBarHeight {
        return true
    }

    // Check if mouse is in dock area (if dock is visible)
    let dockHeight = mainScreen.frame.height - mainScreen.visibleFrame.height - menuBarHeight
    if dockHeight > 0 && point.y >= mainScreen.frame.height - dockHeight {
        return true
    }

    return false
}

@MainActor
private func findWindowUnderMouse(at point: CGPoint) -> Window? {
    let targetMonitor = point.monitorApproximation
    let workspace = targetMonitor.activeWorkspace

    // Strategy 1: Try to get the actual window under mouse using AX API
    if let topWindow = getTopWindowUnderMouseUsingAX(at: point) {
        return topWindow
    }

    // Strategy 2: Use AeroSpace's knowledge + heuristics
    return findWindowUsingAeroSpaceHeuristics(at: point, workspace: workspace)
}

@MainActor
private func getTopWindowUnderMouseUsingAX(at point: CGPoint) -> Window? {
    // Use AX API to get the actual topmost element under mouse
    let systemWideElement = AXUIElementCreateSystemWide()
    var elementRef: AXUIElement?

    let result = AXUIElementCopyElementAtPosition(systemWideElement, Float(point.x), Float(point.y), &elementRef)

    guard result == .success, let element = elementRef else { return nil }

    // Walk up the AX hierarchy to find the window
    if let windowId = element.containingWindowId(),
       let window = Window.get(byId: windowId) {
        return window
    }

    return nil
}

@MainActor
private func findWindowUsingAeroSpaceHeuristics(at point: CGPoint, workspace: Workspace) -> Window? {
    // Strategy: Check floating windows first, then tiled
    // For floating windows, use recency + position heuristics

    var candidateFloatingWindows: [(Window, Double)] = []

    // Check all floating windows that contain the point
    for window in workspace.floatingWindows {
        guard let rect = window.lastAppliedLayoutPhysicalRect else { continue }
        guard rect.contains(point) else { continue }

        // Calculate "priority score" based on multiple factors
        var score: Double = 0

        // Factor 1: Recency (most recently focused gets higher score)
        if let mru = workspace.mostRecentWindowRecursive, mru.windowId == window.windowId {
            score += 1000
        }

        // Factor 2: Size (smaller windows are likely on top)
        let area = rect.width * rect.height
        score += (1000000 - area) / 1000  // Inverse relationship

        // Factor 3: Position (windows closer to mouse get slight preference)
        let distance = point.distance(to: rect.center)
        score += (1000 - distance) / 10

        candidateFloatingWindows.append((window, score))
    }

    // Return the floating window with highest score
    if let bestFloating = candidateFloatingWindows.max(by: { $0.1 < $1.1 }) {
        return bestFloating.0
    }

    // Fall back to tiled windows
    return point.findIn(tree: workspace.rootTilingContainer, virtual: false)
}

// Track focus source for keyboard vs mouse focus
@MainActor
func setFocusSource(_ source: FocusSource, windowRect: Rect? = nil) {
    lastFocusSource = source
    if source == .keyboard {
        keyboardFocusedWindowRect = windowRect
    }
}

// Configuration reload support
@MainActor
func reloadFocusFollowsMouse() {
    deinitFocusFollowsMouse()
    initFocusFollowsMouse()
}
