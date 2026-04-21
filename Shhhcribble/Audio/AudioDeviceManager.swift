import AVFoundation
import CoreAudio
import Combine

/// Discovers audio input devices and keeps the list in sync as devices are
/// connected or disconnected (AirPods, USB mics, etc.). Device UIDs match the
/// CoreAudio UID namespace, so the stored preference round-trips through
/// `AudioRecorder` without translation beyond `AudioObjectGetPropertyData`.
@MainActor
final class AudioDeviceManager: ObservableObject {

    struct Device: Identifiable, Equatable {
        let id: String   // AVCaptureDevice.uniqueID == CoreAudio device UID
        let name: String
    }

    @Published private(set) var devices: [Device] = []

    private var observers: [NSObjectProtocol] = []

    init() {
        refresh()

        let names: [Notification.Name] = [
            .AVCaptureDeviceWasConnected,
            .AVCaptureDeviceWasDisconnected,
        ]
        for name in names {
            let obs = NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
            observers.append(obs)
        }
    }

    deinit {
        for obs in observers { NotificationCenter.default.removeObserver(obs) }
    }

    func refresh() {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
        devices = session.devices.map { Device(id: $0.uniqueID, name: $0.localizedName) }
    }

    /// Resolve a device UID (from AVCaptureDevice) to a CoreAudio AudioDeviceID,
    /// which `AudioRecorder` can assign to the engine's input audio unit.
    /// Returns nil if the device is not currently connected.
    nonisolated static func resolveAudioDeviceID(forUID uid: String) -> AudioDeviceID? {
        var deviceID: AudioDeviceID = kAudioObjectUnknown
        var cfUID = uid as CFString
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = withUnsafeMutablePointer(to: &cfUID) { uidPtr -> OSStatus in
            withUnsafeMutablePointer(to: &deviceID) { devPtr in
                AudioObjectGetPropertyData(
                    AudioObjectID(kAudioObjectSystemObject),
                    &address,
                    UInt32(MemoryLayout<CFString>.size),
                    uidPtr,
                    &size,
                    devPtr
                )
            }
        }

        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }
}
