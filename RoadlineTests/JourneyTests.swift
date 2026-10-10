import XCTest
@testable import Roadline

final class JourneyTests: XCTestCase {
    func trip(_ now: Double = 1000, prediction: Bool = true) -> Trip {
        Trip(destination: "Test drive", start: now, legStart: now, prediction: prediction,
            idleRate: 1.4, plannedKm: 200, tankCapacity: 90, startingFuel: 60, referenceEconomy: 10.5)
    }
    func point(_ time: Double, latitude: Double = 55, longitude: Double = 12, speed: Double? = 0, accuracy: Double = 3) -> RoutePoint {
        RoutePoint(latitude: latitude, longitude: longitude, time: time, accuracy: accuracy, speed: speed)
    }
    func testStationaryDriftNeverIncrementsDistanceOrDrivingTime() {
        var t = trip()
        JourneyEngine.record(point(1000), in: &t)
        for n in 1...20 { JourneyEngine.record(point(1000 + Double(n), latitude: 55 + Double(n % 2) * 0.000015), in: &t) }
        XCTAssertEqual(t.totalMeters, 0); XCTAssertEqual(t.totalDriving, 0)
        XCTAssertEqual(t.totalIdle, 20); XCTAssertEqual(t.currentSpeed(1020), 0)
        XCTAssertEqual(t.totalPredicted, 1.4 * 20 / 3600, accuracy: 0.000001)
    }
    func testPoorAccuracyAndTeleportDoNotAccumulateDistance() {
        var t = trip(); JourneyEngine.record(point(1000), in: &t)
        JourneyEngine.record(point(1001, latitude: 56, speed: 20), in: &t)
        JourneyEngine.record(point(1002, latitude: 55.0001, speed: 20, accuracy: 100), in: &t)
        XCTAssertEqual(t.totalMeters, 0); XCTAssertEqual(t.totalDriving, 0)
    }
    func testFreshAnchorAfterGapDoesNotBridgeUnobservedJourney() {
        var t = trip(); JourneyEngine.record(point(1000, speed: 20), in: &t)
        JourneyEngine.record(point(1100, latitude: 56, speed: 20), in: &t)
        XCTAssertEqual(t.totalMeters, 0); XCTAssertEqual(t.route.count, 2)
    }
    func testRealMovementUsesDistanceAndElapsedTime() {
        var t = trip(); JourneyEngine.record(point(1000, speed: 10), in: &t)
        JourneyEngine.record(point(1002, latitude: 55.0002, speed: 10), in: &t)
        XCTAssertGreaterThan(t.totalMeters, 20); XCTAssertEqual(t.totalDriving, 2)
        XCTAssertEqual(t.currentSpeed(1002), 36)
    }
    func testETAUsesFiveMinuteWeightedWindowWithIdleAndFreshness() {
        var t = trip(); t.plannedKm = 10
        t.intervals = [SpeedInterval(start: 600, end: 900, meters: 6000), SpeedInterval(start: 900, end: 1000, meters: 0)]
        XCTAssertEqual(t.recentSpeed(1000)!, 48, accuracy: 0.000001)
        XCTAssertEqual(t.etaSeconds(1000)!, 750, accuracy: 0.000001)
        XCTAssertNil(t.etaSeconds(1031)); t.status = .paused; XCTAssertNil(t.etaSeconds(1000))
    }
    func testIdleConsumesFuelButPauseDoesNot() {
        var t = trip(); JourneyEngine.record(point(1000), in: &t); JourneyEngine.record(point(1010), in: &t)
        XCTAssertEqual(t.fuelRemaining!, 60 - 1.4 * 10 / 3600, accuracy: 0.000001)
        JourneyEngine.seal(&t, now: 1010); t.status = .paused
        JourneyEngine.record(point(1020), in: &t)
        XCTAssertEqual(t.totalIdle, 10); XCTAssertEqual(t.currentConsumption(1020)?.value, 0)
        XCTAssertEqual(t.elapsed(1060), 60)
    }
    func testManualFuelOnlyUsesLegsWithMeasurements() {
        var t = trip(prediction: false)
        t.legs = [Leg(number: 1, start: 0, end: 1, meters: 100_000, driving: 3600, fuel: 10, route: [], predicted: 0, idle: 0, rangeFuel: 10),
                  Leg(number: 2, start: 1, end: 2, meters: 200_000, driving: 7200, route: [], predicted: 0, idle: 0, rangeFuel: 20)]
        XCTAssertEqual(t.economy, 10); XCTAssertEqual(t.averageSpeed, 100)
        t.refills = [Refill(time: 2, liters: 20)]
        XCTAssertEqual(t.fuelRemaining, 50); XCTAssertEqual(t.rangeKm, 500)
    }
    func testE32InterpolationShiftAndNoExtrapolation() {
        XCTAssertEqual(E32.estimate(30)?.gear, 1); XCTAssertEqual(E32.estimate(34)?.gear, 2)
        XCTAssertEqual(E32.estimate(95)?.gear, 5)
        XCTAssertEqual(E32.estimate(110)!.liters, 7.1, accuracy: 0.000001)
        XCTAssertNil(E32.estimate(5)); XCTAssertNil(E32.estimate(200)); XCTAssertNil(E32.estimate(.nan))
    }
    func testPersistenceRoundTripIncludesRouteFuelAndSettings() throws {
        var state = JourneyState(); var t = trip(); JourneyEngine.record(point(1000), in: &t)
        state.active = t; state.settings.typeface = .bmw
        let restored = try JSONDecoder().decode(JourneyState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(restored.active?.route.count, 1); XCTAssertEqual(restored.active?.startingFuel, 60)
        XCTAssertEqual(restored.settings.typeface, .bmw)
    }
    func testSharingPayloadNeverContainsCoordinatesOrSecretsAndUsesMilliseconds() throws {
        var t = trip(); JourneyEngine.record(point(1000), in: &t)
        let data = try JSONEncoder().encode(LiveSnapshot(t, now: 1001))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["updatedAt"] as? Double, 1_001_000)
        XCTAssertEqual(json["totalMillis"] as? Double, 1000)
        let text = String(decoding: data, as: UTF8.self)
        for key in ["latitude", "longitude", "writeToken", "viewToken", "route"] { XCTAssertFalse(text.contains(key)) }
    }
    func testSharingErrorDoesNotCallServer404APhoneConnectionFailure() {
        let message = SharingError.http(404).localizedDescription
        XCTAssertTrue(message.contains("kept")); XCTAssertFalse(message.contains("phone is offline"))
    }
    func testUnavailableSharingReadingsAndUnmeasuredLegAreExplicitNull() throws {
        var t = trip(); t.plannedKm = nil; t.tankCapacity = nil; t.startingFuel = nil
        JourneyEngine.record(point(1000), in: &t); JourneyEngine.seal(&t, now: 1001)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(LiveSnapshot(t, now: 1002))) as? [String: Any])
        for key in ["recentSpeedKmh", "remainingKm", "etaAt", "rangeKm", "fuelRemaining"] { XCTAssertTrue(json[key] is NSNull, key) }
        let legs = try XCTUnwrap(json["legs"] as? [[String: Any]])
        XCTAssertTrue(legs[0]["fuelLiters"] is NSNull)
    }
    func testLiveRelayAcceptsNativePayloadTokenRolesUpdatesAndRevocation() async throws {
        let id = try SharingKeychain.token(), view = try SharingKeychain.token(), write = try SharingKeychain.token()
        let config = URLSessionConfiguration.ephemeral; config.timeoutIntervalForRequest = 15
        let session = URLSession(configuration: config)
        func request(_ method: String, _ path: String, body: Data? = nil, token: String? = nil) async throws -> (Int, Data) {
            var request = URLRequest(url: URL(string: LiveSharing.origin + path)!)
            request.httpMethod = method; request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let token = token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
            let (data, response) = try await session.data(for: request)
            return ((response as! HTTPURLResponse).statusCode, data)
        }
        let path = "/api/trips/" + id
        struct Create: Encodable { var id: String; var viewToken: String; var writeToken: String; var snapshot: LiveSnapshot }
        let now = Date().timeIntervalSince1970
        var t = trip(now); t.destination = "Roadline iOS verification"; t.plannedKm = nil
        let payload = try JSONEncoder().encode(Create(id: id, viewToken: view, writeToken: write, snapshot: LiveSnapshot(t)))
        do {
            let created = try await request("POST", "/api/trips", body: payload)
            XCTAssertEqual(created.0, 201)
            let read = try await request("GET", path, token: view); XCTAssertEqual(read.0, 200)
            let data = try XCTUnwrap(JSONSerialization.jsonObject(with: read.1) as? [String: Any])
            XCTAssertEqual(data["destination"] as? String, t.destination)
            let wrongRole = try await request("GET", path, token: write); XCTAssertEqual(wrongRole.0, 404)
            t.status = .paused
            let update = try await request("PUT", path, body: JSONEncoder().encode(LiveSnapshot(t)), token: write)
            XCTAssertEqual(update.0, 200)
            let changed = try await request("GET", path, token: view)
            XCTAssertEqual((try JSONSerialization.jsonObject(with: changed.1) as? [String: Any])?["status"] as? String, "PAUSED")
            let deleted = try await request("DELETE", path, token: write); XCTAssertEqual(deleted.0, 200)
            let revoked = try await request("GET", path, token: view); XCTAssertEqual(revoked.0, 404)
        } catch { _ = try? await request("DELETE", path, token: write); throw error }
    }
}
