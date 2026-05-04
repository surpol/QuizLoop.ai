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
        }
        .tint(.teal)
    }
}
