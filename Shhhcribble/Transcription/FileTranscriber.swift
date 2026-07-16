import AppKit
import AVFoundation
import Combine
import UniformTypeIdentifiers
import os

/// Coordinates file-based transcription — the path taken when the user picks
/// "Transcribe File…" or opens audio/video via Finder. Fully independent of
/// `AudioRecorder`: it never records, never auto-pastes, and shares the loaded
/// `AsrManager` only *serially* with live dictation (the decoder state is not
/// safe to use from two transcriptions at once).
///
/// Jobs run one at a time on a serial internal loop, and only while no live
/// dictation is active (`isDictationActive`). Dictation, in turn, is rejected
/// while a file job runs (see `AppDelegate.beginRecording`), so the two are
/// mutually exclusive. Files that arrive mid-dictation stay queued and drain
/// once recording ends (`AppDelegate` re-kicks `drainIfIdle()`).
@MainActor
final class FileTranscriber: ObservableObject {

    enum Status: Equatable {
        case idle
        case running(fileName: String, index: Int, total: Int, progress: Double)
        case finished(count: Int)
        case failed(fileName: String, message: String)
    }

    /// Content types we accept for open-with / the file picker.
    static let supportedContentTypes: [UTType] = [.audio, .movie]

    @Published private(set) var status: Status = .idle
    private(set) var isRunning = false

    private let engine: TranscriptionEngine
    private let store: TranscriptStore
    private let isDictationActive: () -> Bool
    private let log = Logger(subsystem: "com.shhhcribble.app", category: "filetranscribe")

    private var queue: [URL] = []
    private var runTask: Task<Void, Never>?

    init(engine: TranscriptionEngine,
         store: TranscriptStore,
         isDictationActive: @escaping () -> Bool) {
        self.engine = engine
        self.store = store
        self.isDictationActive = isDictationActive
    }

    // MARK: - Public API

    /// Enqueue one or more files and start draining if possible. Extra files
    /// from a Finder multi-select are handled sequentially, never dropped.
    func enqueue(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        queue.append(contentsOf: urls)
        drainIfIdle()
    }

    /// Start the run loop unless already running or a dictation is in flight.
    /// Safe to call repeatedly (e.g. AppDelegate calls it after a recording
    /// ends to pick up files that queued during dictation).
    func drainIfIdle() {
        guard !isRunning, !queue.isEmpty, !isDictationActive() else { return }
        isRunning = true
        engine.isBusy = true
        runTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    /// Cancel the in-flight job and drop anything still queued.
    func cancel() {
        queue.removeAll()
        runTask?.cancel()
    }

    // MARK: - Run loop

    private func runLoop() async {
        var index = 0
        var succeeded = 0
        while !queue.isEmpty {
            if Task.isCancelled { break }
            let url = queue.removeFirst()
            index += 1
            // Recompute the total each iteration so files enqueued mid-run
            // (a second Finder open) don't produce "3 of 2".
            let total = index + queue.count
            if await process(url, index: index, total: total) { succeeded += 1 }
        }
        isRunning = false
        engine.isBusy = false
        runTask = nil
        if !Task.isCancelled { status = .finished(count: succeeded) }
        else { status = .idle }
        // Files may have queued while we were busy (or during dictation) — retry.
        drainIfIdle()
    }

    /// Transcribe one file. Returns true only if a transcript was stored.
    @discardableResult
    private func process(_ url: URL, index: Int, total: Int) async -> Bool {
        let name = url.lastPathComponent
        status = .running(fileName: name, index: index, total: total, progress: 0)

        var tempAudioURL: URL?
        defer { if let tempAudioURL { try? FileManager.default.removeItem(at: tempAudioURL) } }

        do {
            // Video: extract the audio track first — FluidAudio decodes via
            // AVAudioFile, which can't open a container with a video track.
            let audioURL: URL
            if isMovie(url) {
                let extracted = try await extractAudioTrack(from: url)
                tempAudioURL = extracted
                audioURL = extracted
            } else {
                audioURL = url
            }

            let result = try await engine.transcribeFile(url: audioURL) { [weak self] p in
                self?.status = .running(fileName: name, index: index, total: total, progress: p)
            }

            let raw = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            // Same pipeline as dictation (dictionary → cleanup|filler), no length
            // cap. File transcription always uses the faithful Default clean-up —
            // per-app auto and transform styles are a dictation concern (a long
            // recording shouldn't be reshaped into a Slack message, and there's no
            // frontmost/paste context). Snapshot the dictionary on the main actor
            // (this method is @MainActor) before the off-main pipeline await.
            let dictionary = store.dictionaryEntries
            let final = await TranscriptPipeline.process(raw, dictionary: dictionary, style: .defaultCleanup)

            guard !final.isEmpty else {
                status = .failed(fileName: name, message: "No speech detected")
                return false
            }

            // FluidAudio's ASRResult.duration is only populated on the in-memory
            // path; the disk-backed path (files >~30 s) returns 0. Read the real
            // duration from the source instead so the library footer is correct.
            let duration = await assetDuration(for: url) ?? (result.duration > 0 ? result.duration : nil)

            store.add(Transcript(
                id: UUID(), createdAt: Date(), source: .file,
                title: name, text: final, rawText: raw,
                fileName: name, sourcePath: url.path, durationSec: duration
            ))

            copyToClipboard(final)
            writeSidecar(text: final, beside: url)
            log.notice("Transcribed \(name, privacy: .public) (\(final.count) chars)")
            return true
        } catch {
            log.error("File transcription failed for \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            status = .failed(fileName: name, message: error.localizedDescription)
            return false
        }
    }

    // MARK: - Media helpers

    /// Real media duration from the source file (works for audio and video),
    /// independent of FluidAudio's ASRResult.duration.
    private func assetDuration(for url: URL) async -> Double? {
        let asset = AVURLAsset(url: url)
        guard let cm = try? await asset.load(.duration) else { return nil }
        let seconds = CMTimeGetSeconds(cm)
        return (seconds.isFinite && seconds > 0) ? seconds : nil
    }

    private func isMovie(_ url: URL) -> Bool {
        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
            if type.conforms(to: .movie) { return true }
            if type.conforms(to: .audio) { return false }
        }
        // Fall back to extension when the UTI is missing/ambiguous.
        return ["mp4", "mov", "m4v", "mpg", "mpeg", "avi", "mkv",
                "webm", "ts", "m2ts", "3gp", "wmv", "flv"].contains(url.pathExtension.lowercased())
    }

    /// Export the audio track to a temp `.m4a` via `AVAssetExportSession`
    /// (AppleM4A preset = audio only). Throws if the container has no
    /// exportable audio.
    private func extractAudioTrack(from url: URL) async throws -> URL {
        let asset = AVURLAsset(url: url)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw FileTranscriberError.audioExtractionFailed
        }
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("m4a")
        export.outputURL = dest
        export.outputFileType = .m4a

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            export.exportAsynchronously { cont.resume() }
        }

        guard export.status == .completed else {
            throw export.error ?? FileTranscriberError.audioExtractionFailed
        }
        return dest
    }

    // MARK: - Output side-effects

    private func copyToClipboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    /// Write `<sourceName>.txt` beside the source; fall back to ~/Downloads if
    /// the source directory is read-only (e.g. a mounted DMG).
    private func writeSidecar(text: String, beside source: URL) {
        let base = source.deletingPathExtension().lastPathComponent
        let dest = source.deletingLastPathComponent().appendingPathComponent(base).appendingPathExtension("txt")
        do {
            try text.write(to: dest, atomically: true, encoding: .utf8)
        } catch {
            if let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first {
                let fallback = downloads.appendingPathComponent(base).appendingPathExtension("txt")
                try? text.write(to: fallback, atomically: true, encoding: .utf8)
                log.notice("Sidecar written to Downloads (source dir not writable).")
            }
        }
    }
}

enum FileTranscriberError: LocalizedError {
    case audioExtractionFailed

    var errorDescription: String? {
        switch self {
        case .audioExtractionFailed: return "Couldn't extract audio from this file."
        }
    }
}
