import Foundation

public enum Strength {
    public static let minPercent = -50.0
    public static let maxPercent = 200.0
    public static let defaultPercent = 40.0

    public static let bodyMaxPercent = 75.0
    public static let widthMaxPercent = 200.0
    public static let widthDefaultPercent = 100.0
    // Laptop speakers are close together; a modest side boost widens the image without phasiness.
    public static let widthLaptopPercent = 140.0

    public static func clampBody(_ percent: Double) -> Double {
        min(max(percent, minPercent), bodyMaxPercent)
    }

    public static func clamp(_ percent: Double) -> Double {
        min(max(percent, minPercent), maxPercent)
    }
}

public final class Prefs: ObservableObject {
    private let defaults = UserDefaults.standard

    @Published public var enabled: Bool {
        didSet { defaults.set(enabled, forKey: "enabled"); onChange?() }
    }
    @Published public var percent: Double {
        didSet { defaults.set(percent, forKey: "percent"); onChange?() }
    }
    @Published public var bassPercent: Double {
        didSet { defaults.set(bassPercent, forKey: "bassPercent"); onChange?() }
    }
    @Published public var widthPercent: Double {
        didSet { defaults.set(widthPercent, forKey: "widthPercent"); onChange?() }
    }
    @Published public var preventClipping: Bool {
        didSet { defaults.set(preventClipping, forKey: "preventClipping"); onChange?() }
    }
    @Published public var showPercentages: Bool {
        didSet { defaults.set(showPercentages, forKey: "showPercentages") }
    }
    @Published public var lowLatency: Bool {
        didSet { defaults.set(lowLatency, forKey: "lowLatency"); onDeviceChange?() }
    }
    @Published public var outputUID: String? {
        didSet { defaults.set(outputUID, forKey: "outputUID"); onDeviceChange?() }
    }

    public var onChange: (() -> Void)?
    public var onDeviceChange: (() -> Void)?

    public init() {
        enabled = defaults.object(forKey: "enabled") as? Bool ?? true
        let p = defaults.object(forKey: "percent") as? Double ?? Strength.defaultPercent
        percent = Strength.clamp(p)
        bassPercent = Strength.clampBody(defaults.object(forKey: "bassPercent") as? Double ?? 0)
        widthPercent = min(max(defaults.object(forKey: "widthPercent") as? Double ?? Strength.widthDefaultPercent, 0),
                           Strength.widthMaxPercent)
        preventClipping = defaults.object(forKey: "preventClipping") as? Bool ?? false
        showPercentages = defaults.object(forKey: "showPercentages") as? Bool ?? false
        lowLatency = defaults.object(forKey: "lowLatency") as? Bool ?? false
        outputUID = defaults.string(forKey: "outputUID")
    }
}
