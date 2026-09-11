// Sets the desktop picture on every attached display.
//
// NSWorkspace is the supported API and is the only one that survives macOS
// releases; AppleScript fallbacks in the shell cover machines with no Swift
// toolchain installed.
//
// Usage: goes-set-wallpaper <image-path> [fit|fill|stretch|center]

import AppKit

let args = CommandLine.arguments
guard args.count > 1 else {
    FileHandle.standardError.write("usage: goes-set-wallpaper <image> [fit|fill|stretch|center]\n".data(using: .utf8)!)
    exit(64)
}

let path = args[1]
let mode = args.count > 2 ? args[2] : "fit"

guard FileManager.default.fileExists(atPath: path) else {
    FileHandle.standardError.write("no such file: \(path)\n".data(using: .utf8)!)
    exit(66)
}

let url = URL(fileURLWithPath: path)

var options: [NSWorkspace.DesktopImageOptionKey: Any] = [
    .fillColor: NSColor.black
]

switch mode {
case "fill":
    options[.imageScaling] = NSNumber(value: NSImageScaling.scaleProportionallyUpOrDown.rawValue)
    options[.allowClipping] = true
case "stretch":
    options[.imageScaling] = NSNumber(value: NSImageScaling.scaleAxesIndependently.rawValue)
    options[.allowClipping] = false
case "center":
    options[.imageScaling] = NSNumber(value: NSImageScaling.scaleNone.rawValue)
    options[.allowClipping] = false
default: // fit
    options[.imageScaling] = NSNumber(value: NSImageScaling.scaleProportionallyUpOrDown.rawValue)
    options[.allowClipping] = false
}

let screens = NSScreen.screens
guard !screens.isEmpty else {
    FileHandle.standardError.write("no displays attached\n".data(using: .utf8)!)
    exit(69)
}

var failures: [String] = []
for screen in screens {
    do {
        try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: options)
    } catch {
        let name = screen.localizedName
        failures.append("\(name): \(error.localizedDescription)")
    }
}

if failures.count == screens.count {
    FileHandle.standardError.write((failures.joined(separator: "; ") + "\n").data(using: .utf8)!)
    exit(1)
}
if !failures.isEmpty {
    FileHandle.standardError.write(("partial: " + failures.joined(separator: "; ") + "\n").data(using: .utf8)!)
}
exit(0)
