import Foundation

#if LUMA_APP_STORE
/// Mac App Store build — sandbox + compliant capability gates.
enum AppStoreDistribution {
    static let isAppStoreBuild = true
    static let showsLicenseUI = false
    /// Off: App Sandbox fails every cross-application Accessibility call with
    /// `kAXErrorCannotComplete` (-25204), even though `AXIsProcessTrusted()` still reports true, so
    /// asking the user to grant Accessibility would buy them nothing. Verified by running one
    /// binary twice, differing only in the sandbox entitlement.
    static let allowsAccessibilityFeatures = false
    /// ScreenCaptureKit after the user grants Screen Recording.
    static let allowsScreenCapture = true
    /// Arbitrary zsh is disabled; SafeAgentActions / Shortcuts only.
    static let allowsShellAutomation = true
    static let allowsExternalSessionMonitoring = true
    static let allowsSystemControlTools = true
    static let allowsSelectionTranslation = true
    /// Off: reading another app's selection needs cross-application Accessibility, which the
    /// sandbox refuses. Translation is triggered by a second copy of the same text (double ⌘C),
    /// which needs no permission and leaves a single copy alone.
    static let readsSelectionDirectly = false
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
    static let readsSelectionDirectly = true
}
#endif
