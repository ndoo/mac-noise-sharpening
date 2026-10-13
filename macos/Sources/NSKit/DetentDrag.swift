// Sticky detents for a dragged slider. The value stops when the cursor reaches a detent, holds for
// `holdWidth` points of further travel in the same direction, then follows the cursor again.
// Dragging back across the detent sticks again, so values just past a detent stay reachable.
public struct DetentDrag {
    public struct Detent {
        public let value: Double
        public let x: Double
        public init(value: Double, x: Double) {
            self.value = value
            self.x = x
        }
    }

    public var holdWidth: Double
    private var lastX: Double?
    private var stuck: (detent: Detent, direction: Double)?

    public init(holdWidth: Double = 5) {
        self.holdWidth = holdWidth
    }

    // `raw` is the value under the cursor; the result is the value to show.
    public mutating func update(x: Double, raw: Double, detents: [Detent]) -> Double {
        defer { lastX = x }
        guard let last = lastX else { return raw }

        if let s = stuck {
            let travel = (x - s.detent.x) * s.direction
            if travel >= 0 && travel <= holdWidth { return s.detent.value }
            stuck = nil
        }

        guard x != last else { return raw }
        let direction: Double = x > last ? 1 : -1
        let crossed = detents.filter { d in
            direction > 0 ? (last < d.x && d.x <= x) : (x <= d.x && d.x < last)
        }
        // A cursor that jumped well past the detent is already beyond its hold zone.
        if let hit = crossed.min(by: { abs($0.x - last) < abs($1.x - last) }),
           abs(x - hit.x) <= holdWidth {
            stuck = (hit, direction)
            return hit.value
        }
        return raw
    }

    public mutating func end() {
        lastX = nil
        stuck = nil
    }
}
