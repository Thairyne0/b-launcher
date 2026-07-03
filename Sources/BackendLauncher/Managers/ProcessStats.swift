import Darwin
import Foundation

/// Campionamento CPU/RAM di un intero process group (leader + discendenti).
/// Solo osservazione: nessuna dipendenza dai backend.
enum ProcessStats {
    struct Sample: Equatable {
        var cpuPercent: Double   // % di un core, somma sul gruppo (può superare 100)
        var rssMB: Double        // memoria residente somma, in MB
    }

    /// mach_timebase_info è costante per il processo: cachato una volta sola.
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    /// pids del process group `pgid` (leader incluso). Ritorna [] se il gruppo non esiste.
    static func groupPIDs(pgid: pid_t) -> [pid_t] {
        let sizeNeeded = proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(pgid), nil, 0)
        guard sizeNeeded > 0 else { return [] }

        // proc_listpids vuole un buffer di pid_t; dimensioniamo con margine
        // perché il gruppo può crescere tra le due chiamate.
        let capacity = Int(sizeNeeded) / MemoryLayout<pid_t>.size + 16
        var buffer = [pid_t](repeating: 0, count: capacity)
        let bytesReturned = buffer.withUnsafeMutableBytes { ptr -> Int32 in
            proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(pgid), ptr.baseAddress,
                           Int32(ptr.count))
        }
        guard bytesReturned > 0 else { return [] }

        let count = Int(bytesReturned) / MemoryLayout<pid_t>.size
        return buffer[0..<count].filter { $0 != 0 }
    }

    /// CPU cumulativa (user+system, secondi) e RSS correnti di un singolo pid, via proc_pid_rusage.
    /// nil se il pid non esiste o non è leggibile.
    static func rusage(pid: pid_t) -> (cpuSeconds: Double, rssBytes: UInt64)? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { ptr -> Int32 in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rip in
                proc_pid_rusage(pid, RUSAGE_INFO_V4, rip)
            }
        }
        guard result == 0 else { return nil }

        let machTime = info.ri_user_time + info.ri_system_time
        let nanoseconds = Double(machTime) * Double(timebase.numer) / Double(timebase.denom)
        let cpuSeconds = nanoseconds / 1_000_000_000

        return (cpuSeconds: cpuSeconds, rssBytes: info.ri_resident_size)
    }

    /// Somma di rusage su tutto il gruppo.
    static func groupTotals(pgid: pid_t) -> (cpuSeconds: Double, rssBytes: UInt64) {
        let pids = groupPIDs(pgid: pgid)
        var totalCPU = 0.0
        var totalRSS: UInt64 = 0
        for pid in pids {
            if let usage = rusage(pid: pid) {
                totalCPU += usage.cpuSeconds
                totalRSS += usage.rssBytes
            }
        }
        return (cpuSeconds: totalCPU, rssBytes: totalRSS)
    }

    /// Calcola un Sample dal delta tra due letture di cpuSeconds a distanza di `interval` secondi.
    static func sample(previousCPUSeconds: Double, currentCPUSeconds: Double,
                        interval: TimeInterval, rssBytes: UInt64) -> Sample {
        let delta = currentCPUSeconds - previousCPUSeconds
        let cpuPercent = interval > 0 ? max(0, delta / interval * 100) : 0
        let rssMB = Double(rssBytes) / 1_048_576
        return Sample(cpuPercent: cpuPercent, rssMB: rssMB)
    }
}
