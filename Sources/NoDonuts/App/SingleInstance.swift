import Foundation
import os.log
import NoDonutsCore

// Owner: krusty (app shell) — single-instance guard (ND-083).
//
// Two copies of No Donuts (e.g. the ND-016 LaunchAgent AND the SMAppService login
// item, or a manual `open -n`) would each run a camera session, a presence loop and
// a status item — double glyphs, fighting camera clients, duplicate locks. launchd
// does NOT coalesce the two launch mechanisms, so we enforce it ourselves.
//
// Mechanism: an advisory `flock(LOCK_EX|LOCK_NB)` on
// `~/Library/Application Support/NoDonuts/instance.lock`. The kernel releases the
// lock when the process exits or crashes, so a stale lock is impossible (unlike a
// PID file). The fd is held open for the whole process lifetime.
//
// Policy:
// - Lock held by another process (EWOULDBLOCK) → log and `exit(0)`. Exit code 0 so
//   the LaunchAgent's `KeepAlive { SuccessfulExit = false }` does NOT respawn us.
// - ANY other failure (can't create the dir, can't open/lock the file) → log and
//   CONTINUE. Fail open on availability: a broken lock file must never stop
//   protection.
//
// Privacy: the lock file is empty; nothing is written to it.

enum SingleInstance {
    /// The lock fd, kept open (never closed) for the process lifetime so the flock
    /// persists. Written once, before `NSApplication` exists, from the main thread.
    nonisolated(unsafe) private static var lockFD: Int32 = -1

    private static let log = OSLog(subsystem: Log.subsystem, category: Log.Category.app)

    /// Acquire the single-instance lock, or exit(0) if another instance holds it.
    /// Must be called at the very top of launch, before any camera/status-item setup.
    static func acquireOrExit() {
        let fm = FileManager.default
        guard let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            os_log("single-instance: no Application Support dir; continuing without guard",
                   log: log, type: .error)
            return
        }
        let dir = support.appendingPathComponent("NoDonuts", isDirectory: true)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            os_log("single-instance: can't create %{public}@ (%{public}@); continuing without guard",
                   log: log, type: .error, dir.path, error.localizedDescription)
            return
        }
        let path = dir.appendingPathComponent("instance.lock").path

        let fd = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            let err = errno
            os_log("single-instance: open failed (errno %d: %{public}s); continuing without guard",
                   log: log, type: .error, err, strerror(err))
            return
        }

        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let err = errno
            close(fd)
            if err == EWOULDBLOCK {
                os_log("another No Donuts instance is running; exiting", log: log, type: .default)
                exit(0)   // 0 → LaunchAgent KeepAlive(SuccessfulExit=false) won't respawn
            }
            os_log("single-instance: flock failed (errno %d: %{public}s); continuing without guard",
                   log: log, type: .error, err, strerror(err))
            return
        }

        // Hold the fd (and thus the lock) until the process dies. Never closed.
        lockFD = fd
    }
}
