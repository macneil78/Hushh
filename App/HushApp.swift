import HushCore
import HushUI
import SwiftUI

@main
struct HushApp: App {
    @NSApplicationDelegateAdaptor(HushAppDelegate.self) private var appDelegate
    @State private var model = AppModel(loadingFrom: .main)

    var body: some Scene {
        HushScenes(model: model)
    }
}
