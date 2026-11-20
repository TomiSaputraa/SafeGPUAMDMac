import AppKit
import Foundation
import SafeGPUCore

let args = CommandLine.arguments
guard args.count >= 2 else {
    fputs("Usage: SafeGPUIconGen <output.icns>\n", stderr)
    exit(1)
}

let outputURL = URL(fileURLWithPath: args[1])
do {
    let badger = IconBadger()
    try badger.generateSafeGPUAppIcon(outputICNSURL: outputURL)
} catch {
    fputs("Failed to generate SafeGPU icon: \(error.localizedDescription)\n", stderr)
    exit(1)
}
