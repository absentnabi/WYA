import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Group {
            if model.catalog == nil && model.loadError == nil {
                ProgressView("Loading NYC stops")
                    .tint(Theme.accent)
            } else if let loadError = model.loadError {
                ContentUnavailableView {
                    Label("Stops unavailable", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(loadError)
                }
            } else {
                TabView {
                    NearbyView()
                        .tabItem { Label("Nearby", systemImage: "tram.fill") }
                    PlanView()
                        .tabItem { Label("Plan", systemImage: "point.topleft.down.to.point.bottomright.curvepath") }
                }
                .tint(Theme.accent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background(scheme))
    }
}
