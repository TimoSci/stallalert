import Foundation
import StallAlertKit

/// Developer-provisioning path: on DEBUG launches from Xcode, credentials can
/// be supplied as scheme environment variables (typed/pasted on the Mac) and
/// are persisted into the watch's Keychain/UserDefaults on first launch, so
/// they never have to be entered on the watch keyboard.
///
/// Edit Scheme → Run → Arguments → Environment Variables:
///   STALLALERT_SERVICE_URL        e.g. https://stallalert.com
///   STALLALERT_SERVICE_TOKEN      the server's API_TOKEN
///   STALLALERT_WG_USERNAME        Windguru username
///   STALLALERT_WG_MICRO_PASSWORD  Windguru secondary (micro/API) password
///
/// Keys AND values are whitespace-trimmed before matching/storing — pasted
/// scheme entries routinely pick up stray leading/trailing spaces, which
/// otherwise fail silently. Absent or empty(-after-trim) variables leave the
/// stored value untouched, so this never wipes existing configuration. The
/// scheme lives inside the git-ignored .xcodeproj and is wiped by
/// `xcodegen generate`, so pasted secrets never reach version control.
enum CredentialSeeder {
    static func seedFromLaunchEnvironmentIfPresent() {
        #if DEBUG
        let secrets = KeychainStore()
        var settings = Settings.load(defaults: .standard, secrets: secrets)
        var touched = false

        let secretKeys: [String: String] = [
            "STALLALERT_SERVICE_TOKEN": Settings.serviceTokenKey,
            "STALLALERT_WG_USERNAME": Settings.wgUsernameKey,
            "STALLALERT_WG_MICRO_PASSWORD": Settings.wgMicroPasswordKey,
        ]

        for (rawKey, rawValue) in ProcessInfo.processInfo.environment {
            let key = rawKey.trimmingCharacters(in: .whitespaces)
            let value = rawValue.trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { continue }

            if key == "STALLALERT_SERVICE_URL" {
                if let url = URL(string: value), url.host != nil {
                    settings.serviceURL = url
                    touched = true
                }
            } else if let secretKey = secretKeys[key] {
                secrets.set(secretKey, value)
                touched = true
            }
        }

        if touched {
            settings.save(defaults: .standard, secrets: secrets)
        }
        #endif
    }
}
