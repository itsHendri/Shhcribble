import XCTest
@testable import Shhhcribble

/// Tests for two-sided call transcript assembly — attribution, ordering, and
/// the echo filter that stops the far end appearing twice when the user is on
/// speakers.
final class CallTranscriptMergerTests: XCTestCase {

    private func me(_ text: String, _ start: TimeInterval, _ end: TimeInterval) -> CallSegment {
        CallSegment(speaker: .me, start: start, end: end, text: text)
    }

    private func them(_ text: String, _ start: TimeInterval, _ end: TimeInterval) -> CallSegment {
        CallSegment(speaker: .others, start: start, end: end, text: text)
    }

    // MARK: - Ordering and attribution

    func testTurnsAreInterleavedInTimeOrder() {
        let turns = CallTranscriptMerger.merge(
            mic:    [me("hello there", 0, 3), me("sounds good to me", 8, 11)],
            system: [them("hi how are you", 3, 6)])

        XCTAssertEqual(turns, [
            CallTurn(speaker: .me, text: "hello there"),
            CallTurn(speaker: .others, text: "hi how are you"),
            CallTurn(speaker: .me, text: "sounds good to me"),
        ])
    }

    func testConsecutiveSegmentsFromOneSideBecomeOneTurn() {
        let turns = CallTranscriptMerger.merge(
            mic:    [me("first part", 0, 3), me("second part", 3, 6)],
            system: [])

        XCTAssertEqual(turns, [CallTurn(speaker: .me, text: "first part second part")])
    }

    func testEmptyAndWhitespaceSegmentsAreDropped() {
        let turns = CallTranscriptMerger.merge(
            mic:    [me("", 0, 3), me("   \n ", 3, 6), me("real words", 6, 9)],
            system: [])

        XCTAssertEqual(turns, [CallTurn(speaker: .me, text: "real words")])
    }

    func testRenderLabelsEachTurn() {
        let rendered = CallTranscriptMerger.render([
            CallTurn(speaker: .me, text: "hello"),
            CallTurn(speaker: .others, text: "hi"),
        ])
        XCTAssertEqual(rendered, "Me: hello\n\nOthers: hi")
    }

    func testNoSystemAudioStillProducesAOneSidedTranscript() {
        let turns = CallTranscriptMerger.merge(mic: [me("just me talking here", 0, 4)], system: [])
        XCTAssertEqual(turns, [CallTurn(speaker: .me, text: "just me talking here")])
    }

    // MARK: - Echo

    /// The case the whole filter exists for: on speakers, the mic re-records the
    /// far end, so their sentence arrives on both streams and would otherwise be
    /// duplicated *and* misattributed to the user.
    func testFarEndBleedingThroughTheMicIsDropped() {
        let spoken = "the quarterly numbers came in ahead of plan"
        let turns = CallTranscriptMerger.merge(
            mic:    [me("the quarterly numbers came in ahead of plan", 10, 14)],
            system: [them(spoken, 10, 14)])

        XCTAssertEqual(turns, [CallTurn(speaker: .others, text: spoken)])
    }

    /// The mic's copy of speaker bleed is degraded, so the filter has to tolerate
    /// a partial match rather than demanding identical text.
    func testGarbledEchoIsStillRecognised() {
        let turns = CallTranscriptMerger.merge(
            mic:    [me("the quarterly numbers came in a head of plan", 10, 14)],
            system: [them("the quarterly numbers came in ahead of plan", 10, 14)])

        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turns.first?.speaker, .others)
    }

    func testGenuineUserSpeechIsKept() {
        let turns = CallTranscriptMerger.merge(
            mic:    [me("that is completely different from what I expected", 10, 14)],
            system: [them("the quarterly numbers came in ahead of plan", 10, 14)])

        XCTAssertEqual(turns.count, 2)
        XCTAssertTrue(turns.contains(CallTurn(speaker: .me,
                                              text: "that is completely different from what I expected")))
    }

    /// Matching text far apart in time is two people saying the same thing, not
    /// an echo — echo is simultaneous by definition.
    func testMatchingTextOutsideTheTimeWindowIsNotAnEcho() {
        let line = "we should ship it on friday afternoon"
        let turns = CallTranscriptMerger.merge(
            mic:    [me(line, 300, 304)],
            system: [them(line, 10, 14)])

        XCTAssertEqual(turns.count, 2, "same words five minutes apart is agreement, not bleed")
    }

    /// **The guard that protects the user's own voice.** Short backchannel is
    /// mostly words that appear in the other side's speech anyway, so a
    /// similarity test on two or three words is near-random — and deleting them
    /// erases the evidence the user was listening.
    func testShortBackchannelIsNeverDroppedAsEcho() {
        let turns = CallTranscriptMerger.merge(
            mic:    [me("yeah right", 10, 11)],
            system: [them("yeah right so that is the plan yeah right", 10, 14)])

        XCTAssertTrue(turns.contains(CallTurn(speaker: .me, text: "yeah right")))
    }

    func testEchoCheckIsCaseAndPunctuationInsensitive() {
        let turns = CallTranscriptMerger.merge(
            mic:    [me("The quarterly numbers, came in ahead of plan!", 10, 14)],
            system: [them("the quarterly numbers came in ahead of plan", 10, 14)])

        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turns.first?.speaker, .others)
    }

    /// A sentence split across two windows on one side must still be recognised
    /// as the same moment — the streams are sliced independently.
    func testEchoIsFoundEvenWhenTheSystemSideIsSplitAcrossWindows() {
        let turns = CallTranscriptMerger.merge(
            mic:    [me("the quarterly numbers came in ahead of plan", 10, 14)],
            system: [them("the quarterly numbers", 9, 12), them("came in ahead of plan", 12, 15)])

        XCTAssertFalse(turns.contains { $0.speaker == .me })
    }

    func testNoSystemSegmentsMeansNothingIsEverAnEcho() {
        let kept = CallTranscriptMerger.strippingEcho(
            mic: [me("anything at all goes here", 0, 4)], system: [])
        XCTAssertEqual(kept.count, 1)
    }

    // MARK: - Determinism

    func testIdenticalInputRendersIdenticalOutput() {
        let mic = [me("one two three four", 0, 3), me("five six seven eight", 6, 9)]
        let system = [them("nine ten eleven twelve", 3, 6)]

        let first = CallTranscriptMerger.render(CallTranscriptMerger.merge(mic: mic, system: system))
        let second = CallTranscriptMerger.render(CallTranscriptMerger.merge(mic: mic, system: system))
        XCTAssertEqual(first, second)
    }

    /// Both sides starting in the same window must not order randomly — the tie
    /// is broken on speaker, then text, so the same call never renders two ways.
    func testSimultaneousSegmentsOrderDeterministically() {
        let mic = [me("me first here", 0, 3)]
        let system = [them("them also here", 0, 3)]

        let a = CallTranscriptMerger.merge(mic: mic, system: system)
        let b = CallTranscriptMerger.merge(mic: mic, system: system)

        XCTAssertEqual(a, b)
        XCTAssertEqual(a.first?.speaker, .me)
        XCTAssertEqual(a.count, 2)
    }
}
