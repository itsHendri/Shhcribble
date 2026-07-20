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

    // MARK: - Transport-branched readiness rule

    /// Wired/built-in: channel count alone decides — first-tick, regardless of
    /// audio or dwell. This is the "zero added latency on the warm path" claim.
    func testWiredReadyOnChannelsAlone() {
        for sawAudio in [false, true] {
            for dwelled in [false, true] {
                XCTAssertTrue(AudioRecorder.warmUpIsReady(
                    isBluetooth: false, channels: 1, sawAudio: sawAudio, dwellElapsed: dwelled))
                XCTAssertFalse(AudioRecorder.warmUpIsReady(
                    isBluetooth: false, channels: 0, sawAudio: sawAudio, dwellElapsed: dwelled))
            }
        }
    }

    /// Bluetooth: the channel count LIES on a cold route (reports 1 ch while
    /// delivering digital zero — proven by capture diagnostics 2026-07-20), so
    /// channels alone must never fire ready.
    func testBluetoothChannelsAloneIsNotReady() {
        XCTAssertFalse(AudioRecorder.warmUpIsReady(
            isBluetooth: true, channels: 1, sawAudio: false, dwellElapsed: false))
    }

    /// Bluetooth goes ready the moment real audio arrives (route-live signal).
    func testBluetoothReadyOnAudio() {
        XCTAssertTrue(AudioRecorder.warmUpIsReady(
            isBluetooth: true, channels: 1, sawAudio: true, dwellElapsed: false))
    }

    /// The dwell is a backstop for a live route emitting true digital zero.
    func testBluetoothReadyOnDwellBackstop() {
        XCTAssertTrue(AudioRecorder.warmUpIsReady(
            isBluetooth: true, channels: 1, sawAudio: false, dwellElapsed: true))
    }

    /// Zero channels on Bluetooth is never ready — audio or dwell can't
    /// override a route that hasn't even bound its input stream yet.
    func testBluetoothZeroChannelsNeverReady() {
        for sawAudio in [false, true] {
            for dwelled in [false, true] {
                XCTAssertFalse(AudioRecorder.warmUpIsReady(
                    isBluetooth: true, channels: 0, sawAudio: sawAudio, dwellElapsed: dwelled))
            }
        }
    }
}
