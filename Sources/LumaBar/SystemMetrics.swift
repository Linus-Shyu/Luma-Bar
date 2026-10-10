import AppKit
import ApplicationServices
import AVFoundation
import Carbon
import Combine
import CommonCrypto
import Contacts
import CoreAudio
import CoreText
import CoreWLAN
import Darwin
import IOKit.ps
import PDFKit
import QuartzCore
import ScreenCaptureKit
import Security
import SQLite3
import Speech
import SwiftUI

struct SystemMetricsSnapshot: Equatable {
    var cpuUsage: Double = 0
    var cpuCoreCount: Int = 0
    var loadAverage1: Double = 0
    var loadAverage5: Double = 0
    var loadAverage15: Double = 0
    var memoryUsage: Double = 0
    var memoryUsedBytes: UInt64 = 0
    var memoryTotalBytes: UInt64 = 0
    var memoryAvailableBytes: UInt64 = 0
    var diskUsage: Double = 0
    var diskUsedBytes: UInt64 = 0
    var diskFreeBytes: UInt64 = 0
    var diskTotalBytes: UInt64 = 0
    var batteryLevel: Double?
    var isCharging = false
    var powerSourceName = "Unknown"
    var networkDownRate: Double = 0
    var networkUpRate: Double = 0
    var networkReceivedTotalBytes: UInt64 = 0
    var networkSentTotalBytes: UInt64 = 0
    var uptime: TimeInterval = 0
    var osVersion = ""
}

extension SystemMetricsSnapshot {
    var cpuText: String {
        Self.percentText(cpuUsage)
    }

    var memoryText: String {
        Self.percentText(memoryUsage)
    }

    var diskText: String {
        Self.percentText(diskUsage)
    }

    var batteryText: String {
        guard let batteryLevel else { return "AC" }
        return Self.percentText(batteryLevel)
    }

    var networkDownText: String {
        Self.byteRateText(networkDownRate)
    }

    var networkUpText: String {
        Self.byteRateText(networkUpRate)
    }

    var networkDownTotalText: String {
        Self.bytesText(networkReceivedTotalBytes)
    }

    var networkUpTotalText: String {
        Self.bytesText(networkSentTotalBytes)
    }

    var uptimeText: String {
        let totalMinutes = max(0, Int(uptime / 60))
        let days = totalMinutes / 1440
        let hours = (totalMinutes % 1440) / 60
        let minutes = totalMinutes % 60

        if days > 0 {
            return "\(days)d \(hours)h"
        }

        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }

        return "\(minutes)m"
    }

    var memoryDetailText: String {
        "\(Self.bytesText(memoryUsedBytes)) / \(Self.bytesText(memoryTotalBytes))"
    }

    var memoryFreeText: String {
        Self.bytesText(memoryAvailableBytes)
    }

    var diskDetailText: String {
        "\(Self.bytesText(diskFreeBytes)) free"
    }

    var diskUsedText: String {
        Self.bytesText(diskUsedBytes)
    }

    var cpuDetailText: String {
        "\(max(1, cpuCoreCount)) cores • load \(String(format: "%.2f", loadAverage1))"
    }

    var loadAverageText: String {
        "\(String(format: "%.2f", loadAverage1)) / \(String(format: "%.2f", loadAverage5)) / \(String(format: "%.2f", loadAverage15))"
    }

    var osVersionText: String {
        osVersion.replacingOccurrences(of: "Version ", with: "")
    }

    var agentSummaryText: String {
        let battery = batteryLevel == nil
            ? "external power"
            : "\(batteryText) \(isCharging ? "charging" : "battery")"
        return [
            "CPU \(cpuText) on \(max(1, cpuCoreCount)) cores, load \(loadAverageText)",
            "Memory \(memoryDetailText), \(memoryFreeText) available",
            "Disk \(diskText), \(diskDetailText)",
            "Network down \(networkDownText), up \(networkUpText)",
            "Power \(battery)",
            "Uptime \(uptimeText), macOS \(osVersionText)"
        ].joined(separator: "\n")
    }

    static func percentText(_ value: Double) -> String {
        "\(Int(round(min(1, max(0, value)) * 100)))%"
    }

    static func bytesText(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(min(bytes, UInt64(Int64.max))), countStyle: .memory)
    }

    static func byteRateText(_ bytesPerSecond: Double) -> String {
        let clamped = max(0, min(bytesPerSecond, Double(Int64.max)))
        return "\(ByteCountFormatter.string(fromByteCount: Int64(clamped), countStyle: .decimal))/s"
    }
}

struct CPUTicks {
    let user: UInt64
    let system: UInt64
    let idle: UInt64
    let nice: UInt64
}

struct NetworkCounter {
    let receivedBytes: UInt64
    let sentBytes: UInt64
    let timestamp: Date
}

enum SystemMetricsReader {
    static func cpuTicks() -> CPUTicks? {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, reboundPointer, &count)
            }
        }

        guard status == KERN_SUCCESS else { return nil }
        return CPUTicks(
            user: UInt64(info.cpu_ticks.0),
            system: UInt64(info.cpu_ticks.1),
            idle: UInt64(info.cpu_ticks.2),
            nice: UInt64(info.cpu_ticks.3)
        )
    }

    static func cpuUsage(from previous: CPUTicks?, to current: CPUTicks?) -> Double {
        guard let previous, let current else { return 0 }

        let user = cpuTickDelta(from: previous.user, to: current.user)
        let system = cpuTickDelta(from: previous.system, to: current.system)
        let idle = cpuTickDelta(from: previous.idle, to: current.idle)
        let nice = cpuTickDelta(from: previous.nice, to: current.nice)
        let total = user + nice + system + idle

        guard total > 0 else { return 0 }
        return min(1, max(0, 1 - Double(idle) / Double(total)))
    }

    private static func cpuTickDelta(from previous: UInt64, to current: UInt64) -> UInt64 {
        if current >= previous {
            return current - previous
        }

        return UInt64(UInt32.max) - previous + current + 1
    }

    static func memoryStats() -> (usage: Double, usedBytes: UInt64, totalBytes: UInt64, availableBytes: UInt64) {
        let totalBytes = ProcessInfo.processInfo.physicalMemory
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let status = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, reboundPointer, &count)
            }
        }

        guard status == KERN_SUCCESS else {
            return (0, 0, totalBytes, 0)
        }

        let pageSize = UInt64(getpagesize())
        let usedPages = UInt64(stats.active_count)
            + UInt64(stats.inactive_count)
            + UInt64(stats.wire_count)
            + UInt64(stats.compressor_page_count)
        let usedBytes = min(totalBytes, usedPages * pageSize)
        let availableBytes = totalBytes.saturatingSubtract(usedBytes)
        let usage = totalBytes > 0 ? Double(usedBytes) / Double(totalBytes) : 0
        return (min(1, max(0, usage)), usedBytes, totalBytes, availableBytes)
    }

    static func diskStats() -> (usage: Double, usedBytes: UInt64, freeBytes: UInt64, totalBytes: UInt64) {
        guard
            let attributes = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()),
            let total = attributes[.systemSize] as? NSNumber,
            let free = attributes[.systemFreeSize] as? NSNumber
        else {
            return (0, 0, 0, 0)
        }

        let totalBytes = total.uint64Value
        let freeBytes = free.uint64Value
        let usedBytes = totalBytes.saturatingSubtract(freeBytes)
        let usage = totalBytes > 0 ? Double(usedBytes) / Double(totalBytes) : 0
        return (min(1, max(0, usage)), usedBytes, freeBytes, totalBytes)
    }

    static func batteryStats() -> (level: Double?, isCharging: Bool, sourceName: String) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else {
            return (nil, false, "Unknown")
        }

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any] else {
                continue
            }

            let current = (description[kIOPSCurrentCapacityKey as String] as? NSNumber)?.doubleValue
            let maximum = (description[kIOPSMaxCapacityKey as String] as? NSNumber)?.doubleValue
            let state = description[kIOPSPowerSourceStateKey as String] as? String
            let sourceName: String

            if state == kIOPSACPowerValue {
                sourceName = "AC Power"
            } else if state == kIOPSBatteryPowerValue {
                sourceName = "Battery"
            } else {
                sourceName = "Unknown"
            }

            if let current, let maximum, maximum > 0 {
                return (min(1, max(0, current / maximum)), state == kIOPSACPowerValue, sourceName)
            }

            return (nil, state == kIOPSACPowerValue, sourceName)
        }

        return (nil, false, "Unknown")
    }

    static func loadAverages() -> (one: Double, five: Double, fifteen: Double) {
        var values = [Double](repeating: 0, count: 3)
        let result = getloadavg(&values, Int32(values.count))
        guard result == 3 else { return (0, 0, 0) }
        return (values[0], values[1], values[2])
    }

    static func networkCounter() -> NetworkCounter? {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let firstInterface = interfaces else { return nil }
        defer { freeifaddrs(interfaces) }

        var receivedBytes: UInt64 = 0
        var sentBytes: UInt64 = 0
        var pointer: UnsafeMutablePointer<ifaddrs>? = firstInterface

        while let interface = pointer {
            let value = interface.pointee
            let flags = Int32(value.ifa_flags)

            if
                let address = value.ifa_addr,
                address.pointee.sa_family == UInt8(AF_LINK),
                flags & IFF_UP != 0,
                flags & IFF_LOOPBACK == 0,
                let data = value.ifa_data?.assumingMemoryBound(to: if_data.self).pointee
            {
                receivedBytes += UInt64(data.ifi_ibytes)
                sentBytes += UInt64(data.ifi_obytes)
            }

            pointer = value.ifa_next
        }

        return NetworkCounter(receivedBytes: receivedBytes, sentBytes: sentBytes, timestamp: Date())
    }
}

extension UInt64 {
    func saturatingSubtract(_ value: UInt64) -> UInt64 {
        self > value ? self - value : 0
    }
}
