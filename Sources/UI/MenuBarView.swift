import SwiftUI
import Charts
import AppKit

public struct MenuBarView: View {
    @ObservedObject var coordinator: SamplingCoordinator
    @ObservedObject private var launchAtLogin = LaunchAtLoginManager.shared

    // Cosmetic-only 1-second display timer for smooth overcharge countdown.
    // NOTE: This timer ONLY updates a local @State display value; it NEVER writes to SQLite
    // or mutates ChargeSessionTracker, preventing any dual-timer conflict.
    @State private var liveOverchargeSeconds: Double = 0.0
    private let uiTimer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    public init(coordinator: SamplingCoordinator) {
        self.coordinator = coordinator
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 1. Header
            headerView

            Divider()

            // 2. Battery Health Card
            if let snapshot = coordinator.latestBatterySnapshot {
                batteryHealthCard(snapshot: snapshot)
            } else {
                Text("Reading battery hardware...")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Divider()

            // 3. Charge Limit Card (Alert Mode + Live Counter)
            chargeLimitCard

            Divider()

            // 4. Overcharge History Card (Today/Week + 14-day Swift Chart)
            overchargeHistoryCard

            Divider()

            // 5. Footer (Launch at Login + Quit)
            footerView
        }
        .padding(14)
        .frame(width: 330)
        .onReceive(uiTimer) { _ in
            updateLiveDisplayTimer()
        }
        .onAppear {
            syncLiveOverchargeFromCoordinator()
            launchAtLogin.refreshStatus()
        }
        .onChange(of: coordinator.activeSession?.secondsSpentAtOrAboveLimit) { _ in
            syncLiveOverchargeFromCoordinator()
        }
    }

    // MARK: - 1. Header View

    private var headerView: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Brand row
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "shield.lefthalf.filled")
                        .foregroundColor(.accentColor)
                        .font(.system(size: 14, weight: .semibold))

                    Text("BatteryGuard")
                        .font(.system(size: 13, weight: .bold))
                }

                Spacer()

                HStack(spacing: 4) {
                    Circle()
                        .fill(coordinator.isSampling ? Color.green : Color.orange)
                        .frame(width: 6, height: 6)

                    Text(coordinator.isSampling ? "Active" : "Paused")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                }

                Button(action: {
                    coordinator.refreshImmediate()
                }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Refresh battery telemetry now")
            }

            // Prominent telemetry row
            if let snapshot = coordinator.latestBatterySnapshot {
                HStack(alignment: .center, spacing: 12) {
                    // Large prominent charge percentage
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text("\(snapshot.currentChargePercentage)")
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                        Text("%")
                            .font(.system(size: 18, weight: .semibold, design: .rounded))
                            .foregroundColor(.secondary)
                    }

                    // Charging state icon & status badge
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            chargingStateIcon(snapshot: snapshot)
                            Text(chargingStateTitle(snapshot: snapshot))
                                .font(.system(size: 12, weight: .semibold))
                        }

                        // AC connection indicator
                        HStack(spacing: 4) {
                            Image(systemName: snapshot.isACPowerConnected ? "powerplug.fill" : "battery.100")
                                .font(.system(size: 10))
                                .foregroundColor(snapshot.isACPowerConnected ? .green : .secondary)

                            Text(snapshot.isACPowerConnected ? "Power Adapter Connected" : "Running on Battery")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                    }

                    Spacer()
                }
            }
        }
    }

    // MARK: - 2. Battery Health Card

    private func batteryHealthCard(snapshot: BatterySnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Battery Health", systemImage: "heart.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.secondary)

                Spacer()

                // Condition Pill
                let cond = snapshot.condition ?? "Normal"
                HStack(spacing: 4) {
                    Circle()
                        .fill(cond.lowercased() == "normal" || cond.lowercased() == "good" ? Color.green : Color.orange)
                        .frame(width: 5, height: 5)
                    Text(cond)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(cond.lowercased() == "normal" || cond.lowercased() == "good" ? .green : .orange)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.1)))
            }

            HStack(spacing: 12) {
                // Cycle Count
                VStack(alignment: .leading, spacing: 1) {
                    Text("Cycles")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Text(snapshot.cycleCount.map { "\($0)" } ?? "—")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))

                // Estimated Health % with Disclosure Tooltip
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 3) {
                        Text("Estimated Health")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                        Image(systemName: "info.circle")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                            .help("Calculated from raw battery capacity; may differ slightly from macOS's Battery Health screen.")
                    }

                    if let health = snapshot.healthPercentage {
                        Text(String(format: "%.1f%%", health))
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundColor(health >= 80 ? .primary : .orange)
                    } else {
                        Text("—")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
    }

    // MARK: - 3. Charge Limit Card

    private var chargeLimitCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Charge Limit", systemImage: "bolt.badge.clock")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.secondary)

                Spacer()

                // Honest mode badge
                HStack(spacing: 3) {
                    Circle().fill(Color.orange).frame(width: 5, height: 5)
                    Text("Alert Mode")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.orange)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.orange.opacity(0.12)))
                .help("In Alert Mode, BatteryGuard notifies you when your battery reaches the limit so you can unplug. Hardware charging cutoff is not active in this phase.")
            }

            // Stepper and current value
            HStack {
                Text("\(coordinator.chargeLimit)% Limit")
                    .font(.system(size: 14, weight: .bold, design: .rounded))

                Spacer()

                Stepper("", value: $coordinator.chargeLimit, in: 50...100, step: 5)
                    .labelsHidden()
            }

            // Live Overcharge Warning (if actively plugged in and at/above limit)
            let isOverLimit = (coordinator.latestBatterySnapshot?.isACPowerConnected == true) &&
                              ((coordinator.latestBatterySnapshot?.currentChargePercentage ?? 0) >= coordinator.chargeLimit)

            if isOverLimit {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.orange)

                    Text("Overcharging: \(formatDuration(liveOverchargeSeconds))")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(.orange)

                    Spacer()

                    Text("Unplug Now")
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 3).fill(Color.orange.opacity(0.2)))
                        .foregroundColor(.orange)
                }
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.08)))
            } else {
                Text("Notifies you to unplug charger when battery reaches \(coordinator.chargeLimit)%.")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
    }

    // MARK: - 4. Overcharge History Card

    private var overchargeHistoryCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Overcharge Exposure", systemImage: "clock.badge.exclamationmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.secondary)

                Spacer()

                Text("Last 14 Days")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.secondary)
            }

            // Today / This Week metrics row
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Today")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Text(formatDuration(coordinator.todayOverchargeSeconds))
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundColor(coordinator.todayOverchargeSeconds > 0 ? .orange : .primary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))

                VStack(alignment: .leading, spacing: 1) {
                    Text("This Week")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Text(formatDuration(coordinator.weekOverchargeSeconds))
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundColor(coordinator.weekOverchargeSeconds > 0 ? .orange : .primary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
            }

            // Swift Charts: 14-Day Overcharge History
            if !coordinator.dailyHistory.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Chart(coordinator.dailyHistory) { item in
                        BarMark(
                            x: .value("Day", item.date, unit: .day),
                            y: .value("Minutes", item.minutes)
                        )
                        .foregroundStyle(
                            item.minutes > 0
                                ? LinearGradient(colors: [.orange, .red.opacity(0.8)], startPoint: .bottom, endPoint: .top)
                                : LinearGradient(colors: [Color.secondary.opacity(0.2), Color.secondary.opacity(0.2)], startPoint: .bottom, endPoint: .top)
                        )
                        .cornerRadius(2)
                    }
                    .chartYAxis {
                        AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 2]))
                                .foregroundStyle(Color.secondary.opacity(0.2))
                            AxisValueLabel {
                                if let val = value.as(Double.self) {
                                    Text("\(Int(val))m")
                                        .font(.system(size: 8))
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                    .chartXAxis {
                        AxisMarks(values: .stride(by: .day, count: 2)) { value in
                            AxisValueLabel(format: .dateTime.day())
                                .font(.system(size: 8))
                                .foregroundStyle(Color.secondary)
                        }
                    }
                    .frame(height: 75)
                    .padding(.top, 4)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
    }

    // MARK: - 5. Footer View

    private var footerView: some View {
        VStack(spacing: 8) {
            // Launch at Login Toggle
            HStack {
                Toggle(isOn: Binding(
                    get: { launchAtLogin.isEnabled },
                    set: { launchAtLogin.setEnabled($0) }
                )) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 11))
                        Text("Launch at Login")
                            .font(.system(size: 11))
                    }
                }
                .toggleStyle(.checkbox)

                Spacer()

                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .font(.system(size: 11))
                .keyboardShortcut("q", modifiers: .command)
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
            }

            if let message = launchAtLogin.statusMessage {
                Text(message)
                    .font(.system(size: 9))
                    .foregroundColor(.orange)
                    .lineLimit(2)
            }
        }
    }

    // MARK: - Cosmetic Timer & Interpolation

    private func syncLiveOverchargeFromCoordinator() {
        let baseline = coordinator.activeSession?.secondsSpentAtOrAboveLimit ?? 0.0
        self.liveOverchargeSeconds = baseline
    }

    private func updateLiveDisplayTimer() {
        let isOverLimit = (coordinator.latestBatterySnapshot?.isACPowerConnected == true) &&
                          ((coordinator.latestBatterySnapshot?.currentChargePercentage ?? 0) >= coordinator.chargeLimit)

        if isOverLimit {
            // Smooth cosmetic increment without touching storage
            self.liveOverchargeSeconds += 1.0
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func chargingStateIcon(snapshot: BatterySnapshot) -> some View {
        switch snapshot.chargingState {
        case .charging:
            Image(systemName: "bolt.fill")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(.green)
        case .full:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(.green)
        case .discharging:
            Image(systemName: "battery.75")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(snapshot.percentage <= 20 ? .red : .primary)
        case .notCharging:
            Image(systemName: "pause.circle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.orange)
        }
    }

    private func chargingStateTitle(snapshot: BatterySnapshot) -> String {
        switch snapshot.chargingState {
        case .charging:
            return "Charging"
        case .full:
            return "Fully Charged"
        case .discharging:
            return "Discharging"
        case .notCharging:
            return "Not Charging"
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
}
