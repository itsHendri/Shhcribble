import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreMedia
import os

/// Captures **system output audio** — what the other side of a call sounds like
/// — as 16 kHz mono Float32, ready for the same transcription path as the mic.
///
/// **Why ScreenCaptureKit and not Core Audio process taps.** The original
/// research scoped this as `CATapDescription` + an aggregate device, which is
/// trap-laden (`isExclusive` inverts the meaning of the process list, the
/// aggregate needs a real output device as its main sub-device, the IOProc runs
/// on the realtime thread). Two independent competitors then shipped the
/// ScreenCaptureKit route instead — Ghost Pepper directly, Wispr Flow through
/// Electron's `SystemAudioLoopback` — which needs the same TCC grant and none of
/// the aggregate-device machinery. See ROADMAP item 6B.
///
/// **No availability gate is needed.** `capturesAudio` and
/// `excludesCurrentProcessAudio` are `API_AVAILABLE(macos(13.0))`, below this
/// app's macOS 14 floor. (The "macOS 14.4" figure in the older research belonged
/// to the process-tap route.) `SCStream.captureMicrophone` *is* macOS 15+, which
/// is precisely why the microphone stays on `AudioRecorder`: this class is a
/// second, independent stream and **touches nothing in the existing capture
/// path**.
///
/// **This never records the app's own output.** `excludesCurrentProcessAudio`
/// keeps our completion chime and any playback out of the capture.
@MainActor
final class SystemAudioCapture {

    /// Matches `AudioRecorder`'s target so both streams reach the ASR in the
    /// same shape.
    private let targetSampleRate: Double = 16_000

    private var stream: SCStream?
    private var output: StreamOutput?

    private static let log = Logger(subsystem: "com.shhhcribble.app", category: "syscapture")

    enum CaptureError: LocalizedError {
        case permissionDenied
        case noDisplay

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                return "Screen & System Audio Recording permission is needed to capture the other side of a call."
            case .noDisplay:
                return "No display available to attach the audio capture to."
            }
        }
    }

    private(set) var isRunning = false

    /// Has the user already granted the Screen Recording permission?
    ///
    /// Read-only probe: `getShareableContent` is the same call the capture makes,
    /// and it throws rather than prompting when the grant is missing, so this can
    /// be used to decide whether to *offer* both-sides capture without triggering
    /// a system prompt at an awkward moment.
    static func hasPermission() async -> Bool {
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(false,
                                                                    onScreenWindowsOnly: false)
            return true
        } catch {
            return false
        }
    }

    /// Begin capturing system audio. Throws if the permission is missing, which
    /// is the caller's cue to fall back to mic-only capture.
    func start() async throws {
        guard !isRunning else { return }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false,
                                                                          onScreenWindowsOnly: false)
        } catch {
            Self.log.error("System audio: permission or content unavailable — \(error.localizedDescription)")
            throw CaptureError.permissionDenied
        }
        guard let display = content.displays.first else { throw CaptureError.noDisplay }

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        // Our own output — the completion chime, any playback — must not end up
        // in the transcript.
        config.excludesCurrentProcessAudio = true
        config.sampleRate = Int(targetSampleRate)
        config.channelCount = 1
        // Audio-only capture still needs a video configuration, so make it as
        // close to nothing as the API allows: a 2×2 frame at 1 fps costs
        // essentially no CPU or memory, and we never register a video output at
        // all, so those frames are produced and dropped.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.queueDepth = 5

        // The whole display, with no windows excluded — we want every app's
        // audio, and the filter's video side is irrelevant at 2×2.
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let stream = SCStream(filter: filter, configuration: config, delegate: nil)

        let output = StreamOutput()
        try stream.addStreamOutput(output, type: .audio,
                                   sampleHandlerQueue: DispatchQueue(label: "com.shhhcribble.syscapture",
                                                                     qos: .userInitiated))
        try await stream.startCapture()

        self.stream = stream
        self.output = output
        isRunning = true
        Self.log.notice("System audio capture started")
    }

    /// Stop and hand back everything captured, as 16 kHz mono Float32.
    @discardableResult
    func stop() async -> [Float] {
        guard isRunning, let stream, let output else { return [] }
        isRunning = false
        self.stream = nil
        self.output = nil
        do {
            try await stream.stopCapture()
        } catch {
            // A stop that fails still means we're done with it; the samples
            // gathered so far are perfectly usable.
            Self.log.error("System audio: stopCapture failed — \(error.localizedDescription)")
        }
        let samples = output.drain()
        Self.log.notice("System audio capture stopped: \(samples.count) samples")
        return samples
    }

    /// Receives audio buffers off the capture queue and accumulates mono
    /// Float32. Its own lock keeps it safe to drain from the main actor while
    /// the capture queue is still delivering.
    private final class StreamOutput: NSObject, SCStreamOutput {
        private let lock = NSLock()
        private var samples: [Float] = []

        func drain() -> [Float] {
            lock.lock()
            defer { samples = []; lock.unlock() }
            return samples
        }

        func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                    of type: SCStreamOutputType) {
            guard type == .audio, sampleBuffer.isValid,
                  let formatDescription = sampleBuffer.formatDescription,
                  let asbd = formatDescription.audioStreamBasicDescription else { return }

            // ScreenCaptureKit delivers non-interleaved Float32; take the first
            // channel, which is what we asked for with `channelCount = 1`.
            guard asbd.mFormatID == kAudioFormatLinearPCM,
                  asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0 else { return }

            do {
                try sampleBuffer.withAudioBufferList { audioBufferList, _ in
                    guard let buffer = audioBufferList.first,
                          let data = buffer.mData else { return }
                    let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                    guard count > 0 else { return }
                    let pointer = data.bindMemory(to: Float.self, capacity: count)
                    let chunk = Array(UnsafeBufferPointer(start: pointer, count: count))
                    lock.lock()
                    samples.append(contentsOf: chunk)
                    lock.unlock()
                }
            } catch {
                // A malformed buffer is not worth ending a call capture over.
            }
        }
    }
}
