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

enum AgentModelProvider: String {
    case deepseek
    case openAI = "openai"

    static var current: AgentModelProvider {
        let raw = (
            ProcessInfo.processInfo.environment["LUMA_BAR_AGENT_PROVIDER"]
                ?? BundledAgentSecrets.provider
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
        return AgentModelProvider(rawValue: raw) ?? .deepseek
    }

    var displayName: String {
        switch self {
        case .deepseek: return "DeepSeek"
        case .openAI: return "OpenAI"
        }
    }

    var defaultModel: String {
        switch self {
        case .deepseek:
            return ProcessInfo.processInfo.environment["LUMA_BAR_DEEPSEEK_MODEL"]
                ?? BundledAgentSecrets.deepSeekModel
        case .openAI:
            return ProcessInfo.processInfo.environment["LUMA_BAR_OPENAI_MODEL"]
                ?? ProcessInfo.processInfo.environment["OPENAI_MODEL"]
                ?? BundledAgentSecrets.openAIModel
        }
    }
}

enum AgentCredentialStore {
    private static let account = "default"
    private static let keychainService = "LumaBar.OpenAI"

    static var usesBundledCredential: Bool {
        bundledOrEnvironmentAPIKey() != nil
    }

    static var showsAPIKeySetup: Bool {
        true
    }

    static func currentAPIKey() -> String? {
        // A key the user saved always wins. Bundled keys are a local convenience only.
        if let saved = keychainAPIKey() {
            return saved
        }
        return bundledOrEnvironmentAPIKey()
    }

    static func clearKeychainOverrideIfBundled() {
        // Keep the user's key. It is the credential the Agent should call with.
    }

    static func saveAPIKey(_ key: String) throws {
        guard let data = trimmedKey(key)?.data(using: .utf8) else {
            throw AgentCredentialError.emptyKey
        }

        deleteAPIKey()

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: data
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw AgentCredentialError.keychain(status)
        }
    }

    static func deleteAPIKey() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }

    private static func bundledOrEnvironmentAPIKey() -> String? {
#if LUMA_APP_STORE
        // The Mac App Store build never ships a key. Users paste their own.
        return nil
#else
        let environment = ProcessInfo.processInfo.environment
        switch AgentModelProvider.current {
        case .deepseek:
            if let key = trimmedKey(environment["LUMA_BAR_DEEPSEEK_API_KEY"])
                ?? trimmedKey(environment["DEEPSEEK_API_KEY"])
                ?? trimmedKey(BundledAgentSecrets.deepSeekAPIKey)
            {
                return key
            }
            // Allow OpenAI-compatible env override even on DeepSeek provider.
            return trimmedKey(environment["OPENAI_API_KEY"])
        case .openAI:
            return trimmedKey(environment["OPENAI_API_KEY"])
                ?? trimmedKey(BundledAgentSecrets.deepSeekAPIKey)
        }
#endif
    }

    private static func keychainAPIKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return trimmedKey(key)
    }

    private static func trimmedKey(_ value: String?) -> String? {
        let key = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return key.isEmpty ? nil : key
    }
}

enum AgentCredentialError: LocalizedError {
    case emptyKey
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .emptyKey:
            return "API key is empty."
        case .keychain(let status):
            return "Keychain error \(status)."
        }
    }
}

struct AgentTokenUsage: Codable, Equatable, Sendable {
    var inputTokens = 0
    var outputTokens = 0
    var totalTokens = 0

    private static let defaultsKey = "LumaBar.agentTokenUsage"

    static var saved: AgentTokenUsage {
        guard
            let data = UserDefaults.standard.data(forKey: defaultsKey),
            let usage = try? JSONDecoder().decode(AgentTokenUsage.self, from: data)
        else {
            return AgentTokenUsage()
        }
        return usage
    }

    func persist() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }
}

enum ExternalTokenSource: String, Equatable, Hashable, Sendable {
    case codex
    case cursor
    case kiro
    case chatgpt
    case cherryStudio
    case deepSeekHarness

    var brandLabel: String {
        switch self {
        case .codex:
            return "CODEX CONTEXT"
        case .cursor:
            return "CURSOR CONTEXT"
        case .kiro:
            return "KIRO CONTEXT"
        case .chatgpt:
            return "CHATGPT CONTEXT"
        case .cherryStudio:
            return "CHERRY CONTEXT"
        case .deepSeekHarness:
            return "DSH CONTEXT"
        }
    }

    var readingLabel: String {
        switch self {
        case .codex:
            return "Reading Codex"
        case .cursor:
            return "Reading Cursor"
        case .kiro:
            return "Reading Kiro"
        case .chatgpt:
            return "Reading ChatGPT"
        case .cherryStudio:
            return "Reading Cherry Studio"
        case .deepSeekHarness:
            return "Reading DeepSeek Harness"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .codex:
            return "Codex token usage"
        case .cursor:
            return "Cursor token usage"
        case .kiro:
            return "Kiro context usage"
        case .chatgpt:
            return "ChatGPT activity"
        case .cherryStudio:
            return "Cherry Studio activity"
        case .deepSeekHarness:
            return "DeepSeek Harness activity"
        }
    }

    var nearLimitMessage: String {
        switch self {
        case .codex:
            return "Codex 上下文快满了，必要时点右侧 AI 环查看详情。"
        case .cursor:
            return "Cursor 上下文快满了，必要时点右侧 AI 环查看详情。"
        case .kiro:
            return "Kiro 上下文快满了，必要时点右侧 AI 环查看详情。"
        case .chatgpt:
            return "ChatGPT 会话较长了，必要时开新对话。"
        case .cherryStudio:
            return "Cherry Studio 会话较长了，必要时开新话题。"
        case .deepSeekHarness:
            return "DeepSeek Harness 会话较长了，必要时开新会话。"
        }
    }

    var shortBrandName: String {
        switch self {
        case .codex: return "Codex"
        case .cursor: return "Cursor"
        case .kiro: return "Kiro"
        case .chatgpt: return "ChatGPT"
        case .cherryStudio: return "Cherry Studio"
        case .deepSeekHarness: return "DeepSeek Harness"
        }
    }

    var uppercaseBrandName: String {
        shortBrandName.uppercased()
    }

    static func noticeTitle(brand: String, detail: String) -> String {
        let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.caseInsensitiveCompare(brand) != .orderedSame else {
            return brand
        }
        if trimmed.hasPrefix("\(brand) · ") || trimmed.hasPrefix("\(brand) ·") {
            return trimmed
        }
        return "\(brand) · \(trimmed)"
    }
}

struct ExternalTaskState: Equatable, Sendable {
    let source: ExternalTokenSource
    let sessionID: String
    let title: String
    let isRunning: Bool
    let isComplete: Bool
    let updatedAt: Date
}

struct TaskCompletionNotice: Identifiable, Equatable {
    let id: String
    let source: ExternalTokenSource
    let title: String
    let completedAt: Date
}

struct CodexTokenUsageSnapshot: Equatable, Sendable {
    let source: ExternalTokenSource
    let usage: AgentTokenUsage
    let contextWindow: Int
    let model: String?
    let sessionURL: URL
    let updatedAt: Date
    let kiroCredits: KiroCreditsUsage?
    let weeklyQuota: CodexWeeklyQuota?

    init(
        source: ExternalTokenSource,
        usage: AgentTokenUsage,
        contextWindow: Int,
        model: String?,
        sessionURL: URL,
        updatedAt: Date,
        kiroCredits: KiroCreditsUsage? = nil,
        weeklyQuota: CodexWeeklyQuota? = nil
    ) {
        self.source = source
        self.usage = usage
        self.contextWindow = contextWindow
        self.model = model
        self.sessionURL = sessionURL
        self.updatedAt = updatedAt
        self.kiroCredits = kiroCredits
        self.weeklyQuota = weeklyQuota
    }
}

/// ChatGPT / Codex plan window (account menu「剩余用量」).
struct CodexWeeklyQuota: Equatable, Sendable {
    /// Used percent 0...100 from Codex `secondary.used_percent`.
    let usedPercent: Double
    let resetDate: Date?
    let planType: String?
    let windowMinutes: Int?

    var remainingPercent: Double {
        min(100, max(0, 100 - usedPercent))
    }

    /// Progress bar = used share of weekly quota.
    var progress: Double {
        min(1, max(0, usedPercent / 100))
    }

    var remainingPercentText: String {
        "\(Int(remainingPercent.rounded()))%"
    }

    var usedPercentText: String {
        "\(Int(usedPercent.rounded()))%"
    }

    var resetLabel: String? {
        guard let resetDate else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return "\(formatter.string(from: resetDate))重置"
    }

    var windowLabel: String {
        if let windowMinutes, windowMinutes >= 6 * 24 * 60 {
            return "1 周"
        }
        if let windowMinutes, windowMinutes >= 24 * 60 {
            let days = max(1, Int((Double(windowMinutes) / (24 * 60)).rounded()))
            return "\(days) 天"
        }
        if let windowMinutes, windowMinutes > 0 {
            let hours = max(1, Int((Double(windowMinutes) / 60).rounded()))
            return "\(hours) 小时"
        }
        return "周额度"
    }
}

struct KiroCreditsUsage: Equatable, Sendable {
    let used: Double
    let limit: Double
    let percentageUsed: Double
    let resetDate: Date?
    let displayName: String
    let unit: String

    var progress: Double {
        if percentageUsed > 0 {
            return min(1, max(0, percentageUsed / 100))
        }
        guard limit > 0 else { return 0 }
        return min(1, max(0, used / limit))
    }

    var remaining: Double {
        max(0, limit - used)
    }

    var summaryText: String {
        "\(Self.formatAmount(used)) / \(Self.formatAmount(limit))"
    }

    var percentText: String {
        "\(Int((progress * 100).rounded()))%"
    }

    var remainingText: String {
        "\(Self.formatAmount(remaining)) LEFT"
    }

    var resetLabel: String? {
        guard let resetDate else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return "\(formatter.string(from: resetDate))重置"
    }

    private static func formatAmount(_ value: Double) -> String {
        if abs(value - value.rounded()) < 0.05 {
            return "\(Int(value.rounded()))"
        }
        return String(format: "%.1f", value)
    }
}

