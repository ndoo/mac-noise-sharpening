import AppKit
import NSKit
import SwiftUI

// Thin track, fill from `origin` to the knob, pill knob and a dot at each mark.
struct BalanceSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let origin: Double
    let marks: [Double]
    let lowLabel: String
    let highLabel: String
    let title: String
    var note: String?
    var noteHelp: String?

    private let knobWidth: CGFloat = 10
    private let knobHeight: CGFloat = 18
    private let trackHeight: CGFloat = 4

    @Environment(\.isEnabled) private var isEnabled
    @FocusState private var focused: Bool
    @State private var drag = DetentDrag()

    private func set(_ v: Double) {
        value = min(max(v.rounded(), range.lowerBound), range.upperBound)
    }

    var body: some View {
        GeometryReader { geo in
            let travel = geo.size.width - knobWidth
            let x = { (v: Double) -> CGFloat in
                knobWidth / 2 + travel * CGFloat((v - range.lowerBound) / (range.upperBound - range.lowerBound))
            }
            let trackY: CGFloat = 10
            ZStack(alignment: .topLeading) {
                Capsule().fill(Color.secondary.opacity(0.3))
                    .frame(width: travel, height: trackHeight)
                    .offset(x: knobWidth / 2, y: trackY - trackHeight / 2)
                Capsule().fill(Color.accentColor)
                    .frame(width: abs(x(value) - x(origin)), height: trackHeight)
                    .offset(x: min(x(value), x(origin)), y: trackY - trackHeight / 2)
                ForEach(marks, id: \.self) { m in
                    Circle().fill(Color.secondary.opacity(0.8)).frame(width: 2, height: 2)
                        .offset(x: x(m) - 1, y: trackY + 6)
                }
                Text(lowLabel).offset(x: knobWidth / 2, y: trackY + 9)
                if let note {
                    Text(note).foregroundColor(.accentColor)
                        .frame(width: geo.size.width, alignment: .center)
                        .offset(y: trackY + 9)
                        .help(noteHelp ?? "")
                }
                Text(highLabel).frame(width: 20, alignment: .trailing)
                    .offset(x: geo.size.width - knobWidth / 2 - 20, y: trackY + 9)
                Capsule().fill(Color(nsColor: .controlColor))
                    .shadow(color: .black.opacity(0.3), radius: 1, y: 0.5)
                    .frame(width: knobWidth, height: knobHeight)
                    .overlay(Capsule().stroke(Color.accentColor, lineWidth: 2).opacity(focused ? 1 : 0))
                    .offset(x: x(value) - knobWidth / 2, y: trackY - knobHeight / 2)
            }
            .font(.system(size: 10))
            .foregroundColor(.secondary)
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                guard isEnabled else { return }
                let f = min(max(Double((g.location.x - knobWidth / 2) / travel), 0), 1)
                let raw = (range.lowerBound + f * (range.upperBound - range.lowerBound)).rounded()
                let detents = marks.map { DetentDrag.Detent(value: $0, x: Double(x($0))) }
                set(drag.update(x: Double(g.location.x), raw: raw, detents: detents))
            }.onEnded { _ in drag.end() })
        }
        .frame(height: 34)
        .focusable(isEnabled)
        .focused($focused)
        .onMoveCommand { direction in
            switch direction {
            case .left, .down: set(value - 1)
            case .right, .up: set(value + 1)
            @unknown default: break
            }
        }
        .accessibilityRepresentation {
            Slider(value: Binding(get: { value }, set: { set($0) }), in: range, step: 5) { Text(title) }
        }
    }
}

struct MenuItemButton: View {
    let title: String
    let shortcut: String
    let action: () -> Void
    @State private var hovering = false

    init(_ title: String, shortcut: String, action: @escaping () -> Void) {
        self.title = title
        self.shortcut = shortcut
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                Text(shortcut).opacity(hovering ? 1 : 0.6)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity)
            .foregroundColor(hovering ? .white : .primary)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(hovering ? Color.accentColor : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct SwitchRow: View {
    let title: String
    @Binding var isOn: Bool

    init(_ title: String, isOn: Binding<Bool>) {
        self.title = title
        _isOn = isOn
    }

    var body: some View {
        HStack {
            Text(title).accessibilityHidden(true)
            Spacer()
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityLabel(title)
        }
    }
}

struct PercentValue: View {
    let value: String
    var muted = false

    var body: some View {
        HStack(spacing: 0) {
            if muted {
                Text("Muted").frame(width: 39, alignment: .trailing)
            } else {
                Text(value).monospacedDigit().lineLimit(1).fixedSize().frame(width: 27, alignment: .leading)
                Text("%").frame(width: 12, alignment: .trailing)
            }
        }
        .frame(width: 40, alignment: .trailing)
    }
}

// SwiftUI's menu-style Picker keeps its intrinsic width; an NSPopUpButton fills the width it is given.
struct OutputPopUp: NSViewRepresentable {
    let items: [(uid: String, name: String)]
    let selection: String
    let onSelect: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onSelect: onSelect) }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.setAccessibilityLabel("Output")
        button.target = context.coordinator
        button.action = #selector(Coordinator.changed(_:))
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.onSelect = onSelect
        let titles = items.map(\.name)
        if button.itemTitles != titles {
            button.removeAllItems()
            for item in items {
                button.addItem(withTitle: item.name)
                button.lastItem?.representedObject = item.uid
            }
        }
        if let index = items.firstIndex(where: { $0.uid == selection }) {
            button.selectItem(at: index)
        }
    }

    final class Coordinator: NSObject {
        var onSelect: (String) -> Void
        init(onSelect: @escaping (String) -> Void) { self.onSelect = onSelect }

        @objc func changed(_ sender: NSPopUpButton) {
            onSelect(sender.selectedItem?.representedObject as? String ?? "")
        }
    }
}
