import AppKit
import ApplicationServices

let args = CommandLine.arguments
switch args[1] {
case "preflight":
    let info: [String: Any] = [
        "home": FileManager.default.homeDirectoryForCurrentUser.path,
        "screens": NSScreen.screens.count,
        "screen_capture": CGPreflightScreenCaptureAccess(),
        "accessibility": AXIsProcessTrusted(),
        "low_power": ProcessInfo.processInfo.isLowPowerModeEnabled
    ]
    print(String(data: try JSONSerialization.data(withJSONObject: info), encoding: .utf8)!)
case "windows":
    let pid = Int32(args[2])!
    let windows = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as! [[String: Any]]
    let matching = windows.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == pid }
    print(String(data: try JSONSerialization.data(withJSONObject: matching), encoding: .utf8)!)
case "activate":
    NSRunningApplication(processIdentifier: Int32(args[2])!)?.activate(options: [.activateIgnoringOtherApps])
case "mouse":
    let point = CGPoint(x: Double(args[2])!, y: Double(args[3])!)
    for type in [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
        CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.05)
    }
case "desktop":
    print(String(data: try JSONSerialization.data(withJSONObject: [
        "frontmost": NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0,
        "x": CGEvent(source: nil)!.location.x, "y": CGEvent(source: nil)!.location.y
    ]), encoding: .utf8)!)
case "restore":
    CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
            mouseCursorPosition: CGPoint(x: Double(args[3])!, y: Double(args[4])!), mouseButton: .left)?.post(tap: .cghidEventTap)
    NSRunningApplication(processIdentifier: Int32(args[2])!)?.activate(options: [.activateIgnoringOtherApps])
default: fatalError("unknown action")
}
