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

enum AgentLLMClient {
    static func stream(
        prompt: String,
        instructions: String,
        apiKey: String,
        model: String,
        imageData: Data? = nil,
        onDelta: @escaping @Sendable (String) async -> Void
    ) async throws -> AgentTokenUsage? {
        switch AgentModelProvider.current {
        case .deepseek:
            return try await DeepSeekChatClient.stream(
                prompt: prompt,
                instructions: instructions,
                apiKey: apiKey,
                model: model,
                onDelta: onDelta
            )
        case .openAI:
            return try await OpenAIResponsesClient.stream(
                prompt: prompt,
                instructions: instructions,
                apiKey: apiKey,
                model: model,
                imageData: imageData,
                onDelta: onDelta
            )
        }
    }

    static func complete(
        prompt: String,
        instructions: String,
        apiKey: String,
        model: String,
        maxOutputTokens: Int = 300
    ) async throws -> String {
        switch AgentModelProvider.current {
        case .deepseek:
            return try await DeepSeekChatClient.complete(
                prompt: prompt,
                instructions: instructions,
                apiKey: apiKey,
                model: model,
                maxTokens: maxOutputTokens
            )
        case .openAI:
            return try await OpenAIResponsesClient.complete(
                prompt: prompt,
                instructions: instructions,
                apiKey: apiKey,
                model: model,
                maxOutputTokens: maxOutputTokens
            )
        }
    }
}

enum DeepSeekChatClient {
    private static let endpoint = URL(string: "https://api.deepseek.com/chat/completions")!

    static func stream(
        prompt: String,
        instructions: String,
        apiKey: String,
        model: String,
        onDelta: @escaping @Sendable (String) async -> Void
    ) async throws -> AgentTokenUsage? {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": instructions],
                ["role": "user", "content": prompt]
            ],
            "stream": true,
            "max_tokens": 700,
            "stream_options": ["include_usage": true]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAIClientError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw OpenAIClientError.requestFailed(
                statusCode: httpResponse.statusCode,
                message: try await OpenAIResponsesClient.readBodyPublic(from: bytes)
            )
        }

        var completedUsage: AgentTokenUsage?
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data: ") else { continue }
            let payload = String(line.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines)
            if payload.isEmpty || payload == "[DONE]" { continue }
            guard let data = payload.data(using: .utf8) else { continue }
            let chunk = try JSONDecoder().decode(DeepSeekStreamChunk.self, from: data)
            if let message = chunk.error?.message {
                throw OpenAIClientError.api(message)
            }
            if let delta = chunk.choices?.first?.delta?.content, !delta.isEmpty {
                await onDelta(delta)
            }
            if let usage = chunk.usage {
                completedUsage = AgentTokenUsage(
                    inputTokens: usage.promptTokens ?? 0,
                    outputTokens: usage.completionTokens ?? 0,
                    totalTokens: usage.totalTokens
                        ?? ((usage.promptTokens ?? 0) + (usage.completionTokens ?? 0))
                )
            }
        }
        return completedUsage
    }

    static func complete(
        prompt: String,
        instructions: String,
        apiKey: String,
        model: String,
        maxTokens: Int = 700
    ) async throws -> String {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": instructions],
                ["role": "user", "content": prompt]
            ],
            "stream": false,
            "max_tokens": maxTokens
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAIClientError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw OpenAIClientError.requestFailed(statusCode: httpResponse.statusCode, message: message)
        }

        let decoded = try JSONDecoder().decode(DeepSeekCompletionResponse.self, from: data)
        if let message = decoded.error?.message {
            throw OpenAIClientError.api(message)
        }
        let text = decoded.choices?.first?.message?.content?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else {
            throw OpenAIClientError.invalidResponse
        }
        return text
    }
}

struct DeepSeekStreamChunk: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable {
            let content: String?
        }
        let delta: Delta?
    }

    struct Usage: Decodable {
        let promptTokens: Int?
        let completionTokens: Int?
        let totalTokens: Int?

        enum CodingKeys: String, CodingKey {
            case promptTokens = "prompt_tokens"
            case completionTokens = "completion_tokens"
            case totalTokens = "total_tokens"
        }
    }

    struct APIError: Decodable {
        let message: String?
    }

    let choices: [Choice]?
    let usage: Usage?
    let error: APIError?
}

struct DeepSeekCompletionResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let content: String?
        }
        let message: Message?
    }

    struct APIError: Decodable {
        let message: String?
    }

    let choices: [Choice]?
    let error: APIError?
}

enum OpenAIResponsesClient {
    private static let endpoint = URL(string: "https://api.openai.com/v1/responses")!

    /// Exposed for DeepSeek error body reading without duplicating byte-drain logic.
    static func readBodyPublic(from bytes: URLSession.AsyncBytes) async throws -> String {
        try await readBody(from: bytes)
    }

    static func stream(
        prompt: String,
        instructions: String,
        apiKey: String,
        model: String,
        imageData: Data? = nil,
        onDelta: @escaping @Sendable (String) async -> Void
    ) async throws -> AgentTokenUsage? {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        let input: Any
        if let imageData {
            input = [[
                "role": "user",
                "content": [
                    [
                        "type": "input_text",
                        "text": prompt
                    ],
                    [
                        "type": "input_image",
                        "image_url": "data:image/jpeg;base64,\(imageData.base64EncodedString())",
                        "detail": "low"
                    ]
                ]
            ]]
        } else {
            input = prompt
        }

        let body: [String: Any] = [
            "model": model,
            "instructions": instructions,
            "input": input,
            "stream": true,
            "store": false,
            "max_output_tokens": 700
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAIClientError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw OpenAIClientError.requestFailed(
                statusCode: httpResponse.statusCode,
                message: try await readBody(from: bytes)
            )
        }

        var completedUsage: AgentTokenUsage?
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data: ") else { continue }

            let payload = String(line.dropFirst(6))
            if payload == "[DONE]" {
                break
            }

            guard let data = payload.data(using: .utf8) else { continue }
            let event = try JSONDecoder().decode(OpenAIStreamEvent.self, from: data)
            if let message = event.error?.message {
                throw OpenAIClientError.api(message)
            }

            if let delta = event.delta, !delta.isEmpty {
                await onDelta(delta)
            }
            if let usage = event.response?.usage {
                completedUsage = AgentTokenUsage(
                    inputTokens: usage.inputTokens,
                    outputTokens: usage.outputTokens,
                    totalTokens: usage.totalTokens
                )
            }
        }
        return completedUsage
    }

    static func complete(
        prompt: String,
        instructions: String,
        apiKey: String,
        model: String,
        maxOutputTokens: Int = 300
    ) async throws -> String {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "instructions": instructions,
            "input": prompt,
            "stream": false,
            "store": false,
            "max_output_tokens": maxOutputTokens
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAIClientError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw OpenAIClientError.requestFailed(
                statusCode: httpResponse.statusCode,
                message: String(decoding: data, as: UTF8.self)
            )
        }
        let decoded = try JSONDecoder().decode(OpenAICompletedResponse.self, from: data)
        let text = decoded.output
            .flatMap { $0.content ?? [] }
            .compactMap(\.text)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw OpenAIClientError.invalidResponse }
        return text
    }

    private static func readBody(from bytes: URLSession.AsyncBytes) async throws -> String {
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
        }
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            return "No response body."
        }
        return text
    }
}

struct OpenAICompletedResponse: Decodable {
    let output: [Output]

    struct Output: Decodable {
        let content: [Content]?
    }

    struct Content: Decodable {
        let text: String?
    }
}

struct OpenAIStreamEvent: Decodable {
    let type: String
    let delta: String?
    let error: OpenAIStreamError?
    let response: OpenAIStreamResponse?
}

struct OpenAIStreamResponse: Decodable {
    let usage: OpenAIResponseUsage?
}

struct OpenAIResponseUsage: Decodable {
    let inputTokens: Int
    let outputTokens: Int
    let totalTokens: Int

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case totalTokens = "total_tokens"
    }
}

struct OpenAIStreamError: Decodable {
    let message: String
}

enum OpenAIClientError: LocalizedError {
    case invalidResponse
    case requestFailed(statusCode: Int, message: String)
    case api(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid OpenAI response."
        case .requestFailed(let statusCode, let message):
            return "OpenAI request failed (\(statusCode)): \(message)"
        case .api(let message):
            return message
        }
    }
}

enum AgentWeatherClient {
    static func currentWeather(location: String) async throws -> String {
        let place = try await geocode(location: location)
        let forecast = try await forecast(latitude: place.latitude, longitude: place.longitude)
        let current = forecast.current
        let unit = forecast.currentUnits
        let temperatureUnit = unit.temperature2m ?? "deg"
        let windUnit = unit.windSpeed10m ?? "mph"
        let humidity = current.relativeHumidity2m.map { "Humidity \($0)%" } ?? "Humidity n/a"
        let apparent = current.apparentTemperature.map {
            "feels like \(Self.rounded($0))\(temperatureUnit)"
        } ?? "feels like n/a"
        let wind = current.windSpeed10m.map {
            "wind \(Self.rounded($0)) \(windUnit)"
        } ?? "wind n/a"
        let precipitation = current.precipitation.map {
            $0 > 0 ? "precip \(Self.rounded($0)) mm" : "no precip"
        } ?? "precip n/a"
        let condition = Self.weatherDescription(code: current.weatherCode)

        return "\(place.displayName): \(condition), \(Self.rounded(current.temperature2m))\(temperatureUnit), \(apparent). \(humidity), \(wind), \(precipitation)."
    }

    static func petWeather(location: String) async throws -> PetWeatherSnapshot {
        let place = try await geocode(location: location)
        let forecast = try await forecast(latitude: place.latitude, longitude: place.longitude)
        let current = forecast.current
        let temperatureCelsius = (current.temperature2m - 32) * 5 / 9
        return PetWeatherSnapshot(
            location: place.name,
            condition: petWeatherDescription(code: current.weatherCode),
            temperatureCelsius: temperatureCelsius,
            isPrecipitating: (current.precipitation ?? 0) > 0
        )
    }

    private static func geocode(location: String) async throws -> WeatherPlace {
        for query in geocodeQueries(for: location) {
            var components = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")
            components?.queryItems = [
                URLQueryItem(name: "name", value: query),
                URLQueryItem(name: "count", value: "1"),
                URLQueryItem(name: "language", value: "en"),
                URLQueryItem(name: "format", value: "json")
            ]
            guard let url = components?.url else { throw AgentWeatherError.invalidURL }

            let (data, response) = try await URLSession.shared.data(from: url)
            try validateHTTP(response)
            let result = try JSONDecoder().decode(WeatherGeocodingResponse.self, from: data)
            if let place = result.results?.first {
                return place
            }
        }

        throw AgentWeatherError.locationNotFound(location)
    }

    private static func geocodeQueries(for location: String) -> [String] {
        var queries: [String] = []

        func add(_ value: String) {
            let query = value
                .trimmingCharacters(in: CharacterSet(charactersIn: " \n\t,.，。"))
            if !query.isEmpty && !queries.contains(query) {
                queries.append(query)
            }
        }

        add(location)

        if let city = location.split(separator: ",").first {
            add(String(city))
        }

        let withoutStateAbbreviation = location
            .replacingOccurrences(of: #"\b[A-Z]{2}\b"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: ",", with: " ")
        add(withoutStateAbbreviation)

        let normalized = location
            .lowercased()
            .replacingOccurrences(of: ".", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized == "la" || normalized == "l a" {
            add("Los Angeles")
        }

        return queries
    }

    private static func forecast(latitude: Double, longitude: Double) async throws -> WeatherForecastResponse {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")
        components?.queryItems = [
            URLQueryItem(name: "latitude", value: String(latitude)),
            URLQueryItem(name: "longitude", value: String(longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,relative_humidity_2m,apparent_temperature,precipitation,weather_code,wind_speed_10m"),
            URLQueryItem(name: "temperature_unit", value: "fahrenheit"),
            URLQueryItem(name: "wind_speed_unit", value: "mph"),
            URLQueryItem(name: "timezone", value: "auto")
        ]
        guard let url = components?.url else { throw AgentWeatherError.invalidURL }

        let (data, response) = try await URLSession.shared.data(from: url)
        try validateHTTP(response)
        return try JSONDecoder().decode(WeatherForecastResponse.self, from: data)
    }

    private static func validateHTTP(_ response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode)
        else {
            throw AgentWeatherError.requestFailed
        }
    }

    private static func rounded(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }

    private static func weatherDescription(code: Int?) -> String {
        switch code {
        case 0:
            return "clear"
        case 1, 2:
            return "partly cloudy"
        case 3:
            return "overcast"
        case 45, 48:
            return "fog"
        case 51, 53, 55, 56, 57:
            return "drizzle"
        case 61, 63, 65, 66, 67, 80, 81, 82:
            return "rain"
        case 71, 73, 75, 77, 85, 86:
            return "snow"
        case 95, 96, 99:
            return "thunderstorm"
        default:
            return "weather code \(code.map(String.init) ?? "n/a")"
        }
    }

    private static func petWeatherDescription(code: Int?) -> String {
        switch code {
        case 0:
            return "晴朗"
        case 1, 2:
            return "多云"
        case 3:
            return "阴天"
        case 45, 48:
            return "有雾"
        case 51, 53, 55, 56, 57:
            return "有小雨"
        case 61, 63, 65, 66, 67, 80, 81, 82:
            return "下雨"
        case 71, 73, 75, 77, 85, 86:
            return "下雪"
        case 95, 96, 99:
            return "有雷雨"
        default:
            return "天气未知"
        }
    }
}

struct PetWeatherSnapshot {
    let location: String
    let condition: String
    let temperatureCelsius: Double
    let isPrecipitating: Bool
}

struct WeatherGeocodingResponse: Decodable {
    let results: [WeatherPlace]?
}

struct WeatherPlace: Decodable {
    let name: String
    let latitude: Double
    let longitude: Double
    let admin1: String?
    let countryCode: String?

    private enum CodingKeys: String, CodingKey {
        case name
        case latitude
        case longitude
        case admin1
        case countryCode = "country_code"
    }

    var displayName: String {
        [name, admin1, countryCode]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }
}

struct WeatherForecastResponse: Decodable {
    let current: WeatherCurrent
    let currentUnits: WeatherCurrentUnits

    private enum CodingKeys: String, CodingKey {
        case current
        case currentUnits = "current_units"
    }
}

struct WeatherCurrent: Decodable {
    let temperature2m: Double
    let relativeHumidity2m: Int?
    let apparentTemperature: Double?
    let precipitation: Double?
    let weatherCode: Int?
    let windSpeed10m: Double?

    private enum CodingKeys: String, CodingKey {
        case temperature2m = "temperature_2m"
        case relativeHumidity2m = "relative_humidity_2m"
        case apparentTemperature = "apparent_temperature"
        case precipitation
        case weatherCode = "weather_code"
        case windSpeed10m = "wind_speed_10m"
    }
}

struct WeatherCurrentUnits: Decodable {
    let temperature2m: String?
    let windSpeed10m: String?

    private enum CodingKeys: String, CodingKey {
        case temperature2m = "temperature_2m"
        case windSpeed10m = "wind_speed_10m"
    }
}

enum AgentWeatherError: LocalizedError {
    case invalidURL
    case requestFailed
    case locationNotFound(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid weather request."
        case .requestFailed:
            return "Weather request failed."
        case .locationNotFound(let location):
            return "I could not find weather for \(location)."
        }
    }
}

/// Fullscreen hides the island. A partial window or an empty desktop shows it.
/// A settled fullscreen window is inset below the menu bar, so its bounds match a
/// maximized window. Menu-bar status items leave the display only in a fullscreen space.
@MainActor
enum FullScreenDetector {
    private static var menuBarDisplay: CGRect?

    static func isWindowFullScreen(processID: pid_t?) -> Bool {
        guard let processID else { return false }

        // Split view and ordinary windows stay visible even though a fullscreen
        // space also dismisses the menu bar.
        if let axFrame = accessibilityWindowFrame(processID: processID),
           !windowSpansDisplay(axFrame) {
            return false
        }

        guard let window = largestOpaqueWindow(of: processID) else { return false }
        if frameCoversEntireDisplay(window) { return true }
        guard windowSpansDisplay(window) else { return false }
        return menuBarIsHidden(for: window)
    }

    private static func onScreenWindows() -> [[String: Any]] {
        CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] ?? []
    }

    private static func largestOpaqueWindow(of processID: pid_t) -> CGRect? {
        onScreenWindows().compactMap { info -> CGRect? in
            guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == processID,
                  (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  ((info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0.5,
                  let frame = windowFrame(info),
                  frame.width > 80,
                  frame.height > 80
            else {
                return nil
            }
            return frame
        }.max { lhs, rhs in
            lhs.width * lhs.height < rhs.width * rhs.height
        }
    }

    /// Status items on the system menu bar. They are gone while that display is fullscreen.
    private static func isMenuBarExtra(_ info: [String: Any]) -> Bool {
        let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
        if pid == ProcessInfo.processInfo.processIdentifier { return false }
        guard (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 25,
              ((info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0.05,
              let frame = windowFrame(info),
              frame.height >= 16, frame.height <= 48,
              frame.width >= 12, frame.width <= 280
        else {
            return false
        }
        return displayBoundsList().contains { display in
            abs(frame.minY - display.minY) <= 8
                && frame.maxX > display.minX
                && frame.minX < display.maxX
        }
    }

    private static func menuBarIsHidden(for window: CGRect) -> Bool {
        let windows = onScreenWindows()
        let extras = windows.filter(isMenuBarExtra)
        if let extra = extras.compactMap(windowFrame).first,
           let display = displayContaining(extra) {
            menuBarDisplay = display
            return false
        }
        if let menuBarDisplay {
            return window.intersects(menuBarDisplay)
        }
        // No status items have been seen yet. Trust that only when other apps'
        // windows are visible, so a sandboxed empty list does not hide the island.
        let seesOtherApps = windows.contains { info in
            let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
            return pid != nil && pid != ProcessInfo.processInfo.processIdentifier
        }
        return seesOtherApps
    }

    private static func windowSpansDisplay(_ rect: CGRect) -> Bool {
        guard let display = displayContaining(rect),
              display.width > 1, display.height > 1
        else {
            return false
        }
        return rect.width >= display.width * 0.92
            && rect.height >= display.height * 0.80
    }

    private static func frameCoversEntireDisplay(_ windowBounds: CGRect) -> Bool {
        displayBoundsList().contains { displayBounds in
            guard displayBounds.width > 1, displayBounds.height > 1 else { return false }
            let tolerance: CGFloat = 8
            return abs(windowBounds.minX - displayBounds.minX) <= tolerance
                && abs(windowBounds.minY - displayBounds.minY) <= tolerance
                && abs(windowBounds.width - displayBounds.width) <= tolerance
                && abs(windowBounds.height - displayBounds.height) <= tolerance
        }
    }

    private static func displayContaining(_ rect: CGRect) -> CGRect? {
        displayBoundsList()
            .map { display in (display, intersectionArea(display, rect)) }
            .filter { $0.1 > 1 }
            .max { $0.1 < $1.1 }?
            .0
    }

    private static func intersectionArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull, !intersection.isEmpty else { return 0 }
        return intersection.width * intersection.height
    }

    private static func displayBoundsList() -> [CGRect] {
        NSScreen.screens.compactMap { screen in
            guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            return CGDisplayBounds(CGDirectDisplayID(screenNumber.uint32Value))
        }
    }

    private static func windowFrame(_ info: [String: Any]) -> CGRect? {
        guard let bounds = info[kCGWindowBounds as String] as? [String: Any] else { return nil }
        func number(_ key: String) -> CGFloat? {
            if let value = bounds[key] as? NSNumber { return CGFloat(value.doubleValue) }
            if let value = bounds[key] as? CGFloat { return value }
            return nil
        }
        guard let x = number("X"), let y = number("Y"),
              let width = number("Width"), let height = number("Height")
        else {
            return nil
        }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// Returns nil when Accessibility is unavailable, and the caller falls through to the
    /// `CGWindowList` path, which needs no permission.
    private static func accessibilityWindowFrame(processID: pid_t) -> CGRect? {
        guard AppStoreDistribution.allowsAccessibilityFeatures, AXIsProcessTrusted() else { return nil }
        let application = AXUIElementCreateApplication(processID)
        guard let window = axElement(application, kAXFocusedWindowAttribute as String)
            ?? axElement(application, kAXMainWindowAttribute as String),
              let position = axPoint(window, kAXPositionAttribute as String),
              let size = axSize(window, kAXSizeAttribute as String),
              size.width > 80, size.height > 80
        else {
            return nil
        }
        // AX positions share CGDisplayBounds' top-left global space.
        return CGRect(origin: position, size: size)
    }

    private static func axElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value
        else {
            return nil
        }
        return (value as! AXUIElement)
    }

    private static func axPoint(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
        guard let raw = axRawValue(element, attribute), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(raw as! AXValue, .cgPoint, &point) else { return nil }
        return point
    }

    private static func axSize(_ element: AXUIElement, _ attribute: String) -> CGSize? {
        guard let raw = axRawValue(element, attribute), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(raw as! AXValue, .cgSize, &size) else { return nil }
        return size
    }

    private static func axRawValue(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }
}

@MainActor
enum AgentContextProvider {
    private struct PasteboardSnapshot {
        let items: [[NSPasteboard.PasteboardType: Data]]

        init(pasteboard: NSPasteboard) {
            items = pasteboard.pasteboardItems?.map { item in
                Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
                    item.data(forType: type).map { (type, $0) }
                })
            } ?? []
        }

        func restore(to pasteboard: NSPasteboard) {
            pasteboard.clearContents()
            let pasteboardItems = items.map { values in
                let item = NSPasteboardItem()
                for (type, data) in values {
                    item.setData(data, forType: type)
                }
                return item
            }
            if !pasteboardItems.isEmpty {
                pasteboard.writeObjects(pasteboardItems)
            }
        }
    }

    static func capture(
        processID: pid_t?,
        bundleIdentifier: String,
        appName: String,
        includeFocusedText: Bool
    ) -> AgentWorkspaceContext {
        // `AXIsProcessTrusted()` reports true under App Sandbox whether or not the user granted
        // anything, while every call below then fails with -25204, so the capability flag has to
        // be part of the gate — otherwise this build claims a context it cannot read.
        let accessibilityEnabled = AppStoreDistribution.allowsAccessibilityFeatures && AXIsProcessTrusted()
        var windowTitle: String?
        var selectedText: String?
        var focusedText: String?

        if accessibilityEnabled, let processID {
            let application = AXUIElementCreateApplication(processID)
            if let window = elementAttribute(application, kAXFocusedWindowAttribute) {
                windowTitle = stringAttribute(window, kAXTitleAttribute)
            }

            if let focusedElement = elementAttribute(application, kAXFocusedUIElementAttribute),
               !isSecureTextElement(focusedElement)
            {
                selectedText = limitedText(stringAttribute(focusedElement, kAXSelectedTextAttribute), limit: 8_000)
                if includeFocusedText {
                    focusedText = limitedText(stringAttribute(focusedElement, kAXValueAttribute), limit: 10_000)
                }
            }
        }

        let browser = browserDocument(bundleIdentifier: bundleIdentifier)
        return AgentWorkspaceContext(
            appName: appName,
            bundleIdentifier: bundleIdentifier,
            windowTitle: windowTitle,
            selectedText: selectedText,
            focusedText: focusedText,
            pageTitle: browser?.title,
            pageURL: browser?.url,
            hasAccessibilityAccess: accessibilityEnabled
        )
    }

    /// Never prompt in a build that cannot use the grant: the sandbox refuses cross-application
    /// Accessibility regardless, so the panel would be asking for a permission it cannot spend.
    static func requestAccessibilityAccess() {
        guard AppStoreDistribution.allowsAccessibilityFeatures else { return }
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    static func selectedText(processID: pid_t?) -> String? {
        guard AppStoreDistribution.allowsAccessibilityFeatures else { return nil }
        guard AXIsProcessTrusted(), let processID else { return nil }
        let application = AXUIElementCreateApplication(processID)
        guard let focusedElement = elementAttribute(application, kAXFocusedUIElementAttribute),
              !isSecureTextElement(focusedElement)
        else {
            return nil
        }
        return limitedText(stringAttribute(focusedElement, kAXSelectedTextAttribute), limit: 4_000)
    }

    static func isWindowFullScreen(processID: pid_t?) -> Bool {
        FullScreenDetector.isWindowFullScreen(processID: processID)
    }

    /// Last-resort read of the frontmost selection by synthesizing Cmd+C.
    ///
    /// Gated on the Accessibility capability, which also keeps the synthesized key event out of
    /// builds that must not post HID events at all.
    static func copySelectedText(
        processID: pid_t?,
        completion: @escaping (String?) -> Void
    ) {
        guard AppStoreDistribution.allowsAccessibilityFeatures else {
            completion(nil)
            return
        }
        guard AXIsProcessTrusted(),
              let processID,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == processID
        else {
            completion(nil)
            return
        }

        let application = AXUIElementCreateApplication(processID)
        if let focusedElement = elementAttribute(application, kAXFocusedUIElementAttribute),
           isSecureTextElement(focusedElement)
        {
            completion(nil)
            return
        }

        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot(pasteboard: pasteboard)
        let previousChangeCount = pasteboard.changeCount
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: false)
        else {
            completion(nil)
            return
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) {
            let copiedText = pasteboard.changeCount == previousChangeCount
                ? nil
                : limitedText(pasteboard.string(forType: .string), limit: 4_000)
            snapshot.restore(to: pasteboard)
            completion(copiedText)
        }
    }

    static func loadPageText(from url: URL) async -> String? {
        guard url.scheme == "http" || url.scheme == "https" else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 14
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X) AppleWebKit/605.1.15 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              data.count <= 12_000_000
        else {
            return nil
        }

        let mimeType = (response as? HTTPURLResponse)?.mimeType?.lowercased() ?? ""
        if mimeType == "application/pdf" || url.pathExtension.lowercased() == "pdf" {
            guard let document = PDFDocument(data: data) else { return nil }
            let text = (0..<min(document.pageCount, 40))
                .compactMap { document.page(at: $0)?.string }
                .joined(separator: "\n\n")
            return limitedText(text, limit: 24_000)
        }

        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue
        ]
        guard let attributed = try? NSAttributedString(
            data: data,
            options: options,
            documentAttributes: nil
        ) else {
            return nil
        }
        return limitedText(normalizedDocumentText(attributed.string), limit: 24_000)
    }

    private static func elementAttribute(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value
        else {
            return nil
        }
        return (value as! AXUIElement)
    }

    private static func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }

        if let string = value as? String {
            return string
        }
        if let attributed = value as? NSAttributedString {
            return attributed.string
        }
        return nil
    }

    private static func boolAttribute(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let number = value as? NSNumber
        else {
            return nil
        }
        return number.boolValue
    }

    private static func isSecureTextElement(_ element: AXUIElement) -> Bool {
        let subrole = stringAttribute(element, kAXSubroleAttribute)
        return subrole == (kAXSecureTextFieldSubrole as String)
    }

    private static func browserDocument(bundleIdentifier: String) -> (title: String, url: URL)? {
        let source: String
        switch bundleIdentifier {
        case "com.apple.Safari":
            source = """
            tell application id "com.apple.Safari"
                if (count of documents) is 0 then return ""
                set currentDocument to front document
                return (name of currentDocument) & linefeed & (URL of currentDocument)
            end tell
            """
        case "com.google.Chrome", "com.google.Chrome.canary", "company.thebrowser.Browser", "com.microsoft.edgemac":
            source = """
            tell application id "\(bundleIdentifier)"
                if (count of windows) is 0 then return ""
                set currentTab to active tab of front window
                return (title of currentTab) & linefeed & (URL of currentTab)
            end tell
            """
        default:
            return nil
        }

        var errorInfo: NSDictionary?
        guard let value = NSAppleScript(source: source)?.executeAndReturnError(&errorInfo).stringValue else {
            return nil
        }
        let lines = value.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard lines.count == 2, let url = URL(string: String(lines[1])) else { return nil }
        return (String(lines[0]), url)
    }

    private static func normalizedDocumentText(_ text: String) -> String {
        text
            .replacingOccurrences(of: #"[\t ]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func limitedText(_ value: String?, limit: Int) -> String? {
        guard let value else { return nil }
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.count <= limit {
            return text
        }
        return String(text.prefix(limit)) + "\n[truncated]"
    }
}


enum AgentScreenCaptureError: LocalizedError {
    case permissionRequired
    case windowUnavailable
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .permissionRequired:
            return "Screen Recording permission is required for game screenshot analysis."
        case .windowUnavailable:
            return "I could not capture the active game window."
        case .encodingFailed:
            return "The game screenshot could not be encoded."
        }
    }
}

enum AgentScreenCapture {
    static func captureWindow(processID: pid_t?) async throws -> Data {
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            throw AgentScreenCaptureError.permissionRequired
        }
        guard let processID else { throw AgentScreenCaptureError.windowUnavailable }

        let content = try await SCShareableContent.excludingDesktopWindows(
            true,
            onScreenWindowsOnly: true
        )
        let candidates = content.windows.filter {
            $0.owningApplication?.processID == processID
                && $0.isOnScreen
                && $0.windowLayer == 0
                && $0.frame.width >= 240
                && $0.frame.height >= 160
        }
        guard let window = candidates.max(by: {
            $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height
        }) else {
            throw AgentScreenCaptureError.windowUnavailable
        }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        let scale = min(2, min(1_600 / window.frame.width, 1_000 / window.frame.height))
        configuration.width = max(1, Int(window.frame.width * scale))
        configuration.height = max(1, Int(window.frame.height * scale))
        configuration.showsCursor = false
        configuration.queueDepth = 1

        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )
        let representation = NSBitmapImageRep(cgImage: image)
        guard let data = representation.representation(
            using: .jpeg,
            properties: [.compressionFactor: 0.72]
        ) else {
            throw AgentScreenCaptureError.encodingFailed
        }
        return data
    }
}


