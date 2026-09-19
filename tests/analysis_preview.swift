import SwiftUI
@main struct AnalysisPreviewApp: App {
    @StateObject private var mixer = MixerModel(startWorker: false)
    init() { UserDefaults.standard.set("analysis", forKey: "layout.lastPage") }
    var body: some Scene {
        WindowGroup("Cute Mix Analysis · Offline visual test") {
            MixerRoot().environmentObject(mixer).environmentObject(mixer.meters)
        }.defaultSize(width: 1120, height: 720)
    }
}
