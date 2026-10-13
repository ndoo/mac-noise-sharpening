import Foundation

var failures = 0
func check(_ cond: Bool, _ msg: String, line: Int = #line) {
    if !cond { print("FAIL line \(line): \(msg)"); failures += 1 }
}

// 1 point per value unit, detent value 40 at x = 140 (range starts at -100).
func raw(_ x: Double) -> Double { x - 100 }
let detents = [DetentDrag.Detent(value: 40, x: 140)]
func drive(_ d: inout DetentDrag, _ xs: [Double]) -> [Double] {
    xs.map { d.update(x: $0, raw: raw($0), detents: detents) }
}

var d = DetentDrag(holdWidth: 8)
// Approach from the left: tracks the cursor, stops at the detent, holds, then jumps.
var out = drive(&d, [120, 130, 139, 141, 145, 148, 149, 160])
check(out[0] == 20 && out[1] == 30 && out[2] == 39, "tracks before detent \(out)")
check(out[3] == 40 && out[4] == 40 && out[5] == 40, "holds at detent \(out)")
check(out[6] == 49 && out[7] == 60, "releases after holdWidth with a jump \(out)")

// Overshoot, then drag back: tracks the cursor smoothly (precise value just past the detent).
out = drive(&d, [155, 152, 147, 143])
check(out[0] == 55 && out[1] == 52, "tracks back after release \(out)")
check(out[2] == 47 && out[3] == 43, "no re-stick before reaching the detent again \(out)")
// Reaching the detent from the right sticks, then releases on the left side.
out = drive(&d, [140, 136, 132, 131, 120])
check(out[0] == 40 && out[1] == 40 && out[2] == 40, "sticks from the right \(out)")
check(out[3] == 31 && out[4] == 20, "releases on the left \(out)")
d.end()

// First event is never stuck, even on top of a detent.
d = DetentDrag(holdWidth: 8)
check(d.update(x: 142, raw: raw(142), detents: detents) == 42, "first event follows the cursor")
d.end()

// A fast jump far past the detent does not stick.
d = DetentDrag(holdWidth: 8)
out = drive(&d, [100, 190])
check(out[1] == 90, "jump past the hold zone is not stuck \(out)")
d.end()

// A jump that lands inside the hold zone sticks.
d = DetentDrag(holdWidth: 8)
out = drive(&d, [100, 144])
check(out[1] == 40, "lands inside the hold zone \(out)")

// Crossing back over the detent while stuck sticks on the other side.
out = drive(&d, [141, 139, 135, 131])
check(out == [40, 40, 40, 31], "stuck across the detent \(out)")

// Two detents: nearest to the previous position wins.
d = DetentDrag(holdWidth: 8)
let two = [DetentDrag.Detent(value: 40, x: 140), DetentDrag.Detent(value: 45, x: 145)]
_ = d.update(x: 120, raw: 20, detents: two)
check(d.update(x: 146, raw: 46, detents: two) == 40, "nearest detent first")

// Trace recorded from Audio MIDI Setup's Balance slider (detent at the centre, cursor offsets in
// points; raw value equals the offset here). It holds 4 points past the detent and releases at 6.
d = DetentDrag(holdWidth: 5)
let centre = [DetentDrag.Detent(value: 0, x: 0)]
let offsets: [Double] = [-20, -10, -4, -2, 0, 2, 4, 6, 8, 12, 10, 8, 6, 4, 2, 0, -2, -4, -6, -8, -10, -4, -2, 0, 2, 4, 6, 8, 10]
let expected: [Double] = [-20, -10, -4, -2, 0, 0, 0, 6, 8, 12, 10, 8, 6, 4, 2, 0, 0, 0, -6, -8, -10, -4, -2, 0, 0, 0, 6, 8, 10]
let trace = offsets.map { d.update(x: $0, raw: $0, detents: centre) }
// The recorded drag started on the knob, so its first event follows the cursor.
check(trace == expected, "AMS trace \(trace)")

print(failures == 0 ? "detent tests passed" : "\(failures) failures")
exit(failures == 0 ? 0 : 1)
