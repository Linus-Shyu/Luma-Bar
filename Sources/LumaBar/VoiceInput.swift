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

enum DesktopPetMood: Equatable {
    case idle
    case hot
    case working
    case stretch
    case voice
}

enum VoiceWhisperError: LocalizedError {
    case speechUnavailable
    case microphoneUnavailable
    case chineseModelUnavailable

    var errorDescription: String? {
        switch self {
        case .speechUnavailable:
            return "这台 Mac 当前无法使用语音识别。"
        case .microphoneUnavailable:
            return "没有检测到可用的麦克风输入。"
        case .chineseModelUnavailable:
            return "这台 Mac 当前无法使用简体中文语音模型。"
        }
    }
}

enum VoiceWhisperPermissionBroker {
    static func requestSpeechAuthorization(
        completion: @escaping @Sendable (SFSpeechRecognizerAuthorizationStatus) -> Void
    ) {
        SFSpeechRecognizer.requestAuthorization { status in
            completion(status)
        }
    }

    static func requestMicrophoneAccess(
        completion: @escaping @Sendable (Bool) -> Void
    ) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            completion(granted)
        }
    }
}

protocol VoiceWhisperSession: AnyObject {
    var finalizationTimeout: TimeInterval? { get }

    func start() throws
    func finishRecognition()
    func stop()
}

final class VoiceWhisperAudioSession: VoiceWhisperSession {
    private let recognizer: SFSpeechRecognizer
    private let onResult: @Sendable (String, Bool) -> Void
    private let onError: @Sendable (String) -> Void
    private let audioEngine = AVAudioEngine()
    private let recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
    private var recognitionTask: SFSpeechRecognitionTask?
    private var isTapInstalled = false
    private var isFinishing = false
    private var isStopped = false

    let finalizationTimeout: TimeInterval? = 3

    init(
        recognizer: SFSpeechRecognizer,
        onResult: @escaping @Sendable (String, Bool) -> Void,
        onError: @escaping @Sendable (String) -> Void
    ) {
        self.recognizer = recognizer
        self.onResult = onResult
        self.onError = onError
    }

    func start() throws {
        recognitionRequest.shouldReportPartialResults = true
        recognitionRequest.taskHint = .dictation
        if #available(macOS 13.0, *) {
            recognitionRequest.addsPunctuation = true
        }

        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.channelCount > 0 else {
            throw VoiceWhisperError.microphoneUnavailable
        }

        inputNode.installTap(onBus: 0, bufferSize: 1_024, format: inputFormat) { [recognitionRequest] buffer, _ in
            recognitionRequest.append(buffer)
        }
        isTapInstalled = true

        do {
            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            stop()
            throw error
        }

        recognitionTask = recognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            guard let self, !self.isStopped else { return }

            if let result {
                self.onResult(result.bestTranscription.formattedString, result.isFinal)
            }

            if let error, !self.isStopped {
                self.onError(error.localizedDescription)
            }
        }
    }

    func finishRecognition() {
        guard !isStopped, !isFinishing else { return }
        isFinishing = true
        stopAudioInput()
        recognitionRequest.endAudio()
    }

    func stop() {
        guard !isStopped else { return }
        isStopped = true
        stopAudioInput()
        if !isFinishing {
            recognitionRequest.endAudio()
        }
        recognitionTask?.cancel()
        recognitionTask = nil
    }

    private func stopAudioInput() {
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        if isTapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            isTapInstalled = false
        }
    }

    deinit {
        stop()
    }
}

#if LUMABAR_SPEECH_ANALYZER
@available(macOS 26.0, *)
final class VoiceWhisperAudioFileSink: @unchecked Sendable {
    private var audioFile: AVAudioFile?

    init(audioFile: AVAudioFile) {
        self.audioFile = audioFile
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        try? audioFile?.write(from: buffer)
    }

    func close() {
        audioFile = nil
    }
}

@available(macOS 26.0, *)
final class VoiceWhisperAnalyzerSession: VoiceWhisperSession, @unchecked Sendable {
    private let onResult: @Sendable (String, Bool) -> Void
    private let onError: @Sendable (String) -> Void
    private let onStatus: @Sendable (String) -> Void
    private let audioEngine = AVAudioEngine()
    private var audioFileSink: VoiceWhisperAudioFileSink?
    private var recordingURL: URL?
    private var transcriptionTask: Task<Void, Never>?
    private var isTapInstalled = false
    private var isFinishing = false
    private var isStopped = false

    let finalizationTimeout: TimeInterval? = 18

    init(
        onResult: @escaping @Sendable (String, Bool) -> Void,
        onError: @escaping @Sendable (String) -> Void,
        onStatus: @escaping @Sendable (String) -> Void
    ) {
        self.onResult = onResult
        self.onError = onError
        self.onStatus = onStatus
    }

    func start() throws {
        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.channelCount > 0 else {
            throw VoiceWhisperError.microphoneUnavailable
        }

        let recordingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LumaBarVoiceWhisper-\(UUID().uuidString)")
            .appendingPathExtension("caf")
        let audioFile = try AVAudioFile(
            forWriting: recordingURL,
            settings: inputFormat.settings
        )
        let audioFileSink = VoiceWhisperAudioFileSink(audioFile: audioFile)
        self.recordingURL = recordingURL
        self.audioFileSink = audioFileSink

        inputNode.installTap(onBus: 0, bufferSize: 1_024, format: inputFormat) { [audioFileSink] buffer, _ in
            audioFileSink.append(buffer)
        }
        isTapInstalled = true

        do {
            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            stop()
            throw error
        }
    }

    func finishRecognition() {
        guard !isStopped, !isFinishing else { return }
        isFinishing = true
        stopAudioInput()
        audioFileSink?.close()
        audioFileSink = nil
        onStatus("正在准备本地中文转写…")

        transcriptionTask = Task { [weak self] in
            await self?.transcribeRecording()
        }
    }

    func stop() {
        guard !isStopped else { return }
        isStopped = true
        stopAudioInput()
        audioFileSink?.close()
        audioFileSink = nil
        transcriptionTask?.cancel()
        transcriptionTask = nil
        removeRecording()
    }

    private func stopAudioInput() {
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        if isTapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            isTapInstalled = false
        }
    }

    private func transcribeRecording() async {
        do {
            guard let recordingURL,
                  let locale = await SpeechTranscriber.supportedLocale(
                    equivalentTo: Locale(identifier: "zh-CN")
                  ) else {
                throw VoiceWhisperError.chineseModelUnavailable
            }

            let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
            let modules: [any SpeechModule] = [transcriber]
            let assetStatus = await AssetInventory.status(forModules: modules)
            if assetStatus != .installed {
                onStatus("正在下载简体中文语音模型…")
                guard let installationRequest = try await AssetInventory.assetInstallationRequest(
                    supporting: modules
                ) else {
                    throw VoiceWhisperError.chineseModelUnavailable
                }
                try await installationRequest.downloadAndInstall()
            }

            try Task.checkCancellation()
            onStatus("正在本地转写简体中文语音…")

            let analyzer = SpeechAnalyzer(
                modules: modules,
                options: .init(priority: .userInitiated, modelRetention: .lingering)
            )
            let context = AnalysisContext()
            context.contextualStrings[.general] = [
                "终端", "命令", "当前目录", "文件夹", "应用程序",
                "Git", "commit", "Markdown", "Shell", "zsh",
                "打开", "关闭", "执行", "运行", "安装", "下载"
            ]
            try await analyzer.setContext(context)
            let resultTask = Task<String, Error> {
                var transcript = ""
                for try await result in transcriber.results where result.isFinal {
                    transcript += String(result.text.characters)
                }
                return transcript
            }

            let audioFile = try AVAudioFile(forReading: recordingURL)
            let lastSampleTime = try await analyzer.analyzeSequence(from: audioFile)
            if let lastSampleTime {
                try await analyzer.finalizeAndFinish(through: lastSampleTime)
            } else {
                await analyzer.cancelAndFinishNow()
            }

            let transcript = try await resultTask.value
            try Task.checkCancellation()
            guard !isStopped else { return }
            onResult(transcript, true)
        } catch is CancellationError {
            return
        } catch {
            guard !isStopped else { return }
            onError(error.localizedDescription)
        }
    }

    private func removeRecording() {
        guard let recordingURL else { return }
        self.recordingURL = nil
        try? FileManager.default.removeItem(at: recordingURL)
    }

    deinit {
        stop()
    }
}

#endif

struct AgentWorkspaceContext: Sendable {
    let appName: String
    let bundleIdentifier: String
    let windowTitle: String?
    let selectedText: String?
    let focusedText: String?
    let pageTitle: String?
    let pageURL: URL?
    let hasAccessibilityAccess: Bool
}

