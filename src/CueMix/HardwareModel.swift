import Foundation
private func controlError(_ message:String,_ code:UInt64)->String {
    NSLog("828x control: %@ (0x%llx)",message,code)
    return message
}

import SwiftUI
import AppKit

func dspKey(_ section: Int,_ block: Int,_ parameter: Int,_ channel: Int = 0) -> UInt32 {
    UInt32(section << 24 | block << 16 | parameter << 8 | channel)
}
struct HardwareValue: Codable, Equatable {
    var key: UInt32
    var bits: UInt32
    var kind: UInt32
    var number: Double { kind == 4 ? Double(Float(bitPattern: bits)) : Double(bits) }
    var bridge: CueValue { CueValue(key: key,bits: bits,kind: kind,revision: 0) }
    func changing(_ number: Double) -> HardwareValue {
        HardwareValue(key: key,bits: kind == 4 ? Float(number).bitPattern : UInt32(max(0,number.rounded())),kind: kind)
    }
}
let inputNames = ["Mic 1", "Mic 2"] + (1...8).map { "Analog \($0)" } + ["S/PDIF L","S/PDIF R"] + (1...8).map { "ADAT A \($0)" } + (1...8).map { "ADAT B \($0)" }
let outputNames = ["Main L/R","Analog 1–2","Analog 3–4","Analog 5–6","Analog 7–8","S/PDIF","Phones"] + (0..<4).map { "ADAT A \($0*2+1)–\($0*2+2)" } + (0..<4).map { "ADAT B \($0*2+1)–\($0*2+2)" }
func inputMeterIndex(_ channel: Int) -> Int { 2 + channel }
// Verified with a separate host tone on every logical stereo output pair.
// The 828x puts S/PDIF ahead of Main in the meter image.
func outputMeterIndex(_ pair: Int) -> Int { [76,78,80,82,84,74,86,88,90,92,94,96,98,100,102][pair] }
func reductionMeterIndex(_ section:Int,_ channel:Int,_ leveler:Bool=false)->Int { (section==1 ? channel : 28+(outputMeterIndex(channel)-74)/2) + (leveler ? 43:0) }
func compressorResponse(_ input:Double,threshold:Double,ratio:Double,trim:Double,enabled:Bool)->Double {
    guard enabled else{return input}
    let r=max(1,min(10,ratio))
    return (input>threshold ? threshold+(input-threshold)/r:input)-threshold*(1-1/r)+trim
}
func decibels(_ linear: Double) -> Double { linear > 0.000_01 ? max(-96,20*log10(linear)) : -96 }
func amplitude(_ db: Double) -> Double { db <= -95.9 ? 0 : pow(10,db/20) }
func eqBellPreview(_ frequency:Double,center:Double,gain:Double,width:Double)->Double {
    let octaveDistance=log2(max(1,frequency)/max(1,center))
    // Approximate full width at half gain, in octaves. Preserve narrow 0.01-oct
    // filters rather than displaying them as much broader audible changes.
    return gain*exp(-4*log(2)*pow(octaveDistance/max(0.01,width),2))
}
let eqDefaultFrequencies:[Double]=[20,120,1000,2000,4000,18000,20000]

// The 828x disables output sends or mix returns to keep the global reverb
// from feeding back into itself (828x manual, Reverb / Split point).
enum ReverbSplitPoint:Int {
    // Verified on USB 828x with a host tone: 1 feeds output sends into reverb;
    // 0 blocks them. This is reversed from the related FireWire reference.
    case mixes=0,outputs=1
    func permits(section:Int,isReturn:Bool)->Bool {
        switch section {
        case 1:return !isReturn
        case 2:return !isReturn || self == .mixes
        case 3:return isReturn || self == .outputs
        default:return false
        }
    }
    var explanation:String {
        self == .outputs
            ? "Inputs, monitor mixes and outputs can send to reverb. Returns feed outputs; monitor-mix returns are inactive."
            : "Inputs and monitor mixes can send to reverb. Returns feed mixes and outputs; output sends are inactive."
    }
}

// A USB receipt confirms transport only. Keep the user's latest intent pending
// until a new hardware dump agrees, and rotate keys so dragging frequency cannot
// starve the accompanying gain edit.
struct HardwareEditQueue {
    private(set) var desired:[UInt32:HardwareValue]=[:]
    private var queued:[UInt32:HardwareValue]=[:]
    private var order:[UInt32]=[]
    private var retries:[UInt32:Int]=[:]
    var hasQueued:Bool {!order.isEmpty}
    var pending:Set<UInt32> {Set(desired.keys)}
    mutating func edit(_ value:HardwareValue) {
        desired[value.key]=value;retries[value.key]=0;enqueue(value)
    }
    private mutating func enqueue(_ value:HardwareValue) {
        if queued[value.key]==nil {order.append(value.key)}
        queued[value.key]=value
    }
    mutating func next()->HardwareValue? {
        guard !order.isEmpty else{return nil}
        return queued.removeValue(forKey:order.removeFirst())
    }
    mutating func putBack(_ value:HardwareValue) {
        if queued[value.key]==nil {queued[value.key]=value;order.insert(value.key,at:0)}
    }
    mutating func verify(_ actual:[UInt32:HardwareValue])->[UInt32] {
        var failed:[UInt32]=[]
        for key in desired.keys.sorted() where queued[key]==nil {
            guard let wanted=desired[key] else{continue}
            if actual[key]==wanted {desired.removeValue(forKey:key);retries.removeValue(forKey:key)}
            else if retries[key,default:0]<2 {retries[key,default:0]+=1;enqueue(wanted)}
            else {failed.append(key);desired.removeValue(forKey:key);retries.removeValue(forKey:key)}
        }
        return failed
    }
    mutating func clear() {self=HardwareEditQueue()}
}

// This worker owns the connection and serializes all control requests. UI edits
// coalesce by parameter and are verified independently of the driver's receipt
// cache. The USB control endpoint can acknowledge edits it hasn't applied yet.
final class ControlWorker {
    private let queue = DispatchQueue(label:"org.motu828x.cuemix.control",qos:.userInitiated)
    private var timer: DispatchSourceTimer?
    private var connection: UInt32 = 0
    private var revision: UInt32 = 0
    private var epoch: UInt64 = 0
    private var tick = 0
    private var waiting: (UInt64, HardwareValue)?
    private var edits=HardwareEditQueue()
    private var lastEditTick=0
    private var nextSendTime:UInt64=0
    private var verifying=false
    private var verificationDeadline:UInt64=0
    private var readback:[UInt32:HardwareValue]=[:]
    private var interactions:Set<UInt32>=[]
    private var receivedEditRevision:UInt64=0
    private var didSubscribe = false
    private var forceSubscribe = false
    private var meterGeneration:UInt64 = 0
    private var meterAge = 0
    var onUpdate: (([HardwareValue], CueStatus, [Float], Set<UInt32>, String?, Bool, UInt64) -> Void)?
    func start() {
        queue.async {
            let timer=DispatchSource.makeTimerSource(queue:self.queue)
            timer.schedule(deadline:.now(),repeating:.milliseconds(50))
            timer.setEventHandler { [weak self] in self?.poll() }
            self.timer=timer;timer.resume()
        }
    }
    func edit(_ value: HardwareValue,revision:UInt64=0) { queue.async {
        self.edits.edit(value);self.lastEditTick=self.tick
        self.receivedEditRevision=max(self.receivedEditRevision,revision)
    } }
    func interaction(_ key:UInt32,active:Bool) {queue.async {
        if active {self.interactions.insert(key)}else{self.interactions.remove(key)}
        self.lastEditTick=self.tick
    }}
    func refresh() { queue.async {
        self.edits.clear();self.waiting=nil;self.verifying=false;self.readback.removeAll();self.interactions.removeAll();self.didSubscribe=false;self.forceSubscribe=true;self.revision=0
        if self.connection != 0 { cueClose(self.connection);self.connection=0 }
        self.tick=0;self.lastStatus=CueStatus();self.meterGeneration=0;self.meterAge=0
    } }
    private func publish(_ values:[HardwareValue],_ status:CueStatus,_ peaks:[Float],_ error:String? = nil,_ reset:Bool = false) {
        var pending=edits.pending;if let waiting { pending.insert(waiting.1.key) }
        let received=receivedEditRevision
        DispatchQueue.main.async { self.onUpdate?(values,status,peaks,pending,error,reset,received) }
    }
    private func disconnected(_ error:String) {
        cueClose(connection);connection=0;revision=0;epoch=0;didSubscribe=false
        edits.clear();waiting=nil;verifying=false;readback.removeAll();interactions.removeAll();lastStatus=CueStatus();meterGeneration=0;meterAge=0
        publish([],CueStatus(),[Float](repeating:0,count:400),error,true)
    }
    private func poll() {
        tick += 1
        if connection == 0 {
            guard tick % 40 == 1 else { return }
            let ret=cueOpen(&connection)
            guard ret == 0 else { disconnected(controlError("Cannot connect to the 828x. Check its power and USB connection, and make sure the driver is enabled.",UInt64(ret)));return }
            forceSubscribe=true
        }
        var peaks=[Float](repeating:0,count:400),generation:UInt64=0,meterCount:UInt32=0
        let meterResult=cueDSPMeters(connection,&peaks,&generation,&meterCount)
        if meterResult != 0 { disconnected(controlError("The 828x disconnected. Check its power and USB connection.",UInt64(meterResult)));return }
        if generation == meterGeneration {meterAge += 1}else{meterGeneration=generation;meterAge=0}
        if generation == 0 || meterAge>10 {
            peaks=[Float](repeating:0,count:400)
            for i in 264..<350 {peaks[i] = .nan}
        }
        if tick % 4 != 1 && waiting == nil && edits.pending.isEmpty && !verifying { publish([],lastStatus,peaks);return }
        var entries=[CueValue](repeating:CueValue(),count:8192)
        var count:UInt32=8192;var status=CueStatus()
        let ret=cueSnapshot(connection,revision,&entries,&count,&status)
        if ret != 0 { disconnected(controlError("Cannot read the 828x settings. Refresh to try again.",UInt64(ret)));return }
        if epoch != 0 && epoch != status.epoch { disconnected("Driver restarted. Reconnecting…");return }
        epoch=status.epoch;revision=UInt32(status.revision)
        let values=entries.prefix(Int(count)).map { HardwareValue(key:$0.key,bits:$0.bits,kind:$0.kind) }
        var error: String?
        if let pending=waiting, status.ack >= pending.0 {
            if status.status != 0 { error=controlError("The 828x did not accept a change. Refresh to try again.",status.status);edits.clear() }
            waiting=nil
        }
        if status.status != 0 { error=controlError("The mixer connection stopped responding. Refresh to reconnect.",status.status);edits.clear();verifying=false }
        if verifying {
            for v in values {readback[v.key]=v}
            if status.ready != 0 {
                let failed=edits.verify(readback)
                if !failed.isEmpty {error="Some changes could not be applied. The controls now show the 828x’s current settings."}
                verifying=false;readback.removeAll()
            } else if DispatchTime.now().uptimeNanoseconds>=verificationDeadline {
                error="The 828x took too long to confirm a change. Refresh to check its current settings.";edits.clear();verifying=false
            }
        }
        if forceSubscribe || (!didSubscribe && status.ready == 0) {
            let result=cueSubscribe(connection)
            if result == 0 { didSubscribe=true;forceSubscribe=false;revision=0;status.ready=0 }
            else if result != 0xe00002d5 { error=controlError("Cannot load the 828x settings. Refresh to try again.",UInt64(result));didSubscribe=true }
        }
        if status.ready != 0 { didSubscribe=true }
        let now=DispatchTime.now().uptimeNanoseconds
        if status.ready != 0 && !verifying && waiting == nil && edits.hasQueued && now>=nextSendTime,let edit=edits.next() {
            var ticket:UInt64=0
            let result=cueEdit(connection,edit.bridge,&ticket)
            if result == 0 { waiting=(ticket,edit);nextSendTime=now+100_000_000 }
            else if result == 0xe00002d5 {edits.putBack(edit)}
            else { edits.clear();error=controlError("That change could not be applied. The previous setting was kept.",UInt64(result)) }
        } else if status.ready != 0 && !verifying && waiting == nil && !edits.hasQueued && !edits.pending.isEmpty && interactions.isEmpty && tick-lastEditTick>=10 && now>=nextSendTime {
            let result=cueSubscribe(connection)
            if result == 0 {verifying=true;readback.removeAll();revision=0;verificationDeadline=now+3_000_000_000;status.ready=0}
            else if result != 0xe00002d5 {edits.clear();error=controlError("Cannot confirm that change. Refresh to check the 828x’s settings.",UInt64(result))}
        }
        lastStatus=status;publish(values,status,peaks,error)
    }
    private var lastStatus=CueStatus()
}

@MainActor final class MeterState:ObservableObject {
    @Published var peaks=[Float](repeating:0,count:400)
    @Published var reductions=[Float?](repeating:nil,count:86)
}

@MainActor final class MixerModel: ObservableObject {
    @Published var values:[UInt32:HardwareValue]=[:]
    @Published var previews:[UInt32:HardwareValue]=[:]
    let meters=MeterState()
    @Published var sampleRate=48000
    @Published var ready=false
    @Published var connected=false
    @Published var statusText="Connecting to 828x…"
    @Published var error:String?
    private(set) var parameterCount=0
    private(set) var writes=0
    @Published var editsPending=0
    @Published var presetToApply: MixPreset?
    @Published var localNames:[String:String]=UserDefaults.standard.dictionary(forKey:"channelNames") as? [String:String] ?? [:]
    let worker:ControlWorker
    private var connectionError=false
    private var editRevision:UInt64=0
    private var previewRevisions:[UInt32:UInt64]=[:]
    private var interactions:Set<UInt32>=[]
    init(worker:ControlWorker=ControlWorker(),startWorker:Bool=true) {
        self.worker=worker
        worker.onUpdate={ [weak self] changes,status,peaks,pending,error,reset,received in
            self?.receive(changes,status,peaks,pending,error,reset,received)
        }
        if startWorker {worker.start()}
    }
    func receive(_ changes:[HardwareValue],_ status:CueStatus,_ peaks:[Float],_ pending:Set<UInt32>,_ error:String?,_ reset:Bool,_ received:UInt64) {
            if reset { self.values.removeAll();self.previews.removeAll();previewRevisions.removeAll();interactions.removeAll();self.connectionError=true }
            if changes.contains(where:{values[$0.key] != $0}) { var updated=self.values;for v in changes {updated[v.key]=v};self.values=updated }
            // An update queued before the latest pointer event cannot erase its
            // optimistic preview, even if the worker hadn't received it yet.
            let remaining=self.previews.filter { pending.contains($0.key) || previewRevisions[$0.key,default:0]>received }
            if self.previews != remaining {self.previews=remaining;previewRevisions=previewRevisions.filter{remaining[$0.key] != nil}}
            // Readback temporarily makes the transport unready. Retain the last
            // complete settings and keep accepting edits into the worker queue.
            let editable = !reset && status.epoch != 0 && status.status==0 && (ready || status.ready != 0)
            if self.ready != editable {self.ready=editable};if self.connected != (status.epoch != 0) {self.connected=status.epoch != 0}
            if self.parameterCount != Int(status.count) {self.parameterCount=Int(status.count)};if self.writes != Int(status.writes) {self.writes=Int(status.writes)}
            if self.editsPending != pending.count {self.editsPending=pending.count}
            if self.ready && self.connectionError {self.error=nil;self.connectionError=false}
            self.meters.peaks=zip(self.meters.peaks,peaks).map { reset || !$1.isFinite ? 0 : max($1,$0*0.80) }
            self.meters.reductions=(264..<350).map {i in let v=peaks[i];return !reset && v.isFinite && v>=0 && v<=1.001 ? min(1,v):nil}
            if let error { self.error=error }
            let text=self.ready ? "Connected" : self.connected ? "Loading settings…" : "Not connected";if self.statusText != text {self.statusText=text}
    }
    func refresh() { error=nil;values.removeAll();previews.removeAll();previewRevisions.removeAll();interactions.removeAll();ready=false;statusText="Loading settings…";worker.refresh() }
    func number(_ key:UInt32) -> Double? { (previews[key] ?? values[key])?.number }
    var reverbAvailable:Bool {sampleRate<=48000}
    var processingAvailable:Bool {sampleRate<=96000}
    var inputChannels:[Int] {
        if sampleRate>96000 {return Array(0..<10)}
        if sampleRate>48000 {return Array(0..<16)+Array(20..<24)}
        return Array(0..<28)
    }
    var outputChannels:[Int] {
        if sampleRate>96000 {return [0,1,2,3,4,6]}
        if sampleRate>48000 {return Array(0..<9)+[11,12]}
        return Array(0..<15)
    }
    func supported(_ key:UInt32)->Bool {
        let s=Int(key>>24),b=Int((key>>16)&255),ch=Int(key&255)
        if s==1 && !inputChannels.contains(ch) {return false}
        if s==3 && !outputChannels.contains(ch) {return false}
        if s==2 && b>=2 && !inputChannels.contains(b-2) {return false}
        if !reverbAvailable && (s==4 || s==1 && b==12 || s==2 && b==1 || s==3 && b==11) {return false}
        if !processingAvailable && (s==1 && (1...11).contains(b) || s==3 && (0...10).contains(b)) {return false}
        return true
    }
    func available(_ key:UInt32) -> Bool { ready && supported(key) && values[key] != nil }
    var reverbSplitPoint:ReverbSplitPoint? {
        switch number(dspKey(4,0,1)) {case 0:return .mixes;case 1:return .outputs;default:return nil}
    }
    func set(_ key:UInt32,_ value:Double) {
        guard available(key), value.isFinite,let old=values[key] else {return}
        let edit=old.changing(value)
        guard cueValid(edit.bridge) != 0 else { error="This value is outside the 828x’s supported range.";return }
        guard edit != (previews[key] ?? old) else {return}
        editRevision+=1;previewRevisions[key]=editRevision;previews[key]=edit;worker.edit(edit,revision:editRevision)
    }
    func beginInteraction(_ key:UInt32) {if interactions.insert(key).inserted {worker.interaction(key,active:true)}}
    func endInteraction(_ key:UInt32) {if interactions.remove(key) != nil {worker.interaction(key,active:false)}}
    func resetEQPoint(section:Int,channel:Int,band:Int) {
        guard eqDefaultFrequencies.indices.contains(band),(section==1 || section==3) else{return}
        let block=(band==0 ? 2:band==6 ? 8:band+2)-(section==3 ? 1:0)
        set(dspKey(section,block,2,channel),eqDefaultFrequencies[band])
        if band>0 && band<6 {set(dspKey(section,block,3,channel),0)}
    }
    func toggle(_ key:UInt32) { guard let n=number(key) else{return};set(key,n == 0 ? 1:0) }
    func binding(_ key:UInt32, fallback:Double=0) -> Binding<Double> { Binding(get:{ self.number(key) ?? fallback },set:{self.set(key,$0)}) }
    func name(_ section:Int,_ channel:Int) -> String { localNames["\(section):\(channel)"] ?? (section==1 ? inputNames[channel] : outputNames[channel]) }
    func rename(_ section:Int,_ channel:Int,_ name:String) { let key="\(section):\(channel)";localNames[key]=name;UserDefaults.standard.set(localNames,forKey:"channelNames") }
    func mixTitle(_ bus:Int) -> String { guard let n=number(dspKey(2,0,0,bus)),n>=0,n<15 else{return "Mix \(bus+1)"};return outputNames[Int(n)] }
    func peak(_ index:Int) -> Float { meters.peaks.indices.contains(index) ? meters.peaks[index] : 0 }
    func savePreset() {
        let panel=NSSavePanel();panel.nameFieldStringValue="828x Mix.json";panel.allowedContentTypes=[.json]
        if panel.runModal() == .OK,let url=panel.url {
            let preset=MixPreset(format:1,model:"828x",sampleRate:sampleRate,date:Date(),values:values.values.filter { cueValid($0.bridge) != 0 && Self.isPresetKey($0.key) && supported($0.key) }.sorted{$0.key<$1.key})
            do { let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys];try encoder.encode(preset).write(to:url,options:.atomic) }
            catch { self.error=error.localizedDescription }
        }
    }
    // Presets contain DSP processing and mixes, excluding physical input power,
    // preamp mode, talk/listen, monitor volume and output assignments.
    static func isPresetKey(_ key:UInt32) -> Bool {
        let s=key>>24,b=(key>>16)&255,p=(key>>8)&255
        if s==1 {return b>0}
        if s==2 {return !(b==0 && p==0)}
        if s==3 {return b<12}
        return s==4
    }
    func loadPreset() {
        let panel=NSOpenPanel();panel.allowedContentTypes=[.json];panel.allowsMultipleSelection=false
        guard panel.runModal() == .OK,let url=panel.url else{return}
        do {
            let data=try Data(contentsOf:url);guard data.count<2_000_000 else {throw PresetError.invalid}
            let preset=try JSONDecoder().decode(MixPreset.self,from:data)
            try preset.validate(for:values,rate:sampleRate)
            presetToApply=preset
        } catch {self.error="Cannot load preset: \(error.localizedDescription)"}
    }
    func applyPreset() {
        guard let preset=presetToApply,ready else{return}
        do {try preset.validate(for:values,rate:sampleRate);for v in preset.values where supported(v.key) {set(v.key,v.number)}}
        catch {self.error=error.localizedDescription}
        presetToApply=nil
    }
}
struct MixPreset:Codable {
    let format:Int;let model:String;let sampleRate:Int;let date:Date;let values:[HardwareValue]
    @MainActor func validate(for current:[UInt32:HardwareValue],rate:Int=48000) throws {
        guard format==1,model=="828x",[44100,48000,88200,96000,176400,192000].contains(sampleRate),
            (sampleRate<=48000 ? 1:sampleRate<=96000 ? 2:4)==(rate<=48000 ? 1:rate<=96000 ? 2:4),values.count<=8192,
            Set(values.map{$0.key}).count==values.count,
            values.allSatisfy({cueValid($0.bridge) != 0 && MixerModel.isPresetKey($0.key) && current[$0.key]?.kind==$0.kind}) else {throw PresetError.invalid}
    }
}
enum PresetError:LocalizedError {case invalid;var errorDescription:String?{"The file is not a compatible 828x preset."}}
