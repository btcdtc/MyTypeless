import AppKit
import Foundation

final class SingleInstanceGuard {
    static let shared = SingleInstanceGuard()

    private var lockFD: Int32 = -1

    private init() {}

    func acquireOrActivateExisting() -> Bool {
        let lockURL = lockFileURL()
        try? FileManager.default.createDirectory(
            at: lockURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let fd = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            Log.app.error("single-instance lock open failed")
            return true
        }

        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            lockFD = fd
            writeCurrentPID(to: fd)
            return true
        }

        close(fd)
        activateExistingInstance()
        return false
    }

    private func lockFileURL() -> URL {
        AppPaths.appSupportDir.appendingPathComponent("Typeforme.lock")
    }

    private func writeCurrentPID(to fd: Int32) {
        let pid = "\(getpid())\n"
        _ = ftruncate(fd, 0)
        _ = lseek(fd, 0, SEEK_SET)
        pid.withCString { pointer in
            _ = write(fd, pointer, strlen(pointer))
        }
    }

    private func activateExistingInstance() {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.btcdtc.typeforme.mac"
        let currentPID = getpid()
        guard let existing = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first(where: { $0.processIdentifier != currentPID })
        else {
            Log.app.notice("single-instance lock held but no existing app with bundle id found")
            return
        }
        Log.app.notice("another Typeforme instance is already running; activating it and exiting")
        existing.activate()
    }
}
