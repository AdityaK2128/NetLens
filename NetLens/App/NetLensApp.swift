import SwiftUI
import AppKit

@main
struct NetLensApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppDelegate.model

    var body: some Scene {
        Window("NetLens", id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 1040, minHeight: 680)
        }
        .defaultSize(width: 1440, height: 900)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            SidebarCommands()
            CommandMenu("Go") {
                ForEach(Array(NavSection.allCases.enumerated()), id: \.element) { i, s in
                    if i < 9 {
                        Button(s.title) { model.selection = s }
                            .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
                    } else {
                        Button(s.title) { model.selection = s }
                    }
                }
            }
        }

        MenuBarExtra {
            MenuBarView()
                .environment(model)
        } label: {
            MenuBarLabel()
                .environment(model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            Self.model.bootstrap()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

struct SettingsView: View {
    @AppStorage(GeoIPService.enabledKey) private var geoEnabled = true
    @AppStorage("menubar.showRates") private var showRates = true
    @State private var cleared = false

    var body: some View {
        Form {
            Section("Privacy") {
                Toggle("Geolocate public IP addresses", isOn: $geoEnabled)
                Text("Public addresses of hosts you connect to are sent to ip-api.com to look up city, network operator and ASN — this powers the globe and hop annotations. Private and local addresses never leave your Mac. Results are cached for 7 days.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(cleared ? "Cache cleared" : "Clear geolocation cache") {
                    Task { await GeoIPService.shared.clearCache(); cleared = true }
                }
                .disabled(cleared)
            }
            Section("Menu bar") {
                Toggle("Show live throughput in the menu bar", isOn: $showRates)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 320)
    }
}
