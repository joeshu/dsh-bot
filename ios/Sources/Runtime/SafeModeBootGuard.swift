import Foundation

/// Native iOS crash-loop sentinel (`App/Recovery/SafeModeBootGuard`).
/// Tracks consecutive unfinished boots across hard Jetsam / SIGKILL crashes.
/// After 2 consecutive incomplete boots, automatically requests `--safe-mode`
/// (disabling third-party Cordis plugins) until the runtime stabilizes.
@MainActor
public final class SafeModeBootGuard: ObservableObject {
    public static let shared = SafeModeBootGuard()

    private static let crashCountKey = "dsbot.boot.consecutiveCrashCount"
    private static let forceSafeModeKey = "dsbot.boot.forceSafeModeNext"
    private static let maxAllowedBootCrashes = 2

    @Published public private(set) var consecutiveBootCrashes: Int
    @Published public private(set) var isSafeModeRequested: Bool
    private var stabilizeTask: Task<Void, Never>?

    private init() {
        let count = UserDefaults.standard.integer(forKey: Self.crashCountKey)
        let forced = UserDefaults.standard.bool(forKey: Self.forceSafeModeKey)
        self.consecutiveBootCrashes = count
        self.isSafeModeRequested = forced || count >= Self.maxAllowedBootCrashes
    }

    /// Call immediately before launching NodeMobile runtime.
    public func beginBootAttempt() -> Bool {
        let nextCount = consecutiveBootCrashes + 1
        consecutiveBootCrashes = nextCount
        UserDefaults.standard.set(nextCount, forKey: Self.crashCountKey)
        let forced = UserDefaults.standard.bool(forKey: Self.forceSafeModeKey)
        if forced {
            UserDefaults.standard.set(false, forKey: Self.forceSafeModeKey)
        }
        let shouldUseSafeMode = forced || nextCount > Self.maxAllowedBootCrashes
        isSafeModeRequested = shouldUseSafeMode
        return shouldUseSafeMode
    }

    /// Call when runtime transitions to `.ready`. Resets the crash counter
    /// after a short stability window so transient post-boot crashes still count.
    public func markBootReady() {
        stabilizeTask?.cancel()
        stabilizeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled, let self else { return }
            self.consecutiveBootCrashes = 0
            UserDefaults.standard.set(0, forKey: Self.crashCountKey)
        }
    }

    /// Manually request Safe Mode on the next restart (e.g. from Diagnostics).
    public func requestSafeModeOnNextBoot() {
        UserDefaults.standard.set(true, forKey: Self.forceSafeModeKey)
        isSafeModeRequested = true
    }

    /// Clear crash-loop state after user disables a misbehaving plugin.
    public func resetCrashCounter() {
        stabilizeTask?.cancel()
        consecutiveBootCrashes = 0
        isSafeModeRequested = false
        UserDefaults.standard.set(0, forKey: Self.crashCountKey)
        UserDefaults.standard.set(false, forKey: Self.forceSafeModeKey)
    }
}
