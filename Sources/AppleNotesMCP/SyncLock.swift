import Darwin
import Foundation

final class SyncLock: @unchecked Sendable {
    private let path: String
    private var fd: Int32 = -1

    init(path: String) {
        self.path = path
    }

    func acquire() throws -> Bool {
        try ensureParentDirectory(for: path)
        fd = open(path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            throw NotesError.typed(code: "sync_lock_failed", message: "Unable to open sync lock file.")
        }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            let text = "\(getpid()) \(isoNow())\n"
            _ = ftruncate(fd, 0)
            _ = write(fd, text, text.utf8.count)
            return true
        }
        close(fd)
        fd = -1
        return false
    }

    func release() {
        guard fd >= 0 else { return }
        _ = flock(fd, LOCK_UN)
        close(fd)
        fd = -1
    }
}

