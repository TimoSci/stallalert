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
    private let secrets = KeychainStore()

    var body: some View {
        Form {
            Section("Alert threshold") {
                Stepper("\(Int(threshold)) kn", value: $threshold, in: 5...30, step: 1)
            }
            Section("Service") {
                TextField("https://…", text: $serviceURL)
                TextField("API token", text: $serviceToken)
            }
            Section("Windguru (fallback)") {
                TextField("Username", text: $wgUser)
                SecureField("Secondary (API) password", text: $wgMicroPass)
            }
            Section {
                Button("Test alarm") { AlertPresenter().fire() }
                Button("Save") { save() }
            }
        }
        .onAppear {
            threshold = session.settings.thresholdKn
            serviceURL = session.settings.serviceURL?.absoluteString ?? ""
        }
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
