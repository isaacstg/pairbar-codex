import AppKit
import Darwin

// Only our own two requested variables and PID are recorded. All files are fixture-local.
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let records = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("records")
let record: [String: Any] = [
    "PID": getpid(),
    "CODEX_HOME": getenv("CODEX_HOME").map { String(cString: $0) } as Any? ?? NSNull(),
    "CODEX_ELECTRON_USER_DATA_PATH": getenv("CODEX_ELECTRON_USER_DATA_PATH").map { String(cString: $0) } as Any? ?? NSNull()
]
try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
    .write(to: records.appendingPathComponent("\(getpid()).json"), options: .atomic)
// Independent expiry bounds the fixture even if its driver is interrupted.
DispatchQueue.main.asyncAfter(deadline: .now() + 60) { app.terminate(nil) }
app.run()
