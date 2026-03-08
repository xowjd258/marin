import SwiftUI

@main
struct marinApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
#if os(iOS)
                .onAppear {
                    UIApplication.shared.isIdleTimerDisabled = true
                }
#endif
        }
    }
}
