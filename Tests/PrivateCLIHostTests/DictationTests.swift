import AVFoundation
import Foundation
import Speech
import XCTest
@testable import PrivateCLIHost

@MainActor
final class DictationTests: XCTestCase {
    func testJoinSpacesPhrasesAndAttachesPunctuation() {
        XCTAssertEqual(DictationText.join("", " Fix the build"), "Fix the build")
        XCTAssertEqual(DictationText.join("Fix the build", "then run the tests"), "Fix the build then run the tests")
        XCTAssertEqual(DictationText.join("Fix the build", " then run the tests"), "Fix the build then run the tests")
        XCTAssertEqual(DictationText.join("Fix the build", ", please."), "Fix the build, please.")
        XCTAssertEqual(DictationText.join("Fix the build ", "now"), "Fix the build now")
        XCTAssertEqual(DictationText.join("First line\n", "second line"), "First line\nsecond line")
        XCTAssertEqual(DictationText.join("Unchanged", ""), "Unchanged")
        XCTAssertEqual(DictationText.join("Unchanged", "   "), "Unchanged")
    }

    func testPendingPhraseIsReplacedUntilTheRecognizerSettlesIt() {
        var transcript = DictationTranscript()
        transcript.apply("Open the", isFinal: false)
        XCTAssertEqual(transcript.text, "Open the")
        transcript.apply("Open the composer", isFinal: false)
        XCTAssertEqual(transcript.text, "Open the composer")
        transcript.apply("Open the composer.", isFinal: true)
        XCTAssertEqual(transcript.text, "Open the composer.")
        transcript.apply(" Then", isFinal: false)
        XCTAssertEqual(transcript.text, "Open the composer. Then")
        transcript.apply(" Then run the tests.", isFinal: true)
        XCTAssertEqual(transcript.settled, "Open the composer. Then run the tests.")
        XCTAssertEqual(transcript.pending, "")
    }

    func testLanguagesFollowTheMacsPreferenceWithoutRepeats() {
        XCTAssertEqual(DictationLanguage.choices(preferred: ["en-US", "sv-SE"]), ["en-US", "sv-SE"])
        XCTAssertEqual(DictationLanguage.choices(preferred: ["sv-SE"]), ["sv-SE", "en-US"])
        XCTAssertEqual(DictationLanguage.choices(preferred: ["en-US"], including: "de-DE"), ["en-US", "de-DE"])
        XCTAssertEqual(DictationLanguage.choices(preferred: ["en-US", "sv-SE"], including: "sv-SE"), ["en-US", "sv-SE"])
    }

    func testPreferencesPersistAndDefaultToCapsLock() throws {
        let suite = "m4ix.cli.dictation." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let dictation = Dictation(preferences: defaults)
        XCTAssertTrue(dictation.startsWithCapsLock)
        dictation.language = "sv-SE"
        dictation.startsWithCapsLock = false
        let reopened = Dictation(preferences: defaults)
        XCTAssertEqual(reopened.language, "sv-SE")
        XCTAssertFalse(reopened.startsWithCapsLock)
    }

    /// A process without microphone usage text is ended by macOS when it
    /// opens the microphone, so dictation must refuse before trying. The
    /// test runner's own bundle carries usage text, so this test supplies
    /// the package's test bundle, which has none.
    func testBuildWithoutMicrophoneUsageTextNeverOpensTheMicrophone() throws {
        let bundle = Bundle(for: DictationTests.self)
        guard bundle.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") == nil else {
            return XCTFail("The test bundle carries microphone usage text, so starting dictation would open the microphone.")
        }
        let suite = "m4ix.cli.dictation." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let dictation = Dictation(preferences: defaults, bundle: bundle)
        var delivered = false
        dictation.start(target: "draft") { _, _ in delivered = true }
        XCTAssertEqual(dictation.phase, .idle)
        XCTAssertNil(dictation.target)
        XCTAssertEqual(dictation.problem, Dictation.isSupported ? .unpackagedBuild : .unsupportedSystem)
        XCTAssertFalse(delivered)
        dictation.finish()
        XCTAssertEqual(dictation.phase, .idle)
    }

    /// Opt-in: transcribes synthesized speech through the same feed and
    /// recognizer the microphone uses, with each on-device model.
    func testSynthesizedSpeechIsTranscribedOnDevice() async throws {
        guard ProcessInfo.processInfo.environment["M4IX_SPEECH_TESTS"] == "1" else {
            throw XCTSkip("Set M4IX_SPEECH_TESTS=1 to run on-device speech recognition.")
        }
        guard #available(macOS 26, *) else { throw XCTSkip("On-device speech analysis needs macOS 26.") }
        let audio = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".aiff")
        defer { try? FileManager.default.removeItem(at: audio) }
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-v", "Samantha", "-o", audio.path,
                         "Please refactor the prompt composer, then run the tests and summarize what changed."]
        try say.run()
        say.waitUntilExit()
        XCTAssertEqual(say.terminationStatus, 0)

        let locale = Locale(identifier: "en-US")
        // The system dictation model, used where SpeechTranscriber has no
        // language, hears this synthesized voice less well ("read factor").
        let models: [(String, Transcriber, [String])] = [
            ("SpeechTranscriber", try await Transcriber.make(for: locale),
             ["refactor", "prompt", "composer", "tests", "summarize"]),
            ("DictationTranscriber", .dictation(DictationTranscriber(locale: locale, preset: .progressiveLongDictation)),
             ["prompt", "composer", "summarize"])
        ]
        for (name, transcriber, expectedWords) in models {
            let file = try AVAudioFile(forReading: audio)
            let recognizer = try await DictationRecognizer.prepare(transcriber, audio: file.processingFormat) { _ in }
            var updates: [String] = []
            var begun = false
            // As with the microphone, the first second arrives before the recognizer runs.
            while file.framePosition < file.length {
                if !begun, file.framePosition >= AVAudioFramePosition(file.processingFormat.sampleRate) {
                    try await recognizer.begin { updates.append($0) }
                    begun = true
                }
                let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096))
                try file.read(into: buffer)
                recognizer.feed.append(buffer)
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            if !begun { try await recognizer.begin { updates.append($0) } }
            let started = Date()
            let text = try await recognizer.finish()
            let words = text.lowercased().components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty }
            print("\(name): \"\(text)\" after \(updates.count) updates; settled in \(String(format: "%.2f", Date().timeIntervalSince(started))) s")
            for expected in expectedWords {
                XCTAssertTrue(words.contains(expected), "\(name) missed \"\(expected)\" in \"\(text)\"")
            }
            XCTAssertFalse(updates.isEmpty, "\(name) reported no progress before finishing")
            XCTAssertEqual(updates.last, text)
        }
    }
}
