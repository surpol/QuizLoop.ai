import SwiftUI

struct AppView: View {
    var body: some View {
        TabView {
            NavigationStack {
                HomeView()
            }
            .tabItem {
                Label("Ask", systemImage: "waveform")
            }

            NavigationStack {
                ProgressScreen()
            }
            .tabItem {
                Label("Practice", systemImage: "rectangle.stack")
            }

            NavigationStack {
                LibraryView()
            }
            .tabItem {
                Label("Library", systemImage: "books.vertical")
            }

            NavigationStack {
                SettingsView()
            }
            .tabItem {
                Label("Settings", systemImage: "gearshape")
            }
        }
        .tint(.teal)
    }
}

private struct SettingsView: View {
    @EnvironmentObject private var assistant: TutorEngine
    @State private var isShowingModelSetup = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Settings")
                        .font(.largeTitle.weight(.semibold))

                    Text("Model, memory, and local runtime status.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                ModelStatusCard(
                    readiness: assistant.modelReadiness,
                    configuration: assistant.modelConfiguration,
                    onConfigure: { isShowingModelSetup = true },
                    onRefresh: {
                        Task {
                            await assistant.refreshModelReadiness()
                        }
                    }
                )

                SettingsSection(title: "Model Details") {
                    SettingsRow(title: "Runtime", value: assistant.modelConfiguration.mode.title, systemImage: "server.rack")
                    SettingsRow(title: "Model", value: modelDisplayName, systemImage: "cpu")

                    if assistant.modelConfiguration.mode == .localServer {
                        SettingsRow(
                            title: "Mac Address",
                            value: assistant.modelConfiguration.normalizedServerURLString,
                            systemImage: "network"
                        )
                    } else {
                        SettingsRow(title: "Device Runtime", value: "Apple Intelligence", systemImage: "iphone.gen3")
                    }

                    SettingsRow(title: "Status", value: assistant.modelReadiness.title, systemImage: assistant.modelReadiness.systemImage)
                }

                SettingsSection(title: "Storage") {
                    SettingsRow(title: "Sources", value: "\(assistant.sources.count)", systemImage: "tray.full")
                    SettingsRow(title: "Flashcards", value: "\(assistant.flashcards.count)", systemImage: "rectangle.stack")
                    SettingsRow(title: "Messages", value: "\(assistant.turns.count)", systemImage: "bubble.left.and.bubble.right")
                }

                Color.clear
                    .frame(height: 72)
            }
            .padding(16)
        }
        .background(WavesTheme.background)
        .navigationTitle("Settings")
        .sheet(isPresented: $isShowingModelSetup) {
            ModelRuntimeSheet(
                readiness: assistant.modelReadiness,
                configuration: assistant.modelConfiguration,
                onSave: { configuration in
                    await assistant.updateModelConfiguration(configuration)
                },
                onCheckAgain: {
                    await assistant.refreshModelReadiness()
                }
            )
        }
    }

    private var modelDisplayName: String {
        switch assistant.modelConfiguration.mode {
        case .localServer:
            assistant.modelConfiguration.modelName
        case .onDevice:
            "SystemLanguageModel"
        }
    }
}

private struct ModelStatusCard: View {
    let readiness: ModelReadiness
    let configuration: ModelRuntimeConfiguration
    let onConfigure: () -> Void
    let onRefresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: readiness.systemImage)
                    .font(.title2)
                    .foregroundStyle(readiness.color)
                    .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 4) {
                    Text(configuration.mode == .onDevice ? "On-device model" : configuration.modelName)
                        .font(.headline)
                        .lineLimit(1)

                    Text(readiness.detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineSpacing(2)
                }

                Spacer(minLength: 0)
            }

            HStack(spacing: 10) {
                Button(action: onConfigure) {
                    Label("Configure", systemImage: "slider.horizontal.3")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.teal)

                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Check model again")
            }
        }
        .padding(14)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)

            VStack(spacing: 0) {
                content
            }
            .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

private struct SettingsRow: View {
    let title: String
    let value: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.teal)
                .frame(width: 26)

            Text(title)
                .font(.subheadline)

            Spacer(minLength: 12)

            Text(value)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
    }
}

private extension ModelReadiness {
    var title: String {
        switch self {
        case .checking:
            "Checking"
        case .ready:
            "Ready"
        case .serverUnavailable:
            "Server unavailable"
        case .modelMissing:
            "Model missing"
        case .deviceNotEligible:
            "Device not eligible"
        case .appleIntelligenceNotEnabled:
            "Apple Intelligence off"
        case .appleModelNotReady:
            "Model preparing"
        }
    }

    var detail: String {
        switch self {
        case .checking:
            "Waves is checking the selected model runtime."
        case .ready:
            "This is the model Waves is currently using."
        case .serverUnavailable:
            "Waves cannot reach the configured local model server."
        case .modelMissing(let model):
            "The server is reachable, but \(model) is not installed."
        case .deviceNotEligible:
            "This device cannot run the selected on-device model runtime."
        case .appleIntelligenceNotEnabled:
            "Turn on Apple Intelligence in Settings to use on-device mode."
        case .appleModelNotReady:
            "The on-device model is still preparing."
        }
    }

    var systemImage: String {
        switch self {
        case .checking:
            "hourglass"
        case .ready:
            "checkmark.circle.fill"
        case .serverUnavailable:
            "wifi.exclamationmark"
        case .modelMissing:
            "arrow.down.circle"
        case .deviceNotEligible:
            "exclamationmark.triangle"
        case .appleIntelligenceNotEnabled:
            "gear.badge"
        case .appleModelNotReady:
            "icloud.and.arrow.down"
        }
    }

    var color: Color {
        switch self {
        case .ready:
            .teal
        case .checking, .appleModelNotReady:
            .secondary
        case .modelMissing, .appleIntelligenceNotEnabled:
            .orange
        case .serverUnavailable, .deviceNotEligible:
            .red
        }
    }
}
