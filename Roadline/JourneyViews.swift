import SwiftUI
import Charts
import MapKit

struct StopView: View {
    @ObservedObject var store: JourneyStore
    @Environment(\.dismiss) private var dismiss
    @State private var fuel = ""
    @State private var refill = ""
    @State private var cumulative = false
    @State private var message: String?
    private var trip: Trip? { store.state.active }
    private var litersForLeg: Double? {
        guard let value = decimalInput(fuel), value >= 0 else { return nil }
        let earlier = trip?.legs.dropLast().reduce(0) { $0 + ($1.fuel ?? 0) } ?? 0
        let legValue = cumulative ? value - earlier : value
        return legValue >= 0 ? legValue : nil
    }
    var body: some View {
        Form {
            if let trip = trip {
                Section("This stop") {
                    Text("Leg \(trip.legs.last?.number ?? 0) · \(reading(trip.legs.last.map { $0.meters / 1000 })) km")
                    LabeledContent("Average speed", value: reading(trip.legs.last?.averageSpeed) + " km/h")
                    LabeledContent("Driving time", value: durationText(trip.legs.last?.driving ?? 0))
                    LabeledContent("Fuel economy", value: reading(trip.legs.last?.economy, decimals: 2) + " L/100 km")
                }
                Section {
                    Toggle("Enter total fuel used across trip", isOn: $cumulative)
                        .onChange(of: cumulative) { _, _ in fuel = "" }
                    TextField(cumulative ? "Total used (L, e.g. 35.25)" : "Used in this leg (L, e.g. 12.35)", text: $fuel).keyboardType(.decimalPad)
                    Button("Save fuel used") { if let value = litersForLeg { store.recordFuel(value); message = "Fuel used saved." } }.disabled(litersForLeg == nil || trip.legs.isEmpty)
                } header: { Text("Measured fuel") } footer: {
                    Text("Fuel used is the amount consumed. Fuel added at a pump is entered separately below. Pausing assumes the engine is off.")
                }
                Section("Refuel") {
                    if let remaining = trip.fuelRemaining, let capacity = trip.tankCapacity {
                        LabeledContent("Estimated in tank", value: reading(remaining, decimals: 2) + " L")
                        TextField("Fuel added (L)", text: $refill).keyboardType(.decimalPad)
                        Text("Available space: approximately \(reading(max(0, capacity - remaining), decimals: 2)) L").font(.footnote)
                        Button("Record refuel") {
                            if let value = decimalInput(refill), store.refill(value) { refill = ""; message = "Refuel saved." }
                            else { message = "Enter a positive amount that fits your tank." }
                        }.disabled(decimalInput(refill) == nil)
                        ForEach(trip.refills) { entry in
                            LabeledContent(Date(timeIntervalSince1970: entry.time).formatted(date: .omitted, time: .shortened), value: "+" + reading(entry.liters, decimals: 2) + " L")
                        }
                    } else { Text("Tank details were not set for this journey. You can still record measured fuel use above.") }
                }
                if let message = message { Section { Text(message).foregroundStyle(.secondary) } }
                Section {
                    Button("Continue journey") { if let value = litersForLeg, !fuel.isEmpty { store.recordFuel(value) }; store.resume(); dismiss() }
                        .disabled(!fuel.isEmpty && litersForLeg == nil)
                    Button("Complete journey") { if let value = litersForLeg, !fuel.isEmpty { store.recordFuel(value) }; dismiss(); store.finish() }
                        .disabled(!fuel.isEmpty && litersForLeg == nil)
                }
            }
        }
        .navigationTitle("Stop & fuel")
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        .onAppear { if let value = trip?.legs.last?.fuel { fuel = String(format: "%.2f", value) } }
    }
}
struct RemainingView: View {
    @ObservedObject var store: JourneyStore
    @Environment(\.dismiss) private var dismiss
    @State private var value = ""
    var body: some View {
        Form {
            Section {
                TextField("Distance remaining (km)", text: $value).keyboardType(.decimalPad)
            } footer: { Text("Arrival uses the time-weighted average speed over the last five minutes, including stationary time. A fresh GPS reading is required. This is a distance-based estimate, not route navigation.") }
            Button("Update distance") { if let number = decimalInput(value) { store.remaining(number); dismiss() } }.disabled((decimalInput(value) ?? -1) < 0)
        }.navigationTitle("Distance remaining")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .onAppear { value = store.state.active?.remainingKm.map { String(format: "%.1f", $0) } ?? "" }
    }
}
struct SharingView: View {
    @ObservedObject var sharing: LiveSharing
    var trip: Trip
    @Environment(\.dismiss) private var dismiss
    @State private var consent = false
    @State private var revoke = false
    private var isThisTrip: Bool { sharing.session?.tripID == trip.id }
    var body: some View {
        Form {
            Section {
                Label("A friend can follow from anywhere", systemImage: "person.2.wave.2.fill").font(.headline)
                Text("Your friend opens a private browser link; they do not need Roadline or an account.")
                Text("Sharing includes destination, distance, speeds, driving and total time, fuel, estimated range, arrival and leg summaries. GPS coordinates stay on this phone.").font(.footnote).foregroundStyle(.secondary)
            }
            Section("Sharing status") {
                Text(sharing.message)
                if let date = sharing.lastSync { LabeledContent("Last update", value: date.formatted(date: .omitted, time: .standard)) }
                if sharing.busy { ProgressView() }
                if isThisTrip, let session = sharing.session, session.confirmed {
                    ShareLink(item: session.url) { Label("Send live link", systemImage: "square.and.arrow.up") }
                    Button("Retry update") { Task { await sharing.sync(trip) } }.disabled(sharing.busy)
                } else {
                    Button(isThisTrip ? "Retry creating link" : "Enable live sharing") { consent = true }.disabled(sharing.busy)
                }
                if isThisTrip { Button("Stop sharing", role: .destructive) { revoke = true }.disabled(sharing.busy) }
            }
            Section { Text("Links expire after seven days. Updates are attempted about every 10 seconds while active and when background GPS updates arrive. While paused in the background, iOS may suspend updates; your friend can still see the last update.").font(.footnote).foregroundStyle(.secondary) }
        }
        .navigationTitle("Live sharing")
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        .alert("Share this journey?", isPresented: $consent) {
            Button("Enable sharing") { Task { await sharing.start(trip) } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Send the listed trip statistics to roadline-live-journeys.fabledduck.chatgpt.site? Anyone with the private link can view them. You can revoke it at any time.") }
        .confirmationDialog("Revoke this live link?", isPresented: $revoke, titleVisibility: .visible) {
            Button("Stop sharing", role: .destructive) { Task { _ = await sharing.stop() } }
        }
    }
}
struct LegsView: View {
    var trip: Trip
    @Environment(\.roadline) private var style
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Journey chapters").font(style.font(24, weight: .bold)).foregroundStyle(style.ink)
            ForEach(trip.legs) { leg in
                HStack(alignment: .top, spacing: 14) {
                    Text(String(leg.number)).font(.headline).frame(width: 36, height: 36).background(style.accent.opacity(0.15), in: Circle())
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(reading(leg.meters / 1000)) km · \(reading(leg.averageSpeed)) km/h").font(.headline)
                        Text("\(Date(timeIntervalSince1970: leg.start).formatted(date: .omitted, time: .shortened)) – \(Date(timeIntervalSince1970: leg.end).formatted(date: .omitted, time: .shortened)) · \(durationText(leg.driving)) driving").font(.caption).foregroundStyle(style.secondary)
                        Text(leg.fuel.map { "\(reading($0, decimals: 2)) L used · \(reading(leg.economy, decimals: 2)) L/100 km" } ?? "Fuel use not entered").font(.caption).foregroundStyle(style.secondary)
                        if trip.prediction { Text("E32 estimate: \(reading(leg.predicted, decimals: 2)) L · \(durationText(leg.idle)) idle").font(.caption).foregroundStyle(style.secondary) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.foregroundStyle(style.ink)
                if leg.id != trip.legs.last?.id { Divider() }
            }
        }.padding(20).background(style.surface, in: RoundedRectangle(cornerRadius: 30))
    }
}
struct TripSummary: View {
    var trip: Trip
    @ObservedObject var sharing: LiveSharing
    @Environment(\.roadline) private var style
    @State private var share = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Label("Journey complete", systemImage: "flag.checkered").foregroundStyle(style.accent).font(.headline)
                Text(trip.destination).font(style.font(38, weight: .bold)).foregroundStyle(style.ink)
                HStack {
                    Metric(label: "Distance", value: reading(trip.totalMeters / 1000), unit: "km", icon: "road.lanes")
                    Metric(label: "Average speed", value: reading(trip.averageSpeed), unit: "km/h", icon: "speedometer")
                }.frame(minHeight: 120)
                HStack {
                    Metric(label: "Driving", value: durationText(trip.totalDriving), unit: "in motion", icon: "steeringwheel")
                    Metric(label: "Total time", value: durationText(trip.elapsed(trip.end ?? Date().timeIntervalSince1970)), unit: "including stops", icon: "clock")
                }.frame(minHeight: 120)
                HStack {
                    Metric(label: "Measured economy", value: reading(trip.economy, decimals: 2), unit: "L/100 km", icon: "drop")
                    Metric(label: "Fuel logged", value: reading(trip.fuelUsed, decimals: 2), unit: "liters", icon: "fuelpump")
                }.frame(minHeight: 120)
                if trip.prediction {
                    Text("E32 experimental: \(reading(trip.totalPredicted, decimals: 2)) L estimated · \(reading(trip.predictedEconomy, decimals: 2)) L/100 km · \(durationText(trip.totalIdle)) idle").font(.footnote).foregroundStyle(style.secondary)
                }
                if !trip.allRoute.isEmpty {
                    Map(initialPosition: .automatic) {
                        ForEach(trip.legs) { leg in
                            if leg.route.count > 1 { MapPolyline(coordinates: leg.route.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }).stroke(style.accent, lineWidth: 4) }
                        }
                        if let point = trip.allRoute.first { Marker("Start", systemImage: "play.fill", coordinate: CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)).tint(.green) }
                        if let point = trip.allRoute.last { Marker("Finish", systemImage: "flag.checkered", coordinate: CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)).tint(style.accent) }
                    }.frame(height: 260).clipShape(RoundedRectangle(cornerRadius: 30))
                        .accessibilityLabel("Recorded journey map")
                }
                if !trip.legs.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Pace by leg").font(style.font(23, weight: .bold))
                        Chart(trip.legs) { leg in
                            BarMark(x: .value("Leg", String(leg.number)), y: .value("Average km/h", leg.averageSpeed)).foregroundStyle(style.accent).cornerRadius(6)
                        }.frame(height: 200).chartYAxisLabel("km/h")
                        Text("Leg averages use time in motion. Arrival calculations also include stationary time.").font(.caption).foregroundStyle(style.secondary)
                    }.padding(20).background(style.surface, in: RoundedRectangle(cornerRadius: 30))
                    if trip.legs.contains(where: { $0.economy != nil }) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Fuel economy by leg").font(style.font(23, weight: .bold))
                            Chart(trip.legs.filter { $0.economy != nil }) { leg in
                                BarMark(x: .value("Leg", String(leg.number)), y: .value("L/100 km", leg.economy!)).foregroundStyle(style.accent.opacity(0.75)).cornerRadius(6)
                            }.frame(height: 200).chartYAxisLabel("L/100 km")
                        }.padding(20).background(style.surface, in: RoundedRectangle(cornerRadius: 30))
                    }
                    LegsView(trip: trip)
                }
                Button("Share journey", systemImage: "person.2.wave.2") { share = true }.buttonStyle(RoadlineButtonStyle(primary: true))
            }.padding(16).foregroundStyle(style.ink)
        }.background(style.background.ignoresSafeArea()).navigationTitle("Journey summary").navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $share) { NavigationStack { SharingView(sharing: sharing, trip: trip) } }
    }
}
struct SettingsView: View {
    @ObservedObject var store: JourneyStore
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $store.state.settings.palette) { ForEach(Palette.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    .onChange(of: store.state.settings.palette) { _, palette in if palette == .bmw { store.state.settings.typeface = .bmw } }
                Picker("Typeface", selection: $store.state.settings.typeface) { ForEach(Typeface.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                Text("BMW Cluster uses licensed Barlow Condensed to approximate the narrow instrument lettering; it is not BMW's original proprietary font.").font(.footnote).foregroundStyle(.secondary)
                Toggle("Expressive spring animations", isOn: $store.state.settings.motion)
                Text("The iPhone Reduce Motion setting is respected.").font(.footnote).foregroundStyle(.secondary)
            }
            Section("Dashboard sizing") {
                LabeledContent("Text size", value: "\(Int(store.state.settings.textScale * 100))%")
                Slider(value: $store.state.settings.textScale, in: 0.9...1.2, step: 0.05).accessibilityLabel("Text size")
                LabeledContent("Speed panel width", value: "\(Int(store.state.settings.speedFraction * 100))%")
                Slider(value: $store.state.settings.speedFraction, in: 0.48...0.78, step: 0.02).accessibilityLabel("Speed panel width")
                LabeledContent("Supporting panel size", value: "\(Int(store.state.settings.supportScale * 100))%")
                Slider(value: $store.state.settings.supportScale, in: 0.8...1.3, step: 0.05).accessibilityLabel("Supporting panel size")
            }
            Section("Recording") {
                Toggle("Keep screen on while recording", isOn: $store.state.settings.keepScreenOn)
                Button("Allow background location") { store.location.requestBackgroundAccess() }
                Button("Open iPhone location settings") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
                Text("Allow Precise Location. An active recording can continue with the screen locked. Force-quitting Roadline stops GPS updates; reopen it to resume.").font(.footnote).foregroundStyle(.secondary)
            }
            Section("Fuel tank") {
                Stepper("Capacity: \(reading(store.state.settings.tankCapacity, decimals: 0)) L", value: $store.state.settings.tankCapacity, in: 0...300)
                    .onChange(of: store.state.settings.tankCapacity) { _, capacity in store.state.settings.startingFuel = min(capacity, store.state.settings.startingFuel) }
                LabeledContent("Default starting fuel", value: reading(store.state.settings.startingFuel, decimals: 2) + " L")
                Slider(value: $store.state.settings.startingFuel, in: 0...max(0.01, store.state.settings.tankCapacity), step: 0.01).accessibilityLabel("Default starting fuel")
                LabeledContent("Reference consumption", value: reading(store.state.settings.referenceEconomy, decimals: 1) + " L/100 km")
                Slider(value: $store.state.settings.referenceEconomy, in: 1...50, step: 0.1).accessibilityLabel("Reference consumption")
            }
            Section("Experimental E32 model") {
                Toggle("Predict fuel consumption", isOn: $store.state.settings.prediction)
                LabeledContent("Idle fuel rate", value: reading(store.state.settings.idleRate, decimals: 2) + " L/h")
                Slider(value: $store.state.settings.idleRate, in: 0.5...3, step: 0.05).accessibilityLabel("Idle fuel rate")
                Text("1992 BMW E32 M30B30 manual, digitized factory speed curves. Assumed shifts: 34, 52, 72 and 95 km/h. Stationary recording assumes the engine is on; pausing assumes it is off. Steady-speed curves cannot measure traffic, hills, cold starts or throttle. No estimate is shown outside the curves. Settings apply to new trips.").font(.footnote).foregroundStyle(.secondary)
            }
            Section("About") { Text("Roadline iOS 1.4.2 · one-time iPhone edition"); Text("Trips and GPS coordinates are stored on this phone. Live statistics leave the phone only when you enable sharing for a trip.").font(.footnote) }
        }
        .navigationTitle("Settings")
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { store.save(); dismiss() } } }
        .onChange(of: store.state.settings) { _, _ in store.save(); store.applyScreenPreference() }
    }
}

