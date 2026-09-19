import SwiftUI
import AppKit

// Shared defaults keep layouts consistent across windows and application launches.
struct MixerLayoutOptions:View {
    @AppStorage("layout.sidebarWidth") private var sidebar=204.0
    @AppStorage("layout.footerHeight") private var footer=36.0
    @AppStorage("layout.stripWidth") private var strip=112.0
    @AppStorage("layout.processingWidth") private var processing=155.0
    @AppStorage("layout.gridColumns") private var columns=4
    var body:some View {
        VStack(alignment:.leading,spacing:18) {
            Text("Layout").font(.headline)
            control("Sidebar",value:$sidebar,range:180...340)
            control("Bottom bar",value:$footer,range:36...160)
            control("Mixer channels",value:$strip,range:112...190)
            control("Input / output channels",value:$processing,range:155...240)
            Stepper("Overview grid: \(columns) columns",value:$columns,in:2...5)
            Text("Drag the panel dividers to resize. Double-click a divider to reset it.").font(.caption).foregroundStyle(.secondary)
            Button("Reset layout") {sidebar=204;footer=36;strip=112;processing=155;columns=4}.buttonStyle(ConsoleButtonStyle())
        }.padding(22).frame(width:300).background(Color.rail).foregroundStyle(Color.ink)
    }
    func control(_ name:String,value:Binding<Double>,range:ClosedRange<Double>)->some View {
        VStack(alignment:.leading,spacing:6){HStack{Text(name);Spacer();Text("\(Int(value.wrappedValue)) pt").monospacedDigit().foregroundStyle(.secondary)};Slider(value:value,in:range)}
    }
}
struct PanelDivider:View {
    @Binding var value:Double
    var vertical:Bool
    var bounds:ClosedRange<Double>
    var initial:Double
    var label:String
    @State private var origin:Double?
    @State private var hovering=false
    var body:some View {
        ZStack {
            Color.rail
            Capsule().fill(hovering ? Color.ice:Color.edge).frame(width:vertical ? 2:32,height:vertical ? 32:2)
        }.frame(width:vertical ? 8:nil,height:vertical ? nil:8).contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance:1,coordinateSpace:.named("mixerLayout")).onChanged { gesture in
            if origin==nil {origin=value}
            let delta=vertical ? gesture.translation.width : -gesture.translation.height
            value=min(bounds.upperBound,max(bounds.lowerBound,origin!+delta))
        }.onEnded {_ in origin=nil})
        .onTapGesture(count:2){value=initial}
        .onHover { inside in
            hovering=inside
            if inside {(vertical ? NSCursor.resizeLeftRight:NSCursor.resizeUpDown).push()} else {NSCursor.pop()}
        }
        .accessibilityElement().accessibilityLabel(label).accessibilityValue("\(Int(value)) points")
        .accessibilityAdjustableAction {direction in value=min(bounds.upperBound,max(bounds.lowerBound,value+(direction == .increment ? 10:-10)))}
        .help("Drag to resize \(label.lowercased()); double-click to reset")
    }
}
