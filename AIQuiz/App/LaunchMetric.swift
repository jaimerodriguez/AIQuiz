import Foundation

/// Time from process start to the first library row, shown to UI tests in UI-test mode so
/// the SPEC N-8 launch check measures the app, not XCUITest's own launch overhead.
@MainActor
enum LaunchMetric {
    private(set) static var processStart: Date?
    private(set) static var firstRowMilliseconds: Int?

    /// The kernel's start time for this process.
    static func markProcessStart() {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        let ok = sysctl(&mib, 4, &info, &size, nil, 0) == 0
        let tv = info.kp_proc.p_un.__p_starttime
        let start = ok ? Date(timeIntervalSince1970: Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000) : Date()
        processStart = start
    }

    static func markFirstRow() {
        guard firstRowMilliseconds == nil, let start = processStart else { return }
        firstRowMilliseconds = Int(Date().timeIntervalSince(start) * 1000)
        Log.app.info("First library row after \(firstRowMilliseconds ?? -1) ms")
    }
}
