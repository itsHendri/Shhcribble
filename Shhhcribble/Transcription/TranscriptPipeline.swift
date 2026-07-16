import Foundation

/// The single post-transcription text pipeline, shared by the dictation path
/// (`AppDelegate.endRecording`) and the file path (`FileTranscriber`) so the
/// two can never drift. Order is load-bearing: **Personal Dictionary → (styled
/// AI cleanup/transform if available, else FillerWordFilter)** — the dictionary
/// runs on the raw transcript first so the LLM sees corrected terms.
enum TranscriptPipeline {

    /// Clean/transform a trimmed raw transcript according to the active `style`.
    /// Returns the final text, which may be empty (e.g. an all-filler utterance)
    /// — callers treat empty as "no result".
    /// - `rawTrimmed` should already be whitespace-trimmed.
    /// - `dictionary` is snapshotted by the caller on the main actor (the store
    ///   is `@MainActor`) and passed in, because this func is nonisolated and runs
    ///   off-main — it cannot read the store directly.
    /// - `style` is likewise resolved + snapshotted by the caller.
    static func process(_ rawTrimmed: String,
                        dictionary: [DictionaryEntry],
                        style: ActiveStyle) async -> String {
        // Personal-dictionary substitutions run on the RAW transcript first.
        let corrected = PersonalDictionary.apply(dictionary, to: rawTrimmed)
        guard !corrected.isEmpty else { return "" }

        // On-device model (Apple FoundationModels) shapes the transcript per the
        // active style. Both AI paths return nil on failure / empty / unavailable
        // / guard-rejection, dropping to the always-on FillerWordFilter floor so a
        // paste is never broken. `.off` skips the model entirely.
        switch style {
        case .off:
            break
        case .defaultCleanup:
            if let cleaned = await TranscriptCleaner.clean(corrected), !cleaned.isEmpty {
                return cleaned
            }
        case .custom(let s):
            if let styled = await TranscriptCleaner.transform(corrected, style: s), !styled.isEmpty {
                return styled
            }
        }
        return FillerWordFilter.filter(corrected)
    }
}
