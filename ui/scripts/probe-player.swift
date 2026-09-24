// Diagnostic only: no wallpaper windows and no changes to the production engine.
import AVFoundation
import Foundation

let player = AVQueuePlayer()
player.isMuted = true
let template = AVPlayerItem(url: URL(fileURLWithPath: CommandLine.arguments[1]))
let looper = AVPlayerLooper(player: player, templateItem: template)
let started = ProcessInfo.processInfo.systemUptime
player.play()
var samples: [[String: Any]] = []
while ProcessInfo.processInfo.systemUptime - started < 3 {
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
    samples.append([
        "elapsed_ms": (ProcessInfo.processInfo.systemUptime - started) * 1000,
        "template_status": template.status.rawValue,
        "current_status": player.currentItem?.status.rawValue ?? -1,
        "current_is_template": player.currentItem === template,
        "playback_seconds": player.currentTime().seconds,
        "error": player.currentItem?.error?.localizedDescription ?? "",
    ])
}
let advanced = samples.contains { ($0["playback_seconds"] as? Double ?? 0) > 0 }
let report: [String: Any] = [
    "diagnostic_only": true,
    "visible_frame_verified": false,
    "actual_item_advanced": advanced,
    "template_ready": template.status == .readyToPlay,
    "samples": samples,
]
let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
print(String(decoding: data, as: UTF8.self))
player.pause()
looper.disableLooping()
exit(advanced ? 0 : 1)
