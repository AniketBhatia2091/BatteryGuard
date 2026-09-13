import SwiftUI

@main
struct BatteryGuardApp: App {
    @StateObject private var coordinator: SamplingCoordinator

    init() {
        let coord = SamplingCoordinator()
        _coordinator = StateObject(wrappedValue: coord)
        coord.start()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(coordinator: coordinator)
        } label: {
            let isCharging = coordinator.latestBatterySnapshot?.isCharging ?? false
            let percent = coordinator.latestBatterySnapshot?.percentage ?? 100.0

            HStack(spacing: 4) {
                Image(systemName: isCharging ? "battery.100.bolt" : "battery.100")
                Text("\(Int(percent))%")
            }
        }
        .menuBarExtraStyle(.window)
    }
}
