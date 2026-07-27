// Copy to Sources/LumaBar/BundledAgentSecrets.swift (gitignored) and fill in your key.
// Or build with: LUMA_BAR_DEEPSEEK_API_KEY=sk-... ./build_app.sh
// build_app.sh will create an empty copy automatically if missing.

enum BundledAgentSecrets {
    /// `deepseek` (default) or `openai`
    static let provider = "deepseek"

    /// DeepSeek API key. Leave empty to fall back to Keychain / environment.
    static let deepSeekAPIKey = ""

    /// Default DeepSeek model.
    static let deepSeekModel = "deepseek-chat"

    /// Optional OpenAI fallback model when provider == openai.
    static let openAIModel = "gpt-5.6"
}
