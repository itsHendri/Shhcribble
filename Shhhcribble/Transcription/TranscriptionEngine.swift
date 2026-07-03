import Foundation
import FluidAudio

/// Wraps FluidAudio's AsrManager to provide async Parakeet V3 transcription.
/// Models are downloaded from HuggingFace on first use and cached locally
/// (subsequent launches load instantly).
@MainActor
final class TranscriptionEngine: ObservableObject {

    // MARK: - State

    enum LoadingState: Equatable {
        case unloaded
        case loading
        case ready
        case failed(String)

        static func == (lhs: LoadingState, rhs: LoadingState) -> Bool {
            switch (lhs, rhs) {
            case (.unloaded, .unloaded), (.loading, .loading), (.ready, .ready): return true
            case (.failed(let a), .failed(let b)): return a == b
            default: return false
            }
        }
    }

    @Published var loadingState: LoadingState = .unloaded
    @Published var currentModelName: String = ModelManager.selectedModel

    /// True while a recording is in flight. Set by AppDelegate at recording
    /// start/end. Settings reads this to disable the model picker — swapping
    /// models mid-recording orphans `asrManager` and breaks the live-preview
    /// poll loop. Default false so Settings is interactive at launch.
    @Published var isBusy: Bool = false

    private var asrManager: AsrManager?

    var isReady: Bool {
        if case .ready = loadingState { return true }
        return false
    }

    var statusText: String {
        switch loadingState {
        case .unloaded:        return "Model not loaded"
        case .loading:         return "Loading \(modelDisplayName(currentModelName))…"
        case .ready:           return "Ready · \(modelDisplayName(currentModelName))"
        case .failed(let err): return "Error: \(err)"
        }
    }

    // MARK: - Model loading

    func loadModel(variant: String) async {
        currentModelName = variant
        loadingState = .loading
        print("[Shhhcribble] Loading Parakeet model: \(modelDisplayName(variant)) (\(variant))…")

        do {
            let version: AsrModelVersion = (variant == "parakeet-v2") ? .v2 : .v3
            let models = try await AsrModels.downloadAndLoad(version: version)
            let asr = AsrManager(config: .default)
            try await asr.loadModels(models)
            asrManager = asr
            loadingState = .ready
            print("[Shhhcribble] ✅ Parakeet model loaded successfully: \(variant)")
        } catch {
            let msg = error.localizedDescription
            loadingState = .failed(msg)
            print("[Shhhcribble] ❌ Model loading failed: \(msg)")
        }
    }

    func reloadModel(variant: String) async {
        if let asr = asrManager {
            await asr.cleanup()
        }
        asrManager = nil
        loadingState = .unloaded
        await loadModel(variant: variant)
    }

    // MARK: - Transcription

    func transcribe(audioSamples: [Float]) async throws -> String {
        guard let asr = asrManager else {
            throw TranscriptionError.notLoaded
        }
        // Minimum ~0.5 s of audio to avoid spurious transcriptions
        let minSamples = Int(targetSampleRate * 0.5)
        guard audioSamples.count > minSamples else {
            print("[Shhhcribble] Audio too short (\(audioSamples.count) samples, need >\(minSamples)). Skipping.")
            return ""
        }

        print("[Shhhcribble] Transcribing \(audioSamples.count) samples " +
              "(~\(String(format: "%.1f", Double(audioSamples.count) / targetSampleRate))s of audio)…")

        let result = try await asr.transcribe(audioSamples, source: .system)
        let text = result.text
        print("[Shhhcribble] Transcription result: \"\(text)\"")
        return text
    }

    // MARK: - File transcription

    struct FileTranscriptionResult {
        let text: String
        let duration: TimeInterval
    }

    /// Transcribe an audio file URL. Delegates to FluidAudio's
    /// `AsrManager.transcribe(_ url:)`, which **auto-routes to the memory-safe
    /// disk-backed path** above ~30 s — so one call handles a 10-second clip and
    /// a 2-hour recording alike. `progress` (0→1) is best-effort: FluidAudio only
    /// emits for long files, and any failure to observe it never blocks the
    /// transcription itself.
    ///
    /// The caller (FileTranscriber) is responsible for ensuring no live dictation
    /// is running — the shared `AsrManager` decoder state is not safe to use from
    /// two transcriptions at once.
    func transcribeFile(url: URL, progress: ((Double) -> Void)? = nil) async throws -> FileTranscriptionResult {
        guard let asr = asrManager else { throw TranscriptionError.notLoaded }

        // Observe determinate progress in a sibling task. `transcriptionProgressStream`
        // opens a session on access (one at a time) and only emits for >~15 s of
        // audio; wrapped in try? so a missing/failed stream degrades to indeterminate.
        var progressTask: Task<Void, Never>?
        if let progress {
            progressTask = Task {
                let stream = await asr.transcriptionProgressStream
                do {
                    for try await value in stream {
                        if Task.isCancelled { break }
                        await MainActor.run { progress(value) }
                    }
                } catch {
                    // Progress is best-effort; a failed stream just means the
                    // UI stays indeterminate. Never surfaces to the user.
                }
            }
        }
        defer { progressTask?.cancel() }

        let result = try await asr.transcribe(url, source: .system)
        return FileTranscriptionResult(text: result.text, duration: result.duration)
    }

    // MARK: - Helpers

    private let targetSampleRate: Double = 16_000

    private func modelDisplayName(_ id: String) -> String {
        ModelManager.availableModels.first(where: { $0.id == id })?.displayName ?? id
    }
}

// MARK: - Errors

enum TranscriptionError: LocalizedError {
    case notLoaded

    var errorDescription: String? {
        "Parakeet model is not loaded yet. Please wait for the model to finish loading."
    }
}
