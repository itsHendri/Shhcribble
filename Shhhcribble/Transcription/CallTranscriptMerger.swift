import Foundation

/// Which side of a call a stretch of speech came from.
///
/// This is the whole prize of capturing two streams instead of one mixed one:
/// the microphone *is* "Me" and the system output *is* "Others", so attribution
/// falls out of which device the audio arrived on — no diarization model, no
/// voice embeddings, nothing to train or persist.
enum CallSpeaker: String, Equatable {
    case me = "Me"
    case others = "Others"
}

/// A transcribed window of one stream, with the time range it covers.
///
/// Ranges come from slicing the captured audio into fixed windows before
/// transcription, not from the ASR's own token timings — Parakeet-TDT's
/// duration head absorbs trailing silence (the reason the `PauseSegmenter`
/// experiment was reverted), so window arithmetic is the trustworthy clock.
struct CallSegment: Equatable {
    let speaker: CallSpeaker
    let start: TimeInterval
    let end: TimeInterval
    let text: String
}

/// One side speaking, once — consecutive segments from the same side merged.
struct CallTurn: Equatable {
    let speaker: CallSpeaker
    let text: String
}

/// Turns two independently-transcribed call streams into one readable,
/// speaker-labelled transcript.
///
/// **The echo problem this exists to solve.** When the user is on speakers,
/// their microphone re-records the far end coming out of those speakers, so the
/// same sentence is transcribed twice — once cleanly from the system stream and
/// once, usually garbled, from the mic. Left alone that is the most visible
/// possible failure in a transcript: every remark the other person makes is
/// duplicated and misattributed to the user.
///
/// We resolve it in the **text** domain rather than the audio domain. Wispr
/// Flow runs a full audio-correlation subsystem for this (`meeting.echo_gate.*`
/// — correlated windows, suppression fractions, lock stability); this is the
/// cheap majority of the benefit, and it needs no DSP, no alignment, and no
/// extra latency. The system stream is by definition the clean copy of the far
/// end, so where the two disagree, **the system stream wins and the mic segment
/// is dropped**.
enum CallTranscriptMerger {

    /// How far apart two windows may sit and still be considered the same
    /// moment. Generous, because the two streams are sliced independently and a
    /// sentence can straddle a window boundary on one side but not the other.
    static let echoWindow: TimeInterval = 6

    /// Share of a mic segment's words that must also appear in the overlapping
    /// system text before we call it an echo. The mic copy of far-end audio is
    /// degraded, so this can't demand an exact match.
    static let echoSimilarity = 0.6

    /// Below this, a mic segment is never dropped as an echo.
    ///
    /// **Load-bearing.** Short utterances are mostly backchannel — "yeah",
    /// "right", "mm-hm" — and those words are extremely likely to also appear
    /// somewhere in the other side's speech, so a similarity test on three words
    /// is close to a coin toss. Deleting them would silently erase exactly the
    /// part of a conversation that proves the user was listening. When in doubt
    /// we keep the user's audio: a duplicated line is a blemish, a deleted line
    /// is data loss.
    static let minWordsForEchoCheck = 4

    /// Merge both streams into speaker-labelled turns, dropping mic segments
    /// that are really the far end bleeding through the speakers.
    static func merge(mic: [CallSegment], system: [CallSegment]) -> [CallTurn] {
        let kept = strippingEcho(mic: mic, system: system)
        let ordered = (kept + system).sorted {
            // Stable and deterministic: by time, then by speaker, then by text,
            // so an identical input always renders an identical transcript.
            if $0.start != $1.start { return $0.start < $1.start }
            if $0.speaker != $1.speaker { return $0.speaker == .me }
            return $0.text < $1.text
        }
        return coalesce(ordered)
    }

    /// Mic segments with the echoes removed.
    static func strippingEcho(mic: [CallSegment], system: [CallSegment]) -> [CallSegment] {
        mic.filter { !isEcho($0, of: system) }
    }

    /// Is this mic segment just the far end coming back through the speakers?
    static func isEcho(_ segment: CallSegment, of system: [CallSegment]) -> Bool {
        let spoken = words(segment.text)
        guard spoken.count >= minWordsForEchoCheck else { return false }

        // Everything the far end said anywhere near this moment. Pooled rather
        // than compared segment-by-segment, because a sentence the mic caught in
        // one window may be split across two on the system side.
        var nearby: Set<String> = []
        for other in system where overlapsInTime(segment, other) {
            nearby.formUnion(words(other.text))
        }
        guard !nearby.isEmpty else { return false }

        let shared = spoken.filter { nearby.contains($0) }.count
        return Double(shared) / Double(spoken.count) >= echoSimilarity
    }

    /// Render as plain text for storage — the speaker label leads each turn.
    static func render(_ turns: [CallTurn]) -> String {
        turns.map { "\($0.speaker.rawValue): \($0.text)" }
            .joined(separator: "\n\n")
    }

    // MARK: - Internals

    private static func overlapsInTime(_ a: CallSegment, _ b: CallSegment) -> Bool {
        a.start - echoWindow < b.end && b.start < a.end + echoWindow
    }

    /// Fold consecutive segments from the same side into one turn, so a long
    /// stretch of one person talking doesn't render as a stack of labels.
    private static func coalesce(_ segments: [CallSegment]) -> [CallTurn] {
        var turns: [CallTurn] = []
        for segment in segments {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if let last = turns.last, last.speaker == segment.speaker {
                turns[turns.count - 1] = CallTurn(speaker: last.speaker,
                                                  text: last.text + " " + text)
            } else {
                turns.append(CallTurn(speaker: segment.speaker, text: text))
            }
        }
        return turns
    }

    /// Lowercased, punctuation-stripped words — the comparison unit for the
    /// echo test. Diacritic-insensitive so the two streams' different renderings
    /// of the same name still match.
    private static func words(_ text: String) -> [String] {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }
}
