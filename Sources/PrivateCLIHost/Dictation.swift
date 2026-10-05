import AppKit
import AVFoundation
import Foundation
import Speech
import SwiftUI

/// Joins dictated phrases into a draft. The recognizer reports phrases with
/// or without their leading space, and punctuation attaches to the word
/// before it.
enum DictationText {
    static func join(_ head: String, _ tail: String) -> String {
        let tail = String(tail.drop { $0 == " " })
        guard !tail.isEmpty else { return head }
        guard let last = head.last else { return tail }
        if last.isWhitespace || tail.first.map(attachesLeft) == true { return head + tail }
        return head + " " + tail
    }

    private static func attachesLeft(_ character: Character) -> Bool {
        ".,;:!?)…".contains(character)
    }
}

/// Settled phrases plus the phrase still being heard, which the recognizer
/// may revise until it marks the phrase final.
struct DictationTranscript: Equatable {
    private(set) var settled = ""
    private(set) var pending = ""

    var text: String { DictationText.join(settled, pending) }

    mutating func apply(_ phrase: String, isFinal: Bool) {
        if isFinal {
            settled = DictationText.join(settled, phrase)
            pending = ""
        } else {
            pending = phrase
        }
    }
}

enum DictationLanguage {
    /// The Mac's preferred languages, so a bilingual setup offers each of them.
    static func choices(preferred: [String] = Locale.preferredLanguages, including current: String? = nil) -> [String] {
        var seen = Set<String>()
        return (preferred + ["en-US"] + [current].compactMap { $0 }).filter { seen.insert($0).inserted }
    }

    static func title(for identifier: String) -> String {
        Locale.current.localizedString(forIdentifier: identifier) ?? identifier
    }
}

/// Why dictation could not start or stopped early, worded for an alert.
enum DictationProblem: Error, Equatable {
    case unsupportedSystem
    case unpackagedBuild
    case microphoneDenied
    case noMicrophone
    case unsupportedLanguage(String)
    case failed(String)

    var message: String {
        switch self {
        case .unsupportedSystem:
            return "Dictation needs macOS 26 or later, which transcribes speech on this Mac."
        case .unpackagedBuild:
            return "This build has no microphone usage text. Package the app with Packaging/build-and-package.sh to dictate."
        case .microphoneDenied:
            return "m4ix.CLI needs microphone access to dictate. Turn it on in System Settings → Privacy & Security → Microphone."
        case .noMicrophone:
            return "No microphone is available."
        case .unsupportedLanguage(let name):
            return "On-device dictation is not available for \(name) on this Mac. Right-click the microphone to choose another language."
        case .failed(let detail):
            return "Dictation stopped: \(detail)"
        }
    }

    var opensPrivacySettings: Bool { self == .microphoneDenied }
}

/// Input loudness, kept apart from `Dictation` so the meter redraws without
/// redrawing the composer or the terminal.
@MainActor
final class DictationMeter: ObservableObject {
    @Published fileprivate(set) var level: Float = 0
}

/// Speech to text for the message composer, as in Claude Desktop: Caps Lock
/// or the microphone button starts listening, the words appear in the draft,
/// and nothing is sent until Return. Audio is transcribed on this Mac and
/// never stored.
@MainActor
final class Dictation: ObservableObject {
    enum Phase: Equatable {
        case idle
        /// Waiting for microphone access or a speech model.
        case preparing(String)
        case listening
        /// The recognizer is settling the last words.
        case finishing
    }

    @Published private(set) var phase: Phase = .idle
    /// The draft receiving the words, fixed when listening starts.
    @Published private(set) var target: String?
    @Published var problem: DictationProblem?
    @Published var language: String {
        didSet { preferences.set(language, forKey: Self.languageKey) }
    }
    @Published var startsWithCapsLock: Bool {
        didSet { preferences.set(startsWithCapsLock, forKey: Self.capsLockKey) }
    }
    let meter = DictationMeter()

    private let preferences: UserDefaults
    private let bundle: Bundle
    private var deliver: ((String, Bool) -> Void)?
    private var transcript = ""
    private var run: DictationRun?
    private var preparation: Task<Void, Never>?
    /// The permission prompt is another process's window, so the app leaves
    /// the foreground while it is answered.
    private var awaitsPermission = false
    private var finishWhenReady = false
    private var generation = 0
    private var capsLockMonitor: Any?
    private var capsLockIsOn = NSEvent.modifierFlags.contains(.capsLock)
    private var observers: [NSObjectProtocol] = []

    static let languageKey = "PrivateCLIHostDictationLanguage"
    static let capsLockKey = "PrivateCLIHostDictationCapsLock"
    private static let capsLockKeyCode: UInt16 = 57

    static var isSupported: Bool {
        if #available(macOS 26, *) { return true }
        return false
    }

    init(preferences: UserDefaults = HostPaths.preferences, bundle: Bundle = .main) {
        self.preferences = preferences
        self.bundle = bundle
        language = preferences.string(forKey: Self.languageKey) ?? DictationLanguage.choices().first ?? "en-US"
        startsWithCapsLock = preferences.object(forKey: Self.capsLockKey) as? Bool ?? true
        // A microphone left open behind another app is a microphone nobody is watching.
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.awaitsPermission else { return }
                self.finish()
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.capsLockIsOn = NSEvent.modifierFlags.contains(.capsLock) } })
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        if let capsLockMonitor { NSEvent.removeMonitor(capsLockMonitor) }
    }

    func isActive(for key: String) -> Bool { phase != .idle && target == key }

    /// Caps Lock turning on starts dictation and turning off finishes it. A
    /// press while listening also finishes, so either control ends what the
    /// other began. Only presses made while this app is active arrive here.
    func monitorCapsLock(_ start: @escaping () -> Void) {
        guard capsLockMonitor == nil else { return }
        capsLockMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            guard let self, event.keyCode == Self.capsLockKeyCode else { return event }
            let isOn = event.modifierFlags.contains(.capsLock)
            guard isOn != self.capsLockIsOn else { return event }
            self.capsLockIsOn = isOn
            guard self.startsWithCapsLock else { return event }
            if self.phase != .idle { self.finish() } else if isOn { start() }
            return event
        }
    }

    /// Listens for `key`'s draft. `deliver` receives the whole transcript so
    /// far each time it changes, and once more marked final.
    func start(target key: String, deliver: @escaping (_ transcript: String, _ isFinal: Bool) -> Void) {
        guard phase == .idle else { return }
        guard Self.isSupported else { problem = .unsupportedSystem; return }
        // macOS ends an app that opens the microphone without this text.
        guard bundle.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") != nil else {
            problem = .unpackagedBuild
            return
        }
        generation += 1
        let generation = self.generation
        target = key
        self.deliver = deliver
        transcript = ""
        phase = .preparing("Starting…")
        let locale = Locale(identifier: language)
        let events = DictationEvents(
            status: { [weak self] message in
                guard let self, self.accepts(generation) else { return }
                self.phase = .preparing(message)
            },
            listening: { [weak self] in
                guard let self, self.accepts(generation) else { return }
                self.phase = .listening
            },
            level: { [weak self] level in
                guard let self, self.accepts(generation) else { return }
                self.meter.level = level
            },
            text: { [weak self] text in
                guard let self, self.accepts(generation) else { return }
                self.receive(text)
            })
        awaitsPermission = AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined
        preparation = Task { [weak self] in
            guard #available(macOS 26, *) else { return }
            do {
                let allowed = await Self.microphoneAccess()
                self?.awaitsPermission = false
                guard allowed else { throw DictationProblem.microphoneDenied }
                // Listen once the app has the foreground back from the prompt.
                guard await Self.regainsForeground(within: 2) else {
                    self?.cancel()
                    return
                }
                try Task.checkCancellation()
                let run = try await MicrophoneDictation.start(locale: locale, events: events)
                guard let self, self.accepts(generation) else {
                    await run.cancel()
                    return
                }
                self.preparation = nil
                if self.finishWhenReady { self.settle(run) } else { self.run = run }
            } catch is CancellationError {
            } catch {
                self?.fail(error, generation: generation)
            }
        }
    }

    /// Stops listening and puts the settled words in the draft.
    func finish() {
        switch phase {
        case .idle, .finishing: return
        case .preparing: return cancel()
        case .listening: break
        }
        phase = .finishing
        meter.level = 0
        // The microphone opens before the recognizer is running; the run
        // settles as soon as it exists.
        if let run { settle(run) } else { finishWhenReady = true }
    }

    /// Stops without waiting for the recognizer. Words already shown stay in
    /// the draft.
    func cancel() {
        guard phase != .idle else { return }
        preparation?.cancel()
        if let run { Task { await run.cancel() } }
        complete(transcript, generation: generation)
    }

    static func openMicrophoneSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") else { return }
        NSWorkspace.shared.open(url)
    }

    private func accepts(_ generation: Int) -> Bool {
        self.generation == generation && phase != .idle
    }

    private func settle(_ run: DictationRun) {
        self.run = nil
        let generation = self.generation
        let watchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard let self, !Task.isCancelled, self.accepts(generation) else { return }
            HostDiagnostics.record("dictation_finish_timeout")
            await run.cancel()
            self.complete(self.transcript, generation: generation)
        }
        Task { [weak self] in
            let settled = try? await run.finish()
            watchdog.cancel()
            guard let self else { return }
            self.complete(settled ?? self.transcript, generation: generation)
        }
    }

    private func receive(_ text: String) {
        transcript = text
        deliver?(text, false)
    }

    private func complete(_ text: String, generation: Int) {
        guard generation == self.generation, phase != .idle else { return }
        let deliver = self.deliver
        self.generation += 1
        phase = .idle
        target = nil
        meter.level = 0
        self.deliver = nil
        run = nil
        preparation = nil
        awaitsPermission = false
        finishWhenReady = false
        transcript = ""
        deliver?(text, true)
    }

    private func fail(_ error: Error, generation: Int) {
        guard generation == self.generation else { return }
        problem = error as? DictationProblem ?? .failed(error.localizedDescription)
        HostDiagnostics.record("dictation_failed")
        if let run { Task { await run.cancel() } }
        complete(transcript, generation: generation)
    }

    private static func regainsForeground(within seconds: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !NSApp.isActive {
            guard Date() < deadline, !Task.isCancelled else { return false }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return true
    }

    private static func microphoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }
}

struct DictationEvents {
    let status: @MainActor (String) -> Void
    let listening: @MainActor () -> Void
    let level: @MainActor (Float) -> Void
    let text: @MainActor (String) -> Void
}

/// One listening run, from the microphone opening to the settled text.
@MainActor
private protocol DictationRun: AnyObject {
    func finish() async throws -> String
    func cancel() async
}

/// The microphone feeding a recognizer. Capture begins before the model has
/// loaded, and the feed holds the first words until it is ready.
@available(macOS 26, *)
@MainActor
private final class MicrophoneDictation: DictationRun {
    private let engine: AVAudioEngine
    private let recognizer: DictationRecognizer
    private var isCapturing = true

    private init(engine: AVAudioEngine, recognizer: DictationRecognizer) {
        self.engine = engine
        self.recognizer = recognizer
    }

    static func start(locale: Locale, events: DictationEvents) async throws -> MicrophoneDictation {
        let engine = AVAudioEngine()
        let natural = engine.inputNode.outputFormat(forBus: 0)
        guard natural.sampleRate > 0, natural.channelCount > 0 else { throw DictationProblem.noMicrophone }
        let recognizer = try await DictationRecognizer.prepare(locale: locale, audio: natural, status: events.status)
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: natural,
                                    block: tap(feed: recognizer.feed, level: events.level))
        engine.prepare()
        do {
            try engine.start()
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            await recognizer.cancel()
            throw DictationProblem.failed("The microphone could not start (\(error.localizedDescription)).")
        }
        events.listening()
        let run = MicrophoneDictation(engine: engine, recognizer: recognizer)
        do {
            try await recognizer.begin(text: events.text)
        } catch {
            await run.cancel()
            throw error
        }
        return run
    }

    func finish() async throws -> String {
        stopCapture()
        return try await recognizer.finish()
    }

    func cancel() async {
        stopCapture()
        await recognizer.cancel()
    }

    private func stopCapture() {
        guard isCapturing else { return }
        isCapturing = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    /// Built outside the main actor: the engine calls it on its audio thread.
    nonisolated private static func tap(feed: DictationFeed, level: @escaping @MainActor (Float) -> Void) -> AVAudioNodeTapBlock {
        { buffer, _ in
            let loudness = DictationFeed.loudness(of: buffer)
            DispatchQueue.main.async { MainActor.assumeIsolated { level(loudness) } }
            feed.append(buffer)
        }
    }
}

/// One on-device recognizer. SpeechTranscriber is the stronger model; the
/// system dictation model covers more languages, Swedish among them.
@available(macOS 26, *)
@MainActor
final class DictationRecognizer {
    let feed: DictationFeed
    private let transcriber: Transcriber
    private let stream: AsyncStream<AnalyzerInput>
    private let analyzer: SpeechAnalyzer
    private var results: Task<String, Error>?

    private init(feed: DictationFeed, transcriber: Transcriber, stream: AsyncStream<AnalyzerInput>) {
        self.feed = feed
        self.transcriber = transcriber
        self.stream = stream
        self.analyzer = SpeechAnalyzer(modules: [transcriber.module])
    }

    /// Readies the model for `locale`, downloading it on first use, and
    /// opens a feed for audio in `natural` format.
    static func prepare(locale: Locale, audio natural: AVAudioFormat,
                        status: @MainActor (String) -> Void) async throws -> DictationRecognizer {
        try await prepare(Transcriber.make(for: locale), audio: natural, status: status)
    }

    static func prepare(_ transcriber: Transcriber, audio natural: AVAudioFormat,
                        status: @MainActor (String) -> Void) async throws -> DictationRecognizer {
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber.module]) {
            status("Downloading the \(transcriber.languageTitle) speech model…")
            try await request.downloadAndInstall()
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber.module],
                                                                         considering: natural) else {
            throw DictationProblem.failed("The speech model accepts none of the available audio formats.")
        }
        let (stream, input) = AsyncStream.makeStream(of: AnalyzerInput.self)
        let feed = try DictationFeed(from: natural, to: format, input: input)
        return DictationRecognizer(feed: feed, transcriber: transcriber, stream: stream)
    }

    /// Transcribes what the feed has collected and everything after it.
    /// `text` receives the whole transcript each time it changes.
    func begin(text: @escaping @MainActor (String) -> Void) async throws {
        let transcriber = self.transcriber
        results = Task { @MainActor in
            var transcript = DictationTranscript()
            try await transcriber.forEachResult { phrase, isFinal in
                transcript.apply(phrase, isFinal: isFinal)
                text(transcript.text)
            }
            return transcript.text
        }
        try await analyzer.start(inputSequence: stream)
    }

    /// Ends the audio and waits for the last phrase to settle.
    func finish() async throws -> String {
        feed.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        return try await results?.value ?? ""
    }

    func cancel() async {
        feed.finish()
        await analyzer.cancelAndFinishNow()
        results?.cancel()
    }
}

@available(macOS 26, *)
enum Transcriber {
    case speech(SpeechTranscriber)
    case dictation(DictationTranscriber)

    var module: any SpeechModule {
        switch self {
        case .speech(let transcriber): return transcriber
        case .dictation(let transcriber): return transcriber
        }
    }

    var languageTitle: String {
        let locale: Locale?
        switch self {
        case .speech(let transcriber): locale = transcriber.selectedLocales.first
        case .dictation(let transcriber): locale = transcriber.selectedLocales.first
        }
        return locale.map { DictationLanguage.title(for: $0.identifier(.bcp47)) } ?? "selected language"
    }

    static func make(for locale: Locale) async throws -> Transcriber {
        // supportedLocale(equivalentTo:) can name a locale the model then
        // reports as unsupported, so the match must also be listed.
        func listed(_ match: Locale?, in locales: [Locale]) -> Locale? {
            guard let match else { return nil }
            return locales.first { $0.identifier(.bcp47) == match.identifier(.bcp47) }
        }
        if SpeechTranscriber.isAvailable,
           let match = listed(await SpeechTranscriber.supportedLocale(equivalentTo: locale),
                              in: await SpeechTranscriber.supportedLocales) {
            return .speech(SpeechTranscriber(locale: match, preset: .progressiveTranscription))
        }
        if let match = listed(await DictationTranscriber.supportedLocale(equivalentTo: locale),
                              in: await DictationTranscriber.supportedLocales) {
            return .dictation(DictationTranscriber(locale: match, preset: .progressiveLongDictation))
        }
        throw DictationProblem.unsupportedLanguage(DictationLanguage.title(for: locale.identifier(.bcp47)))
    }

    @MainActor
    func forEachResult(_ body: (String, Bool) -> Void) async throws {
        switch self {
        case .speech(let transcriber):
            for try await result in transcriber.results { body(String(result.text.characters), result.isFinal) }
        case .dictation(let transcriber):
            for try await result in transcriber.results { body(String(result.text.characters), result.isFinal) }
        }
    }
}

/// Hands audio to the analyzer in the format its model wants. After setup
/// it is used from one audio thread at a time.
@available(macOS 26, *)
final class DictationFeed: @unchecked Sendable {
    private let format: AVAudioFormat
    private let converter: AVAudioConverter?
    private let input: AsyncStream<AnalyzerInput>.Continuation

    init(from natural: AVAudioFormat, to format: AVAudioFormat, input: AsyncStream<AnalyzerInput>.Continuation) throws {
        self.format = format
        self.input = input
        if natural == format {
            converter = nil
        } else if let converter = AVAudioConverter(from: natural, to: format) {
            self.converter = converter
        } else {
            throw DictationProblem.failed("The microphone's audio format cannot be converted for the speech model.")
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let converter else {
            input.yield(AnalyzerInput(buffer: buffer))
            return
        }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
        var supplied = false
        var error: NSError?
        // noDataNow, not endOfStream, keeps the resampler's state for the next buffer.
        let status = converter.convert(to: output, error: &error) { _, state in
            if supplied {
                state.pointee = .noDataNow
                return nil
            }
            supplied = true
            state.pointee = .haveData
            return buffer
        }
        guard status != .error, output.frameLength > 0 else { return }
        input.yield(AnalyzerInput(buffer: output))
    }

    func finish() { input.finish() }

    /// From 0 at -50 dBFS, where a quiet room sits, to 1 at full scale.
    static func loudness(of buffer: AVAudioPCMBuffer) -> Float {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for index in 0..<Int(buffer.frameLength) { sum += samples[index] * samples[index] }
        let rms = (sum / Float(buffer.frameLength)).squareRoot()
        return max(0, min(1, (20 * log10(max(rms, 0.000_001)) + 50) / 50))
    }
}

/// The microphone beside the composer's image button. Its context menu
/// picks the language and whether Caps Lock starts dictation.
struct DictationControl: View {
    @ObservedObject var dictation: Dictation
    let target: String
    let isEnabled: Bool
    let onToggle: () -> Void

    private var isActive: Bool { dictation.isActive(for: target) }

    private var help: String {
        if isActive { return "Finish dictation" }
        let key = dictation.startsWithCapsLock ? " (⇪ Caps Lock)" : ""
        return "Dictate in \(DictationLanguage.title(for: dictation.language))\(key). Right-click for language"
    }

    var body: some View {
        Button(action: onToggle) {
            Image(systemName: isActive ? "mic.fill" : "mic")
                .foregroundStyle(isActive ? ElevateTheme.onSignal : ElevateTheme.graphite)
                .frame(width: 28, height: 28)
                .background(isActive ? ElevateTheme.signal : Color.clear,
                            in: RoundedRectangle(cornerRadius: ElevateTheme.controlRadius))
        }
        .buttonStyle(ElevateHoverButtonStyle())
        .disabled(!isEnabled && !isActive)
        .help(help)
        .accessibilityLabel(isActive ? "Finish dictation" : "Dictate")
        .accessibilityIdentifier("promptDictate")
        .contextMenu {
            Picker("Language", selection: $dictation.language) {
                ForEach(DictationLanguage.choices(including: dictation.language), id: \.self) { identifier in
                    Text(DictationLanguage.title(for: identifier)).tag(identifier)
                }
            }
            .disabled(dictation.phase != .idle)
            Toggle("Caps Lock starts dictation", isOn: $dictation.startsWithCapsLock)
        }
    }
}

/// Replaces the key hints while dictation runs.
struct DictationStatus: View {
    @ObservedObject var dictation: Dictation
    @ObservedObject var meter: DictationMeter

    private var title: String {
        switch dictation.phase {
        case .idle: return ""
        case .preparing(let message): return message
        case .listening:
            return dictation.startsWithCapsLock ? "Listening · ⇪ to finish" : "Listening"
        case .finishing: return "Finishing…"
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            if dictation.phase == .listening {
                HStack(spacing: 2) {
                    ForEach(Array([0.55, 1, 0.75, 0.4].enumerated()), id: \.offset) { _, scale in
                        Capsule()
                            .fill(ElevateTheme.ink)
                            .frame(width: 2, height: 3 + CGFloat(meter.level) * 13 * scale)
                    }
                }
                .frame(height: 16)
                .animation(.linear(duration: 0.08), value: meter.level)
                .accessibilityHidden(true)
            } else {
                ProgressView().controlSize(.mini)
            }
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(ElevateTheme.graphite)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}
