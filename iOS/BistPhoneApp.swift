#if os(iOS)
import SwiftUI
import UIKit

@MainActor
final class PhoneAppModel: ObservableObject {
    let store: AppStore
    let note: NoteStore
    let sync: BistSyncCoordinator

    init() {
        let testDirectory = PhoneLaunchConfiguration.testDirectory()
        precondition(ProcessInfo.processInfo.environment["BIST_UI_TEST_ID"] == nil || testDirectory != nil,
                     "UI tests require a valid isolated test identifier")
        let store = AppStore(directory: testDirectory)
        let note = NoteStore(directory: store.directory, prepareForWrite: store.prepareForAuxiliaryWrite)
        self.store = store
        self.note = note
        sync = BistSyncCoordinator(store: store, note: note)
    }
}

@MainActor
final class PhoneApplicationDelegate: NSObject, UIApplicationDelegate {
    weak var sync: BistSyncCoordinator?

    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        Task { @MainActor in
            await sync?.refresh()
            completionHandler(.noData)
        }
    }
}

@main
struct BistPhoneApp: App {
    @UIApplicationDelegateAdaptor(PhoneApplicationDelegate.self) private var delegate
    @StateObject private var model = PhoneAppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            PhoneRootView(store: model.store, note: model.note, sync: model.sync)
                .tint(Color(red: 0.71, green: 0.28, blue: 0.10))
                .defaultAppStorage(PhoneLaunchConfiguration.preferences)
                .task {
                    delegate.sync = model.sync
                    if model.sync.isAvailable && model.sync.enabled {
                        UIApplication.shared.registerForRemoteNotifications()
                    }
                    await model.sync.refresh()
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { Task { await model.sync.refresh() } }
                    if phase == .background { model.note.save() }
                }
                .onChange(of: model.sync.enabled) { _, enabled in
                    if enabled && model.sync.isAvailable { UIApplication.shared.registerForRemoteNotifications() }
                }
        }
    }
}
#endif
