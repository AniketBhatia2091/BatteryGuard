import SwiftUI
import AppKit

public struct MenuBarView: View {
    @ObservedObject var coordinator: SamplingCoordinator

    public init(coordinator: SamplingCoordinator) {
        self.coordinator = coordinator
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header
            headerView

            Divider()

            // Current Battery Status Card
            if let snapshot = coordinator.latestBatterySnapshot {
                batteryStatusCard(snapshot: snapshot)
            } else {
                Text("Reading battery hardware...")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Divider()

            // Scrollable Timeline View
            TimelineView(samples: coordinator.recentSamples)

            Divider()

            // Bottom Actions Bar
            footerView
        }
        .padding(14)
        .frame(width: 320)
    }

    // MARK: - Subviews

    private var headerView: some View {
        HStack {
            Image(systemName: "shield.lefthalf.filled")
                .foregroundColor(.accentColor)
                .font(.title3)

            Text("BatteryGuard")
                .font(.headline)

            Spacer()

            HStack(spacing: 4) {
                Circle()
                    .fill(coordinator.isSampling ? Color.green : Color.orange)
                    .frame(width: 7, height: 7)

                Text(coordinator.isSampling ? "Active" : "Paused")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Button(action: {
                coordinator.refreshImmediate()
            }) {
                Image(systemName: "arrow.clockwise")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .help("Refresh battery telemetry now")
        }
    }

    private func batteryStatusCard(snapshot: BatterySnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    Circle()
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 4)
                        .frame(width: 46, height: 46)

                    Circle()
                        .trim(from: 0, to: CGFloat(min(max(snapshot.percentage / 100.0, 0), 1)))
                        .stroke(
                            snapshot.isCharging ? Color.green : (snapshot.percentage > 20 ? Color.blue : Color.red),
                            style: StrokeStyle(lineWidth: 4, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                        .frame(width: 46, height: 46)

                    if snapshot.isCharging {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.green)
                    } else {
                        Text("\(Int(snapshot.percentage))%")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("\(Int(snapshot.percentage))% Capacity")
                            .font(.subheadline.bold())
                        if snapshot.isCharging {
                            Text("• Charging")
                                .font(.caption.bold())
                                .foregroundColor(.green)
                        } else if snapshot.isACPowered {
                            Text("• AC Connected")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else {
                            Text("• On Battery")
                                .font(.caption)
                                .foregroundColor(.orange)
                        }
                    }

                    if let cycles = snapshot.cycleCount {
                        Text("Cycle Count: \(cycles)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }

                    if let health = snapshot.healthPercentage {
                        Text(String(format: "Health: %.1f%%", health))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }

                    if let temp = snapshot.temperatureCelsius {
                        Text(String(format: "Temperature: %.1f°C", temp))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
    }

    private var footerView: some View {
        HStack {
            Button(coordinator.isSampling ? "Pause Loop" : "Resume Loop") {
                if coordinator.isSampling {
                    coordinator.stop()
                } else {
                    coordinator.start()
                }
            }
            .font(.caption)

            Spacer()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .font(.caption)
            .keyboardShortcut("q", modifiers: .command)
        }
    }
}
