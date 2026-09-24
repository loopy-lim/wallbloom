import AppKit
import CoreGraphics
let pid = Int32(CommandLine.arguments[1])!
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
for window in windows where (window[kCGWindowOwnerPID as String] as? Int32) == pid {
    if (window[kCGWindowLayer as String] as? Int) == 0,
       let id = window[kCGWindowNumber as String] { print(id); break }
}
