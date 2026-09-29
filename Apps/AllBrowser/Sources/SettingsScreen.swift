import SwiftUI
import DesignSystem
import StorageKit
import AppLockKit
import AdBlockKit
import BrowserKit
import YouTubeKit

struct SettingsScreen: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var appLock: AppLockService
    @EnvironmentObject private var adBlock: AdBlockService
    @EnvironmentObject private var browser: BrowserController
    @EnvironmentObject private var youtube: YouTubePlaybackService
    @State private var passcodeInput = ""
    @State private var showPasscodeAlert = false
    @State private var lockMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Section("App Lock") {
                    Toggle("Enable App Lock", isOn: Binding(
                        get: { settings.settings.appLockEnabled },
                        set: { enabled in
                            settings.update { $0.appLockEnabled = enabled }
                            if enabled {
                                if !appLock.isPasscodeSet {
                                    showPasscodeAlert = true
                                } else {
                                    appLock.lock()
                                }
                            } else {
                                // Keep passcode stored but stop locking.
                            }
                        }
                    ))
                    Toggle("Lock when leaving app", isOn: Binding(
                        get: { settings.settings.lockOnBackground },
                        set: { value in settings.update { $0.lockOnBackground = value } }
                    ))
                    Picker("Lock grace period", selection: Binding(
                        get: { settings.settings.lockGraceSeconds },
                        set: { value in settings.update { $0.lockGraceSeconds = value } }
                    )) {
                        Text("Immediately").tag(0)
                        Text("1 minute").tag(60)
                        Text("5 minutes").tag(300)
                    }
                    Button(appLock.isPasscodeSet ? "Update Passcode" : "Set Passcode") {
                        showPasscodeAlert = true
                    }
                    if appLock.isPasscodeSet {
                        Button("Clear passcode and disable lock", role: .destructive) {
                            appLock.clearPasscode()
                            settings.update { $0.appLockEnabled = false }
                        }
                    }
                    if let lockMessage {
                        Text(lockMessage).font(.caption).foregroundStyle(ABColor.danger)
                    }
                }

                Section("Ad Blocking") {
                    Toggle("Enable page ad blocking", isOn: Binding(
                        get: { settings.settings.adBlockEnabled },
                        set: { value in
                            settings.update { $0.adBlockEnabled = value }
                            Task { await browser.refreshContentRules() }
                        }
                    ))
                    HStack {
                        Text("Blocked this session")
                        Spacer()
                        Text("\(adBlock.blockedThisSession)")
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Rule version")
                        Spacer()
                        Text(adBlock.pack.version)
                            .foregroundStyle(.secondary)
                    }
                    Button("Restore built-in rules") {
                        adBlock.reloadBundledRules()
                        Task { await browser.refreshContentRules() }
                    }
                }

                Section("YouTube") {
                    Toggle("Enhanced playback", isOn: Binding(
                        get: { settings.settings.youtubeEnhancedPlayback },
                        set: { value in settings.update { $0.youtubeEnhancedPlayback = value } }
                    ))
                    HStack {
                        Text("Temp cache size")
                        Spacer()
                        Text(ByteFormat.string(from: youtube.cacheUsageBytes))
                            .foregroundStyle(.secondary)
                    }
                    Stepper(
                        "TTL \(settings.settings.youtubeCacheTTLHours) hours",
                        value: Binding(
                            get: { settings.settings.youtubeCacheTTLHours },
                            set: { value in settings.update { $0.youtubeCacheTTLHours = value } }
                        ),
                        in: 6...168,
                        step: 6
                    )
                    Button("Clear YouTube temp cache", role: .destructive) {
                        youtube.clearTemporaryCache()
                    }
                    Text("Temp cache is for smooth playback only; not for export or offline downloads.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Browsing") {
                    Toggle("Request desktop site by default", isOn: Binding(
                        get: { settings.settings.desktopModeDefault },
                        set: { value in settings.update { $0.desktopModeDefault = value } }
                    ))
                    Button("Clear History", role: .destructive) {
                        browser.history.clear()
                    }
                }

                Section("About") {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text("1.0.0")
                            .foregroundStyle(.secondary)
                    }
                    Text("AllBrowser — private browsing and local media hub")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Me")
            .navigationBarTitleDisplayMode(.inline)
            .alert("Set Passcode", isPresented: $showPasscodeAlert) {
                SecureField("At least 4 digits", text: $passcodeInput)
                    .keyboardType(.numberPad)
                Button("Save") {
                    do {
                        try appLock.setPasscode(passcodeInput)
                        settings.update { $0.appLockEnabled = true }
                        lockMessage = nil
                        passcodeInput = ""
                        appLock.lock()
                    } catch {
                        lockMessage = error.localizedDescription
                    }
                }
                Button("Cancel", role: .cancel) {
                    passcodeInput = ""
                    if !appLock.isPasscodeSet {
                        settings.update { $0.appLockEnabled = false }
                    }
                }
            } message: {
                Text("Passcode is stored in Keychain and used when Face ID is unavailable.")
            }
        }
    }
}
