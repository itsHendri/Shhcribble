import Foundation

/// The single post-transcription text pipeline, shared by the dictation path
/// (`AppDelegate.endRecording`) and the file path (`FileTranscriber`) so the
/// two can never drift. Order is load-bearing: **Personal Dictionary → (AI
/// cleanup if enabled + available, else FillerWordFilter)** — the dictionary
/// runs on the raw transcript first so the LLM sees corrected terms.
enum TranscriptPipeline {

    /// Clean a trimmed raw transcript. Returns the final text, which may be
    /// empty (e.g. an all-filler utterance) — callers treat empty as "no result".
    /// - `rawTrimmed` should already be whitespace-trimmed.
    static func process(_ rawTrimmed: String) async -> String {
        // Personal-dictionary substitutions run on the RAW transcript first.
        let corrected = PersonalDictionary.apply(ModelManager.dictionaryEntries, to: rawTrimmed)
        guard !corrected.isEmpty else { return "" }

        // On-device LLM cleanup (Apple FoundationModels) replaces the regex
        // filler filter when enabled + available; it does fillers, false starts,
        // punctuation and capitalization in one pass. On failure / empty output /
        // unavailable model, `clean` returns nil and we fall back to the
        // always-on FillerWordFilter floor.
        if ModelManager.transcriptCleanupEnabled,
           let cleaned = await TranscriptCleaner.clean(corrected), !cleaned.isEmpty {
            return cleaned
        }
        return FillerWordFilter.filter(corrected)
    }
}
