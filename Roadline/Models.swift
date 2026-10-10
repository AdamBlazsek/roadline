import Foundation

enum TripStatus: String, Codable { case tracking = "TRACKING", paused = "PAUSED", completed = "COMPLETED" }
enum Palette: String, Codable, CaseIterable { case roadline = "Roadline", ocean = "Ocean", sunset = "Sunset", bmw = "BMW Night" }
enum Typeface: String, Codable, CaseIterable { case system = "System", classic = "Classic", technical = "Technical", bmw = "BMW Cluster" }
struct Settings: Codable, Equatable {
    var keepScreenOn = false
    var prediction = false
    var idleRate = 1.4
    var palette = Palette.roadline
    var typeface = Typeface.system
    var motion = true
    var textScale = 1.0
    var speedFraction = 0.64
    var supportScale = 1.0
    var tankCapacity = 0.0
    var startingFuel = 0.0
    var referenceEconomy = 10.5
}
struct RoutePoint: Codable, Sendable {
    var latitude: Double
    var longitude: Double
    var time: Double
    var accuracy: Double
    var speed: Double?
}
struct SpeedInterval: Codable {
    var start: Double
    var end: Double
    var meters: Double
}
struct Refill: Codable, Identifiable {
    var id = UUID().uuidString
    var time: Double
    var liters: Double
}
struct Leg: Codable, Identifiable {
    var id = UUID().uuidString
    var number: Int
    var start: Double
    var end: Double
    var meters: Double
    var driving: Double
    var fuel: Double?
    var route: [RoutePoint]
    var predicted: Double
    var idle: Double
    var rangeFuel: Double
    var averageSpeed: Double { driving > 0 ? meters / driving * 3.6 : 0 }
    var economy: Double? { fuel.flatMap { meters > 0 ? $0 / meters * 100_000 : nil } }
}
struct Trip: Codable, Identifiable {
    var id = UUID().uuidString
    var destination: String
    var start: Double
    var end: Double?
    var status = TripStatus.tracking
    var legs: [Leg] = []
    var legStart: Double
    var meters = 0.0
    var driving = 0.0
    var route: [RoutePoint] = []
    var predicted = 0.0
    var idle = 0.0
    var rangeFuel = 0.0
    var raw: RoutePoint?
    var intervals: [SpeedInterval] = []
    var prediction: Bool
    var idleRate: Double
    var plannedKm: Double?
    var tankCapacity: Double?
    var startingFuel: Double?
    var referenceEconomy: Double
    var totalMeters: Double { legs.reduce(meters) { $0 + $1.meters } }
    var totalDriving: Double { legs.reduce(driving) { $0 + $1.driving } }
    var totalIdle: Double { legs.reduce(idle) { $0 + $1.idle } }
    var totalPredicted: Double { legs.reduce(predicted) { $0 + $1.predicted } }
    var fuelUsed: Double { legs.reduce(0) { $0 + ($1.fuel ?? 0) } }
    var refills: [Refill] = []
    var averageSpeed: Double { totalDriving > 0 ? totalMeters / totalDriving * 3.6 : 0 }
    var economy: Double? {
        let measured = legs.filter { $0.fuel != nil && $0.meters > 0 }
        let distance = measured.reduce(0) { $0 + $1.meters }
        return distance > 0 ? measured.reduce(0) { $0 + ($1.fuel ?? 0) } / distance * 100_000 : nil
    }
    var predictedEconomy: Double? { totalMeters > 0 && totalPredicted > 0 ? totalPredicted / totalMeters * 100_000 : nil }
    var displayedEconomy: Double? { prediction ? predictedEconomy : economy }
    var displayedFuel: Double { prediction ? totalPredicted : fuelUsed }
    var remainingKm: Double? { plannedKm.map { max(0, $0 - totalMeters / 1000) } }
    var fuelRemaining: Double? {
        guard let initial = startingFuel, let capacity = tankCapacity else { return nil }
        let used = legs.reduce(rangeFuel) { $0 + ($1.fuel ?? $1.rangeFuel) }
        return min(capacity, max(0, initial + refills.reduce(0) { $0 + $1.liters } - used))
    }
    var rangeEconomy: Double {
        if let measured = economy, measured > 0 { return measured }
        if prediction && totalMeters >= 1000, let estimate = predictedEconomy { return estimate }
        return referenceEconomy
    }
    var rangeKm: Double? { fuelRemaining.map { $0 / max(1, rangeEconomy) * 100 } }
    func elapsed(_ now: Double) -> Double { max(0, (end ?? now) - start) }
    func recentSpeed(_ now: Double) -> Double? {
        guard let last = intervals.last, now >= last.end, now - last.end <= 30 else { return nil }
        var duration = 0.0, distance = 0.0
        for interval in intervals where interval.end > interval.start {
            let overlap = max(0, min(interval.end, now) - max(interval.start, now - 300))
            duration += overlap
            distance += interval.meters * overlap / (interval.end - interval.start)
        }
        return duration > 0 ? distance / duration * 3.6 : nil
    }
    func currentSpeed(_ now: Double) -> Double? {
        guard status == .tracking else { return 0 }
        guard let last = intervals.last, now >= last.end, now - last.end <= 30, last.end > last.start else { return nil }
        if last.meters == 0 { return 0 }
        let speed: Double
        if let raw = raw, raw.time == last.end, let measured = raw.speed, measured >= 1.2 { speed = measured * 3.6 }
        else { speed = last.meters / (last.end - last.start) * 3.6 }
        return speed.isFinite && (0...270).contains(speed) ? speed : nil
    }
    func currentConsumption(_ now: Double) -> (value: Double, unit: String)? {
        guard prediction else { return nil }
        if status != .tracking { return (0, "L/h") }
        guard let speed = currentSpeed(now) else { return nil }
        if speed == 0 { return (idleRate, "L/h") }
        return E32.estimate(speed).map { ($0.liters, "L/100 km") }
    }
    func etaSeconds(_ now: Double) -> Double? {
        guard status == .tracking, let remaining = remainingKm else { return nil }
        if remaining == 0 { return 0 }
        guard let speed = recentSpeed(now), speed >= 1 else { return nil }
        return remaining / speed * 3600
    }
    var allRoute: [RoutePoint] { legs.flatMap(\.route) + route }
}
struct JourneyState: Codable {
    var active: Trip?
    var history: [Trip] = []
    var settings = Settings()
}

enum E32 {
    struct Estimate { var gear: Int; var liters: Double }
    static let curves: [[(Double, Double)]] = [
        [(18,17), (30,18), (42,19.2), (55,20.5)],
        [(28,10), (50,10.8), (70,12), (92,14.4)],
        [(34,7), (60,7.8), (90,9.5), (120,12), (140,14.5)],
        [(48,5.3), (75,6.2), (105,8.1), (135,10.9), (160,14), (180,17)],
        [(58,4.2), (80,5.1), (110,7.1), (140,10.1), (170,14.1), (190,17.5)]
    ]
    // Digitized BMW graph 24 80 01 410 00; later economical shift points.
    static func estimate(_ speed: Double) -> Estimate? {
        guard speed.isFinite else { return nil }
        let preferred = [34.0, 52, 72, 95].filter { speed >= $0 }.count
        let candidates = curves.enumerated().compactMap { index, points -> Estimate? in
            guard speed >= points[0].0, speed <= points[points.count - 1].0 else { return nil }
            let upper = points.firstIndex { $0.0 >= speed }!
            if upper == 0 { return Estimate(gear: index + 1, liters: points[0].1) }
            let a = points[upper - 1], b = points[upper]
            return Estimate(gear: index + 1, liters: a.1 + (b.1 - a.1) * (speed - a.0) / (b.0 - a.0))
        }
        return candidates.min { abs($0.gear - 1 - preferred) < abs($1.gear - 1 - preferred) }
    }
}
