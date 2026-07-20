import XCTest
@testable import Shhhcribble

/// Pins the silent-pre-roll trimming introduced with the Bluetooth-aware route
/// warm-up. The trim is what keeps words spoken during a cold AirPods A2DP→HFP
/// switch — a fixed warm-up dwell would have discarded them.
final class AudioRecorderWarmUpTests: XCTestCase {

    private let eps = AudioRecorder.silenceEpsilon

    func testEmptyBufferHasNoLeadingSilence() {
        XCTAssertEqual(AudioRecorder.leadingSilenceCount([]), 0)
    }

    func testAudibleFromTheFirstSampleTrimsNothing() {
        let s: [Float] = [0.5, 0.2, -0.4]
        XCTAssertEqual(AudioRecorder.leadingSilenceCount(s), 0)
    }

    /// The cold-Bluetooth shape: literal digital zero, then real speech.
    func testDigitalSilenceIsTrimmedUpToTheFirstAudibleSample() {
        let s: [Float] = [0, 0, 0, 0, 0.3, 0.6]
        XCTAssertEqual(AudioRecorder.leadingSilenceCount(s), 4)
    }

    /// An all-silent buffer reports its full length, so the caller drops
    /// everything rather than keeping a dead take.
    func testFullySilentBufferReportsItsWholeLength() {
        let s = [Float](repeating: 0, count: 32)
        XCTAssertEqual(AudioRecorder.leadingSilenceCount(s), 32)
    }

    /// Sub-epsilon noise still counts as silence; anything above it is audio.
    func testEpsilonBoundary() {
        XCTAssertEqual(AudioRecorder.leadingSilenceCount([eps, eps * 2]), 1,
                       "a sample exactly at epsilon is silence, above it is audio")
        XCTAssertEqual(AudioRecorder.leadingSilenceCount([eps / 2, eps / 2]), 2)
    }

    /// Negative-going speech must count as audio — the trim uses magnitude.
    func testNegativeAmplitudeCountsAsAudio() {
        XCTAssertEqual(AudioRecorder.leadingSilenceCount([0, 0, -0.7]), 2)
    }

    /// A realistic quiet room on the built-in mic (~0.0016 rms in the field
    /// logs) must NOT be treated as a dead route — otherwise the warm-up would
    /// stall waiting for the user to be louder.
    func testQuietRoomFloorIsTreatedAsAudioNotSilence() {
        let quietRoom: [Float] = [0.0016, -0.0014, 0.0018]
        XCTAssertEqual(AudioRecorder.leadingSilenceCount(quietRoom), 0)
    }

    /// Silence appearing *after* speech (a pause) must never be trimmed — only
    /// the leading run is pre-roll.
    func testInteriorSilenceIsPreserved() {
        let s: [Float] = [0, 0, 0.5, 0, 0, 0.4]
        XCTAssertEqual(AudioRecorder.leadingSilenceCount(s), 2)
    }
}
