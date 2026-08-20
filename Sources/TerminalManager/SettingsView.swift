import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                section("General") {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Open at login")
                                .font(.system(size: 12, weight: .medium))
                            Text("Registers this copy as a login item. Enabling it here replaces whatever other Terminal Manager path was registered.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 12)
                        Toggle("", isOn: Binding(
                            get: { state.openAtLogin },
                            set: { state.setOpenAtLogin($0) }
                        ))
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .controlSize(.small)
                    }
                }

                section("This copy") {
                    Text(PrivacySettings.displayPath)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(PrivacySettings.isInstalledCopy
                         ? "Login and Full Disk Access apply only to this file. The copy in your git repo is a different app to macOS."
                         : "This is the build-folder copy. Login and Full Disk Access you grant here do not cover /Applications/TerminalManager.app, and the other way around.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                section("Folder access") {
                    Text("macOS asks the first time the app looks at Desktop, Documents or Downloads — for example a session that started in Downloads. Allow is enough for that folder, on this copy only.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("Full Disk Access is also per copy. Add each Terminal Manager you actually launch, or keep one in /Applications and always open that.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Button("Open Full Disk Access…") {
                        PrivacySettings.openFullDiskAccess()
                    }
                    .font(.system(size: 12))

                    Button("Reveal in Finder") {
                        PrivacySettings.revealAppBundle()
                    }
                    .font(.system(size: 12))
                    .help("Drag this app into the Full Disk Access list if it is not already there")
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .tracking(0.4)
            content()
        }
    }
}

enum PrivacySettings {
    static var appURL: URL { Bundle.main.bundleURL }

    static var displayPath: String {
        let path = appURL.path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) { return "~" + path.dropFirst(home.count) }
        return path
    }

    static var isInstalledCopy: Bool {
        appURL.path.hasPrefix("/Applications/")
    }

    static func openFullDiskAccess() {
        let candidates = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
        ]
        for candidate in candidates {
            if let url = URL(string: candidate), NSWorkspace.shared.open(url) { return }
        }
    }

    static func revealAppBundle() {
        let url = Bundle.main.bundleURL
        if url.pathExtension == "app" {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: "")
        }
    }
}
