/// Feature gates for distribution. Luma Bar ships as one full-capability binary
/// (Developer ID / direct download). There is no App Store lite build.
enum AppStoreDistribution {
    static let isAppStoreBuild = false
    static let showsLicenseUI = true
    static let allowsAccessibilityFeatures = true
    static let allowsScreenCapture = true
    static let allowsShellAutomation = true
    static let allowsExternalSessionMonitoring = true
    static let allowsSystemControlTools = true
    static let allowsSelectionTranslation = true
}
