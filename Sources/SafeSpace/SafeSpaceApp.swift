import SwiftUI
import AppKit

@main
struct FukMacStorageApp: App {
    @StateObject private var model = AppModel()
    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .frame(minWidth: 1000, minHeight: 680)
                .onAppear { model.refreshCapacity(); NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true) }
        }
        .defaultSize(width: 1180, height: 780)
        .commands { CommandGroup(replacing: .newItem) {} }
    }
}
