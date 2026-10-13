import SwiftUI

@main
struct NoiseSharpeningApp: App {
    @StateObject private var controller = Controller()

    var body: some Scene {
        MenuBarExtra("Noise Sharpening", systemImage: controller.settings.enabled ? "waveform.badge.plus" : "waveform") {
            MenuView(controller: controller, settings: controller.settings)
        }
        .menuBarExtraStyle(.window)
    }
}
