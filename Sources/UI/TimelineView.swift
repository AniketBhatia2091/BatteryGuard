import SwiftUI

/// Demonstrates a scrollable timeline view inside MenuBarExtra (using `.window` style).
/// This satisfies the requirement to prove that MenuBarExtra natively supports scrollable UI.
public struct TimelineView: View {
    public let samples: [MetricSample]

    public init(samples: [MetricSample]) {
        self.samples = samples
    }

    private let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss"
        return df
    }()

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Telemetry Timeline", systemImage: "chart.xyaxis.line")
                    .font(.caption.bold())
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(samples.count) samples")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            if samples.isEmpty {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .frame(height: 70)
                    .overlay(
                        Text("Gathering initial telemetry...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    )
            } else {
                ScrollView(.horizontal, showsIndicators: true) {
                    HStack(alignment: .bottom, spacing: 10) {
                        ForEach(samples) { sample in
                            timelineNode(for: sample)
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 8)
                }
                .frame(height: 100)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(nsColor: .controlBackgroundColor).opacity(0.6))
                )
            }
        }
    }

    @ViewBuilder
    private func timelineNode(for sample: MetricSample) -> some View {
        let percent = sample.data["percentage"] ?? 100.0
        let isCharging = (sample.data["isCharging"] ?? 0) > 0

        VStack(spacing: 4) {
            // Bar graph representation
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.secondary.opacity(0.2))
                    .frame(width: 22, height: 50)

                RoundedRectangle(cornerRadius: 3)
                    .fill(barColor(for: percent, isCharging: isCharging))
                    .frame(width: 22, height: max(6, 50 * CGFloat(percent / 100.0)))

                if isCharging {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 8))
                        .foregroundColor(.white)
                        .padding(.bottom, 2)
                }
            }

            Text("\(Int(percent))%")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))

            Text(dateFormatter.string(from: sample.timestamp))
                .font(.system(size: 8))
                .foregroundColor(.secondary)
        }
        .frame(width: 32)
    }

    private func barColor(for percent: Double, isCharging: Bool) -> Color {
        if isCharging {
            return .green
        }
        if percent > 50 {
            return .blue
        } else if percent > 20 {
            return .orange
        } else {
            return .red
        }
    }
}
