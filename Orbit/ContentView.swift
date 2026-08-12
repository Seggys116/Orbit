import SwiftUI

struct ContentView: View {
    var body: some View {
        RootView()
            .orbitEnvironment(AppEnvironment.shared)
    }
}

#Preview {
    ContentView()
}
