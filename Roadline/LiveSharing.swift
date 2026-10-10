import Foundation
import Security
import Combine
import UIKit

struct LiveSnapshot: Encodable {
    struct SharedLeg: Encodable {
        var number: Int; var distanceKm: Double; var averageSpeedKmh: Double
        var driveMillis: Double; var fuelLiters: Double?
        enum CodingKeys: String, CodingKey { case number, distanceKm, averageSpeedKmh, driveMillis, fuelLiters }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(number, forKey: .number); try c.encode(distanceKm, forKey: .distanceKm)
            try c.encode(averageSpeedKmh, forKey: .averageSpeedKmh); try c.encode(driveMillis, forKey: .driveMillis)
            try c.encode(fuelLiters, forKey: .fuelLiters)
        }
    }
    var destination: String; var status: String; var distanceKm: Double; var averageSpeedKmh: Double
    var recentSpeedKmh: Double?; var driveMillis: Double; var totalMillis: Double; var remainingKm: Double?
    var etaAt: Double?; var rangeKm: Double?; var fuelRemaining: Double?; var fuelUsed: Double
    var updatedAt: Double; var predictionEnabled: Bool; var estimatedFuelUsed: Double?
    var averageConsumption: Double?; var currentSpeedKmh: Double?; var currentConsumption: Double?
    var currentConsumptionUnit: String?; var legs: [SharedLeg]
    enum CodingKeys: String, CodingKey {
        case destination, status, distanceKm, averageSpeedKmh, recentSpeedKmh, driveMillis, totalMillis
        case remainingKm, etaAt, rangeKm, fuelRemaining, fuelUsed, updatedAt, predictionEnabled
        case estimatedFuelUsed, averageConsumption, currentSpeedKmh, currentConsumption, currentConsumptionUnit, legs
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(destination, forKey: .destination); try c.encode(status, forKey: .status)
        try c.encode(distanceKm, forKey: .distanceKm); try c.encode(averageSpeedKmh, forKey: .averageSpeedKmh)
        // The relay requires explicit JSON null for unavailable readings, not omitted keys.
        try c.encode(recentSpeedKmh, forKey: .recentSpeedKmh); try c.encode(driveMillis, forKey: .driveMillis)
        try c.encode(totalMillis, forKey: .totalMillis); try c.encode(remainingKm, forKey: .remainingKm)
        try c.encode(etaAt, forKey: .etaAt); try c.encode(rangeKm, forKey: .rangeKm)
        try c.encode(fuelRemaining, forKey: .fuelRemaining); try c.encode(fuelUsed, forKey: .fuelUsed)
        try c.encode(updatedAt, forKey: .updatedAt); try c.encode(predictionEnabled, forKey: .predictionEnabled)
        try c.encode(estimatedFuelUsed, forKey: .estimatedFuelUsed); try c.encode(averageConsumption, forKey: .averageConsumption)
        try c.encode(currentSpeedKmh, forKey: .currentSpeedKmh); try c.encode(currentConsumption, forKey: .currentConsumption)
        try c.encode(currentConsumptionUnit, forKey: .currentConsumptionUnit); try c.encode(legs, forKey: .legs)
    }
    init(_ trip: Trip, now: Double = Date().timeIntervalSince1970) {
        destination = String(trip.destination.prefix(160)); status = trip.status.rawValue
        distanceKm = trip.totalMeters / 1000; averageSpeedKmh = trip.averageSpeed
        recentSpeedKmh = trip.recentSpeed(now); driveMillis = trip.totalDriving * 1000
        totalMillis = trip.elapsed(now) * 1000; remainingKm = trip.remainingKm
        etaAt = trip.etaSeconds(now).map { (now + $0) * 1000 }; rangeKm = trip.rangeKm
        fuelRemaining = trip.fuelRemaining; fuelUsed = trip.fuelUsed; updatedAt = now * 1000
        predictionEnabled = trip.prediction; estimatedFuelUsed = trip.prediction ? trip.totalPredicted : nil
        averageConsumption = trip.displayedEconomy; currentSpeedKmh = trip.currentSpeed(now)
        let current = trip.currentConsumption(now); currentConsumption = current?.value
        currentConsumptionUnit = current.map { $0.unit == "L/h" ? "L_PER_HOUR" : "L_PER_100_KM" }
        legs = trip.legs.suffix(100).map { SharedLeg(number: $0.number, distanceKm: $0.meters / 1000,
            averageSpeedKmh: $0.averageSpeed, driveMillis: $0.driving * 1000, fuelLiters: $0.fuel) }
    }
}
struct SharingSession: Codable {
    var tripID: String; var id: String; var viewToken: String; var writeToken: String
    var confirmed = false
    var url: URL { URL(string: LiveSharing.origin + "/#" + id + "." + viewToken)! }
}
enum SharingError: LocalizedError {
    case http(Int), unavailable, secureStorage, keychain(OSStatus)
    var errorDescription: String? {
        switch self {
        case .http(let code):
            if [401,403,404,410].contains(code) { return "The sharing service could not update this link. Your link is kept for retry; it may have expired after seven days." }
            if code == 429 { return "The sharing service is busy. Please wait before retrying." }
            return "The sharing service returned \(code). Please retry."
        case .unavailable: return "The sharing service is not ready. This is a service issue, not proof that your phone is offline."
        case .secureStorage: return "The sharing key could not be saved securely. Please unlock your phone and retry."
        case .keychain(let status):
            if status == errSecMissingEntitlement { return "This app's signature does not enable secure key storage. Re-sign the iPhone app with your Apple account." }
            return "Secure key storage could not be accessed (\(status)). Unlock your phone and retry."
        }
    }
}
enum SharingKeychain {
    static let service = "com.roadline.ios.live"
    static let account = "session"
    static var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service, kSecAttrAccount as String: account] }
    static func load() -> SharingSession? {
        var q = query; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var data: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &data) == errSecSuccess, let bytes = data as? Data else { return nil }
        return try? JSONDecoder().decode(SharingSession.self, from: bytes)
    }
    static func save(_ session: SharingSession?) throws {
        if let session = session {
            let data = try JSONEncoder().encode(session)
            let values: [String: Any] = [kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
            let result = SecItemUpdate(query as CFDictionary, values as CFDictionary)
            if result == errSecItemNotFound {
                var q = query; values.forEach { q[$0.key] = $0.value }
                let added = SecItemAdd(q as CFDictionary, nil)
                guard added == errSecSuccess else { throw SharingError.keychain(added) }
            } else if result != errSecSuccess { throw SharingError.keychain(result) }
        } else {
            let result = SecItemDelete(query as CFDictionary)
            guard result == errSecSuccess || result == errSecItemNotFound else { throw SharingError.keychain(result) }
        }
    }
    static func token() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw SharingError.secureStorage }
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

@MainActor final class LiveSharing: ObservableObject {
    nonisolated static let origin = "https://roadline-live-journeys.fabledduck.chatgpt.site"
    @Published private(set) var session: SharingSession?
    @Published private(set) var busy = false
    @Published private(set) var message = "Sharing is off"
    @Published private(set) var lastSync: Date?
    var onReady: (() -> Void)?
    private let network: URLSession
    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15; config.timeoutIntervalForResource = 25
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        network = URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
        session = SharingKeychain.load()
        if session != nil { message = "Waiting to reconnect" }
    }
    func start(_ trip: Trip) async {
        guard !busy else { return }
        let lease = SharingBackgroundLease(); busy = true
        defer { lease.end(); busy = false; onReady?() }
        do {
            if let old = session, old.tripID != trip.id {
                try await request("DELETE", path: "/api/trips/" + old.id, token: old.writeToken)
                try SharingKeychain.save(nil); session = nil
            }
            if session == nil {
                let health = try await request("GET", path: "/api/health")
                let object = try JSONSerialization.jsonObject(with: health) as? [String: Any]
                guard object?["service"] as? String == "roadline-live", object?["ready"] as? Bool == true else { throw SharingError.unavailable }
                let created = try SharingSession(tripID: trip.id, id: SharingKeychain.token(),
                    viewToken: SharingKeychain.token(), writeToken: SharingKeychain.token())
                // Save before POST so a lost response cannot lose the friend's stable URL.
                try SharingKeychain.save(created); session = created
            }
            try await publish(trip)
        } catch { message = describe(error) }
    }
    func sync(_ trip: Trip) async {
        guard !busy, session?.tripID == trip.id else { return }
        let lease = SharingBackgroundLease(); busy = true
        defer { lease.end(); busy = false; onReady?() }
        do { try await publish(trip) } catch { message = describe(error) + " Retrying when updates are available." }
    }
    private func publish(_ trip: Trip) async throws {
        guard var s = session else { return }
        let snapshot = LiveSnapshot(trip), data = try JSONEncoder().encode(snapshot)
        do { try await request("PUT", path: "/api/trips/" + s.id, body: data, token: s.writeToken) }
        catch SharingError.http(let code) where code == 404 && !s.confirmed {
            struct Create: Encodable { var id: String; var viewToken: String; var writeToken: String; var snapshot: LiveSnapshot }
            let body = try JSONEncoder().encode(Create(id: s.id, viewToken: s.viewToken, writeToken: s.writeToken, snapshot: snapshot))
            try await request("POST", path: "/api/trips", body: body)
        }
        s.confirmed = true; try SharingKeychain.save(s); session = s; lastSync = Date()
        message = trip.status == .completed ? "Completed trip shared" : "Live sharing is on"
    }
    func stop() async -> Bool {
        guard !busy else { return false }
        let lease = SharingBackgroundLease(); busy = true
        defer { lease.end(); busy = false; onReady?() }
        do {
            if let s = session { try await request("DELETE", path: "/api/trips/" + s.id, token: s.writeToken) }
            try SharingKeychain.save(nil); session = nil; lastSync = nil; message = "Sharing is off"; return true
        } catch { message = describe(error) + " The link has not been revoked. Retry Stop sharing."; return false }
    }
    private func describe(_ error: Error) -> String {
        if let url = error as? URLError {
            if url.code == .notConnectedToInternet { return "Your phone is offline. The existing link is kept." }
            if url.code == .timedOut { return "The sharing service did not respond in time. The existing link is kept." }
            return "The sharing service could not be reached. The existing link is kept."
        }
        return error.localizedDescription
    }
    @discardableResult private func request(_ method: String, path: String, body: Data? = nil, token: String? = nil) async throws -> Data {
        var request = URLRequest(url: URL(string: Self.origin + path)!)
        request.httpMethod = method; request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        if let token = token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        let (data, response) = try await network.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SharingError.unavailable }
        guard (200...299).contains(http.statusCode) else { throw SharingError.http(http.statusCode) }
        guard http.mimeType?.lowercased() == "application/json" else { throw SharingError.unavailable }
        return data
    }
}
private final class NoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
@MainActor private final class SharingBackgroundLease {
    private var identifier = UIBackgroundTaskIdentifier.invalid
    init() {
        identifier = UIApplication.shared.beginBackgroundTask(withName: "Roadline live update") { [weak self] in
            Task { @MainActor in self?.end() }
        }
    }
    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier); identifier = .invalid
    }
}
