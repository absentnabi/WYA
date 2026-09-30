import MapKit
import SwiftUI
import UIKit
import WYACore

struct NearbyView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    @State private var camera: MapCameraPosition = .automatic

    var body: some View {
        NavigationStack {
            Group {
                if model.nearby.isEmpty {
                    emptyState
                } else {
                    stopList
                }
            }
            .background(Theme.background(scheme))
            .navigationTitle("Nearby")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Preview Union Square", systemImage: "mappin.and.ellipse") {
                            model.usePreview()
                        }
                        if model.usingPreview && model.deviceLocation != nil {
                            Button("Use my location", systemImage: "location.fill") {
                                model.useDeviceLocation()
                            }
                        }
                        if model.authorization == .denied || model.authorization == .restricted {
                            Button("Open Settings", systemImage: "gear") {
                                openSettings()
                            }
                        }
                    } label: {
                        Image(systemName: model.usingPreview ? "mappin.circle.fill" : "location.circle")
                    }
                    .accessibilityLabel("Location options")
                }
            }
        }
        .onAppear { aimCamera() }
        .onChange(of: model.activeCoordinate?.latitude) { _, _ in aimCamera() }
        .onChange(of: model.usingPreview) { _, _ in aimCamera() }
    }

    private var stopList: some View {
        List {
            Section {
                map
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                if let banner = model.banner {
                    bannerView(banner)
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 4, trailing: 16))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            }
            Section {
                ForEach(model.nearby) { stop in
                    stopRow(stop)
                        .listRowBackground(model.selectedStopID == stop.id ? Theme.elevated(scheme) : Theme.card(scheme))
                }
            } header: {
                Text(model.usingPreview ? "Preview around Union Square" : "Closest stops")
            } footer: {
                if let generated = model.catalog?.index.generated {
                    Text("Stop list from MTA GTFS static feeds. Catalog built \(generated.prefix(10)).")
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .refreshable { await model.refreshArrivals(force: true) }
    }

    private var map: some View {
        Map(position: $camera) {
            if !model.usingPreview, model.deviceLocation != nil {
                UserAnnotation()
            }
            ForEach(model.nearby) { stop in
                Annotation(stop.name, coordinate: CLLocationCoordinate2D(
                    latitude: stop.coordinate.latitude,
                    longitude: stop.coordinate.longitude
                )) {
                    Button {
                        model.selectedStopID = stop.id
                    } label: {
                        Circle()
                            .fill(model.selectedStopID == stop.id ? Theme.accent : pinColor(stop.mode))
                            .frame(width: 12, height: 12)
                            .overlay(Circle().stroke(Color.white, lineWidth: 2))
                    }
                    .accessibilityLabel(stop.name)
                }
            }
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        .frame(height: 230)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            if model.deviceLocation == nil && !model.usingPreview
                && model.authorization != .denied && model.authorization != .restricted {
                ProgressView("Finding you")
            } else {
                Image(systemName: "location.slash")
                    .font(.system(size: 36))
                    .foregroundStyle(Theme.accent)
                Text(emptyTitle)
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text(emptyMessage)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Preview Union Square") { model.usePreview() }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .foregroundStyle(.black)
                if model.locationServiceDenied {
                    Button("Open Settings") { openSettings() }
                }
            }
        }
        .padding(28)
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyTitle: String {
        if model.isOutsideNYC { return "Outside the NYC network" }
        if model.authorization == .denied || model.authorization == .restricted { return "Location is off" }
        return "No stops in range"
    }

    private var emptyMessage: String {
        if model.isOutsideNYC {
            return "WYA covers MTA subway, local bus, and express bus stops. Preview Union Square to look around the system."
        }
        if model.authorization == .denied || model.authorization == .restricted {
            return "Allow location while using the app so WYA can list stops around you, or preview a spot in Manhattan."
        }
        return "Move closer to a subway or bus stop, or preview Union Square."
    }

    private func stopRow(_ stop: AccessPoint) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(stop.name)
                        .font(.headline)
                    Text("\(stop.mode.label) · \(Format.distance(stop.distanceMeters)) · \(Format.walk(stop.distanceMeters))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
            }
            arrivalBoard(stop)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func arrivalBoard(_ stop: AccessPoint) -> some View {
        let groups = arrivalGroups(stop)
        if groups.isEmpty {
            Text(model.isRefreshing ? "Checking arrivals…" : "No upcoming arrivals")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        } else {
            ForEach(groups.prefix(5)) { group in
                HStack(spacing: 8) {
                    if let route = model.catalog?.routesByID[group.routeID] {
                        RouteBadge(route: route)
                    } else {
                        RouteBadge(name: group.routeID, colorHex: "4C5563", textHex: "FFFFFF")
                    }
                    if let destination = group.destination {
                        Text(destination)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Text(group.labels.joined(separator: "  ·  "))
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.primary)
                }
                .accessibilityElement(children: .combine)
            }
            if groups.count > 5 {
                Text("\(groups.count - 5) more routes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func arrivalGroups(_ stop: AccessPoint) -> [ArrivalGroup] {
        let now = Date()
        let items = (model.arrivals[stop.id] ?? []).filter { $0.epoch > now.timeIntervalSince1970 - 20 }
        let grouped = Dictionary(grouping: items, by: \.routeID)
        return grouped.map { routeID, arrivals in
            let ordered = arrivals.sorted { $0.epoch < $1.epoch }
            return ArrivalGroup(
                routeID: routeID,
                labels: ordered.prefix(3).map { $0.countdownLabel(at: now) },
                destination: ordered.compactMap(\.destination).first,
                soonest: ordered.first?.epoch ?? .greatestFiniteMagnitude
            )
        }
        .sorted { $0.soonest < $1.soonest }
    }

    private func bannerView(_ banner: StatusBanner) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: banner.tone == .error ? "exclamationmark.triangle.fill" : "info.circle.fill")
            Text(banner.message)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(banner.tone == .warning ? Color.black : Color.primary)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(bannerColor(banner.tone), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func bannerColor(_ tone: BannerTone) -> Color {
        switch tone {
        case .info: return Theme.elevated(scheme)
        case .warning: return Theme.accent
        case .error: return Color.red.opacity(scheme == .dark ? 0.35 : 0.18)
        }
    }

    private func pinColor(_ mode: TransitMode) -> Color {
        switch mode {
        case .subway: return Color(red: 0.10, green: 0.45, blue: 0.85)
        case .localBus: return Color(red: 0.05, green: 0.55, blue: 0.45)
        case .expressBus: return Color(red: 0.45, green: 0.28, blue: 0.62)
        }
    }

    private func aimCamera() {
        guard let coordinate = model.activeCoordinate else { return }
        camera = .region(MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude),
            span: MKCoordinateSpan(latitudeDelta: 0.018, longitudeDelta: 0.018)
        ))
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

private struct ArrivalGroup: Identifiable {
    var id: String { routeID }
    var routeID: String
    var labels: [String]
    var destination: String?
    var soonest: TimeInterval
}

private extension AppModel {
    var locationServiceDenied: Bool {
        authorization == .denied || authorization == .restricted
    }
}
