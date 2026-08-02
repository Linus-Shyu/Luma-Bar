import Foundation

#if LUMA_APP_STORE
/// Mac App Store build — sandbox + compliant capability gates.
enum AppStoreDistribution {
    static let isAppStoreBuild = true
    static let showsLicenseUI = false
    /// Accessibility remains available with user TCC grant.
    static let allowsAccessibilityFeatures = true
    static let allowsScreenCapture = true
    /// Arbitrary zsh is disabled; SafeAgentActions / Shortcuts only.
    static let allowsShellAutomation = true
    static let allowsExternalSessionMonitoring = true
    static let allowsSystemControlTools = true
    static let allowsSelectionTranslation = true
}
#else
/// Direct / Developer ID distribution.
enum AppStoreDistribution {
    static let isAppStoreBuild = false
    static let showsLicenseUI = false
    static let allowsAccessibilityFeatures = true
    static let allowsScreenCapture = true
    static let allowsShellAutomation = true
    static let allowsExternalSessionMonitoring = true
    static let allowsSystemControlTools = true
    static let allowsSelectionTranslation = true
}
#endif
