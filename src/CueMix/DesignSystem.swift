import SwiftUI

struct ConsoleButtonStyle:ButtonStyle {
    var accent:Color = .ice
    var prominent=false
    func makeBody(configuration:Configuration)->some View {
        ConsoleButtonBody(configuration:configuration,accent:accent,prominent:prominent)
    }
    private struct ConsoleButtonBody:View {
        @Environment(\.isEnabled) private var enabled
        @State private var hovering=false
        let configuration:ButtonStyleConfiguration
        let accent:Color
        let prominent:Bool
        var body:some View {
            configuration.label.font(.system(size:12,weight:.medium))
                .foregroundStyle(prominent ? accent:Color.ink)
                .padding(.horizontal,12).frame(minHeight:34)
                .background(RoundedRectangle(cornerRadius:7).fill(configuration.isPressed ? accent.opacity(0.2):hovering ? Color.white.opacity(0.09):prominent ? accent.opacity(0.08):Color.white.opacity(0.035)))
                .overlay(RoundedRectangle(cornerRadius:7).stroke(hovering ? accent.opacity(0.4):Color.edge))
                .contentShape(RoundedRectangle(cornerRadius:7)).opacity(enabled ? 1:0.4)
                .onHover{hovering=$0}
        }
    }
}
struct NavigationRow:View {
    var title:String
    var symbol:String?=nil
    var number:Int?=nil
    var selected:Bool
    var color:Color = .ice
    var action:()->Void
    @State private var hovering=false
    var body:some View {
        Button(action:action) {
            HStack(spacing:11) {
                if let symbol {Image(systemName:symbol).font(.system(size:14,weight:.medium)).frame(width:22)}
                else if let number {Text(String(format:"%02d",number)).font(.system(size:11,weight:.semibold,design:.monospaced)).foregroundStyle(selected ? color:Color.quiet).frame(width:22)}
                Text(title).font(.system(size:13,weight:selected ? .semibold:.medium)).lineLimit(1)
                Spacer(minLength:0)
                if selected {RoundedRectangle(cornerRadius:1).fill(color).frame(width:3,height:16)}
                else if number != nil {Circle().fill(color.opacity(0.7)).frame(width:4,height:4)}
            }.foregroundStyle(selected ? Color.ink:Color.quiet).padding(.horizontal,12).frame(height:38)
                .background(RoundedRectangle(cornerRadius:7).fill(selected ? color.opacity(0.1):hovering ? Color.white.opacity(0.045):.clear))
                .overlay(RoundedRectangle(cornerRadius:7).stroke(selected ? color.opacity(0.15):.clear))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).onHover{hovering=$0}.help(title)
        .accessibilityAddTraits(selected ? .isSelected:[])
    }
}
enum ChannelGroup:String,CaseIterable,Identifiable {
    case all="All",analog="Analog",spdif="S/PDIF",adatA="ADAT A",adatB="ADAT B"
    var id:String{rawValue}
    func channels(section:Int)->[Int] {
        if section==1 {
            switch self {case .all:return Array(0..<28);case .analog:return Array(0..<10);case .spdif:return [10,11];case .adatA:return Array(12..<20);case .adatB:return Array(20..<28)}
        }
        switch self {case .all:return Array(0..<15);case .analog:return [0,1,2,3,4,6];case .spdif:return [5];case .adatA:return Array(7..<11);case .adatB:return Array(11..<15)}
    }
}
struct ChannelFilter:View {
    @Binding var selection:ChannelGroup
    var body:some View {
        HStack(spacing:4) {
            ForEach(ChannelGroup.allCases){group in
                Button {selection=group} label:{Text(group.rawValue).font(.system(size:12,weight:.medium)).padding(.horizontal,13).frame(height:30)
                    .foregroundStyle(selection==group ? Color.ink:Color.quiet)
                    .background(RoundedRectangle(cornerRadius:6).fill(selection==group ? Color.white.opacity(0.1):.clear)).contentShape(Rectangle())}
                    .buttonStyle(.plain).accessibilityLabel("Show \(group.rawValue.lowercased()) channels").accessibilityAddTraits(selection==group ? .isSelected:[])
            }
        }.padding(4).background(Color.rail,in:RoundedRectangle(cornerRadius:9))
    }
}
struct MeterWell:View {
    var index:Int
    var stereo=false
    var color:Color = .ice
    var body:some View {
        GeometryReader {g in
            HStack(spacing:10) {
                ZStack(alignment:.topTrailing) {
                    ForEach([0,-12,-24,-48,-72],id:\.self) {value in
                        Text(value == -72 ? "−∞":"\(value)").font(.system(size:9,design:.monospaced)).foregroundStyle(Color.quiet)
                            .position(x:12,y:7+(g.size.height-14)*CGFloat(-value)/72)
                    }
                }.frame(width:24)
                HStack(spacing:4) {LiveMeter(index:index,color:color,width:11);if stereo {LiveMeter(index:index+1,color:color,width:11)}}
                    .padding(.vertical,7)
            }.frame(maxWidth:.infinity)
        }.frame(minHeight:110)
    }
}
struct SectionHeading:View {
    var title:String
    var detail:String
    var body:some View {
        HStack(alignment:.firstTextBaseline) {Text(title).font(.system(size:17,weight:.semibold));Spacer();Text(detail).font(.system(size:11)).foregroundStyle(Color.quiet)}
    }
}
