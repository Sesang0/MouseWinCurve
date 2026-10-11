import Foundation
import CoreGraphics

/// Manually digitized from the supplied graph. Y is interpreted as gain.
/// X is HID counts per report, NOT counts per second. Beyond 75 we clamp.
struct PointerCurve {
    static let points: [(Double, Double)] = [
        (0,0.55),(1.5,0.57),(3,0.68),(4.5,0.75),(6,0.89),
        (8,0.98),(10,1.04),(12,1.09),(13.5,1.14),(15,1.34),
        (18,1.55),(21,1.70),(25,1.85),(30,1.99),(35,2.09),
        (40,2.17),(45,2.23),(50,2.28),(55,2.32),(60,2.35),
        (65,2.38),(70,2.40),(75,2.41)
    ]
    static func gain(_ distance: Double) -> Double {
        guard distance.isFinite else { return 1 }
        let x = max(0, distance)
        for i in 1..<points.count where x <= points[i].0 {
            let (x0,y0) = points[i-1], (x1,y1) = points[i]
            return y0 + (y1-y0) * (x-x0)/(x1-x0)
        }
        return points.last!.1
    }
    static func advance(_ p: CGPoint, dx: Double, dy: Double, enabled: Bool,
                        scaleX: Double, scaleY: Double, bounds: CGRect, speed: Double = 1) -> CGPoint {
        let g = enabled ? gain(hypot(dx,dy)) : 1
        // Preserve fractional movement internally, and remove overshoot at edges.
        return CGPoint(x: min(max(p.x + dx*g*speed/scaleX, bounds.minX), bounds.maxX - 1/scaleX),
                       y: min(max(p.y + dy*g*speed/scaleY, bounds.minY), bounds.maxY - 1/scaleY))
    }
}

struct UnlockShortcut {
    static func matches(keyCode: Int64, flags: CGEventFlags) -> Bool {
        keyCode == 53 && flags.contains(.maskCommand)
    }
}

/// Keep native event type, source, flags, click count and button identity intact.
/// Only replace the geometry calculated by the raw-HID pointer pipeline.
struct PointerEvent {
    static func isStationaryMove(type:CGEventType,to point:CGPoint,previous:CGPoint) -> Bool {
        type == .mouseMoved && point == previous
    }
    static func retarget(_ event: CGEvent, to point: CGPoint, previous: CGPoint) {
        event.location = point
        event.setDoubleValueField(.mouseEventDeltaX, value: point.x - previous.x)
        event.setDoubleValueField(.mouseEventDeltaY, value: point.y - previous.y)
    }
}

struct SpeedMath {
    // Classic 11-notch, EPP-off style multipliers. EPP-on remains our graph approximation.
    static let factors: [Double] = [1.0/32,1.0/16,0.25,0.5,0.75,1,1.5,2,2.5,3,3.5]
    static func pointer(_ step: Int) -> Double { factors[min(11,max(1,step))-1] }
    // App-defined fine adjustment, not an assertion about Riot's internal formula.
    static func league(_ value: Int) -> Double { pow(2,Double(min(100,max(0,value))-50)/25) }
    static func isLeagueGame(bundleID: String?, executable: String?) -> Bool {
        bundleID == "com.riotgames.LeagueofLegends.GameClient" && executable == "LeagueofLegends"
    }
}


struct LockPolicy {
    static func waits(onlyGame:Bool,gameForeground:Bool) -> Bool { onlyGame && !gameForeground }
}

// X and Y elements from one report share a timestamp; count that report once.
struct HIDRateMeter {
    private var lastStamp: UInt64?
    private var lastDevice: UInt64?
    private(set) var count = 0
    mutating func record(stamp:UInt64,device:UInt64) {
        guard lastStamp != stamp || lastDevice != device else { return }
        lastStamp = stamp; lastDevice = device; count += 1
    }
    mutating func sample(elapsed:Double) -> Int {
        guard elapsed > 0 else { return 0 }
        let result = Int((Double(count)/elapsed).rounded())
        count = 0
        return result
    }
}

// Pending run-loop work belongs to exactly one activation. Native-event drains
// do not release this reservation; only the queued block can do that.
struct InputSession {
    private(set) var generation: UInt64 = 0
    private var queued = false
    mutating func reset() { generation &+= 1; queued = false }
    mutating func schedule() -> UInt64? {
        guard !queued else { return nil }
        queued = true; return generation
    }
    mutating func consume(_ token: UInt64) -> Bool {
        guard token == generation, queued else { return false }
        queued = false; return true
    }
}
