import Foundation

/// Reading the two Linux files usage is measured from, as pure functions of their text.
public enum MachineCounters {
    /// Seconds of CPU time not spent idle since boot, summed over every core: the `cpu` line of
    /// `/proc/stat` less `idle` and `iowait`, which are the two a machine is not billed as busy for.
    public static func nonIdleCPUSeconds(procStat: String, ticksPerSecond: Double) -> Double? {
        guard ticksPerSecond > 0,
              let line = procStat.split(separator: "\n").first(where: { $0.hasPrefix("cpu ") }) else { return nil }
        let fields = line.split(separator: " ").dropFirst().compactMap { Double($0) }
        guard fields.count >= 5 else { return nil }
        // user nice system idle iowait irq softirq steal guest guest_nice. Guest time is already
        // counted inside user and nice, so the first eight are the whole of it.
        let total = fields.prefix(8).reduce(0, +)
        let idle = fields[3] + fields[4]
        return (total - idle) / ticksPerSecond
    }

    /// Memory in use: `MemTotal - MemAvailable` from `/proc/meminfo`, in bytes.
    public static func usedMemoryBytes(meminfo: String) -> Int64? {
        var total: Int64?
        var available: Int64?
        for line in meminfo.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == ":" })
            guard parts.count >= 2, let kilobytes = Int64(parts[1]) else { continue }
            if parts[0] == "MemTotal" { total = kilobytes * 1_024 }
            if parts[0] == "MemAvailable" { available = kilobytes * 1_024 }
        }
        guard let total, let available else { return nil }
        return max(0, total - available)
    }
}
