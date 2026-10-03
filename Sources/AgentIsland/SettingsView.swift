import SwiftUI

import IslandCore

struct SettingsView: View {
    let store: StateStore?
    @AppStorage("hideWhenEmpty") private var hideWhenEmpty = false
    @AppStorage(PreferenceKeys.chimeMuted) private var chimeMuted = false
    @AppStorage(PreferenceKeys.showExecThreads) private var showExecThreads = false
    @AppStorage(PreferenceKeys.screenSelectionMode) private var screenSelectionMode = ScreenSelectionMode.primary.rawValue
    @AppStorage("glassFrostRadiusNotch") private var notchFrostRadius = NotchGlassStyle.defaultFrostRadius
    @AppStorage("glassTintOpacityNotch") private var notchTintOpacity = NotchGlassStyle.defaultTintOpacity
    @AppStorage("glassFrostRadiusPill") private var pillFrostRadius = NotchGlassStyle.defaultFrostRadius
    @AppStorage("glassTintOpacityPill") private var pillTintOpacity = NotchGlassStyle.defaultTintOpacity

    var body: some View {
        Form {
            Section {
                Toggle("Hide when no sessions are active", isOn: $hideWhenEmpty)
                Toggle("Mute chime", isOn: $chimeMuted)
                Toggle("Show Codex exec threads", isOn: $showExecThreads)
                Picker("Show the pill on", selection: $screenSelectionMode) {
                    Text("Primary display").tag(ScreenSelectionMode.primary.rawValue)
                    Text("All displays").tag(ScreenSelectionMode.allDisplays.rawValue)
                }
                // A legacy "pointer"/"focusedWindow" value would leave the
                // picker blank; store its migrated value the first time
                // Settings opens.
                .onAppear {
                    let normalized = ScreenSelectionMode(storedValue: screenSelectionMode).rawValue
                    if normalized != screenSelectionMode {
                        screenSelectionMode = normalized
                    }
                }
            } header: {
                Text("General")
            }

            Section {
                appearanceControls(frost: $notchFrostRadius, tint: $notchTintOpacity)
            } header: {
                Text("Appearance · Notch display")
            } footer: {
                Text("The band beside the camera always stays black; Tint sets how dark the glass below it fades.")
            }

            Section {
                appearanceControls(frost: $pillFrostRadius, tint: $pillTintOpacity)
            } header: {
                Text("Appearance · External displays")
            } footer: {
                Text("Frosted diffuses what shows through the glass; Tint darkens its base. Each kind of display keeps its own values.")
            }

            Section {
                Button("Reset custom session names") {
                    store?.clearAllSessionNames()
                }
                .disabled(store == nil)
            } header: {
                Text("Sessions")
            } footer: {
                Text("Sessions renamed from the notch menu go back to their live tab titles.")
            }

            Section("About") {
                LabeledContent("Version", value: Self.versionText)
                Button("Quit Agent Island") {
                    NSApp.terminate(nil)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
    }

    /// One pair of appearance sliders; each display kind gets its own pair
    /// bound to its own stored values, plus a reset that appears only once
    /// that pair leaves the hand-tuned defaults.
    @ViewBuilder
    private func appearanceControls(
        frost: Binding<Double>,
        tint: Binding<Double>
    ) -> some View {
        Slider(
            value: frost,
            in: NotchGlassStyle.frostRadiusRange
        ) {
            Text("Frosted")
        } minimumValueLabel: {
            Image(systemName: "circle")
                .foregroundStyle(.secondary)
                .accessibilityLabel("Clear glass")
        } maximumValueLabel: {
            Image(systemName: "circle.fill")
                .foregroundStyle(.secondary)
                .accessibilityLabel("Frosted glass")
        }
        Slider(
            value: tint,
            in: NotchGlassStyle.tintOpacityRange
        ) {
            Text("Tint")
        } minimumValueLabel: {
            Image(systemName: "sun.max")
                .foregroundStyle(.secondary)
                .accessibilityLabel("Transparent tint")
        } maximumValueLabel: {
            Image(systemName: "moon.fill")
                .foregroundStyle(.secondary)
                .accessibilityLabel("Dark tint")
        }
        if frost.wrappedValue != NotchGlassStyle.defaultFrostRadius
            || tint.wrappedValue != NotchGlassStyle.defaultTintOpacity {
            Button("Reset to default appearance") {
                frost.wrappedValue = NotchGlassStyle.defaultFrostRadius
                tint.wrappedValue = NotchGlassStyle.defaultTintOpacity
            }
        }
    }

    /// `swift run` executes outside the app bundle, where no Info.plist
    /// version exists — label those builds instead of hiding the row.
    private static var versionText: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development"
    }
}
