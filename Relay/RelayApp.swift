import SwiftUI

@main
struct RelayApp: App {
    @StateObject private var store = RelayStore()
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            WorkspaceView().environmentObject(store)
                .tint(.primary)
                .task { await store.restore() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { Task { await store.foreground() } }
                    if phase == .background { store.stopUpdates() }
                }
        }
    }
}
