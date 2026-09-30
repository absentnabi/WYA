import SwiftUI
import WYACore

struct PlanView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    @State private var query = ""

    private let suggestions = [
        "from here to Times Square",
        "Union Square to Grand Central",
        "from here to Brooklyn Museum",
        "Grand Central to Yankee Stadium"
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Ask for a trip in plain language. WYA times the walk, the wait, and the ride from MTA stops instead of letting the model invent a schedule.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    suggestionRow

                    if let planError = model.planError {
                        Label(planError, systemImage: "exclamationmark.circle")
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.red.opacity(scheme == .dark ? 0.28 : 0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }

                    if model.isPlanning {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Timing the walk, wait, and ride…")
                                .font(.subheadline)
                        }
                        .padding(.vertical, 8)
                    }

                    ForEach(model.history) { record in
                        planCard(record)
                    }
                }
                .padding(16)
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
            }
            .background(Theme.background(scheme))
            .navigationTitle("Plan")
            .safeAreaInset(edge: .bottom) { composer }
            .scrollDismissesKeyboard(.interactively)
        }
    }

    private var suggestionRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(suggestions, id: \.self) { suggestion in
                    Button(suggestion) { submit(suggestion) }
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Theme.card(scheme), in: Capsule())
                        .overlay(Capsule().stroke(Theme.elevated(scheme), lineWidth: 1))
                }
            }
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Where to? Try “from here to Barclays”", text: $query, axis: .vertical)
                .lineLimit(1...3)
                .textInputAutocapitalization(.sentences)
                .submitLabel(.go)
                .onSubmit { submit(query) }
                .padding(12)
                .background(Theme.card(scheme), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            Button {
                submit(query)
            } label: {
                Image(systemName: "arrow.up")
                    .font(.headline)
                    .foregroundStyle(.black)
                    .frame(width: 44, height: 44)
                    .background(Theme.accent, in: Circle())
            }
            .disabled(model.isPlanning || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel("Plan trip")
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(.ultraThinMaterial)
    }

    private func planCard(_ record: PlanRecord) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(record.query)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if record.options.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(record.options.enumerated()), id: \.offset) { index, option in
                            Button {
                                model.select(recordID: record.id, option: index)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(option.displayMinutes) min")
                                        .font(.headline)
                                    Text(routeSummary(option))
                                        .font(.caption2)
                                        .lineLimit(1)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .foregroundStyle(index == record.selected ? Color.black : Color.primary)
                                .background(
                                    index == record.selected ? Theme.accent : Theme.elevated(scheme),
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                                )
                            }
                        }
                    }
                }
            }
            DurationBreakdown(plan: record.plan)
            Text(record.spoken)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
            Text(record.usedModel && record.selected == 0
                 ? "Written by \(record.modelName) from the calculated itinerary."
                 : "Times are calculated from MTA schedules, live arrivals when a key is set, and a walking estimate.")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(record.notes, id: \.self) { note in
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(Theme.card(scheme), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func routeSummary(_ plan: TripPlan) -> String {
        let names = plan.legs.compactMap { leg -> String? in
            guard let routeID = leg.routeID, leg.kind == .ride else { return nil }
            return model.catalog?.routesByID[routeID]?.shortName ?? routeID
        }
        return names.isEmpty ? "Walk" : names.joined(separator: " · ")
    }

    private func submit(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        query = trimmed
        Task { await model.plan(query: trimmed) }
    }
}

struct DurationBreakdown: View {
    let plan: TripPlan

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(plan.displayMinutes)")
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("min")
                    .font(.title3.weight(.semibold))
                Spacer()
                Text(plan.destinationName)
                    .font(.headline)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(2)
            }
            proportionBar
            ForEach(Array(plan.legs.enumerated()), id: \.offset) { _, leg in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: icon(leg.kind))
                        .frame(width: 18)
                        .foregroundStyle(color(for: leg))
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(leg.title)
                            .font(.subheadline.weight(.semibold))
                        Text(leg.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Text(Format.legMinutes(leg.seconds))
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                }
            }
        }
    }

    private var proportionBar: some View {
        GeometryReader { proxy in
            let total = max(1, plan.totalSeconds)
            HStack(spacing: 3) {
                ForEach(Array(plan.legs.enumerated()), id: \.offset) { _, leg in
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(color(for: leg))
                        .frame(width: max(6, proxy.size.width * CGFloat(max(leg.seconds, 1)) / CGFloat(total)))
                }
            }
        }
        .frame(height: 8)
    }

    private func icon(_ kind: TripLeg.Kind) -> String {
        switch kind {
        case .walk: return "figure.walk"
        case .wait: return "clock"
        case .ride: return "tram.fill"
        }
    }

    private func color(for leg: TripLeg) -> Color {
        switch leg.kind {
        case .walk: return Theme.walk
        case .wait: return Theme.wait
        case .ride: return Theme.accent
        }
    }
}
