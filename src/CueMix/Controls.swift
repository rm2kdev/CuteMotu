import SwiftUI

extension Color {
    static let desk = Color(red:0.064,green:0.073,blue:0.080)
    static let rail = Color(red:0.092,green:0.102,blue:0.113)
    static let strip = Color(red:0.129,green:0.143,blue:0.158)
    static let edge = Color.white.opacity(0.10)
    static let ink = Color(red:0.88,green:0.91,blue:0.94)
    static let quiet = Color(red:0.61,green:0.65,blue:0.69)
    static let signal = Color(red:1,green:0.47,blue:0.13)
    static let ice = Color(red:0.25,green:0.69,blue:0.96)
}
let busColors:[Color]=[.ice,.red,.orange,.yellow,.mint,.cyan,.purple,.pink]
let bandColors:[Color]=[.cyan,.mint,Color(red:0.65,green:0.47,blue:1),.pink,.orange,.blue,.yellow]

struct Caption:View {
    var text:String
    var body:some View {Text(text.uppercased()).font(.system(size:10,weight:.medium,design:.monospaced)).tracking(1.1).foregroundStyle(Color.quiet)}
}
struct Panel<Content:View>:View {
    var title:String
    @ViewBuilder var content:Content
    var body:some View { VStack(alignment:.leading,spacing:18) { Text(title).font(.system(size:13,weight:.semibold));content }.padding(20).frame(maxWidth:.infinity,alignment:.leading).background(LinearGradient(colors:[Color.rail,Color.rail.opacity(0.85)],startPoint:.top,endPoint:.bottom)).overlay(RoundedRectangle(cornerRadius:10).stroke(Color.edge)).clipShape(RoundedRectangle(cornerRadius:10)) }
}
struct Chip:View {
    @EnvironmentObject var model:MixerModel
    var label:String;var key:UInt32;var color:Color = .ice;var offLabel:String?=nil
    var body:some View {
        let on=(model.number(key) ?? 0) != 0
        Button {model.toggle(key)} label:{HStack(spacing:6){Circle().fill(on ? color:Color.quiet.opacity(0.35)).frame(width:4,height:4);Text(on ? label : offLabel ?? label).font(.system(size:10,weight:.semibold)).lineLimit(1).minimumScaleFactor(0.8)}.frame(maxWidth:.infinity,minHeight:32).background(on ? color.opacity(0.15) : Color.black.opacity(0.08)).foregroundStyle(on ? color : Color.quiet).overlay(RoundedRectangle(cornerRadius:5).stroke(on ? color.opacity(0.6) : Color.white.opacity(0.14))).clipShape(RoundedRectangle(cornerRadius:5)).contentShape(Rectangle())}
        .buttonStyle(.plain).disabled(!model.available(key)).opacity(model.available(key) ? 1 : 0.35)
        .accessibilityLabel(label).accessibilityValue(model.number(key) == nil ? "Unavailable" : on ? "On" : "Off")
    }
}
struct Parameter:View {
    @EnvironmentObject var model:MixerModel
    let title:String;let key:UInt32;let range:ClosedRange<Double>
    var unit:String="";var step:Double=0;var logarithmic=false;var gain=false;var color:Color = .ice
    @State private var enteringValue=false
    var display:Double? {guard let n=model.number(key) else{return nil};return gain ? decibels(n):n}
    var valueBinding:Binding<Double> { Binding(get:{
        let n=display ?? range.lowerBound;return logarithmic ? log10(max(range.lowerBound,n)):n
    },set:{ x in
        var n=logarithmic ? pow(10,x):x;if step>0{n=(n/step).rounded()*step};model.set(key,gain ? amplitude(n):n)
    }) }
    var body:some View {
        VStack(alignment:.leading,spacing:8) {
            HStack(spacing:5) {
                Text(title).font(.system(size:11,weight:.medium)).lineLimit(1).help(title)
                Spacer(minLength:0)
                Button {enteringValue=true} label:{Text(valueText).font(.system(size:11,design:.monospaced)).foregroundStyle(model.previews[key] == nil ? Color.ink:color).fixedSize().padding(.horizontal,5).frame(minHeight:25).background(Color.white.opacity(0.04),in:RoundedRectangle(cornerRadius:4)).contentShape(Rectangle())}
                    .buttonStyle(.plain).disabled(!model.available(key)).accessibilityLabel("Enter \(title.lowercased())").help("Enter an exact value")
                    .popover(isPresented:$enteringValue) {ParameterEntry(title:title,current:display ?? range.lowerBound,range:range,step:step,unit:unit.isEmpty && gain ? "dB":unit) {number in
                        model.beginInteraction(key);model.set(key,gain ? amplitude(number):number);model.endInteraction(key)
                    }}
            }
            Slider(value:valueBinding,in:logarithmic ? log10(range.lowerBound)...log10(range.upperBound):range,onEditingChanged:{active in if active {model.beginInteraction(key)}else{model.endInteraction(key)}}).tint(color).controlSize(.small).disabled(!model.available(key)).accessibilityLabel(title).accessibilityValue(valueText)
        }.opacity(model.available(key) ? 1:0.35).onDisappear{model.endInteraction(key)}
    }
    var valueText:String {guard let x=display else{return "—"};if gain && x <= -95.9{return "−∞ dB"};return String(format:step>=1 ? "%.0f%@":step>0 && step<0.1 ? "%.2f%@":"%.1f%@",x,unit.isEmpty ? "":" \(unit)")}
}
struct Choice:View {
    @EnvironmentObject var model:MixerModel
    var title:String;var key:UInt32;var labels:[String];var codes:[Int]?=nil
    var body:some View {
        VStack(alignment:.leading,spacing:7) {Text(title).font(.system(size:11)).foregroundStyle(Color.quiet)
            Picker(title,selection:Binding(get:{Int(model.number(key) ?? 0)},set:{model.set(key,Double($0))})) {ForEach(labels.indices,id:\.self){Text(labels[$0]).tag(codes?[$0] ?? $0)}}.labelsHidden().disabled(!model.available(key))
        }
    }
}
struct ReverbLevel:View {
    @EnvironmentObject var model:MixerModel
    var section:Int;var channel:Int;var isReturn=false;var compact=false
    var key:UInt32 {dspKey(section,section==1 ? 12:section==2 ? 1:11,isReturn ? 1:0,channel)}
    var allowed:Bool {model.reverbAvailable && (model.reverbSplitPoint?.permits(section:section,isReturn:isReturn) ?? false)}
    var body:some View {
        VStack(alignment:.leading,spacing:5) {
            Parameter(title:compact ? (isReturn ? "Return":"Send"):(isReturn ? "Reverb return":"Reverb send"),key:key,range: -96...0,unit:"dB",gain:true,color:.purple)
                .disabled(!allowed).opacity(allowed ? 1:0.4)
            if !allowed {
                Text(!model.reverbAvailable ? "Available at 44.1 / 48 kHz":model.reverbSplitPoint == nil ? "Reading reverb routing…":section==3 ? "Requires Outputs split point":"Requires Mixes split point")
                    .font(.system(size:9)).foregroundStyle(Color.quiet).fixedSize(horizontal:false,vertical:true)
            }
        }
    }
}
struct LevelMeter:View {
    var peak:Float;var color:Color = .signal;var width:CGFloat=9
    var body:some View {
        GeometryReader {g in
            let fraction=max(0,min(1,(decibels(Double(peak))+72)/72))
            ZStack(alignment:.bottom) {
                RoundedRectangle(cornerRadius:2).fill(Color.black.opacity(0.7))
                Rectangle().fill(color.gradient).frame(height:g.size.height*fraction)
                if peak>=0.999 {Rectangle().fill(Color.red).frame(height:3).offset(y: -g.size.height+3)}
                Canvas {context,size in
                    var ticks=Path()
                    for y in stride(from:4.0,to:size.height,by:5) {ticks.move(to:CGPoint(x:0,y:y));ticks.addLine(to:CGPoint(x:size.width,y:y))}
                    context.stroke(ticks,with:.color(Color.black.opacity(0.26)),lineWidth:1)
                }.allowsHitTesting(false)
            }
        }.frame(width:width).accessibilityLabel("Hardware peak meter").accessibilityValue(String(format:"%.0f dBFS",decibels(Double(peak))))
    }
}
struct LiveMeter:View {
    @EnvironmentObject var meters:MeterState
    var index:Int;var color:Color = .signal;var width:CGFloat=9
    var body:some View {LevelMeter(peak:meters.peaks.indices.contains(index) ? meters.peaks[index]:0,color:color,width:width)}
}
struct GainReductionMeter:View {
    @EnvironmentObject var meters:MeterState
    var section:Int;var channel:Int;var leveler=false;var color:Color = .ice
    var body:some View {
        let gain=meters.reductions[reductionMeterIndex(section,channel,leveler)]
        let db=gain.map{max(0,-decibels(Double($0)))}
        return VStack(spacing:7) {
            HStack {Text("GAIN REDUCTION").font(.system(size:9,design:.monospaced));Spacer();Text(db.map{String(format:"%.1f dB",$0)} ?? "—").font(.system(size:11,design:.monospaced))}.foregroundStyle(Color.quiet)
            GeometryReader {g in ZStack(alignment:.leading) {Rectangle().fill(Color.black.opacity(0.6));Rectangle().fill(color).frame(width:g.size.width*min(1,(db ?? 0)/24))}}.frame(height:4)
        }.accessibilityElement(children:.combine)
    }
}
struct Fader:View {
    @EnvironmentObject var model:MixerModel
    var key:UInt32;var meterIndex:Int?;var color:Color = .signal
    var db:Double {decibels(model.number(key) ?? 0)}
    // Give the operating range around unity more space than the silence end.
    func position(_ db:Double)->Double { db >= -48 ? (db+48)/64+0.25 : (db+96)/192 }
    func level(_ pos:Double)->Double {pos>=0.25 ? (pos-0.25)*64-48 : pos*192-96}
    var body:some View {
        VStack(spacing:12) {
            GeometryReader {g in
                let height=g.size.height-24
                ZStack(alignment:.topLeading) {
                    ForEach([0,-12,-24,-48,-96],id:\.self) {n in
                        let y=height*(1-position(Double(n)))+12
                        Path {p in p.move(to:CGPoint(x:15,y:y));p.addLine(to:CGPoint(x:53,y:y))}.stroke(Color.white.opacity(0.14),lineWidth:1)
                        Text(n == -96 ? "−∞":"\(n)").font(.system(size:9,design:.monospaced)).foregroundStyle(Color.quiet).position(x:5,y:y)
                    }
                    if let meterIndex {LiveMeter(index:meterIndex,color:color).frame(height:height).offset(x:26,y:12)}
                    Capsule().fill(.black).frame(width:3,height:height).offset(x:65,y:12)
                    Circle().fill(Color.black).overlay(Circle().stroke(color,lineWidth:2).padding(4)).overlay(Circle().stroke(Color.black,lineWidth:2)).frame(width:29,height:29).offset(x:52,y:height*(1-position(db))-2)
                }.contentShape(Rectangle()).gesture(DragGesture(minimumDistance:0).onChanged {event in
                    guard model.available(key) else{return};model.beginInteraction(key);let pos=min(1,max(0,1-(event.location.y-12)/height));model.set(key,amplitude(level(pos)))
                }.onEnded {_ in model.endInteraction(key)}).onTapGesture(count:2) {model.set(key,1)}
            }.frame(width:86).frame(minHeight:180)
            Text(model.number(key) == nil ? "—" : db <= -95.9 ? "−∞" : String(format:"%.1f",db)).font(.system(size:12,weight:.medium,design:.monospaced)).foregroundStyle(color)
        }.opacity(model.available(key) ? 1:0.35).onDisappear{model.endInteraction(key)}.accessibilityElement(children:.ignore).accessibilityLabel("Mix level").accessibilityValue(String(format:"%.1f decibels",db)).accessibilityAdjustableAction {direction in model.set(key,amplitude(max(-96,min(0,db+(direction == .increment ? 1:-1))))) }
    }
}
struct Knob:View {
    @EnvironmentObject var model:MixerModel
    var title:String;var key:UInt32;var range:ClosedRange<Double>;var unit:String="";var step:Double=0;var color:Color = .ice
    var body:some View {
        VStack(spacing:9) {
            let n=model.number(key) ?? range.lowerBound
            let fraction=(n-range.lowerBound)/(range.upperBound-range.lowerBound)
            ZStack {
                Circle().trim(from:0,to:0.75).stroke(Color.white.opacity(0.06),style:StrokeStyle(lineWidth:7,lineCap:.round)).rotationEffect(.degrees(135))
                Circle().trim(from:0,to:0.75*max(0,min(1,fraction))).stroke(color,style:StrokeStyle(lineWidth:7,lineCap:.round)).rotationEffect(.degrees(135))
                Text(model.number(key) == nil ? "—":String(format:step>=1 ? "%.0f":"%.1f",n)).font(.system(size:13,weight:.medium,design:.monospaced))
            }.frame(width:66,height:66).padding(6)
            Parameter(title:title,key:key,range:range,unit:unit,step:step,color:color)
        }.frame(minWidth:90,maxWidth:150)
    }
}
struct EmptyNotice:View {
    var text:String
    var body:some View {Text(text).font(.system(size:12)).foregroundStyle(Color.quiet).fixedSize(horizontal:false,vertical:true).padding(14).frame(maxWidth:.infinity,alignment:.leading).background(Color.white.opacity(0.03)).clipShape(RoundedRectangle(cornerRadius:5))}
}
