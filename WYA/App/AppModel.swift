import CoreLocation
import Foundation
import Observation
import WYACore

struct PlanRecord: Identifiable {
    let id = UUID()
    let query: String
    var options: [TripPlan]
    var selected: Int
    var narration: String
    var usedModel: Bool
    var modelName: String
    var notes: [String]

    var plan: TripPlan { options[selected] }

    var spoken: String {
        selected == 0 ? narration : options[selected].summary
    }
}

enum BannerTone {
    case info
    case warning
    case error
}

struct StatusBanner: Equatable {
    var tone: BannerTone
    var message: String
}

@MainActor
@Observable
final class AppModel {
    private(set) var catalog: TransitCatalog?
    private(set) var loadError: String?
    private(set) var secrets: AppSecrets
    private let locationService = LocationService()
    private let realtime = RealtimeArrivalsService()
    private let geocoder = PlaceGeocoder()
    private let llm = LLMClient()
    private let refiner = WalkingRefiner()
    private let cache = ArrivalCache()

    var usingPreview = false
    var deviceLocation: CLLocation?
    var authorization: CLAuthorizationStatus = .notDetermined
    var locationError: String?
    var nearby: [AccessPoint] = []
    var arrivals: [String: [Arrival]] = [:]
    var banner: StatusBanner?
    var isRefreshing = false
    var selectedStopID: String?
    var isPlanning = false
    var planError: String?
    var history: [PlanRecord] = []

    private var didStart = false
    private var refreshTask: Task<Void, Never>?
    private var lastFetchAt: Date?
    private var lastFetchCoordinate: Coordinate?
    private var appliedCoordinate: Coordinate?

    init() {
        secrets = AppSecrets.load()
        authorization = locationService.authorization
        locationService.onAuthorization = { [weak self] status in
            self?.authorization = status
            if status == .authorizedAlways || status == .authorizedWhenInUse {
                self?.locationError = nil
            }
        }
        locationService.onLocation = { [weak self] location in
            guard let self, !self.usingPreview else { return }
            self.deviceLocation = location
            self.locationChanged()
        }
        locationService.onFailure = { [weak self] message in
            self?.locationError = message
        }
    }

    var activeCoordinate: Coordinate? {
        if usingPreview { return LocationService.unionSquare }
        guard let deviceLocation else { return nil }
        return Coordinate(latitude: deviceLocation.coordinate.latitude, longitude: deviceLocation.coordinate.longitude)
    }

    var isOutsideNYC: Bool {
        guard let coordinate = activeCoordinate, !usingPreview else { return false }
        return coordinate.latitude < 40.48 || coordinate.latitude > 40.93
            || coordinate.longitude < -74.27 || coordinate.longitude > -73.68
    }

    func start() async {
        guard !didStart else { return }
        didStart = true
        guard let url = Bundle.main.url(forResource: "transit-index", withExtension: "json") else {
            loadError = "The bundled MTA stop index is missing from the app."
            return
        }
        do {
            catalog = try await Task.detached(priority: .userInitiated) {
                try CatalogLoader.load(from: url)
            }.value
        } catch {
            loadError = "WYA couldn't read the bundled MTA stop index."
            return
        }
        if let snapshot = cache.snapshot, deviceLocation == nil {
            let coordinate = Coordinate(latitude: snapshot.latitude, longitude: snapshot.longitude)
            apply(coordinate: coordinate, cached: true)
        }
        locationService.request()
    }

    func usePreview() {
        usingPreview = true
        guard let coordinate = activeCoordinate else { return }
        apply(coordinate: coordinate, cached: false)
        scheduleRefresh(force: true)
    }

    func useDeviceLocation() {
        usingPreview = false
        if let coordinate = activeCoordinate {
            apply(coordinate: coordinate, cached: false)
            scheduleRefresh(force: true)
        }
    }

    func locationChanged() {
        guard let coordinate = activeCoordinate else { return }
        if let appliedCoordinate, distance(appliedCoordinate, coordinate) < 40 { return }
        apply(coordinate: coordinate, cached: true)
        scheduleRefresh(force: false)
    }

    func refreshArrivals(force: Bool) async {
        guard let catalog, let coordinate = activeCoordinate else {
            isRefreshing = false
            return
        }
        if !force, let lastFetchAt, let lastFetchCoordinate,
           Date().timeIntervalSince(lastFetchAt) < 25,
           distance(lastFetchCoordinate, coordinate) < 120 {
            isRefreshing = false
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        if nearby.isEmpty {
            nearby = catalog.nearby(to: coordinate)
        }
        let access = nearby
        let fetched = await realtime.fetch(access: access, secrets: secrets)
        let fresh = fetched.byAccessID.values.flatMap { $0 }
        if !fresh.isEmpty {
            arrivals = fetched.byAccessID
            banner = banner(for: fetched, showingSaved: nil)
        } else if !fetched.errors.isEmpty, let restored = cache.restore(for: access), !restored.isEmpty {
            arrivals = restored
            let savedAt = cache.snapshot?.savedAt
            banner = banner(for: fetched, showingSaved: savedAt)
        } else {
            arrivals = fetched.byAccessID
            banner = banner(for: fetched, showingSaved: nil)
        }
        lastFetchAt = Date()
        lastFetchCoordinate = coordinate
        if fetched.usedNetwork && fetched.errors.isEmpty && !fetched.subwaySample && !fetched.busSample && !fresh.isEmpty {
            cache.save(coordinate: coordinate, arrivals: fresh)
        }
    }

    func plan(query: String) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            planError = "Enter a destination, like “from here to Grand Central”."
            return
        }
        guard let catalog else {
            planError = "Transit data is still loading."
            return
        }
        isPlanning = true
        planError = nil
        defer { isPlanning = false }

        var parsed = TripQueryParser.parse(trimmed)
        if secrets.hasLLM, let extracted = try? await llm.extract(query: trimmed, secrets: secrets),
           let destination = extracted.destination, !destination.isEmpty {
            parsed = extracted
        }
        guard let destinationQuery = parsed.destination, !destinationQuery.isEmpty else {
            planError = "Say where you want to go. “From here to Times Square” works."
            return
        }

        let origin: ResolvedPlace
        if let originQuery = parsed.origin {
            do {
                origin = try await geocoder.resolve(originQuery)
            } catch {
                planError = "Couldn't find a starting point for “\(originQuery)”."
                return
            }
        } else if let coordinate = activeCoordinate {
            origin = ResolvedPlace(
                name: usingPreview ? "Union Square preview" : "Your location",
                coordinate: coordinate
            )
        } else {
            planError = "Turn on location, preview Union Square, or name a start. “From Grand Central to …” works without GPS."
            return
        }

        let destinationPlace: ResolvedPlace
        do {
            destinationPlace = try await geocoder.resolve(destinationQuery)
        } catch let error as GeocodeError {
            planError = error.localizedDescription
            return
        } catch {
            planError = "Couldn't look up “\(destinationQuery)”."
            return
        }

        let access = catalog.nearby(to: origin.coordinate, subwayRadius: 1100, busRadius: 850, limit: 8)
        let fetched = await realtime.fetch(access: access, secrets: secrets)
        let hints = fetched.byAccessID.values.flatMap { arrivals in
            arrivals.filter { !$0.isSample }.map {
                LiveArrivalHint(stopID: $0.stopID, routeID: $0.routeID, arrival: $0.date)
            }
        }
        var options = TripEstimator(catalog: catalog).plans(
            from: origin.coordinate,
            originName: origin.name,
            to: destinationPlace.coordinate,
            destinationName: destinationPlace.name,
            at: Date(),
            liveArrivals: hints
        )
        guard !options.isEmpty else {
            planError = "No MTA trip found within a short walk of those places."
            return
        }
        options = await refiner.refine(options)
        var narration = options[0].summary
        var usedModel = false
        if secrets.hasLLM, let text = try? await llm.narrate(plan: options[0], secrets: secrets) {
            narration = text
            usedModel = true
        }
        var notes: [String] = []
        if fetched.subwaySample || fetched.busSample {
            notes.append("Sample arrivals are filling in where an MTA key is missing, so some waits are not live.")
        } else if !options[0].legs.contains(where: { $0.kind == .wait && $0.live }) && options[0].legs.contains(where: { $0.kind == .wait }) {
            notes.append("Wait time is a typical estimate. Live arrivals were not available for the boarding stop.")
        }
        if !usedModel {
            notes.append(secrets.hasLLM
                ? "The written summary fell back to the calculated itinerary."
                : "Add an LLM key in Secrets.plist if you want a short written summary. The times above are calculated, not guessed.")
        }
        history.insert(
            PlanRecord(
                query: trimmed,
                options: options,
                selected: 0,
                narration: narration,
                usedModel: usedModel,
                modelName: secrets.llmModel,
                notes: notes
            ),
            at: 0
        )
        if history.count > 8 { history.removeLast(history.count - 8) }
    }

    func select(recordID: UUID, option: Int) {
        guard let index = history.firstIndex(where: { $0.id == recordID }) else { return }
        guard history[index].options.indices.contains(option) else { return }
        var records = history
        records[index].selected = option
        history = records
    }

    private func apply(coordinate: Coordinate, cached: Bool) {
        guard let catalog else { return }
        appliedCoordinate = coordinate
        nearby = catalog.nearby(to: coordinate)
        if cached, let restored = cache.restore(for: nearby), !restored.isEmpty {
            arrivals = restored
            if let savedAt = cache.snapshot?.savedAt {
                banner = StatusBanner(
                    tone: .info,
                    message: "Showing arrivals saved at \(savedAt.formatted(date: .omitted, time: .shortened))."
                )
            }
        }
    }

    private func scheduleRefresh(force: Bool) {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            self.isRefreshing = true
            if !force {
                try? await Task.sleep(nanoseconds: 350_000_000)
            }
            guard !Task.isCancelled else { return }
            await self.refreshArrivals(force: force)
        }
    }

    private func banner(for fetch: ArrivalFetch, showingSaved: Date?) -> StatusBanner? {
        var parts: [String] = []
        if fetch.subwaySample && fetch.busSample {
            parts.append("Sample arrivals. Add MTA subway and Bus Time keys in Secrets.plist for live countdowns.")
        } else if fetch.subwaySample {
            parts.append("Subway times are sample data. Add an MTA subway API key for live trains.")
        } else if fetch.busSample {
            parts.append("Bus times are sample data. Add an MTA Bus Time key for live buses.")
        }
        if let showingSaved {
            parts.append("Couldn't refresh. Showing arrivals saved at \(showingSaved.formatted(date: .omitted, time: .shortened)).")
        } else if !fetch.errors.isEmpty && !fetch.subwaySample && !fetch.busSample {
            parts.append(fetch.errors[0])
        } else if !fetch.errors.isEmpty {
            parts.append("Some live feeds didn't load.")
        }
        guard let message = parts.first else { return nil }
        let text = parts.count == 1 ? message : parts.joined(separator: " ")
        let tone: BannerTone
        if showingSaved != nil || fetch.subwaySample || fetch.busSample {
            tone = .warning
        } else if !fetch.errors.isEmpty {
            tone = .error
        } else {
            tone = .info
        }
        return StatusBanner(tone: tone, message: text)
    }

    private func distance(_ a: Coordinate, _ b: Coordinate) -> Double {
        WalkingModel.nyc.distanceMeters(a, b)
    }
}
