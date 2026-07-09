import SwiftUI
import StallAlertKit

struct StationPickerView: View {
    @Environment(SessionController.self) private var session
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        // NavigationStack so the title renders inside the bare .sheet.
        NavigationStack {
            stationList
        }
    }

    private var stationList: some View {
        List {
            Button {
                session.selectAutoStation(); dismiss()
            } label: {
                HStack {
                    Text("Auto (nearest)")
                    Spacer()
                    if !session.manualStationActive { Image(systemName: "checkmark") }
                }
            }
            if session.nearbyStations.isEmpty {
                Text("No candidates yet").font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(session.nearbyStations, id: \.id) { s in
                Button {
                    session.selectStation(s); dismiss()
                } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(s.name).lineLimit(1)
                            Text("\(s.distanceKm, specifier: "%.1f") km")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if session.manualStationActive && session.conditions?.station?.id == s.id {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        }
        .navigationTitle("Station")
    }
}
