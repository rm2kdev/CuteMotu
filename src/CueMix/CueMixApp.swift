import SwiftUI
import AppKit
@main struct CuteMixApp:App {
    @StateObject private var model=MixerModel()
    var body:some Scene {
        WindowGroup("Cute Mix USB Prototype") {MixerRoot().environmentObject(model).environmentObject(model.meters)}
            .defaultSize(width:1360,height:900)
            .commands {CommandGroup(replacing:.newItem) {} ; CommandGroup(after:.saveItem) {
                Button("Save preset…"){model.savePreset()}.keyboardShortcut("s").disabled(!model.ready)
                Button("Load preset…"){model.loadPreset()}.keyboardShortcut("o").disabled(!model.ready)
                Divider();Button("Refresh settings"){model.refresh()}.keyboardShortcut("r")
            }}
    }
}
