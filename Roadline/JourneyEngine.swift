import Foundation

enum JourneyEngine {
    static func distance(_ a: RoutePoint, _ b: RoutePoint) -> Double {
        let p = Double.pi / 180, lat1 = a.latitude * p, lat2 = b.latitude * p
        let dLat = lat2 - lat1, dLon = (b.longitude - a.longitude) * p
        let h = pow(sin(dLat / 2), 2) + cos(lat1) * cos(lat2) * pow(sin(dLon / 2), 2)
        return 12_742_000 * asin(sqrt(min(1, max(0, h))))
    }
    static func record(_ point: RoutePoint, in trip: inout Trip) {
        guard trip.status == .tracking, point.accuracy > 0, point.accuracy <= 65,
              point.latitude.isFinite, point.longitude.isFinite,
              (-90...90).contains(point.latitude), (-180...180).contains(point.longitude) else { return }
        guard let anchor = trip.route.last else { trip.route = [point]; trip.raw = point; return }
        let elapsed = point.time - anchor.time
        guard elapsed > 0 else { return }
        let meters = distance(anchor, point), observed = meters / elapsed
        var stationary = false, rawElapsed = 0.0
        if let raw = trip.raw {
            rawElapsed = point.time - raw.time
            let rawDistance = distance(raw, point)
            if rawElapsed > 0 && rawElapsed <= 30 {
                if let a = raw.speed, let b = point.speed { stationary = a < 0.5 && b < 0.5 }
                else { stationary = rawDistance / rawElapsed < 0.5 && rawDistance < max(5, (raw.accuracy + point.accuracy) * 0.7) }
            }
        }
        let freshAnchor = elapsed > 30
        let accepted = !freshAnchor && meters <= max(100, 75 * elapsed)
            && meters >= max(5, (anchor.accuracy + point.accuracy) * 0.7)
            && ((point.speed ?? 0) >= 1.2 || observed >= 1.5) && !stationary
        let speed = (point.speed ?? 0) >= 1.2 ? point.speed! * 3.6 : observed * 3.6
        let curve = E32.estimate(speed)?.liters
        let idleFuel = stationary ? max(0, trip.idleRate) * rawElapsed / 3600 : 0
        if accepted {
            trip.meters += meters
            trip.driving += elapsed
            if trip.prediction { trip.predicted += (curve ?? 0) * meters / 100_000 }
            let rate = trip.legs.contains { $0.fuel != nil } ? trip.rangeEconomy : (trip.prediction ? curve ?? trip.referenceEconomy : trip.referenceEconomy)
            trip.rangeFuel += rate * meters / 100_000
            // Do not count stationary intervals twice in the rolling window.
            let start = max(anchor.time, trip.intervals.last?.end ?? anchor.time)
            if point.time > start { trip.intervals.append(SpeedInterval(start: start, end: point.time, meters: meters)) }
        } else if stationary, let raw = trip.raw {
            trip.intervals.append(SpeedInterval(start: raw.time, end: point.time, meters: 0))
        }
        if stationary { trip.idle += rawElapsed; trip.rangeFuel += idleFuel; if trip.prediction { trip.predicted += idleFuel } }
        if accepted || freshAnchor {
            if trip.route.count >= 1500 { trip.route = trip.route.enumerated().filter { $0.offset % 2 == 0 }.map(\.element) }
            trip.route.append(point)
        }
        trip.intervals.removeAll { $0.end <= point.time - 300 }
        trip.raw = point
    }
    static func seal(_ trip: inout Trip, now: Double) {
        if !trip.route.isEmpty || trip.meters > 0 || trip.idle > 0 {
            trip.legs.append(Leg(number: trip.legs.count + 1, start: trip.legStart, end: now,
                meters: trip.meters, driving: trip.driving, route: trip.route,
                predicted: trip.predicted, idle: trip.idle, rangeFuel: trip.rangeFuel))
        }
        trip.legStart = now; trip.meters = 0; trip.driving = 0; trip.route = []
        trip.predicted = 0; trip.idle = 0; trip.rangeFuel = 0; trip.raw = nil; trip.intervals = []
    }
}
