import SwiftUI
import AppKit

struct ChannelTarget:Identifiable {var section:Int;var channel:Int;var tab:Int=0;var bus:Int?=nil;var id:String{"\(section):\(channel)"}}
struct MixerRoot:View {
    @EnvironmentObject var model:MixerModel
    @AppStorage("layout.lastPage") private var page="home"
    @State private var target:ChannelTarget?
    @State private var showLayout=false
    @AppStorage("layout.sidebarWidth") private var sidebarWidth=204.0
    @AppStorage("layout.footerHeight") private var footerHeight=36.0
    var body:some View {
        GeometryReader { geometry in HStack(spacing:0) {
            sidebar.frame(width:min(340,max(180,sidebarWidth))).background(Color.rail)
            PanelDivider(value:$sidebarWidth,vertical:true,bounds:180...340,initial:204,label:"Sidebar width")
            VStack(spacing:0) {
                header
                if let error=model.error {
                    HStack(spacing:12) {
                        Image(systemName:"exclamationmark.circle.fill")
                        Text(error).font(.system(size:12)).fixedSize(horizontal:false,vertical:true)
                        Spacer(minLength:10)
                        Button("Retry"){model.refresh()}.buttonStyle(ConsoleButtonStyle(accent:.orange))
                        Button{model.error=nil}label:{Image(systemName:"xmark").frame(width:30,height:30).contentShape(Rectangle())}.buttonStyle(.plain).accessibilityLabel("Dismiss message")
                    }.foregroundStyle(Color.orange).padding(12).background(Color.orange.opacity(0.06))
                }
                content.frame(maxWidth:.infinity,maxHeight:.infinity)
                PanelDivider(value:$footerHeight,vertical:false,bounds:36...min(160,max(36,geometry.size.height-570)),initial:36,label:"Bottom bar height")
                footer.frame(height:min(max(36,footerHeight),max(36,geometry.size.height-570)))
            }
        }.coordinateSpace(name:"mixerLayout")}.foregroundStyle(Color.ink).background(Color.desk).preferredColorScheme(.dark)
        .frame(minWidth:1120,minHeight:720)
        .task {while !Task.isCancelled {
            let state=await Task.detached{AudioRateAccess.read()}.value
            if state.rate>0 && model.sampleRate != Int(state.rate) {model.sampleRate=Int(state.rate);target=nil}
            try? await Task.sleep(nanoseconds:1_000_000_000)
        }}
        .sheet(item:$target) {item in ChannelEditor(target:item).environmentObject(model).environmentObject(model.meters)}
        .alert("Apply preset?",isPresented:Binding(get:{model.presetToApply != nil},set:{if !$0 {model.presetToApply=nil}})) {
            Button("Cancel",role:.cancel){model.presetToApply=nil}
            Button("Apply"){model.applyPreset()}
        } message: {Text("Apply these mixer and effects settings to the 828x? Input power, monitor volume, talkback and mix destinations will stay as they are.")}
    }
    var sidebar:some View {
        VStack(alignment:.leading,spacing:0) {
            HStack(spacing:10) {
                Image(systemName:"waveform").font(.system(size:21,weight:.medium)).foregroundStyle(Color.ice)
                    .frame(width:36,height:36).background(Color.ice.opacity(0.09),in:RoundedRectangle(cornerRadius:9))
                VStack(alignment:.leading,spacing:3) {Text("Cute Mix").font(.system(size:19,weight:.semibold,design:.rounded));Text("MOTU 828x").font(.system(size:11)).foregroundStyle(Color.quiet)}
            }.padding(.horizontal,18).padding(.top,22).padding(.bottom,24)
            ScrollView(.vertical) {
                VStack(alignment:.leading,spacing:4) {
                    nav("home","Overview","square.grid.2x2")
                    nav("inputs","Inputs","arrow.down.to.line")
                    nav("outputs","Outputs","arrow.up.to.line")
                    nav("reverb","Reverb","waveform.path")
                    nav("analysis","Analysis","chart.xyaxis.line")
                    Caption(text:"Monitor mixes").padding(.horizontal,12).padding(.top,23).padding(.bottom,7)
                    ForEach(0..<8,id:\.self) {bus in
                        NavigationRow(title:model.mixTitle(bus),number:bus+1,selected:page=="mix\(bus)",color:busColors[bus]){page="mix\(bus)"}
                    }
                }.padding(.horizontal,10).padding(.bottom,12)
            }
            Divider().overlay(Color.edge).padding(.horizontal,18)
            nav("device","Device","slider.horizontal.3").padding(.horizontal,10).padding(.top,10)
            HStack(spacing:8) {
                Circle().fill(model.ready ? Color.mint:Color.orange).frame(width:6,height:6)
                Text(model.statusText).lineLimit(1)
                Spacer(minLength:0)
                if model.ready {Text(String(format:"%g kHz",Double(model.sampleRate)/1000)).monospacedDigit()}
            }.font(.system(size:10,weight:.medium)).foregroundStyle(Color.quiet).padding(.horizontal,22).padding(.top,12).padding(.bottom,18)
        }
    }
    func nav(_ id:String,_ name:String,_ symbol:String)->some View {
        NavigationRow(title:name,symbol:symbol,selected:page==id){page=id}
    }
    var title:String {if page.hasPrefix("mix"),let bus=Int(page.dropFirst(3)),(0..<8).contains(bus){return model.mixTitle(bus)};return ["home":"Studio overview","device":"Device settings","inputs":"Inputs","outputs":"Outputs","reverb":"Reverb","analysis":"Signal analysis"][page] ?? "Studio overview"}
    var subtitle:String {if page.hasPrefix("mix"){return "Your direct monitor mix"};return ["home":"Your studio, at a glance","device":"Connections, playback and routing","inputs":"Input levels and channel processing","outputs":"Output levels and channel processing","reverb":"Room, decay and send routing","analysis":"A closer look at what you hear"][page] ?? ""}
    var header:some View {
        HStack(spacing:16) {
            VStack(alignment:.leading,spacing:5){Text(title).font(.system(size:25,weight:.semibold));Text(subtitle).font(.system(size:12)).foregroundStyle(Color.quiet)}
            Spacer(minLength:8)
            Menu {
                Button("Load preset…"){model.loadPreset()}.disabled(!model.ready)
                Button("Save preset…"){model.savePreset()}.disabled(!model.ready)
            } label:{Label("Presets",systemImage:"slider.horizontal.2.square")}.menuStyle(.borderlessButton).fixedSize().padding(.horizontal,12).frame(height:34).background(Color.white.opacity(0.035),in:RoundedRectangle(cornerRadius:7)).overlay(RoundedRectangle(cornerRadius:7).stroke(Color.edge))
            Button {showLayout.toggle()} label:{Image(systemName:"rectangle.3.group")}.buttonStyle(ConsoleButtonStyle())
                .accessibilityLabel("Customize layout").help("Customize layout").popover(isPresented:$showLayout){MixerLayoutOptions()}
            Button {model.refresh()} label:{Image(systemName:"arrow.clockwise")}.buttonStyle(ConsoleButtonStyle())
                .accessibilityLabel("Refresh settings").help("Refresh settings · ⌘R")
        }.font(.system(size:12)).padding(.horizontal,24).padding(.vertical,20)
    }
    @ViewBuilder var content:some View {
        if page=="device" {DevicePage()}
        else if page=="inputs" {ChannelBank(section:1,open:{target=$0}).id(1)}
        else if page=="outputs" {ChannelBank(section:3,open:{target=$0}).id(3)}
        else if page=="reverb" {ReverbPage()}
        else if page=="analysis" {AnalysisPage()}
        else if page.hasPrefix("mix"),let bus=Int(page.dropFirst(3)),(0..<8).contains(bus) {MixPage(bus:bus,open:{target=$0}).id(bus)}
        else {OverviewPage(open:{target=$0},mix:{page="mix\($0)"})}
    }
    var footer:some View {
        HStack(spacing:8) {
            Image(systemName:page.hasPrefix("mix") ? "slider.vertical.3":"waveform.path").foregroundStyle(Color.ice)
            Text(page.hasPrefix("mix") ? "Direct monitoring":"MOTU 828x").foregroundStyle(Color.quiet)
            Spacer()
            if model.editsPending>0 {ProgressView().controlSize(.mini)}
            Text(model.error != nil ? "Needs attention" : !model.connected ? "Waiting for your interface" : model.editsPending>0 ? "Applying changes…" : model.ready ? "All changes applied" : "Loading settings…").foregroundStyle(Color.quiet)
        }.font(.system(size:11)).padding(.horizontal,24).frame(maxWidth:.infinity,maxHeight:.infinity).background(Color.rail)
    }
}
struct ChannelBank:View {
    @EnvironmentObject var model:MixerModel
    var section:Int
    var open:(ChannelTarget)->Void
    @State private var group=ChannelGroup.all
    var body:some View {
        VStack(spacing:14) {
            HStack {ChannelFilter(selection:$group);Spacer();Text("Select a channel to edit").font(.system(size:11)).foregroundStyle(Color.quiet)}.padding(.horizontal,24)
            GeometryReader {geometry in
                ScrollView([.horizontal,.vertical]) {
                    HStack(alignment:.top,spacing:2) {ForEach(group.channels(section:section).filter{(section==1 ? model.inputChannels:model.outputChannels).contains($0)},id:\.self) {ch in ProcessingStrip(section:section,channel:ch,open:open)}}
                        .frame(height:max(section==1 ? 640:590,geometry.size.height-16)).padding(.horizontal,16).padding(.bottom,16)
                        .frame(minWidth:max(0,geometry.size.width-16),alignment:.leading)
                }
            }
        }
    }
}
struct OverviewPage:View {
    @EnvironmentObject var model:MixerModel
    @AppStorage("layout.gridColumns") private var gridColumns=4
    @AppStorage("layout.showTalkback") private var showTalkback=false
    var open:(ChannelTarget)->Void;var mix:(Int)->Void
    var body:some View {
        ScrollView {
            VStack(alignment:.leading,spacing:24) {
                HStack(alignment:.top,spacing:14) {
                    ForEach(0..<2,id:\.self) {ch in
                        Panel(title:model.name(1,ch)) {
                            HStack(spacing:20) {
                                LiveMeter(index:inputMeterIndex(ch),color:.ice,width:9).frame(height:105)
                                VStack(spacing:15) {
                                    HStack(spacing:8){Chip(label:"48V",key:dspKey(1,0,11,ch),color:.red);Chip(label:"PAD",key:dspKey(1,0,9,ch))}
                                    Parameter(title:"Input gain",key:dspKey(1,0,2,ch),range:0...53,unit:"dB",step:1)
                                }
                            }
                            Button{open(ChannelTarget(section:1,channel:ch))}label:{HStack{Text("EQ & dynamics");Spacer();Image(systemName:"arrow.up.right")}}.buttonStyle(ConsoleButtonStyle())
                        }
                    }
                    Panel(title:"Monitor") {
                        HStack(spacing:18) {
                            HStack(spacing:4){LiveMeter(index:outputMeterIndex(0),color:.mint,width:9);LiveMeter(index:outputMeterIndex(0)+1,color:.mint,width:9)}.frame(height:105)
                            VStack(alignment:.leading,spacing:15) {
                                Parameter(title:"Master volume",key:dspKey(0,0,0),range: -96...0,unit:"dB",gain:true,color:.mint)
                                Text("Main L/R output levels").font(.system(size:11)).foregroundStyle(Color.quiet)
                            }
                        }
                        HStack(spacing:8){Chip(label:"TALK",key:dspKey(0,0,1));Chip(label:"LISTEN",key:dspKey(0,0,2),color:.orange)}.frame(height:34)
                    }
                }
                VStack(alignment:.leading,spacing:14) {
                    SectionHeading(title:"Monitor mixes",detail:"Choose a mix to adjust")
                    LazyVGrid(columns:Array(repeating:GridItem(.flexible(),spacing:12),count:min(5,max(2,gridColumns))),spacing:12) {
                        ForEach(0..<8,id:\.self) {bus in MixOverviewCard(bus:bus){mix(bus)}}
                    }
                }
                Panel(title:"Input activity") {
                    HStack(alignment:.bottom,spacing:22) {
                        activityGroup("MIC",channels:0..<2,color:.ice)
                        activityGroup("ANALOG",channels:2..<10,color:.ice)
                        if model.sampleRate<=96000 {
                            activityGroup("S/PDIF",channels:10..<12,color:.mint)
                            activityGroup("ADAT A",channels:12..<(model.sampleRate<=48000 ? 20:16),color:.mint)
                            activityGroup("ADAT B",channels:20..<(model.sampleRate<=48000 ? 28:24),color:.mint)
                        }
                    }
                }
                DisclosureGroup(isExpanded:$showTalkback) {
                    VStack(spacing:20) {
                        HStack(spacing:24) {
                            Choice(title:"Talkback source",key:dspKey(0,0,3),labels:model.inputChannels.map{inputNames[$0]}+["Disabled"],codes:model.inputChannels+[255])
                            Choice(title:"Listenback source",key:dspKey(0,0,4),labels:model.inputChannels.map{inputNames[$0]}+["Disabled"],codes:model.inputChannels+[255])
                            Choice(title:"Return to computer",key:dspKey(0,0,8),labels:model.outputChannels.map{outputNames[$0]},codes:model.outputChannels)
                        }
                        HStack(spacing:30){Parameter(title:"Talk level",key:dspKey(0,0,5),range: -96...0,unit:"dB",gain:true);Parameter(title:"Listen level",key:dspKey(0,0,6),range: -96...0,unit:"dB",gain:true)}
                        Text("Choose talkback destinations in an output’s Channel tab.").font(.system(size:11)).foregroundStyle(Color.quiet).frame(maxWidth:.infinity,alignment:.leading)
                    }.padding(.top,18)
                } label:{Label("Talkback & routing",systemImage:"mic.badge.plus").font(.system(size:13,weight:.medium))}
                    .padding(18).background(Color.rail,in:RoundedRectangle(cornerRadius:10)).overlay(RoundedRectangle(cornerRadius:10).stroke(Color.edge))
            }.padding(.horizontal,24).padding(.bottom,24)
        }
    }
    func activityGroup(_ title:String,channels:Range<Int>,color:Color)->some View {
        VStack(alignment:.leading,spacing:12) {
            Caption(text:title)
            HStack(alignment:.bottom,spacing:0) {ForEach(Array(channels),id:\.self) {ch in
                VStack(spacing:9){LiveMeter(index:inputMeterIndex(ch),color:color,width:7).frame(height:64);Text("\(ch-channels.lowerBound+1)").font(.system(size:9,design:.monospaced)).foregroundStyle(Color.quiet)}.frame(maxWidth:.infinity)
            }}
        }.frame(maxWidth:.infinity)
    }
}
struct MixOverviewCard:View {
    @EnvironmentObject var model:MixerModel
    var bus:Int
    var action:()->Void
    @State private var hovering=false
    var destination:String {
        guard let n=model.number(dspKey(2,0,0,bus)) else{return "Connecting…"}
        return outputNames.indices.contains(Int(n)) ? "To \(model.name(3,Int(n)))":"No output assigned"
    }
    var body:some View {
        let color=busColors[bus]
        let muted=model.number(dspKey(2,0,1,bus))==1
        return Button(action:action) {
            VStack(alignment:.leading,spacing:12) {
                HStack {Text(String(format:"MIX %02d",bus+1)).font(.system(size:10,weight:.medium,design:.monospaced)).foregroundStyle(color);Spacer();Image(systemName:"arrow.up.right").font(.system(size:10,weight:.semibold)).foregroundStyle(hovering ? color:Color.quiet)}
                Text(model.mixTitle(bus)).font(.system(size:16,weight:.semibold)).foregroundStyle(Color.ink).lineLimit(1)
                Text(muted ? "Muted":destination).font(.system(size:10)).foregroundStyle(muted ? Color.orange:Color.quiet).lineLimit(1)
            }.padding(15).frame(maxWidth:.infinity,alignment:.leading).background(hovering ? Color.strip:Color.rail)
                .overlay(alignment:.top){Rectangle().fill(color.opacity(hovering ? 0.9:0.5)).frame(height:2)}
                .clipShape(RoundedRectangle(cornerRadius:9)).overlay(RoundedRectangle(cornerRadius:9).stroke(hovering ? color.opacity(0.4):Color.edge)).contentShape(Rectangle())
        }.buttonStyle(.plain).onHover{hovering=$0}.help("Open \(model.mixTitle(bus)) · \(destination)")
    }
}
struct MixPage:View {
    @EnvironmentObject var model:MixerModel
    @State private var group=ChannelGroup.all
    var bus:Int;var open:(ChannelTarget)->Void
    var color:Color{busColors[bus]}
    var body:some View {
        VStack(spacing:14) {
            HStack {ChannelFilter(selection:$group);Spacer();Text("MIX \(bus+1)").font(.system(size:11,weight:.semibold,design:.monospaced)).foregroundStyle(color)}.padding(.horizontal,24)
            GeometryReader {geometry in
                ScrollView(.vertical) {
                    HStack(spacing:12) {
                        ScrollView(.horizontal) {
                            HStack(spacing:2) {ForEach(group.channels(section:1).filter{model.inputChannels.contains($0)},id:\.self) {ch in MixStrip(bus:bus,channel:ch,open:open)}}.padding(.leading,16).padding(.bottom,10)
                        }
                        VStack(spacing:12) {
                            HStack {Text("Mix output").font(.system(size:14,weight:.semibold));Spacer();Circle().fill(color).frame(width:6,height:6)}
                            Choice(title:"Destination",key:dspKey(2,0,0,bus),labels:model.outputChannels.map{outputNames[$0]}+["Disabled"],codes:model.outputChannels+[255])
                            Chip(label:"MUTE",key:dspKey(2,0,1,bus),color:.red)
                            Fader(key:dspKey(2,0,2,bus),meterIndex:30+bus*2,color:color).frame(maxHeight:.infinity)
                            Divider().overlay(Color.edge)
                            Caption(text:"Reverb").frame(maxWidth:.infinity,alignment:.leading)
                            ReverbLevel(section:2,channel:bus,compact:true)
                            ReverbLevel(section:2,channel:bus,isReturn:true,compact:true)
                            Button("Clear solos") {for ch in 0..<28 where model.number(dspKey(2,ch+2,1,bus))==1 {model.set(dspKey(2,ch+2,1,bus),0)}}
                                .buttonStyle(ConsoleButtonStyle()).disabled(!model.ready || !(0..<28).contains{model.number(dspKey(2,$0+2,1,bus))==1})
                        }.padding(16).frame(width:180).frame(maxHeight:.infinity).background(Color.strip,in:RoundedRectangle(cornerRadius:8))
                            .overlay(alignment:.top){RoundedRectangle(cornerRadius:2).fill(color).frame(height:2).padding(.horizontal,12)}.padding(.trailing,16)
                    }.frame(height:max(660,geometry.size.height-16)).padding(.bottom,16)
                }
            }
        }
    }
}
struct MixStrip:View {
    @EnvironmentObject var model:MixerModel
    @AppStorage("layout.stripWidth") private var stripWidth=112.0
    var bus:Int;var channel:Int;var open:(ChannelTarget)->Void
    var color:Color {busColors[bus]}
    var body:some View {
        VStack(spacing:13) {
            Button {open(ChannelTarget(section:1,channel:channel,bus:bus))} label:{EQGraph(section:1,channel:channel,mini:true).frame(height:45).contentShape(Rectangle())}.buttonStyle(.plain).help("Edit channel EQ and dynamics")
            Text(model.name(1,channel)).font(.system(size:11,weight:.semibold)).lineLimit(1).frame(maxWidth:.infinity).padding(.vertical,7).background(Color.black.opacity(0.35))
            Parameter(title:"Pan",key:dspKey(2,channel+2,2,bus),range: -1...1,color:color)
            Chip(label:"MUTE",key:dspKey(2,channel+2,0,bus),color:.red)
            Fader(key:dspKey(2,channel+2,3,bus),meterIndex:inputMeterIndex(channel),color:color).frame(maxHeight:.infinity)
            Chip(label:"SOLO",key:dspKey(2,channel+2,1,bus),color:.yellow)
        }.padding(.horizontal,11).padding(.vertical,13).frame(width:min(190,max(112,stripWidth))).frame(maxHeight:.infinity).background(Color.rail).overlay(alignment:.top){Rectangle().fill(color.opacity(0.5)).frame(height:2)}
    }
}
struct ProcessingStrip:View {
    @EnvironmentObject var model:MixerModel
    @AppStorage("layout.processingWidth") private var stripWidth=155.0
    var section:Int;var channel:Int;var open:(ChannelTarget)->Void
    var body:some View {
        VStack(spacing:14) {
            VStack(alignment:.leading,spacing:7) {
                Caption(text:section==1 ? "Input \(channel+1)":"Stereo output")
                Button{open(ChannelTarget(section:section,channel:channel))}label:{HStack(spacing:4){Text(model.name(section,channel)).font(.system(size:14,weight:.semibold)).lineLimit(1);Spacer(minLength:0);Image(systemName:"chevron.right").font(.system(size:9))}.foregroundStyle(Color.ink).frame(minHeight:28).contentShape(Rectangle())}.buttonStyle(.plain).help("Edit \(model.name(section,channel))")
            }.frame(maxWidth:.infinity,alignment:.leading)
            Button{open(ChannelTarget(section:section,channel:channel))} label:{EQGraph(section:section,channel:channel,mini:true).frame(height:70).contentShape(Rectangle())}.buttonStyle(.plain)
            Chip(label:"EQ",key:dspKey(section,section==1 ? 1:0,0,channel),color:.purple)
            Chip(label:"DYNAMICS",key:dspKey(section,section==1 ? 9:8,0,channel),color:.ice)
            if section==1 {
                Parameter(title:"Trim",key:dspKey(1,0,2,channel),range: channel<2 ? 0...53 : channel<10 ? -96...22 : 0...12,unit:"dB",step:1)
                Chip(label:"PHASE ∅",key:dspKey(1,0,0,channel))
            }
            MeterWell(index:section==1 ? inputMeterIndex(channel):outputMeterIndex(channel),stereo:section==3).frame(maxHeight:.infinity)
            Divider().overlay(Color.edge)
            Caption(text:"Reverb").frame(maxWidth:.infinity,alignment:.leading)
            ReverbLevel(section:section,channel:channel,compact:true)
            if section==3 {ReverbLevel(section:section,channel:channel,isReturn:true,compact:true)}
            Button{open(ChannelTarget(section:section,channel:channel))}label:{Text("Edit channel").frame(maxWidth:.infinity)}.buttonStyle(ConsoleButtonStyle(prominent:true))
        }.padding(14).frame(width:min(240,max(155,stripWidth))).frame(maxHeight:.infinity).background(Color.rail).overlay(alignment:.top){Rectangle().fill(Color.ice.opacity(0.3)).frame(height:2)}
    }
}
struct DevicePage:View {
    @EnvironmentObject var model:MixerModel
    var rate:AudioRateAccess.State {var s=AudioRateAccess.State();s.rate=Double(model.sampleRate);return s}
    var body:some View {
        ScrollView {VStack(spacing:20) {
            Panel(title:"Your interface") {
                HStack(alignment:.top) {VStack(alignment:.leading,spacing:8){Text("MOTU 828x").font(.system(size:36,weight:.light));Text("USB audio interface").foregroundStyle(Color.quiet)};Spacer();Image(systemName:"hifispeaker.fill").font(.system(size:48)).foregroundStyle(Color.ice)}
                Divider()
                HStack {deviceStat("CLOCK","Internal");deviceStat("OPTICAL A / B",model.sampleRate>96000 ? "Unavailable":"ADAT / ADAT")}
                AudioRateSettingsView()
            }
            Panel(title:"Driver volume control") {AudioVolumeSettingsView()}
            Panel(title:"Routing reference") {
                Text(rate.outputRouting).font(.system(size:13,design:.monospaced)).lineSpacing(8)
                Text("Cute Mix bus destination selectors use the hardware output names. A mix adds direct inputs to its destination; it does not redirect the DAW’s output channels.").font(.system(size:12)).foregroundStyle(Color.quiet)
            }
            Panel(title:"Mixing & effects") {
                Text("8 stereo mixes · \(model.inputChannels.count) physical inputs\n"+(model.processingAvailable ? "7-band EQ · compressor · Leveler":"EQ and dynamics unavailable at this rate")+(model.reverbAvailable ? " · stereo reverb":"")).font(.system(size:16)).lineSpacing(8)
                EmptyNotice(text:"Mixing and effects run on your 828x and keep working when you close Cute Mix.")
                HStack {Button("Driver settings"){NSWorkspace.shared.open(URL(fileURLWithPath:"/Applications/828x Control.app"))};Button("Refresh settings"){model.refresh()}}.buttonStyle(ConsoleButtonStyle())
            }
        }.padding(26).padding(.top,0)}
    }
    func deviceStat(_ title:String,_ value:String)->some View{VStack(alignment:.leading,spacing:9){Caption(text:title);Text(value).font(.system(size:15,weight:.medium))}.frame(maxWidth:.infinity,alignment:.leading)}
}
