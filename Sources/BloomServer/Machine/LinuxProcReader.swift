import BloomCore
import Foundation

/// The machine's counters as Linux publishes them.
///
/// `/proc` inside a Sprite is virtualised, and memory totals were seen moving between 8 and 16 GB
/// as the provider scaled the machine, so these are estimates of what is billed rather than the
/// bill. runbloom.app reconciles against the provider's invoice. See docs/REMOTE-WORKSPACES.md,
/// "Usage".
enum LinuxProcReader {
    static func sample() -> MachineUsageReading? {
        guard let stat = try? String(contentsOfFile: "/proc/stat", encoding: .utf8),
              let meminfo = try? String(contentsOfFile: "/proc/meminfo", encoding: .utf8),
              let cpu = MachineCounters.nonIdleCPUSeconds(procStat: stat, ticksPerSecond: ticksPerSecond),
              let memory = MachineCounters.usedMemoryBytes(meminfo: meminfo) else { return nil }
        let boot = (try? String(contentsOfFile: "/proc/sys/kernel/random/boot_id", encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
        return MachineUsageReading(cpuSeconds: cpu, memoryUsedBytes: memory, diskUsedBytes: diskUsedBytes(), bootID: boot)
    }

    /// `USER_HZ`, which is 100 on every Linux this runs on; `sysconf` is asked where it can be.
    static var ticksPerSecond: Double {
        #if os(Linux)
        let ticks = sysconf(Int32(_SC_CLK_TCK))
        return ticks > 0 ? Double(ticks) : 100
        #else
        return 100
        #endif
    }

    static func diskUsedBytes(path: String = "/") -> Int64? {
        guard let attributes = try? FileManager.default.attributesOfFileSystem(forPath: path),
              let size = (attributes[.systemSize] as? NSNumber)?.int64Value,
              let free = (attributes[.systemFreeSize] as? NSNumber)?.int64Value else { return nil }
        return size - free
    }
}
