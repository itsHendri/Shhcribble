import SwiftUI
import AVFoundation
import ApplicationServices

/// First-run onboarding flow modelled on Superwhisper:
/// Welcome → Permissions → Mic test → Model download → Done.
/// Shown once (gated on `ModelManager.hasCompletedOnboarding`), re-openable
/// from the menu bar via "Run Setup Again…".
struct OnboardingView: View {

    enum Step: Int, CaseIterable {
        case welcome, permissions, micTest, modelDownload, done
    }

    @ObservedObject var transcriptionEngine: TranscriptionEngine
    var onFinish: () -> Void

    @State private var step: Step = .welcome

    var body: some View {
        VStack(spacing: 0) {
            if step != .welcome {
                ProgressBar(progress: Double(step.rawValue) / Double(Step.allCases.count - 1))
                    .frame(height: 3)
                    .padding(.top, 16)
                    .padding(.horizontal, 24)
            }

            Group {
                switch step {
                case .welcome:       WelcomeStep(onNext: { advance() })
                case .permissions:   PermissionsStep(onNext: { advance() })
                case .micTest:       MicTestStep(onNext: { advance() })
                case .modelDownload: ModelDownloadStep(engine: transcriptionEngine, onNext: { advance() })
                case .done:          DoneStep(onFinish: onFinish)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 480, height: 560)
        .background(Color(red: 0.08, green: 0.08, blue: 0.09))
    }

    private func advance() {
        if let next = Step(rawValue: step.rawValue + 1) {
            withAnimation(.easeInOut(duration: 0.2)) { step = next }
        }
    }
}

// MARK: - Progress bar

private struct ProgressBar: View {
    let progress: Double   // 0...1

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12))
                Capsule()
                    .fill(LinearGradient(colors: [Color(red: 0.45, green: 0.75, blue: 1.0), .white],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(10, geo.size.width * progress))
            }
        }
    }
}

// MARK: - Step 1: Welcome

private struct WelcomeStep: View {
    var onNext: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Text("Welcome to Shhhcribble")
                .font(.system(size: 26, weight: .bold))
                .foregroundColor(.white)
            VStack(spacing: 6) {
                Text("We'll guide you through set up and make sure")
                Text("Shhhcribble works the way you want.")
            }
            .font(.system(size: 13))
            .foregroundColor(.white.opacity(0.65))
            .multilineTextAlignment(.center)

            Text("Estimated time: less than 2 minutes")
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.4))
                .padding(.top, 14)
            Spacer()
            PrimaryButton(title: "Get Started", action: onNext)
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
        }
    }
}

// MARK: - Step 2: Permissions

private struct PermissionsStep: View {
    var onNext: () -> Void

    @State private var micStatus: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var axGranted: Bool = AXIsProcessTrusted()

    private let pollTimer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Let's set up permissions")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(.white)
                Text("Shhhcribble runs entirely on your Mac — no audio leaves your device.")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.55))
            }

            PermissionRow(
                icon: "mic.fill",
                title: "Allow Microphone Access",
                detail: "Required to capture audio for transcription. Only used while recording.",
                granted: micStatus == .authorized
            ) {
                AVCaptureDevice.requestAccess(for: .audio) { _ in
                    DispatchQueue.main.async {
                        micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
                    }
                }
            }

            PermissionRow(
                icon: "figure.wave",
                title: "Allow Accessibility Access",
                detail: "Required to paste text into focused fields. Only used when inserting a transcription.",
                granted: axGranted
            ) {
                let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
                _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
            }

            Spacer()
            PrimaryButton(title: "Continue Setup", action: onNext)
        }
        .padding(24)
        .onReceive(pollTimer) { _ in
            axGranted = AXIsProcessTrusted()
            micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        }
    }
}

private struct PermissionRow: View {
    let icon: String
    let title: String
    let detail: String
    let granted: Bool
    var action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundColor(Color(red: 0.45, green: 0.75, blue: 1.0))
                .frame(width: 28)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            if granted {
                Label("Allowed", systemImage: "checkmark.circle.fill")
                    .labelStyle(.iconOnly)
                    .font(.system(size: 18))
                    .foregroundColor(.green)
            } else {
                Button("Allow", action: action)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }
}

// MARK: - Step 3: Mic test

private struct MicTestStep: View {
    var onNext: () -> Void

    @StateObject private var deviceManager = AudioDeviceManager()
    @State private var preferredInputUID: String = ModelManager.preferredInputDeviceUID ?? ""
    @State private var audioLevel: Double = 0
    @StateObject private var recorderHolder = RecorderHolder()

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Let's test your microphone")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(.white)
                Text("Speak and see if the bars react. No response? Change your input below.")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.55))
            }

            // Input device picker
            HStack {
                Text("Input")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.65))
                Picker("", selection: $preferredInputUID) {
                    Text("System Default").tag("")
                    ForEach(deviceManager.devices) { device in
                        Text(device.name).tag(device.id)
                    }
                }
                .labelsHidden()
                .onChange(of: preferredInputUID) { _, newValue in
                    ModelManager.preferredInputDeviceUID = newValue.isEmpty ? nil : newValue
                    // Restart the test recorder with the new device
                    recorderHolder.restart { level in
                        audioLevel = Double(level)
                    }
                }
            }

            // Live bars
            SoundwaveBars(audioLevel: audioLevel)
                .frame(height: 48)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)

            Spacer()
            PrimaryButton(title: "Continue", action: {
                recorderHolder.stop()
                onNext()
            })
        }
        .padding(24)
        .onAppear {
            recorderHolder.start { level in audioLevel = Double(level) }
        }
        .onDisappear { recorderHolder.stop() }
    }
}

/// Wraps an AudioRecorder for the mic-test step so SwiftUI can own its lifecycle.
@MainActor
private final class RecorderHolder: ObservableObject {
    private let recorder = AudioRecorder()

    func start(level: @escaping (Float) -> Void) {
        recorder.start(levelCallback: level, onError: { message in
            print("[Shhhcribble] Mic test error: \(message)")
        })
    }

    func restart(level: @escaping (Float) -> Void) {
        _ = recorder.stop()
        start(level: level)
    }

    func stop() {
        _ = recorder.stop()
    }
}

// MARK: - Step 4: Model download

private struct ModelDownloadStep: View {
    @ObservedObject var engine: TranscriptionEngine
    var onNext: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Downloading Parakeet")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(.white)
                Text("Parakeet will be your default voice model. You can change this later in Settings.")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            VStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(Color(red: 0.35, green: 0.6, blue: 0.2).opacity(0.25))
                        .frame(width: 120, height: 120)
                    Image(systemName: engine.isReady ? "checkmark.circle.fill" : "arrow.down.circle")
                        .font(.system(size: 54))
                        .foregroundColor(engine.isReady ? .green : Color(red: 0.5, green: 0.85, blue: 0.35))
                }

                Text(engine.statusText)
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.6))

                if !engine.isReady {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .tint(Color(red: 0.45, green: 0.75, blue: 1.0))
                        .frame(width: 200)
                }
            }
            .frame(maxWidth: .infinity)

            Spacer()

            PrimaryButton(
                title: engine.isReady ? "Continue" : "Please wait…",
                action: onNext
            )
            .disabled(!engine.isReady)
        }
        .padding(24)
    }
}

// MARK: - Step 5: Done

private struct DoneStep: View {
    var onFinish: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 54))
                .foregroundColor(.green)
            Text("You're all set")
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(.white)

            VStack(spacing: 4) {
                Text("Hold \(ModelManager.selectedHotkey.symbol) to record, release to paste.")
                Text("Change your shortcut or model any time in Settings.")
            }
            .font(.system(size: 13))
            .foregroundColor(.white.opacity(0.65))
            .multilineTextAlignment(.center)

            Spacer()
            PrimaryButton(title: "Start Using Shhhcribble", action: onFinish)
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
        }
    }
}

// MARK: - Shared primary button

private struct PrimaryButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color(red: 0.45, green: 0.75, blue: 1.0))
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
}
