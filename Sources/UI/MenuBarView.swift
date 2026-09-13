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

            // Overcharge Exposure Card (SQLite-backed)
            overchargeStatsCard

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
                        HStack(spacing: 3) {
                            Text(String(format: "Estimated Health: %.1f%%", health))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Image(systemName: "info.circle")
                                .font(.system(size: 9))
                                .foregroundColor(.secondary)
                                .help("Calculated from raw battery data; may differ slightly from macOS's Battery Health screen.")
                        }
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

    private var overchargeStatsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Overcharge Exposure", systemImage: "clock.badge.exclamationmark")
                    .font(.caption.bold())
                    .foregroundColor(.secondary)
                Spacer()
                if coordinator.activeSession != nil {
                    HStack(spacing: 3) {
                        Circle().fill(Color.green).frame(width: 5, height: 5)
                        Text("Plugged In")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                } else {
                    Text("On Battery")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            HStack(spacing: 8) {
                // Today
                VStack(alignment: .leading, spacing: 2) {
                    Text("Today")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text(formatDuration(coordinator.todayOverchargeSeconds))
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundColor(coordinator.todayOverchargeSeconds > 0 ? .orange : .primary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.1)))

                // This Week
                VStack(alignment: .leading, spacing: 2) {
                    Text("This Week")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text(formatDuration(coordinator.weekOverchargeSeconds))
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundColor(coordinator.weekOverchargeSeconds > 0 ? .orange : .primary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.1)))
            }

            if let session = coordinator.activeSession, session.secondsSpentAtOrAboveLimit > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundColor(.orange)
                    Text("Session Overcharge: \(formatDuration(session.secondsSpentAtOrAboveLimit))")
                        .font(.caption2.bold())
                        .foregroundColor(.orange)
                }
            }
        }
    }

    private func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60

        if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else if minutes > 0 {
            return "\(minutes)m \(secs)s"
        } else {
            return "\(secs)s"
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
