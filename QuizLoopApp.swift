import SwiftUI

@main
struct QuizLoopApp: App {
    @StateObject private var tutorEngine = TutorEngine()
    @StateObject private var speechService = SpeechService()

    var body: some Scene {
        WindowGroup {
            AppView()
                .environmentObject(tutorEngine)
                .environmentObject(speechService)
        }
    }
}
