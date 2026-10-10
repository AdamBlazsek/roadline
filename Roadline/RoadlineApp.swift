import SwiftUI

@main struct RoadlineApp: App {
    @StateObject private var store = JourneyStore()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            RootView(store: store)
                .environment(\.roadline, RoadlineStyle(settings: store.state.settings, reduceMotion: reduceMotion))
                .tint(RoadlineStyle(settings: store.state.settings).accent)
                .preferredColorScheme(store.state.settings.palette == .bmw ? .dark : nil)
                .onChange(of: scenePhase) { _, phase in
                    store.save()
                    if phase == .active { store.tick(force: true); store.applyScreenPreference() }
                    else { UIApplication.shared.isIdleTimerDisabled = false }
                }
        }
    }
}
struct RootView: View {
    @ObservedObject var store: JourneyStore
    @Environment(\.roadline) private var style
    @State private var settings = false
    @State private var completed: Trip?
    @State private var showSummary = false
    var body: some View {
        NavigationStack {
            Group {
                if let trip = store.state.active { Dashboard(store: store, trip: trip).transition(.opacity.combined(with: .scale(scale: 0.97))) }
                else { HomeView(store: store).transition(.opacity) }
            }
            .background(style.background.ignoresSafeArea())
            .navigationTitle("Roadline")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if store.state.active == nil {
                    ToolbarItem(placement: .topBarTrailing) { Button("Settings", systemImage: "slider.horizontal.3") { settings = true } }
                }
            }
            .sheet(isPresented: $settings) { NavigationStack { SettingsView(store: store) } }
            .navigationDestination(isPresented: $showSummary) { if let trip = completed { TripSummary(trip: trip, sharing: store.sharing) } }
            .onChange(of: store.state.active?.id) { old, new in
                if old != nil && new == nil { completed = store.state.history.first; showSummary = completed != nil }
            }
            .animation(style.animation, value: store.state.active?.id)
            .safeAreaInset(edge: .bottom) {
                if let error = store.error { Text(error).font(.caption).padding().frame(maxWidth: .infinity).background(.red.opacity(0.15)) }
            }
        }
    }
}
struct HomeView: View {
    @ObservedObject var store: JourneyStore
    @Environment(\.roadline) private var style
    @State private var start = false
    @State private var delete: Trip?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 10) {
                    Image(systemName: "road.lanes.curved.left").font(.system(size: 44)).foregroundStyle(style.accent)
                    Text("Every mile.\nEvery moment.").font(style.font(42, weight: .bold)).foregroundStyle(style.ink)
                    Text("Your long-distance drives, beautifully recorded.").font(.body).foregroundStyle(style.secondary)
                    Button("Start a journey", systemImage: "location.fill") { start = true }.buttonStyle(RoadlineButtonStyle(primary: true)).disabled(store.error != nil)
                }.padding(24).background(style.surface, in: RoundedRectangle(cornerRadius: 36))
                Text("Your journeys").font(style.font(25, weight: .bold)).foregroundStyle(style.ink)
                if store.state.history.isEmpty {
                    ContentUnavailableView("An open road ahead", systemImage: "map", description: Text("Completed journeys and their stops will appear here."))
                }
                ForEach(store.state.history) { trip in
                    HStack {
                        NavigationLink { TripSummary(trip: trip, sharing: store.sharing) } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(trip.destination).font(style.font(23, weight: .bold)).foregroundStyle(style.ink)
                                Text(Date(timeIntervalSince1970: trip.start), format: .dateTime.day().month().year()).foregroundStyle(style.secondary)
                                Text("\(reading(trip.totalMeters / 1000)) km · \(durationText(trip.totalDriving)) driving").font(.subheadline).foregroundStyle(style.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Button("Delete journey", systemImage: "trash", role: .destructive) { delete = trip }.labelStyle(.iconOnly).padding(10)
                    }.padding(20).background(style.surface, in: RoundedRectangle(cornerRadius: 28))
                }
            }.padding(16)
        }
        .sheet(isPresented: $start) { NavigationStack { StartView(store: store) } }
        .confirmationDialog("Delete this journey?", isPresented: Binding(get: { delete != nil }, set: { if !$0 { delete = nil } }), titleVisibility: .visible) {
            Button("Delete journey", role: .destructive) { if let trip = delete { Task { await store.delete(trip) } }; delete = nil }
        } message: { Text("This removes its local route and statistics and stops its live link, if one is active.") }
    }
}
struct StartView: View {
    @ObservedObject var store: JourneyStore
    @Environment(\.dismiss) private var dismiss
    @State private var destination = ""
    @State private var planned = ""
    @State private var fuel = ""
    var valid: Bool {
        !destination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        (planned.isEmpty || (decimalInput(planned) ?? -1) > 0) &&
        (store.state.settings.tankCapacity == 0 || (decimalInput(fuel).map { (0...store.state.settings.tankCapacity).contains($0) } ?? false))
    }
    var body: some View {
        Form {
            Section("Journey") {
                TextField("Destination", text: $destination).textInputAutocapitalization(.words)
                TextField("Planned distance (km, optional)", text: $planned).keyboardType(.decimalPad)
            }
            Section("Fuel") {
                if store.state.settings.tankCapacity > 0 {
                    TextField("Fuel in tank (liters)", text: $fuel).keyboardType(.decimalPad)
                    Text("Tank capacity: \(reading(store.state.settings.tankCapacity)) L")
                } else { Text("Set your tank details in Settings to estimate remaining fuel and range.") }
                Text(store.state.settings.prediction ? "E32 experimental prediction includes engine-on idle fuel." : "Measured fuel economy is calculated from the fuel you enter at stops.").font(.footnote).foregroundStyle(.secondary)
            }
            Section { Button("Start recording") { store.start(destination: destination, planned: decimalInput(planned), fuel: decimalInput(fuel)); dismiss() }.disabled(!valid) }
        }
        .navigationTitle("New journey")
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        .onAppear { if store.state.settings.tankCapacity > 0 { fuel = String(format: "%.2f", store.state.settings.startingFuel) } }
    }
}
private enum TripSheet: String, Identifiable { case stop, sharing, distance; var id: String { rawValue } }
struct Dashboard: View {
    @ObservedObject var store: JourneyStore
    var trip: Trip
    @Environment(\.roadline) private var style
    @State private var currentSpeed = false
    @State private var remainingDistance = false
    @State private var currentConsumption = false
    @State private var remainingFuel = false
    @State private var sheet: TripSheet?
    @State private var finish = false
    var body: some View {
        GeometryReader { geometry in
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                let now = timeline.date.timeIntervalSince1970
                ScrollView {
                    VStack(spacing: 12) {
                        HStack {
                            Circle().fill(trip.status == .paused ? Color.orange : style.accent).frame(width: 8, height: 8)
                            Text(trip.status == .paused ? "Paused · engine off" : "Recording").font(.subheadline)
                            Spacer()
                            Button("Share", systemImage: "person.2.wave.2") { sheet = .sharing }.labelStyle(.iconOnly).font(.title3).frame(width: 44, height: 44)
                        }.foregroundStyle(style.secondary)
                        Text(trip.destination).font(style.font(25, weight: .bold)).foregroundStyle(style.ink).lineLimit(2).minimumScaleFactor(0.5).frame(maxWidth: .infinity, alignment: .leading)
                        HStack(spacing: 12) {
                            Metric(label: currentSpeed ? "Current speed" : "Average speed",
                                value: reading(currentSpeed ? trip.currentSpeed(now) : trip.averageSpeed, decimals: 0), unit: "km/h", icon: "speedometer",
                                large: true, selected: true, hint: currentSpeed ? "Tap for average" : "Tap for current") { currentSpeed.toggle() }
                                .frame(width: max(80, (geometry.size.width - 44) * style.settings.speedFraction))
                            Metric(label: remainingDistance ? "Remaining" : "Distance covered",
                                value: reading(remainingDistance ? trip.remainingKm : trip.totalMeters / 1000), unit: "km", icon: "road.lanes",
                                large: true, hint: remainingDistance ? "Tap for covered" : "Tap for remaining") { remainingDistance.toggle() }
                        }.frame(height: min(300, max(210, geometry.size.height * 0.35)))
                        HStack(spacing: 12) {
                            Button(trip.status == .paused ? "Resume" : "Add stop", systemImage: trip.status == .paused ? "play.fill" : "pause.fill") {
                                if trip.status == .paused { store.resume() } else { store.pause(); sheet = .stop }
                            }.buttonStyle(RoadlineButtonStyle(primary: true))
                            Button("Finish", systemImage: "flag.checkered") { finish = true }.buttonStyle(RoadlineButtonStyle())
                        }
                        if trip.status == .paused {
                            Button("Fuel and refuel details", systemImage: "fuelpump.fill") { sheet = .stop }
                                .buttonStyle(RoadlineButtonStyle())
                        }
                        HStack(spacing: 10) {
                            Metric(label: "Driving", value: durationText(trip.totalDriving), unit: "in motion", icon: "steeringwheel")
                            Metric(label: "Total time", value: durationText(trip.elapsed(now)), unit: "including stops", icon: "clock")
                        }.frame(minHeight: 112 * style.settings.supportScale)
                        HStack(spacing: 10) {
                            Metric(label: "Arrival", value: trip.etaSeconds(now).map { Date(timeIntervalSince1970: now + $0).formatted(date: .omitted, time: .shortened) } ?? "—",
                                unit: trip.remainingKm == nil ? "Set remaining distance" : "Last 5 min average", icon: "clock.badge.checkmark") { sheet = .distance }
                            Metric(label: "Legs", value: String(trip.legs.count + (trip.status == .tracking ? 1 : 0)), unit: "recorded", icon: "point.topleft.down.to.point.bottomright.curvepath")
                                .frame(width: max(92, geometry.size.width * 0.24))
                        }.frame(minHeight: 112 * style.settings.supportScale)
                        if trip.prediction { Label("E32 experimental estimate", systemImage: "sparkles").font(.caption).foregroundStyle(style.secondary).frame(maxWidth: .infinity, alignment: .leading) }
                        HStack(spacing: 10) {
                            Metric(label: currentConsumption ? "Current consumption" : "Average consumption",
                                value: reading(currentConsumption ? trip.currentConsumption(now)?.value : trip.displayedEconomy, decimals: 2),
                                unit: currentConsumption ? trip.currentConsumption(now)?.unit ?? "L/100 km" : "L/100 km", icon: "gauge.with.dots.needle.33percent") { currentConsumption.toggle() }
                            Metric(label: "Estimated range", value: reading(trip.rangeKm, decimals: 0), unit: "km", icon: "fuelpump")
                        }.frame(minHeight: 120 * style.settings.supportScale)
                        HStack(spacing: 10) {
                            Metric(label: remainingFuel ? "Fuel remaining" : (trip.prediction ? "Estimated fuel used" : "Fuel logged"),
                                value: reading(remainingFuel ? trip.fuelRemaining : trip.displayedFuel, decimals: 2), unit: "liters", icon: "drop.fill") { remainingFuel.toggle() }
                            Metric(label: "Idle time", value: durationText(trip.totalIdle), unit: "engine assumed on", icon: "hourglass")
                        }.frame(minHeight: 112 * style.settings.supportScale)
                        if currentConsumption && !trip.prediction { Text("Current fuel consumption needs the experimental E32 model. It is not a sensor reading.").font(.caption).foregroundStyle(style.secondary) }
                        if trip.legs.count > 0 { LegsView(trip: trip) }
                    }.padding(.horizontal, 16).padding(.bottom, 20)
                }.onChange(of: timeline.date) { _, _ in store.tick() }
            }
        }
        .sensoryFeedback(.selection, trigger: currentSpeed)
        .sensoryFeedback(.selection, trigger: remainingDistance)
        .sensoryFeedback(.selection, trigger: currentConsumption)
        .sensoryFeedback(.selection, trigger: remainingFuel)
        .sheet(item: $sheet) { item in
            NavigationStack {
                switch item {
                case .stop: StopView(store: store)
                case .sharing: SharingView(sharing: store.sharing, trip: trip)
                case .distance: RemainingView(store: store)
                }
            }
        }
        .confirmationDialog("Complete this journey?", isPresented: $finish, titleVisibility: .visible) {
            Button("Complete journey") { store.finish() }
            if trip.status == .tracking { Button("Add a stop and enter final fuel first") { store.pause(); sheet = .stop } }
            else { Button("Enter final fuel first") { sheet = .stop } }
        } message: { Text("Your stops, route, driving time and total time will be saved.") }
    }
}
