# BatteryGuard

BatteryGuard is a lightweight, modern macOS menu bar application built with Swift and SwiftUI targeting macOS 13.0+. It runs purely in the menu bar (`LSUIElement = true`) without a Dock icon, tracking real-time battery hardware telemetry and monitoring battery overcharge exposure via a local SQLite store.

---

## Features

- **SwiftUI MenuBarExtra**: Native macOS 13+ `.window` style interface supporting custom scrollable timelines and real-time telemetry cards.
- **Low-Level IOKit Telemetry**:
  - State of Charge percentage (`IOPSCopyPowerSourcesInfo`)
  - Precise charging states (`charging`, `discharging`, `full`, `not charging`)
  - Hardware cycle count and raw capacity (`AppleSmartBattery`)
  - Temperature, voltage, and real-time current draw (amperage)
- **Estimated Battery Health**:
  - Transparently calculated as $\frac{\text{NominalChargeCapacity}}{\text{DesignCapacity}} \times 100$.
  - Clearly labeled as an estimated hardware ratio with info tooltips distinguishing it from Apple's entitlement-gated proprietary Battery Health algorithm.
- **SQLite Charge Session Store**:
  - Persistent SQLite3 store running in `WAL` mode (`batteryguard.sqlite`).
  - Records session start/end timestamps, max charge reached, and overcharge durations.
- **Robust Session Lifecycle Engine**:
  - **Overcharge Timers**: Tracks seconds spent at or above the configured charge limit (e.g. $\ge 80\%$) and seconds spent at $100\%$.
  - **Sleep / Wake Accounting**: Registers for `NSWorkspace.willSleepNotification` and `NSWorkspace.didWakeNotification`. If the battery was at/above limit before sleep and remains plugged in on wake, credits the elapsed sleep duration to the overcharge counter.
  - **Crash & Restart Recovery**: Detects orphaned sessions (`end_time IS NULL`) on app launch and resumes tracking if still on AC power, or closes the session with the last recorded sample timestamp if on battery.
  - **Rapid Plug/Unplug Debounce**: 12-second grace period on AC disconnect to avoid splitting sessions when cables are bumped.
  - **Delta-Time Capping**: Periodic ticks cap $\Delta t$ at `samplingInterval * 2` as a safety net against delayed timer wakeups.
  - **Aggregate Queries**: Real-time aggregation of overcharge exposure today and this week.

---

## Explicit Design Boundaries (MVP Scope)

> ### ⚠️ Documented Constraint: Offline Charging Events
> Charge sessions and overcharge timers are tracked while BatteryGuard is running. Unplug and replug cycles that occur while the app is completely closed/quit are not observable by BatteryGuard until the app is launched. (This will be fully mitigated by the launch-at-login feature in an upcoming phase). Crash recovery covers unexpected termination mid-session, but does not infer events that occurred while the app was powered off or not running.
>
> ### 📅 Midnight-Spanning Sessions
> For the MVP phase, aggregate overcharge statistics (today / this week) attribute a session's overcharge duration to the calendar day of that session's `start_time`.

---

## Directory Structure

```
.
├── project.yml                          # XcodeGen declarative project specification
├── BatteryGuard.xcodeproj               # Generated Xcode project
├── Sources/
│   ├── App/
│   │   └── BatteryGuardApp.swift        # App entry point using MenuBarExtra(.window)
│   ├── Collectors/
│   │   ├── CollectorProtocol.swift      # MetricCollector protocol & MetricSample model
│   │   ├── BatteryCollector.swift       # IOKit battery telemetry reader
│   │   ├── ChargeSessionTracker.swift   # Charge session state machine & overcharge logic
│   │   └── SamplingCoordinator.swift   # Orchestrator running background loop & observers
│   ├── CLI/
│   │   └── main.swift                   # Dedicated CLI debug tool (5s polling loop)
│   ├── Storage/
│   │   └── MetricsStorage.swift         # SQLiteMetricsStore (WAL mode) & InMemoryMetricsStorage
│   └── UI/
│       ├── MenuBarView.swift            # Menu bar popup with telemetry & overcharge cards
│       └── TimelineView.swift           # Horizontal scrollable telemetry timeline
└── build/
    └── Debug/
        ├── BatteryGuard.app             # Universal app bundle (arm64 + x86_64)
        └── BatteryGuardCLI              # Universal command-line tool (arm64 + x86_64)
```

---

## Building and Running

### Prerequisites
- macOS 13.0 or later
- Xcode 15+ / Command Line Tools
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

### Generate Xcode Project
```bash
xcodegen generate
```

### Build Universal Binaries
```bash
# Build Menu Bar App
xcodebuild -project BatteryGuard.xcodeproj -scheme BatteryGuard -configuration Debug ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO build

# Build CLI Monitor
xcodebuild -project BatteryGuard.xcodeproj -scheme BatteryGuardCLI -configuration Debug ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO build
```

### Run the CLI Debug Monitor
To inspect live IOKit telemetry, session state, and today/week overcharge totals:
```bash
./build/Debug/BatteryGuardCLI
```

### Run the Menu Bar App
```bash
open "build/Debug/BatteryGuard.app"
```
