import AppKit
import Darwin

let mainBundleIdentifier = "io.github.diamondplated.ScreenWren"
let helperURL = Bundle.main.bundleURL
let mainAppURL = helperURL
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
let configuration = NSWorkspace.OpenConfiguration()

if let flag = CommandLine.arguments.firstIndex(of: "--relaunch"),
   CommandLine.arguments.indices.contains(flag + 1),
   let processID = pid_t(CommandLine.arguments[flag + 1]) {
    let deadline = Date().addingTimeInterval(15)
    while kill(processID, 0) == 0, Date() < deadline {
        Thread.sleep(forTimeInterval: 0.1)
    }
    guard kill(processID, 0) != 0 else { exit(EXIT_FAILURE) }
} else {
    guard NSRunningApplication.runningApplications(withBundleIdentifier: mainBundleIdentifier).isEmpty else {
        exit(EXIT_SUCCESS)
    }
    configuration.arguments = ["--login-item"]
}

NSWorkspace.shared.openApplication(at: mainAppURL, configuration: configuration) { _, _ in
    Task { @MainActor in
        NSApplication.shared.terminate(nil)
    }
}
NSApplication.shared.run()
