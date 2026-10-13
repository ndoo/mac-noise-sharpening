import NSKit
import ServiceManagement
import SwiftUI

struct MenuView: View {
    @ObservedObject var controller: Controller
    @ObservedObject var settings: Prefs
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    private static let snapPoints = [0.0, Strength.defaultPercent]

    private static let labelCell: CGFloat = 70
    private static let labelInset: CGFloat = 8
    private static let contentInset: CGFloat = 10
    private static let valueInset: CGFloat = 8

    private func formula(_ name: String, _ variable: String, _ expression: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            (Text(name + " (") + Text(variable).font(.system(size: 13, design: .serif)).italic() + Text("):"))
                .frame(width: 56, alignment: .trailing)
            Text(expression).font(.system(size: 13, design: .serif)).italic()
        }
    }

    // Label cell, divider and control area in one rounded container, as in Audio MIDI Setup.
    private func sliderRow<S: View>(_ title: String, _ value: String, active: Bool = true, muted: Bool = false,
                                    @ViewBuilder slider: () -> S) -> some View {
        HStack(spacing: 0) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: Self.labelCell - Self.labelInset, alignment: .trailing)
                .padding(.trailing, Self.labelInset)
                .frame(maxHeight: .infinity)
                .background(Color(nsColor: .shadowColor).opacity(0.22))
                .accessibilityHidden(true)
            Rectangle().fill(Color.primary.opacity(0.15)).frame(width: 1)
            slider()
                .frame(maxWidth: .infinity)
                .padding(.horizontal, Self.contentInset)
                .padding(.vertical, 4)
            if settings.showPercentages {
                Rectangle().fill(Color.primary.opacity(0.15)).frame(width: 1)
                PercentValue(value: value, muted: muted)
                    .padding(.horizontal, Self.valueInset)
                    .frame(maxHeight: .infinity)
                    .accessibilityHidden(true)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .background(Color.primary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.primary.opacity(0.15)))
        .disabled(!active)
        .opacity(active && !muted ? 1 : 0.4)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SwitchRow("Enabled", isOn: $settings.enabled)
            SwitchRow("Prevent clipping", isOn: $settings.preventClipping)
                .disabled(!settings.enabled)
                .opacity(settings.enabled ? 1 : 0.4)
                .help("Scales the output so it can't exceed the input's peak level, and raises the volume to make up the loudness it removes.")
            HStack(spacing: 0) {
                Text("Output").frame(width: Self.labelCell - Self.labelInset, alignment: .trailing)
                Spacer().frame(width: Self.labelInset + 1 + Self.contentInset)
                OutputPopUp(
                    items: [("", "System default")] + controller.devices.map { ($0.uid, $0.name) },
                    selection: settings.outputUID ?? "",
                    onSelect: { settings.outputUID = $0.isEmpty ? nil : $0 })
                    .frame(maxWidth: .infinity)
                    .padding(.trailing, settings.showPercentages ? Self.valueInset : Self.contentInset)
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                sliderRow("Body", "\(Int(settings.bassPercent))", active: settings.enabled) {
                    BalanceSlider(value: Binding(
                        get: { settings.bassPercent },
                        set: { settings.bassPercent = $0 }),
                        range: Strength.minPercent...Strength.bodyMaxPercent,
                        origin: 0, marks: Self.snapPoints, lowLabel: "-50", highLabel: "75", title: "Body")
                }
                sliderRow("Air", "\(Int(settings.percent))", active: settings.enabled) {
                    BalanceSlider(value: Binding(
                        get: { settings.percent },
                        set: { settings.percent = $0 }),
                        range: Strength.minPercent...Strength.maxPercent,
                        origin: 0, marks: Self.snapPoints, lowLabel: "-50", highLabel: "200", title: "Air")
                }
                sliderRow("Stereo", "\(Int(settings.widthPercent))", active: settings.enabled) {
                    BalanceSlider(value: Binding(
                        get: { settings.widthPercent },
                        set: { settings.widthPercent = $0 }),
                        range: 0...Strength.widthMaxPercent,
                        origin: Strength.widthDefaultPercent,
                        marks: [Strength.widthDefaultPercent, Strength.widthLaptopPercent],
                        lowLabel: "0", highLabel: "200", title: "Stereo")
                }
                if let volume = controller.volume {
                    sliderRow("Volume", "\(Int((volume * 100).rounded()))", muted: controller.muted) {
                        BalanceSlider(value: Binding(
                            get: { Double(volume * 100) },
                            set: { controller.setOutputVolume(Float($0.rounded() / 100)) }),
                            range: 0...100, origin: 0, marks: [], lowLabel: "0", highLabel: "100", title: "Volume",
                            note: controller.limited ? "Clip-limited" : nil,
                            noteHelp: "Volume is at maximum, so the loudness lost to Prevent clipping can't be fully made up.")
                    }
                }
            }
            SwitchRow("Display percentages", isOn: $settings.showPercentages)
            SwitchRow("Low latency", isOn: $settings.lowLatency)
                .help("Requests 128-frame audio buffers on BlackHole and the output device and keeps less audio queued. Lowers the delay, but may click on a busy system or with some devices.")
            SwitchRow("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { on in
                    try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                }
            if !controller.keysActive {
                Button("Volume keys need Accessibility access…") {
                    controller.startKeyTap(prompt: true)
                    if let url = URL(string: "x-apple.systemsettings:com.apple.preference.security?Privacy_Accessibility") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.link).font(.caption)
            }
            if controller.blackHoleMissing {
                VStack(alignment: .leading, spacing: 4) {
                    Text("BlackHole is not installed. It carries the system audio into this app.")
                        .foregroundColor(.red).font(.caption)
                    HStack {
                        Button("Get BlackHole…") {
                            if let url = URL(string: "https://existential.audio/blackhole/") { NSWorkspace.shared.open(url) }
                        }
                        Button("Retry") { controller.restart() }
                    }
                }
            } else if let error = controller.error {
                Text(error).foregroundColor(.red).font(.caption)
                Button("Retry") { controller.restart() }
            }
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Text("Air re-implements foobar2000's Noise Sharpening plugin ([foo_dsp_delta](https://foobar.hyv.fi/?view=foo_dsp_delta)). Body is the same filter with the delayed sample inverted, which boosts the opposite end of the spectrum.")
                VStack(alignment: .leading, spacing: 4) {
                    formula("Air", "a", "y[n] = x[n] + a·(x[n] − x[n−1])")
                    formula("Body", "b", "y[n] = x[n] + b·(x[n] + x[n−1])")
                    formula("Stereo", "w", "L′ = M + w·S,  R′ = M − w·S")
                }
                .fixedSize()
                .frame(maxWidth: .infinity)
            }
            .font(.caption)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            Divider()
            MenuItemButton("Quit Noise Sharpening", shortcut: "⌘Q") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
        .padding(12)
        .frame(width: 320)
        .onAppear {
            controller.refreshDevices()
            controller.refreshVolume()
            controller.refreshMute()
        }
    }
}
