import CryptoKit
import Foundation
import Security

/// Surge-style licensing: 14-day full trial, then Free vs Pro via offline-signed keys.
enum LumaLicenseSecrets {
    /// Rotate before real sales; keep in sync with `scripts/issue_license.py`.
    static let hmacKey = "luma-bar-license-v1-change-me-before-sale"
    static let buyURL = URL(string: "https://github.com/Linus-Shyu/Luma-Bar-Download")!
    /// Replace with Lemon Squeezy / Stripe / 微信收款页后改这里。
    static let purchaseURL = URL(string: "https://github.com/Linus-Shyu/Luma-Bar-Download#purchase")!
}

enum LumaLicenseTier: Int, Codable, Equatable, Sendable {
    case devices1 = 1
    case devices3 = 3
    case devices5 = 5

    var displayName: String {
        "\(rawValue) 台设备"
    }

    var priceYuan: Int {
        switch self {
        case .devices1: return 28
        case .devices3: return 45
        case .devices5: return 68
        }
    }
}

struct LumaLicenseRecord: Codable, Equatable, Sendable {
    var key: String
    var devices: Int
    /// Maintenance / update entitlement end (Surge FUS style).
    var maintenanceExpiresAt: Date
    var activatedAt: Date
}

enum LumaLicensePhase: Equatable, Sendable {
    case trial(daysRemaining: Int)
    case pro(devices: Int, maintenanceExpiresAt: Date)
    case free
}

struct LumaLicenseStatus: Equatable, Sendable {
    var phase: LumaLicensePhase
    var trialEndsAt: Date?
    var record: LumaLicenseRecord?

    var isProActive: Bool {
        switch phase {
        case .trial, .pro: return true
        case .free: return false
        }
    }

    var menuTitle: String {
        switch phase {
        case .trial(let days):
            return "许可证（试用剩余 \(days) 天）…"
        case .pro:
            return "许可证（Pro 已激活）…"
        case .free:
            return "许可证（升级 Pro）…"
        }
    }

    var summary: String {
        switch phase {
        case .trial(let days):
            return "全功能试用中，剩余 \(days) 天。到期后 Pro 能力将锁定，基础刘海仍可用。"
        case .pro(let devices, let expiry):
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.locale = Locale(identifier: "zh_CN")
            return "Pro 已激活（\(devices) 台）。维护更新至 \(formatter.string(from: expiry))。"
        case .free:
            return "试用已结束。升级 Pro（¥28 起）解锁微信提醒、任务完成提醒、划词翻译与 Agent。"
        }
    }
}

enum LumaLicenseError: LocalizedError {
    case invalidFormat
    case invalidSignature
    case expiredMaintenancePayload
    case persistenceFailed

    var errorDescription: String? {
        switch self {
        case .invalidFormat: return "许可证格式无效。"
        case .invalidSignature: return "许可证校验失败，请检查是否完整复制。"
        case .expiredMaintenancePayload: return "该许可证维护期异常，请联系支持重新签发。"
        case .persistenceFailed: return "无法保存许可证，请检查钥匙串权限。"
        }
    }
}

enum LumaLicenseManager {
    private static let trialDefaultsKey = "LumaBar.license.trialStartedAt"
    private static let recordDefaultsKey = "LumaBar.license.record"
    private static let keychainService = "LumaBar.License"
    private static let keychainAccount = "default"
    private static let trialDurationDays = 14

    static func currentStatus(now: Date = Date()) -> LumaLicenseStatus {
        if let record = loadRecord(), verify(record.key) != nil {
            return LumaLicenseStatus(
                phase: .pro(devices: record.devices, maintenanceExpiresAt: record.maintenanceExpiresAt),
                trialEndsAt: trialEndDate(),
                record: record
            )
        }

        let trialEnd = ensureTrialStarted(now: now)
        let remaining = Calendar.current.dateComponents([.day], from: now, to: trialEnd).day ?? 0
        if now < trialEnd {
            return LumaLicenseStatus(
                phase: .trial(daysRemaining: max(1, remaining)),
                trialEndsAt: trialEnd,
                record: nil
            )
        }

        return LumaLicenseStatus(phase: .free, trialEndsAt: trialEnd, record: nil)
    }

    @discardableResult
    static func ensureTrialStarted(now: Date = Date()) -> Date {
        let defaults = UserDefaults.standard
        if let existing = defaults.object(forKey: trialDefaultsKey) as? Date {
            return existing.addingTimeInterval(TimeInterval(trialDurationDays * 24 * 3600))
        }
        defaults.set(now, forKey: trialDefaultsKey)
        return now.addingTimeInterval(TimeInterval(trialDurationDays * 24 * 3600))
    }

    static func trialEndDate() -> Date? {
        guard let start = UserDefaults.standard.object(forKey: trialDefaultsKey) as? Date else {
            return nil
        }
        return start.addingTimeInterval(TimeInterval(trialDurationDays * 24 * 3600))
    }

    static func activate(key rawKey: String, now: Date = Date()) throws -> LumaLicenseRecord {
        let key = normalize(rawKey)
        guard let payload = verify(key) else {
            throw LumaLicenseError.invalidSignature
        }
        let record = LumaLicenseRecord(
            key: key,
            devices: payload.devices,
            maintenanceExpiresAt: payload.maintenanceExpiresAt,
            activatedAt: now
        )
        try saveRecord(record)
        return record
    }

    static func deactivate() {
        UserDefaults.standard.removeObject(forKey: recordDefaultsKey)
        deleteKeychain()
    }

    // MARK: - Key format
    // LB1.<devices>.<maintYYYYMMDD>.<hex16>
    // HMAC-SHA256 over "LB1.{devices}.{maintYYYYMMDD}" with shared secret.

    struct Payload: Equatable {
        var devices: Int
        var maintenanceExpiresAt: Date
    }

    static func verify(_ rawKey: String) -> Payload? {
        let key = normalize(rawKey)
        let parts = key.split(separator: ".").map(String.init)
        guard parts.count == 4, parts[0] == "LB1",
              let devices = Int(parts[1]),
              [1, 3, 5].contains(devices),
              let expiry = parseYYYYMMDD(parts[2])
        else {
            return nil
        }
        let payload = "LB1.\(devices).\(parts[2])"
        let expected = signatureHex(for: payload)
        guard constantTimeEqual(expected, parts[3].lowercased()) else {
            return nil
        }
        return Payload(devices: devices, maintenanceExpiresAt: expiry)
    }

    static func issueKey(devices: Int, maintenanceMonths: Int, from date: Date = Date()) -> String {
        let months = max(1, maintenanceMonths)
        let expiry = Calendar.current.date(byAdding: .month, value: months, to: date) ?? date
        let stamp = formatYYYYMMDD(expiry)
        let payload = "LB1.\(devices).\(stamp)"
        let sig = signatureHex(for: payload)
        return "\(payload).\(sig)"
    }

    private static func signatureHex(for payload: String) -> String {
        let key = SymmetricKey(data: Data(LumaLicenseSecrets.hmacKey.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: Data(payload.utf8), using: key)
        let full = Data(mac).map { String(format: "%02x", $0) }.joined()
        return String(full.prefix(16))
    }

    private static func normalize(_ key: String) -> String {
        let trimmed = key
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
        let parts = trimmed.split(separator: ".").map(String.init)
        guard parts.count == 4 else { return trimmed }
        return "LB1.\(parts[1]).\(parts[2]).\(parts[3].lowercased())"
    }

    private static func formatYYYYMMDD(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd"
        return formatter.string(from: date)
    }

    private static func parseYYYYMMDD(_ raw: String) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd"
        return formatter.date(from: raw)
    }

    private static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let aBytes = Array(a.utf8)
        let bBytes = Array(b.utf8)
        guard aBytes.count == bBytes.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<aBytes.count {
            diff |= aBytes[i] ^ bBytes[i]
        }
        return diff == 0
    }

    // MARK: - Persistence

    private static func saveRecord(_ record: LumaLicenseRecord) throws {
        let data = try JSONEncoder().encode(record)
        UserDefaults.standard.set(data, forKey: recordDefaultsKey)
        let status = saveKeychain(data)
        if status != errSecSuccess && status != errSecDuplicateItem {
            // Keychain optional; Defaults is enough for MVP.
        }
    }

    private static func loadRecord() -> LumaLicenseRecord? {
        if let data = UserDefaults.standard.data(forKey: recordDefaultsKey),
           let record = try? JSONDecoder().decode(LumaLicenseRecord.self, from: data)
        {
            return record
        }
        if let data = loadKeychain(),
           let record = try? JSONDecoder().decode(LumaLicenseRecord.self, from: data)
        {
            return record
        }
        return nil
    }

    private static func saveKeychain(_ data: Data) -> OSStatus {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
        SecItemDelete(query as CFDictionary)
        var values = query
        values[kSecValueData as String] = data
        return SecItemAdd(values as CFDictionary, nil)
    }

    private static func loadKeychain() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else { return nil }
        return item as? Data
    }

    private static func deleteKeychain() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
        SecItemDelete(query as CFDictionary)
    }
}
