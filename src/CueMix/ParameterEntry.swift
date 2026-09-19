import SwiftUI

struct ParameterEntry:View {
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused:Bool
    var title:String
    var current:Double
    var range:ClosedRange<Double>
    var step:Double
    var unit:String
    var apply:(Double)->Void
    @State private var text=""
    var parsed:Double? {parsedParameterValue(text,range:range,step:step)}
    var body:some View {
        VStack(alignment:.leading,spacing:14) {
            Text(title).font(.system(size:15,weight:.semibold))
            HStack {
                TextField(title,text:$text).labelsHidden().textFieldStyle(.roundedBorder).focused($focused).onSubmit(commit)
                    .font(.system(size:16,design:.monospaced))
                if !unit.isEmpty {Text(unit).font(.system(size:12)).foregroundStyle(.secondary)}
            }
            Text("\(range.lowerBound.formatted(.number.precision(.fractionLength(0...2)))) to \(range.upperBound.formatted(.number.precision(.fractionLength(0...2))))\(unit.isEmpty ? "":" \(unit)")")
                .font(.caption).foregroundStyle(parsed == nil ? Color.orange:Color.quiet)
            HStack {Button("Cancel"){dismiss()}.keyboardShortcut(.cancelAction);Spacer();Button("Apply",action:commit).keyboardShortcut(.defaultAction).disabled(parsed == nil)}
                .buttonStyle(ConsoleButtonStyle())
        }.padding(18).frame(width:260).background(Color.rail).foregroundStyle(Color.ink)
        .onAppear {text=current.formatted(.number.grouping(.never).precision(.fractionLength(0...2)));focused=true}
    }
    func commit() {guard let value=parsed else{return};apply(value);dismiss()}
}
