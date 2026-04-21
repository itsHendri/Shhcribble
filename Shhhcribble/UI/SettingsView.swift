import SwiftUI
import ApplicationServices
import AVFoundation
import ServiceManagement

struct SettingsView: View {
    @ObservedObject var transcriptionEngine: TranscriptionEngine
    var appDelegate: AppDelegate

    @State private var selectedModel:        String = ModelManager.selectedModel
    @State private var selectedHotkeyID:    String = ModelManager.selectedHotkeyID
    @State private var fillerFilterEnabled:   Bool = ModelManager.fillerFilterEnabled
    @State private var showLiveTranscription: Bool = ModelManager.showLiveTranscription
    @State private var playLaunchSound:       Bool = ModelManager.playLaunchSound
    @State private var launchAtLogin:         Bool = SMAppService.mainApp.status == .enabled
    @State private var activationMode:        ModelManager.ActivationMode = ModelManager.activationMode
    @State private var preferredInputUID:     String = ModelManager.preferredInputDeviceUID ?? ""

    @StateObject private var deviceManager = AudioDeviceManager()

    @State private var axGranted        = false
    @State private var micGranted       = false
    @State private var micNotDetermined = false

    // Auto-refresh permission status while the panel is open
    private let permissionTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            // MARK: Model picker
            Section {
                Picker("Model", selection: $selectedModel) {
                    ForEach(ModelManager.availableModels, id: \.id) { model in
                        Text(model.displayName).tag(model.id)
                    }
                }
                .pickerStyle(.radioGroup)
                .onChange(of: selectedModel) { _, newValue in
                    guard newValue != ModelManager.selectedModel else { return }
                    ModelManager.selectedModel = newValue
                    Task { await transcriptionEngine.reloadModel(variant: newValue) }
                }

                // Loading state feedback
                switch transcriptionEngine.loadingState {
                case .loading:
                    HStack(spacing: 6) {
                        ProgressView().scaleEffect(0.7)
                        Text(transcriptionEngine.statusText)
                            .font(.caption).foregroundColor(.secondary)
                    }
                case .failed:
                    Label(transcriptionEngine.statusText, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundColor(.red)
                default:
                    Text(transcriptionEngine.statusText)
                        .font(.caption).foregroundColor(.secondary)
                }
            } header: {
                Text("Transcription Model")
            } footer: {
                Text("Models are downloaded once and cached on your Mac.\n" +
                     "Parakeet V3 (multilingual) is recommended for most users.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // MARK: Microphone input
            Section {
                Picker("Input device", selection: $preferredInputUID) {
                    Text("System Default").tag("")
                    ForEach(deviceManager.devices) { device in
                        Text(device.name).tag(device.id)
                    }
                }
                .onChange(of: preferredInputUID) { _, newValue in
                    ModelManager.preferredInputDeviceUID = newValue.isEmpty ? nil : newValue
                }
            } header: {
                Text("Microphone")
            } footer: {
                Text("Pin a specific mic to avoid macOS silently switching inputs mid-recording (common with AirPods).")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // MARK: Hotkey picker
            Section {
                Picker("Shortcut", selection: $selectedHotkeyID) {
                    ForEach(ModelManager.availableHotkeys) { option in
                        Text(option.label).tag(option.id)
                    }
                }
                .pickerStyle(.radioGroup)
                .onChange(of: selectedHotkeyID) { _, newValue in
                    guard let option = ModelManager.availableHotkeys.first(where: { $0.id == newValue }) else { return }
                    appDelegate.updateHotkey(option)
                }
            } header: {
                Text("Recording Shortcut")
            } footer: {
                Text(activationMode == .pushToTalk
                     ? "Hold the shortcut to record, release to transcribe and paste."
                     : "Tap the shortcut to start recording; tap again to transcribe and paste.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // MARK: Activation mode
            Section {
                Picker("Activation", selection: $activationMode) {
                    Text("Push-to-talk (hold)").tag(ModelManager.ActivationMode.pushToTalk)
                    Text("Toggle (tap to start, tap to stop)").tag(ModelManager.ActivationMode.toggle)
                }
                .pickerStyle(.radioGroup)
                .onChange(of: activationMode) { _, newValue in
                    ModelManager.activationMode = newValue
                }
            } header: {
                Text("Activation Mode")
            } footer: {
                Text("Toggle mode is handy for long recordings where holding the shortcut gets tiring.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // MARK: Transcription options
            Section {
                Toggle("Remove filler words", isOn: $fillerFilterEnabled)
                    .onChange(of: fillerFilterEnabled) { _, newValue in
                        ModelManager.fillerFilterEnabled = newValue
                    }

                Toggle("Show live transcription", isOn: $showLiveTranscription)
                    .onChange(of: showLiveTranscription) { _, newValue in
                        ModelManager.showLiveTranscription = newValue
                    }

                Toggle("Play launch sound", isOn: $playLaunchSound)
                    .onChange(of: playLaunchSound) { _, newValue in
                        ModelManager.playLaunchSound = newValue
                    }

                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        setLaunchAtLogin(newValue)
                    }

            } header: {
                Text("Options")
            } footer: {
                Text("“Show live transcription” types words into the pill as you speak. Turning it off can feel snappier on slower Macs.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // MARK: Permissions
            Section {
                // Accessibility
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .center, spacing: 12) {
                        Image(systemName: "hand.raised.fill")
                            .foregroundColor(.secondary)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Accessibility (optional)").fontWeight(.medium)
                            Text(axGranted
                                 ? "Text is inserted directly at the cursor in the focused field"
                                 : "Without this, text is pasted via ⌘V instead")
                                .font(.caption).foregroundColor(.secondary)
                        }
                        Spacer()
                        if axGranted {
                            Label("Granted", systemImage: "checkmark.circle.fill")
                                .foregroundColor(.green).font(.callout)
                        } else {
                            HStack(spacing: 8) {
                                Button("Re-check") { checkPermissions() }
                                    .controlSize(.small)
                                Button("Open Settings") { openSystemPrivacy("Privacy_Accessibility") }
                                    .controlSize(.small)
                            }
                        }
                    }
                    .padding(.vertical, 2)

                    if !axGranted {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("First time:")
                                .font(.caption2).fontWeight(.semibold).foregroundColor(.secondary)
                            Text("Open Settings → find Shhhcribble → toggle it on.")
                                .font(.caption2).foregroundColor(.secondary)
                            Text("After a rebuild:")
                                .font(.caption2).fontWeight(.semibold).foregroundColor(.secondary)
                                .padding(.top, 2)
                            Text("If the toggle is already on but not detected, click − to remove Shhhcribble then + to re-add the freshly built app.")
                                .font(.caption2).foregroundColor(.secondary)
                        }
                        .padding(.leading, 32)
                    }
                }

                // Microphone — distinguish "never asked" from "denied"
                microphoneRow
            } header: {
                Text("Permissions")
            }

            // MARK: About
            Section("About") {
                HStack {
                    Text("Shhhcribble").fontWeight(.medium)
                    Spacer()
                    Text("v1.0").foregroundColor(.secondary)
                }
                Text(aboutShortcutHint)
                    .font(.caption)
                    .foregroundColor(.secondary)

                VStack(alignment: .leading, spacing: 4) {
                    Text("( ᴗ ͜ʖ ᴗ)  psst… this app was handcrafted")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                    Text("        by a human named Hendri,")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                    Text("        with chief vibes officer Tiuri")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                    Text("        whispering ideas in his ear.")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                    Text("        both humans. probably.")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary.opacity(0.5))
                }
                .padding(.top, 2)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .onAppear { checkPermissions() }
        .onReceive(permissionTimer) { _ in checkPermissions() }
    }

    private var aboutShortcutHint: String {
        let symbol = ModelManager.availableHotkeys.first(where: { $0.id == selectedHotkeyID })?.symbol ?? "⌥Space"
        switch activationMode {
        case .pushToTalk:
            return "Hold \(symbol) to record, release to transcribe and paste into any text field."
        case .toggle:
            return "Tap \(symbol) to start recording, tap again to transcribe and paste into any text field."
        }
    }

    // MARK: - Microphone row (inline to call requestAccess directly)

    @ViewBuilder
    private var microphoneRow: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "mic.fill")
                .foregroundColor(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text("Microphone").fontWeight(.medium)
                Text("Required to record your voice")
                    .font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            if micGranted {
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .foregroundColor(.green).font(.callout)
            } else if micNotDetermined {
                // First-time: trigger the system prompt directly
                Button("Grant Access") {
                    AVCaptureDevice.requestAccess(for: .audio) { _ in
                        DispatchQueue.main.async { checkPermissions() }
                    }
                }
                .controlSize(.small)
            } else {
                // Already denied — must go to System Settings
                Button("Open Settings") { openSystemPrivacy("Privacy_Microphone") }
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Helpers

    private func checkPermissions() {
        axGranted = AXIsProcessTrusted()

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:    micGranted = true;  micNotDetermined = false
        case .notDetermined: micGranted = false; micNotDetermined = true
        default:             micGranted = false; micNotDetermined = false
        }

        // Mirror any external change (e.g. user toggled off via System Settings → Login Items)
        let currentLaunchState = SMAppService.mainApp.status == .enabled
        if launchAtLogin != currentLaunchState { launchAtLogin = currentLaunchState }
    }

    private func setLaunchAtLogin(_ enable: Bool) {
        let service = SMAppService.mainApp
        do {
            if enable {
                if service.status != .enabled { try service.register() }
            } else {
                if service.status == .enabled { try service.unregister() }
            }
        } catch {
            print("[Shhhcribble] ⚠️ Failed to update launch-at-login: \(error.localizedDescription)")
        }
        // Reflect actual state in case the system rejected the change.
        launchAtLogin = service.status == .enabled
    }

    private func openSystemPrivacy(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}
