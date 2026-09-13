# BatteryGuard Design Notes

## 1. Swift Charts Overcharge History Query

### Query Architecture & Metric Selection
The daily overcharge history shown in the MenuBarExtra dashboard is powered by `getDailyOverchargeHistory(days: 14)` in `MetricsStorage.swift` (`SQLiteMetricsStore`).

```sql
SELECT 
    date(start_time, 'unixepoch', 'localtime') AS day_str,
    SUM(seconds_spent_at_or_above_limit) AS total_seconds
FROM charge_sessions
WHERE start_time >= ?
GROUP BY day_str
ORDER BY day_str ASC;
```

### Key Design Guarantees:
- **Metric Fidelity**: We strictly query `seconds_spent_at_or_above_limit / 60.0` rather than `seconds_spent_at_100_percent`. When a user sets an 80% charge limit, their exposure to chemical stress begins at 80%, not 100%. Aggregating `seconds_spent_at_or_above_limit` ensures the 14-day chart matches the exact metrics reported by the "Today" and "This Week" cards.
- **Continuous Calendar Bucketing**: Rather than returning a sparse array that would collapse or distort the chart timeline on days without charge sessions, the implementation pre-populates a continuous 14-day array of `DailyOverchargeSummary` items (from `now - 13 days` to `today` midnight-to-midnight) initialized to `0.0` minutes. Database rows are then mapped into their respective calendar dates.
- **Async Execution**: The chart query is invoked on a background utility queue from `SamplingCoordinator` and cached as an `@Published` property, ensuring zero disk I/O occurs on the main UI thread during menu bar interaction.

---

## 2. Live 1-Second Timer Architecture & Battery Performance

### Cosmetic-Only UI Interpolation
The menu bar dashboard provides real-time feedback when plugged in past the charge limit, displaying a ticking counter (e.g., `Overcharging: 4m 12s`).

To prevent the classic architecture bug of competing timers ("dual-timer double-counting"):
- **Zero-Write Guarantee**: The 1-second UI timer (`Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()`) is purely display-side in `MenuBarView.swift`. It increments a local SwiftUI `@State private var liveOverchargeSeconds: Double` value.
- **Source of Truth**: `ChargeSessionTracker` running inside `SamplingCoordinator` remains the single source of truth, sampling every 5 seconds and recording discrete delta intervals into SQLite.
- **Resynchronization**: Whenever `SamplingCoordinator` emits a new 5-second tick, or when an active session snapshot changes, `MenuBarView` re-anchors `liveOverchargeSeconds` to the coordinator's verified database-backed value:
  ```swift
  .onChange(of: coordinator.activeSession?.secondsSpentAtOrAboveLimit) { _ in
      syncLiveOverchargeFromCoordinator()
  }
  ```
- **Energy Efficiency**: The 1-second display timer only increments the counter when the battery is actively connected to AC power and charge percentage >= configured limit. When on battery or when the popover is closed, no database writes or disk wakeups occur.

---

## 3. Launch at Login Implementation (`SMAppService`)

### Modern Service Management
BatteryGuard avoids the legacy and deprecated `SMLoginItemSetEnabled` API (deprecated since macOS 13) in favor of the modern `ServiceManagement.SMAppService.mainApp` API.

### Implementation Details (`LaunchAtLoginManager.swift`):
- **Direct App Service Registration**:
  ```swift
  let service = SMAppService.mainApp
  try service.register() // or service.unregister()
  ```
- **State Synchronization**:
  Monitors `service.status`:
  - `.enabled`: Toggle shows active.
  - `.requiresApproval`: Alerts the user that System Settings > General > Login Items requires manual approval.
  - `.notRegistered` / `.notFound`: Gracefully handles sandboxed and test execution environments without crashing.
- **User Privacy & Transparency**: The toggle is cleanly exposed in the dashboard footer alongside an explicit Quit button, complying with Apple's Human Interface Guidelines for menu bar utility applications.
