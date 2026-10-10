import Foundation
import Combine
import CoreLocation
import UIKit

@MainActor final class LocationRecorder: NSObject, CLLocationManagerDelegate, ObservableObject {
    private let manager = CLLocationManager()
    var onPoint: ((RoutePoint) -> Void)?
    @Published var message = "Location access is needed to record a trip"
    private var recording = false
    override init() {
        super.init(); manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone
        manager.activityType = .automotiveNavigation
        manager.pausesLocationUpdatesAutomatically = false
        manager.showsBackgroundLocationIndicator = true
    }
    func setRecording(_ enabled: Bool) {
        recording = enabled
        if !enabled { manager.stopUpdatingLocation(); return }
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            manager.allowsBackgroundLocationUpdates = true
            manager.startUpdatingLocation(); message = "GPS recording active"
        default: message = "Enable Precise Location for Roadline in iPhone Settings"
        }
    }
    func requestBackgroundAccess() { manager.requestAlwaysAuthorization() }
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in if self?.recording == true { self?.setRecording(true) } }
    }
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let points = locations.sorted(by: { $0.timestamp < $1.timestamp }).compactMap { location -> RoutePoint? in
            guard abs(location.timestamp.timeIntervalSinceNow) < 30 else { return nil }
            return RoutePoint(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude,
                time: location.timestamp.timeIntervalSince1970, accuracy: location.horizontalAccuracy,
                speed: location.speed >= 0 ? location.speed : nil)
        }
        Task { @MainActor [weak self] in for point in points { self?.onPoint?(point) } }
    }
    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor [weak self] in
            self?.message = "GPS is temporarily unavailable. Waiting for a fresh reading."
        }
    }
}

@MainActor final class JourneyStore: ObservableObject {
    @Published var state: JourneyState
    @Published var error: String?
    let location = LocationRecorder()
    let sharing = LiveSharing()
    private let file: URL
    private var lastSave = 0.0
    private var lastSync = 0.0
    private var canPersist = true
    private var pendingForcedSync = false
    private var syncScheduled = false
    init(storageFile: URL? = nil) {
        file = storageFile ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Roadline/journeys.json")
        if FileManager.default.fileExists(atPath: file.path) {
            do { state = try JSONDecoder().decode(JourneyState.self, from: Data(contentsOf: file)) }
            catch { state = JourneyState(); canPersist = false; self.error = "Saved journeys could not be read. Your saved file has been retained; recording is disabled until it is recovered." }
        } else { state = JourneyState() }
        #if DEBUG && targetEnvironment(simulator)
        if let screen = ProcessInfo.processInfo.environment["ROADLINE_PREVIEW"] {
            state = Self.previewState(screen); canPersist = false; error = nil
        }
        #endif
        sharing.onReady = { [weak self] in if self?.pendingForcedSync == true { self?.tick(force: true) } }
        location.onPoint = { [weak self] point in
            guard let self = self, var trip = self.state.active else { return }
            JourneyEngine.record(point, in: &trip); self.state.active = trip
            if Date().timeIntervalSince1970 - self.lastSave >= 5 { self.save() }
            self.tick()
        }
        // A relaunched recording resumes only after location authorization is checked.
        location.setRecording(canPersist && state.active?.status == .tracking)
        applyScreenPreference()
    }
    func save() {
        guard canPersist else { return }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(state).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            lastSave = Date().timeIntervalSince1970
        } catch { self.error = "Journeys could not be saved: " + error.localizedDescription }
    }
    func start(destination: String, planned: Double?, fuel: Double?) {
        guard state.active == nil, error == nil else { return }
        let now = Date().timeIntervalSince1970, s = state.settings
        state.active = Trip(destination: destination.trimmingCharacters(in: .whitespacesAndNewlines), start: now,
            legStart: now, prediction: s.prediction, idleRate: s.idleRate, plannedKm: planned,
            tankCapacity: s.tankCapacity > 0 ? s.tankCapacity : nil,
            startingFuel: s.tankCapacity > 0 ? fuel.map { min(s.tankCapacity, max(0, $0)) } : nil,
            referenceEconomy: s.referenceEconomy)
        save(); location.setRecording(true); applyScreenPreference()
    }
    func pause() {
        guard var trip = state.active, trip.status == .tracking else { return }
        JourneyEngine.seal(&trip, now: Date().timeIntervalSince1970); trip.status = .paused
        state.active = trip; location.setRecording(false); save(); applyScreenPreference(); tick(force: true)
    }
    func resume() {
        guard var trip = state.active, trip.status == .paused else { return }
        trip.legStart = Date().timeIntervalSince1970; trip.status = .tracking; trip.raw = nil; trip.intervals = []
        state.active = trip; location.setRecording(true); save(); applyScreenPreference(); tick(force: true)
    }
    func finish() {
        guard var trip = state.active else { return }
        let now = Date().timeIntervalSince1970
        if trip.status == .tracking { JourneyEngine.seal(&trip, now: now) }
        trip.status = .completed; trip.end = now
        state.history.insert(trip, at: 0); state.active = nil
        location.setRecording(false); save(); applyScreenPreference(); tick(force: true)
    }
    func recordFuel(_ liters: Double) {
        guard var trip = state.active, trip.status == .paused, !trip.legs.isEmpty, liters.isFinite, liters >= 0 else { return }
        trip.legs[trip.legs.count - 1].fuel = (liters * 100).rounded() / 100
        state.active = trip; save(); tick(force: true)
    }
    func refill(_ liters: Double) -> Bool {
        guard var trip = state.active, trip.status == .paused, let remaining = trip.fuelRemaining,
            let capacity = trip.tankCapacity, liters.isFinite, liters > 0, liters <= capacity - remaining + 0.01 else { return false }
        trip.refills.append(Refill(time: Date().timeIntervalSince1970, liters: (liters * 100).rounded() / 100))
        state.active = trip; save(); tick(force: true); return true
    }
    func remaining(_ km: Double) {
        guard km.isFinite, km >= 0, var trip = state.active else { return }
        trip.plannedKm = trip.totalMeters / 1000 + km; state.active = trip; save(); tick(force: true)
    }
    func delete(_ trip: Trip) async {
        if sharing.session?.tripID == trip.id, !(await sharing.stop()) { return }
        state.history.removeAll { $0.id == trip.id }; save()
    }
    func tick(force: Bool = false) {
        let now = Date().timeIntervalSince1970
        guard let id = sharing.session?.tripID,
            let trip = state.active?.id == id ? state.active : state.history.first(where: { $0.id == id }) else { pendingForcedSync = false; return }
        if force { pendingForcedSync = true }
        guard !sharing.busy, !syncScheduled, pendingForcedSync || now - lastSync >= 10 else { return }
        pendingForcedSync = false; syncScheduled = true; lastSync = now
        Task {
            if sharing.busy { pendingForcedSync = true; syncScheduled = false; return }
            await sharing.sync(trip); syncScheduled = false
            if pendingForcedSync { tick(force: true) }
        }
    }
    func applyScreenPreference() { UIApplication.shared.isIdleTimerDisabled = state.settings.keepScreenOn && state.active?.status == .tracking }

    #if DEBUG && targetEnvironment(simulator)
    private static func previewState(_ screen: String) -> JourneyState {
        let now = Date().timeIntervalSince1970
        var state = JourneyState()
        state.settings.prediction = true
        if screen == "bmw" { state.settings.palette = .bmw; state.settings.typeface = .bmw }
        var trip = Trip(destination: "Copenhagen → Aarhus", start: now - 5600, legStart: now - 1180,
            prediction: true, idleRate: 1.4, plannedKm: 310, tankCapacity: 90, startingFuel: 72, referenceEconomy: 10.5)
        let points = [RoutePoint(latitude: 55.676, longitude: 12.568, time: now - 5600, accuracy: 3, speed: 27.3),
                      RoutePoint(latitude: 55.482, longitude: 11.818, time: now - 1180, accuracy: 3, speed: 27.3)]
        trip.legs = [Leg(number: 1, start: now - 5600, end: now - 1400, meters: 108000, driving: 3600,
            fuel: 10.78, route: points, predicted: 10.9, idle: 240, rangeFuel: 10.9)]
        trip.meters = 32600; trip.driving = 1000; trip.predicted = 3.62; trip.rangeFuel = 3.62
        trip.idle = 55; trip.route = [RoutePoint(latitude: 55.335, longitude: 11.144, time: now, accuracy: 3, speed: 27.3)]
        trip.raw = trip.route.last; trip.intervals = [SpeedInterval(start: now - 300, end: now, meters: 8200)]
        if screen == "home" { JourneyEngine.seal(&trip, now: now); trip.status = .completed; trip.end = now; state.history = [trip] }
        else { state.active = trip }
        return state
    }
    #endif
}
