import SwiftUI
import CoreAudio

// Uses a generic HAL boolean control so volume mode cannot rename the sound output.
enum AudioVolumeAccess {
    struct State {var device:AudioDeviceID=0;var modeControl:AudioObjectID=0;var supported=false;var enabled=false;var scalar:Float=1;var muted:UInt32=0}
    static func address(_ selector:AudioObjectPropertySelector)->AudioObjectPropertyAddress {
        .init(mSelector:selector,mScope:kAudioDevicePropertyScopeOutput,mElement:kAudioObjectPropertyElementMain)
    }
    static func read()->State {
        var list=AudioObjectPropertyAddress(mSelector:kAudioHardwarePropertyDevices,mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain)
        var size:UInt32=0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),&list,0,nil,&size)==0 else{return State()}
        var devices=[AudioDeviceID](repeating:0,count:Int(size)/MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),&list,0,nil,&size,&devices)==0 else{return State()}
        for device in devices {
            var uidAddress=AudioObjectPropertyAddress(mSelector:kAudioDevicePropertyDeviceUID,mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain)
            var uid:Unmanaged<CFString>?;var uidSize=UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            let uidResult=withUnsafeMutablePointer(to:&uid){AudioObjectGetPropertyData(device,&uidAddress,0,nil,&uidSize,$0)}
            guard uidResult==0, let uid=uid?.takeRetainedValue(), uid as String == "org.cutemix.usbaudio.prototype" else{continue}
            var aliveAddress=AudioObjectPropertyAddress(mSelector:kAudioDevicePropertyDeviceIsAlive,mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain)
            var alive:UInt32=0;var aliveBytes:UInt32=4
            guard AudioObjectGetPropertyData(device,&aliveAddress,0,nil,&aliveBytes,&alive)==0,alive != 0 else{continue}
            var state=State();state.device=device
            var controlsAddress=AudioObjectPropertyAddress(mSelector:kAudioObjectPropertyControlList,mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain)
            var controlsSize:UInt32=0
            if AudioObjectGetPropertyDataSize(device,&controlsAddress,0,nil,&controlsSize)==0 {
                var controls=[AudioObjectID](repeating:0,count:Int(controlsSize)/MemoryLayout<AudioObjectID>.size)
                if AudioObjectGetPropertyData(device,&controlsAddress,0,nil,&controlsSize,&controls)==0 {
                    for control in controls {
                        var classAddress=AudioObjectPropertyAddress(mSelector:kAudioObjectPropertyClass,mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain)
                        var controlClass:AudioClassID=0;var classSize:UInt32=4
                        guard AudioObjectGetPropertyData(control,&classAddress,0,nil,&classSize,&controlClass)==0,controlClass==kAudioBooleanControlClassID else{continue}
                        var nameAddress=AudioObjectPropertyAddress(mSelector:kAudioObjectPropertyName,mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain)
                        var name:Unmanaged<CFString>?;var nameSize=UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
                        let result=withUnsafeMutablePointer(to:&name){AudioObjectGetPropertyData(control,&nameAddress,0,nil,&nameSize,$0)}
                        if result==0,let name=name?.takeRetainedValue(),name as String == "macOS volume control" {state.modeControl=control;break}
                    }
                }
            }
            var mode:UInt32=0;var modeAddress=AudioObjectPropertyAddress(mSelector:kAudioBooleanControlPropertyValue,mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain);var bytes:UInt32=4
            state.supported=state.modeControl != 0 && AudioObjectGetPropertyData(state.modeControl,&modeAddress,0,nil,&bytes,&mode)==0 && mode<=1
            state.enabled=state.supported && mode==1
            var volumeAddress=address(kAudioDevicePropertyVolumeScalar);bytes=4
            _=AudioObjectGetPropertyData(device,&volumeAddress,0,nil,&bytes,&state.scalar)
            var muteAddress=address(kAudioDevicePropertyMute);bytes=4
            _=AudioObjectGetPropertyData(device,&muteAddress,0,nil,&bytes,&state.muted)
            return state
        }
        return State()
    }
    static func setEnabled(_ value:UInt32)->OSStatus {
        let state=read();guard state.supported else{return kAudioHardwareBadDeviceError}
        var a=AudioObjectPropertyAddress(mSelector:kAudioBooleanControlPropertyValue,mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain);var v=value
        return AudioObjectSetPropertyData(state.modeControl,&a,0,nil,UInt32(MemoryLayout<UInt32>.size),&v)
    }
}
@MainActor final class AudioVolumeSettings:ObservableObject {
    @Published var state=AudioVolumeAccess.State()
    @Published var busy=false
    @Published var error:String?
    func refresh() async {state=await Task.detached{AudioVolumeAccess.read()}.value}
    func setEnabled(_ value:Bool) {
        guard !busy else{return};busy=true;error=nil
        Task {
            let result=await Task.detached{AudioVolumeAccess.setEnabled(UInt32(value ? 1:0))}.value
            if result==0 {
                for _ in 0..<30 {
                    await refresh();if state.enabled==value {break}
                    try? await Task.sleep(nanoseconds:100_000_000)
                }
                if state.enabled != value {error="The driver has not completed the volume-mode change. Try again when audio apps are stopped."}
            } else {NSLog("828x volume setting failed (%d)",result);error="Could not change this setting. Check the driver connection and try again."}
            busy=false
        }
    }
}
struct AudioVolumeSettingsView:View {
    @StateObject private var volume=AudioVolumeSettings()
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            Toggle("macOS volume control",isOn:Binding(get:{volume.state.enabled},set:volume.setEnabled))
                .toggleStyle(.switch).disabled(!volume.state.supported || volume.busy)
            Text("Use the Mac’s volume keys, mute key and system slider for computer playback on Main L/R (outputs 1–2). Other outputs, recording and direct hardware monitoring keep their own levels.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            if !volume.state.supported {Text(volume.state.device==0 ? "Connect the 828x and start the Cute Mix USB service to change this setting." : "Start the Cute Mix USB service to use this setting.").font(.caption).foregroundStyle(.orange)}
            else if volume.busy {ProgressView("Updating driver…").controlSize(.small)}
            else {Text(volume.state.enabled ? (volume.state.muted != 0 ? "Main L/R computer playback is muted." : "Enabled · choose Cute Motu 828x as your Mac’s sound output.") : "Off · computer playback uses fixed level (0 dB). Disabling restores full level.").font(.caption).foregroundStyle(.secondary)}
            if let error=volume.error {Text(error).font(.caption).foregroundStyle(.orange)}
        }.task {
            while !Task.isCancelled {await volume.refresh();try? await Task.sleep(nanoseconds:1_000_000_000)}
        }
    }
}

// Rate changes use Core Audio's normal configuration transaction, shared with
// Audio MIDI Setup and DAWs. The driver owns USB quiescence and clock recovery.
enum AudioRateAccess {
    struct State {
        var device:AudioDeviceID=0
        var rate:Double=0
        var rates:[Double]=[]
        var inputs:UInt32=0
        var outputs:UInt32=0
        var label:String {rate>0 ? String(format:"%g kHz",rate/1000):"—"}
        var channelLabel:String {device==0 ? "—":"\(inputs) in / \(outputs) out"}
        var capabilities:String {
            if rate>96000 {return "Analog I/O and stereo return. Digital I/O, EQ, dynamics and reverb are unavailable. Headphones mirror an output pair."}
            if rate>48000 {return "Four ADAT channels per bank. EQ and dynamics remain available; reverb is unavailable. Headphones mirror an output pair."}
            return "Eight ADAT channels per bank, independent Phones playback, EQ, dynamics and reverb."
        }
        var outputRouting:String {
            let analog="Core Audio output 1–2 → Main L/R\n3–10 → Analog 1–8"
            if rate>96000 {return analog}
            if rate>48000 {return analog+"\n11–12 → S/PDIF\n13–16 → ADAT A 1–4\n17–20 → ADAT B 1–4"}
            return analog+"\n11–12 → Phones\n13–14 → S/PDIF\n15–22 → ADAT A 1–8\n23–30 → ADAT B 1–8"
        }
    }
    static func read()->State {
        var result=State();result.device=AudioVolumeAccess.read().device
        guard result.device != 0 else{return result}
        var a=AudioObjectPropertyAddress(mSelector:kAudioDevicePropertyNominalSampleRate,mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain)
        var size=UInt32(MemoryLayout<Double>.size)
        guard AudioObjectGetPropertyData(result.device,&a,0,nil,&size,&result.rate)==0 else{return State()}
        a.mSelector=kAudioDevicePropertyAvailableNominalSampleRates;size=0
        if AudioObjectGetPropertyDataSize(result.device,&a,0,nil,&size)==0 {
            var ranges=[AudioValueRange](repeating:AudioValueRange(),count:Int(size)/MemoryLayout<AudioValueRange>.size)
            if !ranges.isEmpty && AudioObjectGetPropertyData(result.device,&a,0,nil,&size,&ranges)==0 {
                result.rates=[44100.0,48000,88200,96000,176400,192000].filter {rate in ranges.contains{rate >= $0.mMinimum && rate <= $0.mMaximum}}
            }
        }
        for input in [true,false] {
            a=AudioObjectPropertyAddress(mSelector:kAudioDevicePropertyStreamFormat,mScope:input ? kAudioObjectPropertyScopeInput:kAudioObjectPropertyScopeOutput,mElement:kAudioObjectPropertyElementMain)
            var format=AudioStreamBasicDescription();size=UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            if AudioObjectGetPropertyData(result.device,&a,0,nil,&size,&format)==0 {
                if input {result.inputs=format.mChannelsPerFrame}else{result.outputs=format.mChannelsPerFrame}
            }
        }
        return result
    }
    static func set(_ rate:Double)->OSStatus {
        let state=read();guard state.device != 0,state.rates.contains(rate) else{return kAudioHardwareUnsupportedOperationError}
        var a=AudioObjectPropertyAddress(mSelector:kAudioDevicePropertyNominalSampleRate,mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain)
        var value=rate
        return AudioObjectSetPropertyData(state.device,&a,0,nil,UInt32(MemoryLayout<Double>.size),&value)
    }
}
@MainActor final class AudioRateSettings:ObservableObject {
    @Published var state=AudioRateAccess.State()
    @Published var busy=false
    @Published var error:String?
    func refresh() async {state=await Task.detached{AudioRateAccess.read()}.value}
    func setRate(_ rate:Double) {
        guard !busy,rate != state.rate else{return};busy=true;error=nil
        Task {
            let result=await Task.detached{AudioRateAccess.set(rate)}.value
            if result==0 {
                for _ in 0..<200 {
                    await refresh();if state.rate==rate {break}
                    try? await Task.sleep(nanoseconds:100_000_000)
                }
                if state.rate != rate {error="The rate change did not complete. Stop audio in your DAW and try again."}
            } else {
                NSLog("828x rate change failed (%d)",result)
                await refresh();error="Could not switch sample rate. Stop audio in your DAW and try again."
            }
            busy=false
        }
    }
}
struct AudioRateSettingsView:View {
    @StateObject private var rate=AudioRateSettings()
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            HStack {
                Picker("Sample rate",selection:Binding(get:{rate.state.rate},set:rate.setRate)) {
                    if rate.state.rate==0 {Text("Not connected").tag(0.0)}
                    ForEach(rate.state.rates,id:\.self){Text(String(format:"%g kHz",$0/1000)+($0>88200 ? " · Experimental":"")).tag($0)}
                }.frame(maxWidth:270).disabled(rate.busy || rate.state.rates.count<2)
                Spacer()
                if rate.busy {ProgressView("Switching…").controlSize(.small)}
                else {Text(rate.state.channelLabel).font(.callout).foregroundStyle(.secondary)}
            }
            Text("Changing sample rate briefly pauses audio. Your DAW and Audio MIDI Setup share this setting.").font(.callout).foregroundStyle(.secondary)
            if rate.state.device != 0 {
                Text(rate.state.capabilities).font(.caption).foregroundStyle(.secondary)
                Text("96, 176.4 and 192 kHz are experimental; reliability on this USB connection is not yet verified.").font(.caption).foregroundStyle(.secondary)
            }
            if let error=rate.error {Text(error).font(.caption).foregroundStyle(.orange)}
        }.task {while !Task.isCancelled {await rate.refresh();try? await Task.sleep(nanoseconds:1_000_000_000)}}
    }
}
