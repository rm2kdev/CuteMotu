import SwiftUI

private struct EQCurveBand:Equatable {
    var enabled:Bool;var frequency:Double;var gain:Double;var width:Double;var type:Double
    func response(_ f:Double,band:Int)->Double {
        guard enabled else{return 0}
        if band==0 || band==6 {
            let ratio=band==0 ? frequency/f:f/frequency
            return -10*log10(1+pow(ratio,2*(type+1)))
        }
        if type==4 {return gain/(1+exp((band==1 ? 1:-1)*log2(f/max(1,frequency))*3))}
        return eqBellPreview(f,center:frequency,gain:gain,width:width)
    }
}

// Render only when this channel's EQ changes. In particular, a hardware dump or
// edits to another strip must not redraw every miniature curve in the mixer.
private struct EQCurveCanvas:View,Equatable {
    var bands:[EQCurveBand];var enabled:Bool;var mini:Bool
    func point(_ f:Double,_ gain:Double,_ size:CGSize)->CGPoint {
        CGPoint(x:log10(f/20)/3*size.width,y:size.height*(0.5-gain/48))
    }
    var body:some View {
        Canvas {context,size in
            let samples=mini ? 72:240
            var frequencies=(0...samples).map{20*pow(1000,Double($0)/Double(samples))}
            for b in bands {let w=max(0.01,b.width);frequencies += [-1.0,-0.5,0,0.5,1].map{max(20,min(20000,b.frequency*pow(2,$0*w)))}}
            frequencies.sort()
            var grid=Path()
            for f in [20.0,50,100,200,500,1000,2000,5000,10000,20000] {let x=point(f,0,size).x;grid.move(to:CGPoint(x:x,y:0));grid.addLine(to:CGPoint(x:x,y:size.height))}
            for db in [-24.0,-12,0,12,24] {let y=point(20,db,size).y;grid.move(to:CGPoint(x:0,y:y));grid.addLine(to:CGPoint(x:size.width,y:y))}
            context.stroke(grid,with:.color(Color.white.opacity(mini ? 0.04:0.12)),lineWidth:1)
            var totals=[Double](repeating:0,count:frequencies.count)
            if enabled {for (index,band) in bands.enumerated() where band.enabled {
                var fill=Path();fill.move(to:CGPoint(x:0,y:size.height/2))
                for (i,f) in frequencies.enumerated() {let gain=band.response(f,band:index);totals[i]+=gain;fill.addLine(to:point(f,max(-24,min(24,gain)),size))}
                fill.addLine(to:CGPoint(x:size.width,y:size.height/2));fill.closeSubpath()
                context.fill(fill,with:.color(bandColors[index].opacity(mini ? 0.22:0.16)))
            }}
            var combined=Path()
            for (i,f) in frequencies.enumerated() {let p=point(f,max(-24,min(24,totals[i])),size);if i==0{combined.move(to:p)}else{combined.addLine(to:p)}}
            context.stroke(combined,with:.color(Color.ink.opacity(0.85)),lineWidth:mini ? 1.5:2)
        }
    }
}

struct EQGraph:View {
    @EnvironmentObject var model:MixerModel
    var section:Int;var channel:Int;var mini=false
    var selected:Binding<Int>?
    func block(_ b:Int)->Int {b-(section==3 ? 1:0)}
    func value(_ b:Int,_ p:Int)->Double? {model.number(dspKey(section,block(b),p,channel))}
    private var bands:[EQCurveBand] {
        (0..<7).map {band in
            let b=band==0 ? 2:band==6 ? 8:band+2
            return EQCurveBand(enabled:value(b,0)==1,frequency:value(b,2) ?? eqDefaultFrequencies[band],gain:value(b,3) ?? 0,width:value(b,4) ?? 1,type:value(b,1) ?? 0)
        }
    }
    func point(_ frequency:Double,_ gain:Double,_ size:CGSize)->CGPoint {
        CGPoint(x:(log10(frequency)-log10(20))/3*size.width,y:size.height*(0.5-gain/48))
    }
    var body:some View {
        GeometryReader {g in
            ZStack {
                Color.black.opacity(0.55)
                EQCurveCanvas(bands:bands,enabled:model.processingAvailable && value(1,0)==1,mini:mini).equatable()
                if !mini {
                    ForEach(0..<7,id:\.self){band in
                        let b=band==0 ? 2:band==6 ? 8:band+2
                        if let f=value(b,2) {
                            let p=point(f,value(b,3) ?? 0,g.size)
                            let active=model.processingAvailable && value(1,0)==1 && value(b,0)==1
                            Circle().fill(active ? bandColors[band]:Color.desk).overlay(Circle().stroke(bandColors[band],lineWidth:1.5)).frame(width:10,height:10).padding(10).background(Circle().fill(bandColors[band].opacity(active ? 0.2:0.04))).overlay(Circle().stroke(selected?.wrappedValue==band ? Color.white:Color.clear)).opacity(active ? 1:0.5).position(p)
                                .gesture(DragGesture(minimumDistance:3,coordinateSpace:.named("eqGraph")).onChanged {e in
                                    guard model.available(dspKey(section,block(b),2,channel)) else{return}
                                    model.beginInteraction(dspKey(section,block(b),2,channel))
                                    selected?.wrappedValue=band
                                    let f=20*pow(1000,max(0,min(1,e.location.x/g.size.width)))
                                    model.set(dspKey(section,block(b),2,channel),f.rounded())
                                    if band>0 && band<6 {model.set(dspKey(section,block(b),3,channel),max(-20,min(20,(0.5-e.location.y/g.size.height)*48)))}
                                }.onEnded {_ in model.endInteraction(dspKey(section,block(b),2,channel))})
                                .simultaneousGesture(TapGesture(count:2).onEnded {selected?.wrappedValue=band;model.resetEQPoint(section:section,channel:channel,band:band)})
                                .simultaneousGesture(TapGesture().onEnded {selected?.wrappedValue=band})
                                .accessibilityAction(named:"Reset point") {model.resetEQPoint(section:section,channel:channel,band:band)}
                                .help(active ? "Drag to adjust. Double-click to reset frequency and gain.":"Band bypassed. Double-click to reset its position; enable below to hear it.")
                        }
                    }
                }
            }.coordinateSpace(name:"eqGraph").clipped()
        }.accessibilityLabel("Equalizer response preview").onDisappear {for band in 0..<7 {let b=band==0 ? 2:band==6 ? 8:band+2;model.endInteraction(dspKey(section,block(b),2,channel))}}
    }
}
struct ChannelEditor:View {
    @EnvironmentObject var model:MixerModel
    @Environment(\.dismiss) var dismiss
    @State var target:ChannelTarget
    @State private var selectedBand=2
    @State private var name=""
    var section:Int{target.section};var channel:Int{target.channel}
    func key(_ b:Int,_ p:Int)->UInt32 {dspKey(section,b-(section==3 ? 1:0),p,channel)}
    var body:some View {
        VStack(spacing:0) {
            HStack {
                Button{move(-1)}label:{Image(systemName:"chevron.left")}.buttonStyle(ConsoleButtonStyle()).accessibilityLabel("Previous channel").disabled(channel==channels.first)
                Button{move(1)}label:{Image(systemName:"chevron.right")}.buttonStyle(ConsoleButtonStyle()).accessibilityLabel("Next channel").disabled(channel==channels.last)
                VStack(alignment:.leading,spacing:3) {Text(model.name(section,channel)).font(.system(size:25,weight:.semibold));Text(section==3 ? "OUTPUT PROCESSING":"INPUT PROCESSING").font(.system(size:9,design:.monospaced)).foregroundStyle(Color.quiet)}.padding(.leading,12)
                Spacer()
                Picker("Editor",selection:$target.tab){Text("Equalizer").tag(0);Text("Dynamics").tag(1);Text("Channel").tag(2)}.pickerStyle(.segmented).labelsHidden().frame(width:300)
                Button{dismiss()}label:{Image(systemName:"xmark")}.buttonStyle(ConsoleButtonStyle()).keyboardShortcut(.cancelAction).accessibilityLabel("Close channel editor").help("Close · Esc").padding(.leading,12)
            }.padding(26)
            ScrollView {VStack(spacing:22) {
                if target.tab==0 {eq}
                else if target.tab==1 {dynamics}
                else {channelSettings}
            }.padding(26).padding(.top,0)}
        }.background(Color.desk).foregroundStyle(Color.ink).preferredColorScheme(.dark).frame(width:1060,height:730)
    }
    var channels:[Int] {section==1 ? model.inputChannels:model.outputChannels}
    func move(_ amount:Int){if let index=channels.firstIndex(of:channel),channels.indices.contains(index+amount){target.channel=channels[index+amount];name=""}}
    var eq:some View {
        VStack(spacing:20) {
            if !model.processingAvailable {EmptyNotice(text:"The 828x’s EQ and dynamics are unavailable at 176.4 and 192 kHz.")}
            HStack {Chip(label:"EQ ON",key:key(1,0),color:.purple,offLabel:"EQ BYPASSED").frame(width:130);Spacer();Text(model.number(key(1,0))==1 ? "7-band EQ · hardware processing":"EQ is bypassed. Enable it to hear changes.").font(.system(size:11)).foregroundStyle(model.number(key(1,0))==1 ? Color.quiet:Color.orange)}
            EQGraph(section:section,channel:channel,selected:$selectedBand).frame(height:300)
            GeometryReader {g in ForEach([20.0,50,100,200,500,1000,2000,5000,10000,20000],id:\.self){f in Text(f>=1000 ? String(format:"%.0fk",f/1000):String(format:"%.0f",f)).font(.system(size:9,design:.monospaced)).foregroundStyle(Color.quiet).position(x:max(10,min(g.size.width-14,log10(f/20)/3*g.size.width)),y:5)}}.frame(height:10)
            HStack(spacing:8) {ForEach(0..<7,id:\.self) {band in Button{selectedBand=band} label:{Text(["HIGH PASS","LOW","LOW MID","MID","HIGH MID","HIGH","LOW PASS"][band]).font(.system(size:10,weight:.bold)).frame(maxWidth:.infinity).padding(.vertical,11).foregroundStyle(bandColors[band]).background(selectedBand==band ? bandColors[band].opacity(0.12):Color.rail).overlay(alignment:.bottom){Rectangle().fill(selectedBand==band ? bandColors[band]:Color.clear).frame(height:2)}.contentShape(Rectangle())}.buttonStyle(.plain)}}
            eqParameters
            Text("Double-click a point to reset its frequency and gain. Hollow points are bypassed. Curves approximate T1–T4; width is in octaves.").font(.system(size:10)).foregroundStyle(Color.quiet)
        }
    }
    var eqParameters:some View {
        let b=selectedBand==0 ? 2:selectedBand==6 ? 8:selectedBand+2
        let color=bandColors[selectedBand]
        return HStack(alignment:.top,spacing:24) {
            VStack(alignment:.leading,spacing:8) {Chip(label:"BAND ON",key:key(b,0),color:color,offLabel:"BAND BYPASSED");if model.number(key(b,0)) != 1 {Text("Enable to hear this band").font(.system(size:9)).foregroundStyle(Color.orange)}}.frame(width:135).padding(.top,12)
            Parameter(title:"Frequency",key:key(b,2),range:20...20000,unit:"Hz",step:1,logarithmic:true,color:color)
            if selectedBand==0 || selectedBand==6 {
                Choice(title:"Slope",key:key(b,1),labels:["6 dB/oct","12 dB/oct","18 dB/oct","24 dB/oct","30 dB/oct","36 dB/oct"])
            } else {
                Parameter(title:"Gain",key:key(b,3),range: -20...20,unit:"dB",step:0.1,color:color)
                Parameter(title:"Width",key:key(b,4),range:0.01...3,unit:"oct",step:0.01,color:color)
                Choice(title:"Shape",key:key(b,1),labels:selectedBand==1 || selectedBand==5 ? ["Type 1","Type 2","Type 3","Type 4","Shelf"]:["Type 1","Type 2","Type 3","Type 4"])
            }
        }.padding(20).background(Color.rail,in:RoundedRectangle(cornerRadius:9))
    }
    var dynamics:some View {
        VStack(spacing:22) {
            if !model.processingAvailable {EmptyNotice(text:"The 828x’s EQ and dynamics are unavailable at 176.4 and 192 kHz.")}
            HStack {Chip(label:"DYNAMICS",key:key(9,0),color:.ice).frame(width:140);Spacer();Text("Compressor + Leveler").foregroundStyle(Color.quiet)}
            HStack(alignment:.top,spacing:20) {
                Panel(title:"Compressor") {
                    HStack {Chip(label:"ON",key:key(10,0),color:.ice).frame(width:80);Spacer();Choice(title:"Detection",key:key(10,6),labels:["Peak","RMS"])}
                    DynamicsGraph(threshold:model.number(key(10,1)) ?? -24,ratio:model.number(key(10,2)) ?? 2,gain:model.number(key(10,5)) ?? 0,active:model.processingAvailable && model.number(key(10,0))==1).frame(height:235)
                    GainReductionMeter(section:section,channel:channel)
                    HStack(spacing:18){Parameter(title:"Threshold",key:key(10,1),range: -48...0,unit:"dB",step:1);Parameter(title:"Ratio",key:key(10,2),range:1...10,step:0.1)}
                    HStack(spacing:18){Parameter(title:"Attack",key:key(10,3),range:10...100,unit:"ms",step:1);Parameter(title:"Release",key:key(10,4),range:10...1000,unit:"ms",step:1);Parameter(title:"Trim",key:key(10,5),range: -6...0,unit:"dB",step:0.1)}
                    Text("Automatic makeup gain follows threshold and ratio. Trim adjusts the resulting output level.").font(.system(size:10)).foregroundStyle(Color.quiet)
                }
                Panel(title:"Leveler") {
                    Chip(label:"LEVELER ON",key:key(11,0),color:.orange)
                    Choice(title:"Mode",key:key(11,1),labels:["Compress","Limit"])
                    HStack(spacing:28){Knob(title:"Gain reduction",key:key(11,3),range:0...100,unit:"%",step:1,color:.orange);Knob(title:"Makeup",key:key(11,2),range:0...100,unit:"%",step:1,color:.orange)}.padding(.vertical,28)
                    GainReductionMeter(section:section,channel:channel,leveler:true,color:.orange)
                    EmptyNotice(text:"The Leveler is the 828x’s optical compressor model. These controls change its onboard processor. Its gain-reduction meter shows attenuation measured by the hardware.")
                }.frame(width:330)
            }
        }
    }
    var channelSettings:some View {
        VStack(spacing:20) {
            if let bus=target.bus {
                Panel(title:"Mix \(bus+1) stereo image") {
                    Choice(title:"Mode",key:dspKey(2,channel+2,4,bus),labels:["Balance","Width"])
                    HStack(spacing:28) {
                        Parameter(title:"Pan",key:dspKey(2,channel+2,2,bus),range: -1...1,color:busColors[bus])
                        Parameter(title:"Balance",key:dspKey(2,channel+2,5,bus),range: -1...1,color:busColors[bus])
                        Parameter(title:"Width",key:dspKey(2,channel+2,6,bus),range: -1...1,color:busColors[bus])
                    }
                }
            }
            Panel(title:"Channel label") {HStack {TextField(model.name(section,channel),text:$name).textFieldStyle(.roundedBorder);Button("Rename"){model.rename(section,channel,name.isEmpty ? (section==1 ? inputNames[channel]:outputNames[channel]):name)}};Text("Saved on this Mac.").font(.system(size:10)).foregroundStyle(Color.quiet)}
            if section==1 {
                Panel(title:"Input") {
                    HStack{Chip(label:"PHASE INVERT",key:dspKey(1,0,0,channel));Chip(label:"STEREO PAIR",key:dspKey(1,0,1,channel));Chip(label:"SWAP",key:dspKey(1,0,3,channel))}
                    HStack(spacing:24){Parameter(title:"Input trim",key:dspKey(1,0,2,channel),range: channel<2 ? 0...53 : channel<10 ? -96...22 : 0...12,unit:"dB",step:1);Choice(title:"Stereo mode",key:dspKey(1,0,4,channel),labels:["L/R","Mid / Side"]);Parameter(title:"Width",key:dspKey(1,0,5,channel),range:0...1)}
                    HStack{Chip(label:"LIMITER",key:dspKey(1,0,6,channel));Chip(label:"LOOKAHEAD",key:dspKey(1,0,7,channel));Chip(label:"SOFT CLIP",key:dspKey(1,0,8,channel));Chip(label:"PAD",key:dspKey(1,0,9,channel));Chip(label:"48V",key:dspKey(1,0,11,channel),color:.red)}
                    EmptyNotice(text:"Only controls reported by this device are available. Phantom power affects the physical input; use it only with equipment that requires it.")
                }
            } else {
                Panel(title:"Monitor destinations") {HStack{Chip(label:"MONITOR GROUP",key:dspKey(3,12,0,channel));Chip(label:"TALKBACK",key:dspKey(3,12,1,channel));Chip(label:"LISTENBACK",key:dspKey(3,12,2,channel))}}
            }
            Panel(title:"Reverb") {HStack(alignment:.top,spacing:30){ReverbLevel(section:section,channel:channel);if section==3 {ReverbLevel(section:section,channel:channel,isReturn:true)}else{Parameter(title:"Pan",key:key(12,2),range: -1...1,color:.purple)}}}
        }
    }
}
struct DynamicsGraph:View {
    var threshold:Double;var ratio:Double;var gain:Double;var active:Bool
    var body:some View {
        Canvas {context,size in
            func point(_ x:Double,_ y:Double)->CGPoint{CGPoint(x:(x+72)/72*size.width,y: -max(-72,min(0,y))/72*size.height)}
            var grid=Path();for i in stride(from: -72.0,through:0,by:12) {grid.move(to:point(i,-72));grid.addLine(to:point(i,0));grid.move(to:point(-72,i));grid.addLine(to:point(0,i))};context.stroke(grid,with:.color(.white.opacity(0.12)),lineWidth:1)
            var diagonal=Path();diagonal.move(to:point(-72,-72));diagonal.addLine(to:point(0,0));context.stroke(diagonal,with:.color(.white.opacity(0.3)),lineWidth:1)
            var curve=Path();for i in -72...0 {let x=Double(i),y=compressorResponse(x,threshold:threshold,ratio:ratio,trim:gain,enabled:active);if i == -72 {curve.move(to:point(x,y))}else{curve.addLine(to:point(x,y))}};context.stroke(curve,with:.color(.ice),lineWidth:3)
        }.background(.black.opacity(0.5)).accessibilityLabel("Compressor transfer curve")
    }
}
struct ReverbPage:View {
    @EnvironmentObject var model:MixerModel
    @State private var output=0
    func key(_ p:Int)->UInt32{dspKey(4,0,p)}
    var body:some View {
        ScrollView {VStack(spacing:22) {
            if !model.reverbAvailable {EmptyNotice(text:"The 828x’s reverb is available at 44.1 and 48 kHz. Choose one of these rates in Device settings to use it.")}
            HStack{Chip(label:"REVERB ON",key:key(0),color:.purple,offLabel:"REVERB OFF").frame(width:140);Spacer();Choice(title:"Split point",key:key(1),labels:["Outputs","Mixes"],codes:[ReverbSplitPoint.outputs.rawValue,ReverbSplitPoint.mixes.rawValue])}
            Text(model.reverbSplitPoint?.explanation ?? "Reading reverb routing…").font(.system(size:12)).foregroundStyle(Color.quiet).frame(maxWidth:.infinity,alignment:.leading)
            Panel(title:"Output send & return") {
                HStack(alignment:.top,spacing:28) {
                    VStack(alignment:.leading,spacing:7) {
                        Text("Output pair").font(.system(size:11)).foregroundStyle(Color.quiet)
                        Picker("Output pair",selection:$output){ForEach(outputNames.indices,id:\.self){Text(model.name(3,$0)).tag($0)}}.labelsHidden()
                    }.frame(width:200)
                    ReverbLevel(section:3,channel:output)
                    ReverbLevel(section:3,channel:output,isReturn:true)
                }
                Text("For macOS or Ableton playback, choose its output pair here. Use Outputs split point and raise both send and return. Sidebar monitor mixes carry physical inputs.")
                    .font(.system(size:11)).foregroundStyle(Color.quiet)
                if model.number(key(0)) == 0 {
                    Text("Reverb is off. Enable it above to hear the effect.").font(.system(size:11)).foregroundStyle(Color.orange)
                } else if model.reverbSplitPoint == .outputs,
                          let send=model.number(dspKey(3,11,0,output)),let level=model.number(dspKey(3,11,1,output)),send==0 || level==0 {
                    Text(level==0 ? "\(model.name(3,output)) return is silent. Raise it to hear the reverb.":"\(model.name(3,output)) send is silent. Raise it to feed this output into reverb.")
                        .font(.system(size:11)).foregroundStyle(Color.orange)
                }
            }
            ReverbGraph(delay:model.number(key(2)) ?? 0,decay:model.number(key(5)) ?? 1000,
                        low:model.number(key(6)) ?? 100,mid:model.number(key(7)) ?? 100,high:model.number(key(8)) ?? 100,
                        active:model.number(key(0))==1).equatable().frame(height:260)
            HStack(alignment:.top,spacing:22) {
                Panel(title:"Room") {
                    Choice(title:"Shape",key:key(12),labels:["A","B","C","D","E"])
                    Parameter(title:"Size",key:key(13),range:50...400,step:1,color:.purple)
                    Parameter(title:"Width",key:key(11),range: -1...1,color:.purple)
                    Parameter(title:"Early reflections",key:key(14),range: -96...0,gain:true,color:.purple)
                }
                Panel(title:"Time") {
                    Knob(title:"Pre-delay",key:key(2),range:0...100,unit:"ms",step:1,color:.purple)
                    Parameter(title:"Decay",key:key(5),range:100...60000,unit:"ms",step:1,logarithmic:true,color:.ice)
                }
                Panel(title:"High-frequency shelf") {
                    Parameter(title:"Frequency",key:key(3),range:1000...20000,unit:"Hz",step:1,logarithmic:true,color:.orange)
                    Parameter(title:"Attenuation",key:key(4),range: -40...0,unit:"dB",step:1,color:.orange)
                    EmptyNotice(text:"Set send and return levels in each mix or channel. Reverb settings are shared across the 828x.")
                }
            }
            Panel(title:"Multiband decay") {
                HStack(spacing:28) {Parameter(title:"Low",key:key(6),range:0...100,unit:"%",step:1,color:.mint);Parameter(title:"Mid",key:key(7),range:0...100,unit:"%",step:1,color:.purple);Parameter(title:"High",key:key(8),range:0...100,unit:"%",step:1,color:.ice)}
                HStack(spacing:28) {Parameter(title:"Low / mid crossover",key:key(9),range:100...20000,unit:"Hz",step:1,logarithmic:true,color:.mint);Parameter(title:"Mid / high crossover",key:key(10),range:100...20000,unit:"Hz",step:1,logarithmic:true,color:.ice)}
            }
        }.padding(26).padding(.top,0)}
    }
}
