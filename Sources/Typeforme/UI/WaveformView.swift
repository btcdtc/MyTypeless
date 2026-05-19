import SwiftUI

/// Live RMS waveform. 20 thin bars with a center-weighted shape envelope and
/// a subtle gradient — replaces the older 5-bar version. Bars stay flat (only
/// the base height) when `state != .recording`.
struct WaveformView: View {
    let level: Float
    let state: DictationState

    private static let barCount = 20
    private static let barWidth: CGFloat = 2.5
    private static let barSpacing: CGFloat = 2
    private static let baseHeight: CGFloat = 4
    private static let maxBoost: CGFloat = 26

    var body: some View {
        HStack(spacing: Self.barSpacing) {
            ForEach(0..<Self.barCount, id: \.self) { i in
                Capsule(style: .continuous)
                    .fill(barGradient)
                    .frame(width: Self.barWidth, height: barHeight(for: i))
                    .opacity(state == .recording ? 1.0 : 0.45)
            }
        }
        .animation(.easeOut(duration: 0.08), value: level)
        .animation(.easeInOut(duration: 0.22), value: state)
    }

    private var barGradient: LinearGradient {
        LinearGradient(
            colors: [.accentColor, Color.accentColor.opacity(0.55)],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    /// Center-weighted bell envelope so the middle bars peak higher than the
    /// edges, matching the visual idiom every modern dictation HUD uses.
    private func barHeight(for index: Int) -> CGFloat {
        let center = CGFloat(Self.barCount - 1) / 2
        let distFromCenter = abs(CGFloat(index) - center) / center
        let envelope = pow(1 - distFromCenter, 1.4)
        let clamped = CGFloat(min(max(level, 0), 1))
        let activeMul: CGFloat = (state == .recording) ? 1.0 : 0.0
        return Self.baseHeight + Self.maxBoost * envelope * clamped * activeMul
    }
}
