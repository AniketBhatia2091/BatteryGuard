import SwiftUI

@main
struct BatteryGuardApp: App {
    @StateObject private var coordinator: SamplingCoordinator

    init() {
        let coord = SamplingCoordinator()
        _coordinator = StateObject(wrappedValue: coord)
        coord.start()
        MenuBarIconProvider.registerIfNeeded()
    }

    var body: some Scene {
        MenuBarExtra("BatteryGuard", image: "MenuBarIcon") {
            MenuBarView(coordinator: coordinator)
        }
        .menuBarExtraStyle(.window)
    }
}
