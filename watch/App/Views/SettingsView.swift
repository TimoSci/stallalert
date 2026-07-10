import SwiftUI
import StallAlertKit

struct SettingsView: View {
    @Environment(SessionController.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var threshold: Double = 12
    @State private var serviceURL = ""
    @State private var serviceToken = ""
    @State private var wgUser = ""
    @State private var wgMicroPass = ""
    @State private var tokenSaved = false
    @State private var microPassSaved = false
    @State private var forecastModel = "wg"
    private let secrets = KeychainStore()

    var body: some View {
        Form {
            Section("Alert threshold") {
                Stepper("\(Int(threshold)) kn", value: $threshold, in: 5...30, step: 1)
            }
            Section {
                Picker("Forecast source", selection: $forecastModel) {
                    Text("WG blend (default)").tag("wg")
                    ForEach(session.availableModels.filter { $0.id != "wg" }, id: \.id) { m in
                        Text(m.name).tag(m.id)
                    }
                }
                .onChange(of: forecastModel) { _, newValue in
                    var s = session.settings
                    s.forecastModel = newValue
                    s.save(defaults: .standard, secrets: secrets)
                    session.settings = s
                    Task { await session.refreshTick() }
                }
            }
            Section("Service") {
                TextField("https://…", text: $serviceURL)
                TextField("API token", text: $serviceToken)
                statusLine("token", saved: tokenSaved)
            }
            Section("Windguru (fallback)") {
                TextField("Username", text: $wgUser)
                SecureField("Secondary (API) password", text: $wgMicroPass)
                statusLine("password", saved: microPassSaved)
            }
            Section {
                Button("Test alarm") { AlertPresenter().fire() }
                Button("Save") { save() }
            }
        }
        .onAppear {
            threshold = session.settings.thresholdKn
            serviceURL = session.settings.serviceURL?.absoluteString ?? ""
            forecastModel = session.settings.forecastModel
            wgUser = secrets.get(Settings.wgUsernameKey) ?? ""
            tokenSaved = secrets.get(Settings.serviceTokenKey) != nil
            microPassSaved = secrets.get(Settings.wgMicroPasswordKey) != nil
        }
    }

    // Secret values are never displayed; only their presence is.
    private func statusLine(_ label: String, saved: Bool) -> some View {
        Text(saved ? "\(label): saved ✓" : "\(label): not set")
            .font(.footnote)
            .foregroundStyle(saved ? .green : .secondary)
    }

    private func save() {
        var s = session.settings
        s.thresholdKn = threshold
        s.serviceURL = URL(string: serviceURL)
        s.save(defaults: .standard, secrets: secrets)
        if !serviceToken.isEmpty { secrets.set(Settings.serviceTokenKey, serviceToken) }
        if !wgUser.isEmpty { secrets.set(Settings.wgUsernameKey, wgUser) }
        if !wgMicroPass.isEmpty { secrets.set(Settings.wgMicroPasswordKey, wgMicroPass) }
        session.settings = s
        dismiss()
    }
}
