import Foundation
@main enum CueMixModelTests {
    @MainActor static func main() throws {
        // Exact-value entry must reject invalid input before it reaches hardware.
        for text in ["", "NaN", "inf", "-inf", "1e999", "-96.1", "0.1", "12 dB", "1,2,3"] {
            precondition(parsedParameterValue(text,range: -96...0,step:0)==nil)
        }
        precondition(parsedParameterValue(" −12,5 ",range: -96...0,step:0)==(-12.5))
        precondition(parsedParameterValue("-96",range: -96...0,step:0)==(-96))
        precondition(parsedParameterValue("0",range: -96...0,step:0)==0)
        precondition(parsedParameterValue("12.6",range:0...53,step:1)==13)
        precondition(parsedParameterValue("2.04",range:0.01...3,step:0.1)==2)
        let pan=HardwareValue(key:dspKey(2,2,2,7),bits:Float(0.25).bitPattern,kind:4)
        let mute=HardwareValue(key:dspKey(2,0,1,7),bits:1,kind:1)
        let current=[pan.key:pan,mute.key:mute]
        // Sample-rate capability changes must disable unavailable DSP writes
        // while retaining the physical identifiers of channels that remain.
        let ratesModel=MixerModel(startWorker:false)
        ratesModel.sampleRate=96000
        precondition(ratesModel.inputChannels.count==20 && ratesModel.inputChannels.contains(20) && !ratesModel.inputChannels.contains(16))
        precondition(!ratesModel.reverbAvailable && ratesModel.processingAvailable)
        precondition(!ratesModel.supported(dspKey(4,0,0)))
        precondition(ratesModel.supported(dspKey(3,1,0,0)))
        ratesModel.sampleRate=192000
        precondition(ratesModel.inputChannels.count==10 && ratesModel.outputChannels==[0,1,2,3,4,6])
        precondition(!ratesModel.processingAvailable && !ratesModel.supported(dspKey(3,1,0,0)))
        precondition(ratesModel.supported(dspKey(1,0,2,0)))
        precondition(!ratesModel.supported(dspKey(2,12,2,0)))
        func preset(_ values:[HardwareValue],rate:Int=48000)->MixPreset {MixPreset(format:1,model:"828x",sampleRate:rate,date:Date(timeIntervalSince1970:0),values:values)}
        let data=try JSONEncoder().encode(preset([pan,mute]))
        let decoded=try JSONDecoder().decode(MixPreset.self,from:data)
        try decoded.validate(for:current)
        precondition(decoded.values==[pan,mute])
        func rejects(_ p:MixPreset) {do {try p.validate(for:current);fatalError("Invalid preset accepted")}catch{}}
        rejects(preset([pan,pan]))
        try preset([pan],rate:44100).validate(for:current)
        rejects(preset([pan],rate:96000))
        try preset([pan],rate:96000).validate(for:current,rate:88200)
        rejects(preset([pan.changing(2)]))
        rejects(preset([HardwareValue(key:pan.key,bits:Float.nan.bitPattern,kind:4)]))
        rejects(preset([HardwareValue(key:pan.key,bits:1,kind:1)]))
        rejects(preset([HardwareValue(key:dspKey(2,2,2,0),bits:Float(0).bitPattern,kind:4)]))
        for key in [dspKey(1,0,11),dspKey(0,0,0),dspKey(2,0,0),dspKey(3,12,0)] {precondition(!MixerModel.isPresetKey(key))}
        precondition(abs(amplitude(decibels(0.25))-0.25)<0.000001)
        precondition(amplitude(-96)==0 && decibels(0)==(-96))
        precondition(pan.changing(-0.5).number == -0.5)
        precondition(compressorResponse(-36,threshold:-48,ratio:2,trim:-6,enabled:true) == -24)
        precondition(compressorResponse(-36,threshold:-12,ratio:2,trim:-6,enabled:true) == -36)
        precondition(compressorResponse(-36,threshold:-48,ratio:2,trim:-6,enabled:false) == -36)
        // Every physical output has distinct meter slots, including S/PDIF's
        // position ahead of Main, observed on the USB 828x (not the mk3 map).
        let outputs=(0..<15).map(outputMeterIndex)
        precondition(Set(outputs).count==15 && outputs[0]==76 && outputs[5]==74 && outputs[6]==86)
        precondition(reductionMeterIndex(3,0)+264==293 && reductionMeterIndex(3,1,true)+264==337)
        // 828x routing: output sends require Outputs; mix returns require Mixes.
        // Input/mix sends and output returns remain available in either mode.
        precondition(ReverbSplitPoint.outputs.rawValue==1 && ReverbSplitPoint.mixes.rawValue==0)
        for split in [ReverbSplitPoint.outputs,.mixes] {
            precondition(split.permits(section:1,isReturn:false))
            precondition(split.permits(section:2,isReturn:false))
            precondition(split.permits(section:3,isReturn:true))
            precondition(!split.permits(section:1,isReturn:true))
            precondition(split.permits(section:3,isReturn:false) == (split == .outputs))
            precondition(split.permits(section:2,isReturn:true) == (split == .mixes))
        }
        // Frequency and gain must both get time on the wire during a drag.
        // A USB receipt alone must not clear the outstanding hardware check.
        let frequency=HardwareValue(key:dspKey(3,4,2),bits:Float(440).bitPattern,kind:4)
        let gain=HardwareValue(key:dspKey(3,4,3),bits:Float(-12).bitPattern,kind:4)
        var queue=HardwareEditQueue();queue.edit(frequency);queue.edit(gain)
        precondition(queue.next()==frequency)
        queue.edit(frequency.changing(660))
        precondition(queue.next()==gain && queue.next()==frequency.changing(660))
        precondition(queue.pending.count==2 && !queue.hasQueued)
        // Hardware retained an older frequency: retry only that parameter.
        precondition(queue.verify([frequency.key:frequency,gain.key:gain]).isEmpty)
        precondition(queue.pending==[frequency.key] && queue.next()==frequency.changing(660))
        precondition(queue.verify([frequency.key:frequency.changing(660)]).isEmpty && queue.pending.isEmpty)
        // Edits arriving during readback supersede it and cannot be discarded.
        queue.edit(gain);precondition(queue.next()==gain)
        queue.edit(gain.changing(-6))
        precondition(queue.verify([gain.key:gain]).isEmpty && queue.pending==[gain.key])
        precondition(queue.next()==gain.changing(-6))
        // A rejected write gets two retries, then a visible failure, not a loop.
        for _ in 0..<2 {precondition(queue.verify([gain.key:gain]).isEmpty);precondition(queue.next()==gain.changing(-6))}
        precondition(queue.verify([gain.key:gain])==[gain.key] && queue.pending.isEmpty && !queue.hasQueued)
        // Busy transport retains the newer coalesced value.
        queue.edit(gain);_ = queue.next();queue.edit(gain.changing(-3));queue.putBack(gain)
        precondition(queue.next()==gain.changing(-3))
        precondition(eqBellPreview(7000,center:7000,gain:20,width:0.01)==20)
        precondition(abs(eqBellPreview(7000*pow(2,0.005),center:7000,gain:20,width:0.01)-10)<0.00001)
        precondition(eqBellPreview(7100,center:7000,gain:20,width:0.01)<0.01)
        let model=MixerModel(startWorker:false)
        precondition(model.reverbSplitPoint == nil)
        let split=HardwareValue(key:dspKey(4,0,1),bits:0,kind:1)
        model.values[split.key]=split;precondition(model.reverbSplitPoint == .mixes)
        model.previews[split.key]=split.changing(1);precondition(model.reverbSplitPoint == .outputs)
        model.previews.removeAll();model.values.removeAll()
        let peaks=[Float](repeating:0,count:400)
        var status=CueStatus();status.epoch=1
        model.receive([frequency,gain],status,peaks,[],nil,false,0)
        precondition(!model.ready) // initial read must still finish
        status.ready=1;model.receive([frequency,gain],status,peaks,[],nil,false,0)
        precondition(model.available(frequency.key))
        model.set(frequency.key,550)
        // A main-queue callback from before this drag must not snap it back.
        model.receive([frequency],status,peaks,[],nil,false,0)
        precondition(model.number(frequency.key)==550)
        status.ready=0
        model.receive([],status,peaks,[frequency.key],nil,false,1)
        precondition(model.ready && model.available(gain.key))
        model.set(gain.key,-6)
        model.receive([gain],status,peaks,[frequency.key],nil,false,1)
        precondition(model.number(gain.key)==(-6)) // edit during readback remains live
        status.ready=1
        model.receive([frequency.changing(550),gain.changing(-6)],status,peaks,[],nil,false,2)
        precondition(model.previews.isEmpty && model.number(frequency.key)==550 && model.number(gain.key)==(-6))
        var republished=0
        let observer=model.$values.dropFirst().sink {_ in republished+=1}
        model.receive([frequency.changing(550),gain.changing(-6)],status,peaks,[],nil,false,2)
        precondition(republished==0);observer.cancel()
        for section in [1,3] {for band in 0..<7 {
            let b=(band==0 ? 2:band==6 ? 8:band+2)-(section==3 ? 1:0)
            let f=HardwareValue(key:dspKey(section,b,2),bits:Float(5000).bitPattern,kind:4)
            let g=HardwareValue(key:dspKey(section,b,3),bits:Float(-9).bitPattern,kind:4)
            let width=HardwareValue(key:dspKey(section,b,4),bits:Float(2).bitPattern,kind:4)
            let enabled=HardwareValue(key:dspKey(section,b,0),bits:0,kind:1)
            model.values=[f.key:f,g.key:g,width.key:width,enabled.key:enabled];model.previews=[:]
            model.resetEQPoint(section:section,channel:0,band:band)
            precondition(model.number(f.key)==eqDefaultFrequencies[band])
            precondition(model.number(g.key)==(band>0 && band<6 ? 0:-9))
            precondition(model.number(width.key)==2 && model.number(enabled.key)==0)
        }}
        model.receive([],CueStatus(),peaks,[],nil,true,UInt64.max)
        precondition(!model.ready && model.previews.isEmpty && model.values.isEmpty)
        print("PASS: CueMix presets, ranges, meters, readback/retries, interactive previews during sync, no-op updates and all EQ point resets")
    }
}
