import SwiftUI

// MARK: - View model

enum RecordingUIState: Equatable {
    case hidden
    case recording
    case transcribing   // post-release: transcribing + (optional) on-device AI cleanup in progress
    case copied
    case noResult
    case info(String)   // neutral transient message (e.g. "Getting ready…" while the model loads)
    case error(String)
}

@MainActor
final class SoundwaveViewModel: ObservableObject {
    @Published var state: RecordingUIState = .hidden
    @Published var audioLevel: Double = 0
    @Published var liveText: String = ""   // interim transcription shown while recording
    @Published var isVisible: Bool = false  // drives entry/exit animation
}

// MARK: - Typing view model

/// Appends characters one-at-a-time so live transcription feels like active
/// dictation rather than instant jumps to new text.
@MainActor
final class TypingViewModel: ObservableObject {
    @Published var displayedText: String = ""
    private var targetText: String = ""
    private var typingTask: Task<Void, Never>?

    func updateTarget(_ newText: String) {
        if newText.hasPrefix(displayedText) {
            // New text simply extends what's already displayed — continue typing
            targetText = newText
        } else {
            // Text changed (engine revised earlier words) — rewind to common prefix
            var commonLen = 0
            let dChars = Array(displayedText)
            let nChars = Array(newText)
            for i in 0..<min(dChars.count, nChars.count) {
                if dChars[i] == nChars[i] { commonLen = i + 1 } else { break }
            }
            displayedText = String(displayedText.prefix(commonLen))
            targetText = newText
        }

        typingTask?.cancel()
        typingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let current = self.displayedText
                let target  = self.targetText
                guard current.count < target.count else { break }
                let nextIdx = target.index(target.startIndex, offsetBy: current.count)
                self.displayedText = String(target[target.startIndex...nextIdx])
                try? await Task.sleep(for: .milliseconds(70))
            }
        }
    }

    func reset() {
        typingTask?.cancel()
        typingTask = nil
        displayedText = ""
        targetText    = ""
    }
}

// MARK: - Root view

struct SoundwaveView: View {
    @ObservedObject var viewModel: SoundwaveViewModel

    var body: some View {
        // Outer transparent container (400×136) gives the spring animation room to
        // overshoot without being clipped by the NSPanel window boundary.
        ZStack {
            Color.clear

            // Inner animated pill — 320×56
            ZStack {
                // Solid dark background for maximum contrast
                Capsule()
                    .fill(Color(red: 0.1, green: 0.1, blue: 0.12).opacity(0.94))
                    .shadow(color: .black.opacity(0.5), radius: 18, y: 7)

                HStack(spacing: 0) {
                    // Leading indicator: a spinner while transcribing/cleaning,
                    // otherwise the mic / checkmark / warning glyph.
                    Group {
                        if viewModel.state == .transcribing {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.white)
                        } else {
                            Image(systemName: iconName)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(iconColor)
                        }
                    }
                    .padding(.leading, 16)
                    .padding(.trailing, 10)

                    switch viewModel.state {
                    case .recording:
                        // Bars always visible at fixed width
                        SoundwaveBars(audioLevel: viewModel.audioLevel)
                            .frame(width: 36)
                        // Single-line text types characters left→right as words arrive
                        ScrollingLiveText(text: viewModel.liveText)
                            .padding(.horizontal, 8)

                    case .transcribing:
                        Text("Transcribing…")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.white)
                        Spacer()

                    case .copied:
                        Text("Copied! ⌘V to paste")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.white)
                        Spacer()

                    case .noResult:
                        Text("No speech detected")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.white.opacity(0.7))
                        Spacer()

                    case .info(let message):
                        Text(message)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.white.opacity(0.85))
                            .lineLimit(1)
                        Spacer()

                    case .error(let message):
                        Text(message)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(Color(red: 1.0, green: 0.45, blue: 0.45))
                            .lineLimit(1)
                        Spacer()

                    case .hidden:
                        SoundwaveBars(audioLevel: 0, isActive: false)
                            .frame(width: 36)
                        Spacer()
                    }

                    // Animated status dot — glows and pulses during recording
                    AnimatedDot(color: dotColor, animate: viewModel.state == .recording)
                        .padding(.leading, 2)
                        .padding(.trailing, 12)
                        .opacity(viewModel.state == .hidden ? 0 : 1)
                }
            }
            .frame(width: 320, height: 56)
            .clipShape(Capsule())
            // Thin state-coloured halo border — animates with state colour
            .overlay(
                Capsule()
                    .strokeBorder(dotColor.opacity(0.28), lineWidth: 0.75)
                    .animation(.easeInOut(duration: 0.4), value: viewModel.state)
            )
            // Shadow sits outside the clip so it renders on the whole capsule shape
            .shadow(color: .black.opacity(0.45), radius: 16, y: 6)
            // Entry / exit animation driven by isVisible
            .scaleEffect(viewModel.isVisible ? 1.0 : 0.78)
            .offset(y: viewModel.isVisible ? 0 : -18)
            .opacity(viewModel.isVisible ? 1.0 : 0.0)
        }
        .frame(width: 400, height: 136)
    }

    private var iconName: String {
        switch viewModel.state {
        case .copied:   return "checkmark.circle.fill"
        case .noResult: return "waveform.slash"
        case .info:     return "info.circle.fill"
        case .error:    return "exclamationmark.triangle.fill"
        default:        return "mic.fill"
        }
    }

    private var iconColor: Color {
        switch viewModel.state {
        case .copied: return .green
        case .error:  return Color(red: 1.0, green: 0.45, blue: 0.45)
        default:      return .white.opacity(0.55)
        }
    }

    private var dotColor: Color {
        switch viewModel.state {
        case .recording:    return Color(red: 0.25, green: 0.55, blue: 1.0)
        case .transcribing: return Color(red: 0.65, green: 0.50, blue: 1.0)  // violet = on-device AI working
        case .copied:       return .green
        case .noResult:     return .white.opacity(0.3)
        case .info:         return .white.opacity(0.45)
        case .error:        return Color(red: 1.0, green: 0.45, blue: 0.45)
        case .hidden:       return .clear
        }
    }
}

// MARK: - Animated status dot

/// Three-layer LED-style dot: always fully visible.
/// During recording a light-streak shimmer sweeps slowly across the surface.
/// No pulse-away — the dot stays lit at all times; only the shimmer moves.
struct AnimatedDot: View {
    let color: Color
    let animate: Bool

    @State private var shimmerX: CGFloat = -0.6

    var body: some View {
        ZStack {
            // Layer 1: static outer glow — always present, no pulsing
            Circle()
                .fill(color.opacity(0.22))
                .frame(width: 20, height: 20)
                .blur(radius: 4)
                .opacity(animate ? 1.0 : 0.0)

            // Layer 2: dark housing / bezel
            Circle()
                .fill(Color(white: 0.10))
                .frame(width: 14, height: 14)
                .overlay(Circle().strokeBorder(Color(white: 0.22), lineWidth: 0.5))

            // Layer 3: permanently lit core with off-centre specular highlight
            Circle()
                .fill(
                    RadialGradient(
                        colors: [.white.opacity(0.85), color, color.opacity(0.35)],
                        center: UnitPoint(x: 0.35, y: 0.28),
                        startRadius: 0,
                        endRadius: 5
                    )
                )
                .frame(width: 9, height: 9)

            // Layer 4: shimmer streak — only visible during recording
            if animate {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [.clear, .white.opacity(0.50), .clear],
                            startPoint: UnitPoint(x: shimmerX - 0.4, y: 0.1),
                            endPoint:   UnitPoint(x: shimmerX + 0.4, y: 0.9)
                        )
                    )
                    .frame(width: 9, height: 9)
            }
        }
        .frame(width: 22, height: 22)
        // Smooth colour crossfade when state changes (recording → transcribing → copied)
        .animation(.easeOut(duration: 0.4), value: color)
        .onAppear      { if animate { startShimmer() } }
        .onChange(of: animate) { _, v in if v { startShimmer() } }
    }

    private func startShimmer() {
        shimmerX = -0.6
        withAnimation(.linear(duration: 2.8).repeatForever(autoreverses: false)) {
            shimmerX = 1.6
        }
    }
}

// MARK: - Scrolling live text

/// Single-line text that types characters one-at-a-time via TypingViewModel,
/// then instantly scrolls to keep the latest character in view.
/// Left and right edges fade to transparent so text appears to emerge from / vanish into nothing.
/// The typing cadence (70 ms/char) IS the animation — no SwiftUI scroll animation needed.
struct ScrollingLiveText: View {
    let text: String

    @StateObject private var typer = TypingViewModel()

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                styledText
                    .font(.system(size: 12, weight: .regular))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .id("end")
            }
            .disabled(true)   // no manual scrolling
            .clipped()
            .onChange(of: typer.displayedText) { _, _ in
                // Instant scroll — the character-by-character typing is the animation
                proxy.scrollTo("end", anchor: .trailing)
            }
        }
        // Gradient mask: text fades in from the left and fades out to the right
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.00),
                    .init(color: .black, location: 0.12),
                    .init(color: .black, location: 0.82),
                    .init(color: .clear, location: 1.00)
                ],
                startPoint: .leading,
                endPoint:   .trailing
            )
        )
        .onChange(of: text) { _, newValue in
            typer.updateTarget(newValue)
        }
        .onAppear {
            if !text.isEmpty { typer.updateTarget(text) }
        }
        .onDisappear {
            typer.reset()
        }
    }

    /// Renders the typed string with the *just-completed* word (i.e. the
    /// second-to-last token) at higher opacity than the rest. Highlighting the
    /// in-progress trailing word looked buggy because horizontal autoscroll
    /// kept that word under the right-edge fade mask — the emphasis was
    /// half-hidden. Settled words sit in the visible centre, where emphasis
    /// reads clean. Pattern borrowed from ABY Journal and Otter.ai on Mobbin.
    private var styledText: Text {
        let displayed = typer.displayedText
        if displayed.isEmpty {
            return Text(" ").foregroundColor(.white.opacity(0))
        }
        let dim = Color.white.opacity(0.40)
        let lit = Color.white.opacity(0.85)

        guard let lastSpace = displayed.lastIndex(where: { $0.isWhitespace }) else {
            // Only one token typed so far — render uniform until a space lands.
            return Text(displayed).foregroundColor(dim)
        }

        let beforeLastSpace = displayed[..<lastSpace]
        guard let secondLastSpace = beforeLastSpace.lastIndex(where: { $0.isWhitespace }) else {
            // Exactly two tokens: first is "just completed", second is in progress.
            let highlighted = String(beforeLastSpace)
            let tail = String(displayed[lastSpace...])
            return Text(highlighted).foregroundColor(lit)
                 + Text(tail).foregroundColor(dim)
        }

        // Three or more tokens: head | highlighted just-completed word | trailing in-progress word.
        let head = String(displayed[..<displayed.index(after: secondLastSpace)])
        let highlighted = String(displayed[displayed.index(after: secondLastSpace)..<lastSpace])
        let tail = String(displayed[lastSpace...])
        return Text(head).foregroundColor(dim)
             + Text(highlighted).foregroundColor(lit)
             + Text(tail).foregroundColor(dim)
    }
}

// MARK: - Soundwave bars

struct SoundwaveBars: View {
    let audioLevel: Double
    /// When false the bars rest at their baseline and skip per-tick recompute.
    /// Set false for the off-screen `.hidden` state so the panel doesn't churn
    /// ~20 Hz while idle, and so a fresh recording always enters from rest.
    var isActive: Bool = true

    private let barCount = 7
    private let restHeight: CGFloat = 4

    @State private var heights: [CGFloat] = Array(repeating: 4, count: 7)
    @State private var phase: Double = 0

    let timer = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(0..<barCount, id: \.self) { i in
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.white.opacity(0.75))
                    .frame(width: 3, height: heights[i])
                    .animation(.easeInOut(duration: 0.05), value: heights[i])
            }
        }
        .frame(height: 36)
        .onReceive(timer) { _ in
            guard isActive else {
                // Idle: settle to baseline once, then do nothing each tick.
                if heights.contains(where: { $0 != restHeight }) {
                    heights = Array(repeating: restHeight, count: barCount)
                }
                return
            }
            phase += 0.35
            for i in 0..<barCount {
                let wave = sin(phase + Double(i) * 0.75)
                let normalised = 0.65 + 0.35 * wave
                let level = max(audioLevel, 0.05)
                heights[i] = restHeight + CGFloat(level * 32 * normalised)
            }
        }
    }
}
