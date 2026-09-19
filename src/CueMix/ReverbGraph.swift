import SwiftUI

// A schematic envelope, not a measurement of MOTU's proprietary room response.
// A rounded time window lets changes move the curves instead of stretching
// every setting to the same width. Band endpoints include the pre-delay.
struct ReverbGraph:View,Equatable {
    var delay:Double
    var decay:Double
    var low:Double
    var mid:Double
    var high:Double
    var active:Bool

    private var preDelay:Double {max(0,min(100,delay))}
    private var decayTime:Double {max(100,min(60000,decay))}
    private var bands:[(name:String,time:Double,color:Color)] {
        [("LOW",decayTime*max(0,min(100,low))/100,.mint),
         ("MID",decayTime*max(0,min(100,mid))/100,.purple),
         ("HIGH",decayTime*max(0,min(100,high))/100,.ice)]
    }
    private var timeWindow:Double {
        let end=(preDelay+decayTime)*1.08
        return [250.0,500,1000,2000,5000,10000,20000,30000,60000,90000].first{$0>=end} ?? 90000
    }
    private func duration(_ ms:Double)->String {
        ms<1000 ? String(format:"%.0f ms",ms):String(format:"%.2f s",ms/1000)
    }
    var body:some View {
        VStack(alignment:.leading,spacing:14) {
            HStack(alignment:.firstTextBaseline) {
                Caption(text:"Reverb envelope")
                Text("PREVIEW").font(.system(size:9,design:.monospaced)).foregroundStyle(Color.quiet.opacity(0.7))
                Spacer()
                if !active {Text("BYPASSED").font(.system(size:9,weight:.semibold,design:.monospaced)).foregroundStyle(Color.quiet)}
            }
            HStack(spacing:24) {
                HStack(spacing:7) {
                    Rectangle().fill(Color.signal).frame(width:2,height:12)
                    Text("PRE-DELAY").foregroundStyle(Color.quiet)
                    Text(duration(preDelay)).foregroundStyle(Color.ink)
                }
                Spacer(minLength:8)
                ForEach(bands.indices,id:\.self) {i in
                    HStack(spacing:6) {
                        Circle().fill(bands[i].color).frame(width:5,height:5)
                        Text(bands[i].name).foregroundStyle(Color.quiet)
                        Text(duration(bands[i].time)).foregroundStyle(bands[i].color)
                    }
                }
            }.font(.system(size:10,weight:.medium,design:.monospaced))
            Canvas {context,size in
                let plot=CGRect(x:8,y:7,width:max(1,size.width-16),height:max(1,size.height-31))
                let start=plot.minX+plot.width*preDelay/timeWindow
                let bottom=plot.maxY
                let opacity=active ? 1.0:0.65

                // The horizontal axis is real time. Height is a perceptually
                // compressed envelope illustration, so it has no dB ticks.
                var grid=Path()
                for i in 0...5 {
                    let fraction=Double(i)/5
                    let x=plot.minX+plot.width*fraction
                    grid.move(to:CGPoint(x:x,y:plot.minY));grid.addLine(to:CGPoint(x:x,y:bottom))
                    let ms=timeWindow*fraction
                    let label=timeWindow<=1000 ? String(format:"%.0f ms",ms):String(format:"%.1f s",ms/1000)
                    context.draw(Text(label).font(.system(size:9,design:.monospaced)).foregroundColor(Color.quiet),
                                 at:CGPoint(x:x,y:bottom+15),anchor:i==0 ? .leading:i==5 ? .trailing:.center)
                }
                for fraction in [0.0,0.5,1.0] {
                    let y=plot.minY+plot.height*fraction
                    grid.move(to:CGPoint(x:plot.minX,y:y));grid.addLine(to:CGPoint(x:plot.maxX,y:y))
                }
                context.stroke(grid,with:.color(.white.opacity(0.065)),lineWidth:1)
                if preDelay>0 {
                    context.fill(Path(CGRect(x:plot.minX,y:plot.minY,width:start-plot.minX,height:plot.height)),with:.color(Color.signal.opacity(0.07)))
                }

                // Longest first keeps the shorter bands visible; offsets make
                // identical band times legible without shifting their endpoints.
                for i in bands.indices.sorted(by:{bands[$0].time>bands[$1].time}) {
                    let band=bands[i]
                    guard band.time>0 else{continue}
                    let height=plot.height-Double(i)*3
                    let end=plot.minX+plot.width*(preDelay+band.time)/timeWindow
                    var line=Path()
                    for sample in 0...160 {
                        let t=Double(sample)/160
                        let envelope=(exp(-3*t)-exp(-3))/(1-exp(-3))
                        let point=CGPoint(x:start+(end-start)*t,y:bottom-height*envelope)
                        if sample==0 {line.move(to:point)}else{line.addLine(to:point)}
                    }
                    var fill=line
                    fill.addLine(to:CGPoint(x:start,y:bottom));fill.closeSubpath()
                    context.fill(fill,with:.linearGradient(Gradient(colors:[band.color.opacity(0.15*opacity),band.color.opacity(0.015)]),
                                                          startPoint:CGPoint(x:0,y:plot.minY),endPoint:CGPoint(x:0,y:bottom)))
                    context.stroke(line,with:.color(band.color.opacity(0.9*opacity)),style:StrokeStyle(lineWidth:1.7,lineCap:.round))
                    context.fill(Path(ellipseIn:CGRect(x:end-2.5,y:bottom-2.5,width:5,height:5)),with:.color(band.color.opacity(opacity)))
                }
                var onset=Path();onset.move(to:CGPoint(x:start,y:plot.minY));onset.addLine(to:CGPoint(x:start,y:bottom))
                context.stroke(onset,with:.color(Color.signal.opacity(0.75)),style:StrokeStyle(lineWidth:1,dash:[3,4]))
            }
            .accessibilityLabel("Reverb envelope preview")
            .accessibilityValue("Pre-delay \(duration(preDelay)); low decay \(duration(bands[0].time)); mid decay \(duration(bands[1].time)); high decay \(duration(bands[2].time)); \(active ? "enabled":"bypassed")")
        }
        .padding(18)
        .background(Color.black.opacity(0.32))
        .overlay(RoundedRectangle(cornerRadius:7).stroke(Color.edge))
        .clipShape(RoundedRectangle(cornerRadius:7))
        .help("Illustrative decay envelopes. Times follow the hardware settings; curve shapes are approximate.")
    }
}
