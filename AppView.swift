import SwiftUI

struct AppView: View {
    @State private var selectedTab: AppTab = .ask
    @State private var draftPrompt = ""
    @State private var activeSourceID: UUID?

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                AskView(
                    draftPrompt: $draftPrompt,
                    selectedSourceID: $activeSourceID
                ) {
                    selectedTab = .notes
                } onOpenSettings: {
                    selectedTab = .settings
                }
            }
            .tabItem {
                Label("Home", systemImage: "house")
            }
            .tag(AppTab.ask)

            NavigationStack {
                NotesView(activeSourceID: $activeSourceID) { prompt in
                    draftPrompt = prompt
                    selectedTab = .ask
                }
            }
            .tabItem {
                Label("Library", systemImage: "books.vertical")
            }
            .tag(AppTab.notes)

            NavigationStack {
                QuizzesView()
            }
            .tabItem {
                Label("History", systemImage: "clock.arrow.circlepath")
            }
            .tag(AppTab.quizzes)

            NavigationStack {
                SettingsView()
            }
            .tabItem {
                Label("Settings", systemImage: "gearshape")
            }
            .tag(AppTab.settings)
        }
        .tint(.teal)
    }
}

private enum AppTab {
    case ask
    case notes
    case quizzes
    case settings
}
