import SwiftUI

private func instrumentText(_ context: inout GraphicsContext, _ text: String, _ point: CGPoint,
                            color: Color = .quiet, anchor: UnitPoint = .center) {
    context.draw(Text(text).font(.system(size: 10, design: .monospaced)).foregroundColor(color), at: point, anchor: anchor)
}

struct OscilloscopeDisplay: View {
    let frame: AnalysisScopeFrame?
    var body: some View {
        Canvas { context, size in
            let rect = CGRect(x: 42, y: 30, width: max(1, size.width - 62), height: max(1, size.height - 60))
            let settings = frame?.settings ?? AnalysisScopeSettings()
            let laneHeight = rect.height / 2
            func y(_ sample: Double, _ channel: Int) -> Double {
                rect.minY + laneHeight * (Double(channel) + 0.5) - min(1, max(-1, sample * settings.gain)) * laneHeight * 0.42
            }
            for tick in 0...10 {
                let x = rect.minX + Double(tick) / 10 * rect.width
                var line = Path(); line.move(to: CGPoint(x: x, y: rect.minY)); line.addLine(to: CGPoint(x: x, y: rect.maxY))
                context.stroke(line, with: .color(.white.opacity(tick % 5 == 0 ? 0.1 : 0.05)), lineWidth: 1)
            }
            for ch in 0..<2 {
                for level in [-1.0, 0, 1] {
                    let vertical = y(level / settings.gain, ch)
                    var line = Path(); line.move(to: CGPoint(x: rect.minX, y: vertical)); line.addLine(to: CGPoint(x: rect.maxX, y: vertical))
                    context.stroke(line, with: .color(.white.opacity(level == 0 ? 0.22 : 0.07)), lineWidth: 1)
                    instrumentText(&context, String(format: "%g", level / settings.gain), CGPoint(x: rect.minX - 9, y: vertical), anchor: .trailing)
                }
                instrumentText(&context, ch == 0 ? "L" : "R", CGPoint(x: rect.minX - 27, y: y(0, ch)), color: ch == 0 ? .ice : .mint)
            }
            let origin = frame?.triggered == true ? frame!.triggerFraction : 0
            for tick in 0...4 {
                let fraction = Double(tick) / 4
                instrumentText(&context, String(format: settings.windowMS < 10 ? "%.2f" : "%.1f", (fraction - origin) * settings.windowMS),
                               CGPoint(x: rect.minX + fraction * rect.width, y: rect.maxY + 15))
            }
            instrumentText(&context, "ms", CGPoint(x: rect.maxX + 18, y: rect.maxY + 15))
            guard let frame, !frame.columns.isEmpty else {
                instrumentText(&context, "Start analysis to see the waveform", CGPoint(x: rect.midX, y: rect.midY)); return
            }
            let mode = settings.trigger == .free ? "FREE RUN" : frame.triggered ? "TRIGGER \(settings.trigger == .left ? "L" : "R") \(settings.rising ? "↑" : "↓")" : "AUTO · NO CROSSING"
            instrumentText(&context, mode, CGPoint(x: rect.minX, y: 10), color: frame.triggered ? .mint : .quiet, anchor: .leading)
            instrumentText(&context, String(format: "%g ms total · %g ms/div", settings.windowMS, settings.windowMS / 10), CGPoint(x: rect.maxX, y: 10), anchor: .trailing)
            if frame.triggered {
                let x = rect.minX + frame.triggerFraction * rect.width
                var line = Path(); line.move(to: CGPoint(x: x, y: rect.minY)); line.addLine(to: CGPoint(x: x, y: rect.maxY))
                context.stroke(line, with: .color(.orange.opacity(0.55)), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
            }
            for ch in 0..<2 {
                var path = Path(), envelope = Path()
                for (index, column) in frame.columns.enumerated() {
                    let x = rect.minX + Double(index) / Double(frame.columns.count) * rect.width
                    let point = CGPoint(x: x, y: y(ch == 0 ? column.left : column.right, ch))
                    if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                    envelope.move(to: CGPoint(x: x, y: y(ch == 0 ? column.minL : column.minR, ch)))
                    envelope.addLine(to: CGPoint(x: x, y: y(ch == 0 ? column.maxL : column.maxR, ch)))
                }
                let color = ch == 0 ? Color.ice : Color.mint
                context.stroke(envelope, with: .color(color.opacity(0.45)), lineWidth: 1)
                context.stroke(path, with: .color(color.opacity(0.85)), lineWidth: 1.1)
            }
        }.accessibilityLabel("Stereo oscilloscope. Horizontal time in milliseconds; separate left and right amplitude traces.")
            .accessibilityValue(frame.map { "\(Int($0.settings.windowMS)) milliseconds across the display, \($0.triggered ? "triggered" : "free running")" } ?? "No audio")
    }
}

struct MeteringDisplay: View {
    let reading: AnalysisMeterResult?
    private func number(_ value: Double?) -> String {
        guard let value else { return "—" }
        return value <= -119 || !value.isFinite ? "−∞" : String(format: "%.1f", value)
    }
    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 14) {
                HStack(spacing: 10) {
                    loudness("MOMENTARY", "400 ms", reading?.momentaryReady == 1 ? reading?.momentary : nil, .ice, geometry.size.width)
                    loudness("SHORT-TERM", "3 seconds", reading?.shortTermReady == 1 ? reading?.shortTerm : nil, .mint, geometry.size.width)
                    loudness("INTEGRATED", "Gated · since reset", reading?.momentaryReady == 1 ? reading?.integrated : nil, .ink, geometry.size.width)
                }
                Spacer(minLength: 0)
                channel("L", peak: reading?.peakLeft, rms: reading?.momentaryReady == 1 ? reading?.rmsLeft : nil,
                        maximum: reading?.maxLeft, clipped: reading?.clippedLeft == 1, color: .ice)
                channel("R", peak: reading?.peakRight, rms: reading?.momentaryReady == 1 ? reading?.rmsRight : nil,
                        maximum: reading?.maxRight, clipped: reading?.clippedRight == 1, color: .mint)
                HStack {
                    Text("RMS fill · sample peak marker"); Spacer(); Text("dBFS")
                }.font(.system(size: 9)).foregroundStyle(Color.quiet)
                Spacer(minLength: 0)
            }.padding(.horizontal, 8).padding(.top, 2)
        }
    }
    private func loudness(_ label: String, _ detail: String, _ value: Double?, _ color: Color, _ width: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 9, weight: .semibold, design: .monospaced)).tracking(0.5).foregroundStyle(Color.quiet)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(number(value)).font(.system(size: min(34, max(23, width / 21)), weight: .medium, design: .monospaced)).foregroundStyle(color)
                Text("LUFS").font(.system(size: 9)).foregroundStyle(Color.quiet)
            }.lineLimit(1).minimumScaleFactor(0.7)
            Text(detail).font(.system(size: 10)).foregroundStyle(Color.quiet)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.07))
                    Capsule().fill(color.opacity(0.75)).frame(width: g.size.width * min(1, max(0, ((value ?? -60) + 60) / 60)))
                }
            }.frame(height: 3).padding(.top, 3)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
            .background(Color.rail.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
            .accessibilityElement(children: .combine)
    }
    private func channel(_ label: String, peak: Double?, rms: Double?, maximum: Double?, clipped: Bool, color: Color) -> some View {
        VStack(spacing: 7) {
            HStack(spacing: 12) {
                Text(label).font(.system(size: 13, weight: .bold, design: .monospaced)).foregroundStyle(color).frame(width: 12)
                metric("PEAK", number(peak)); metric("RMS", number(rms)); metric("MAX", number(maximum))
                Spacer(minLength: 0)
                Text(clipped ? "0 dBFS" : "").font(.system(size: 9, weight: .bold)).foregroundStyle(Color.orange).frame(width: 42)
            }
            GeometryReader { g in
                let position: (Double) -> Double = { db in g.size.width * min(1, max(0, (db + 60) / 60)) }
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.06))
                    RoundedRectangle(cornerRadius: 3).fill(color.opacity(0.65)).frame(width: position(rms ?? -60))
                    ForEach([-48.0, -36, -24, -12, -6], id: \.self) { db in
                        Rectangle().fill(Color.black.opacity(0.4)).frame(width: 1).offset(x: position(db))
                    }
                    if let peak, peak > -60 { Rectangle().fill(peak >= 0 ? Color.orange : color).frame(width: 2).offset(x: max(0, position(peak) - 2)) }
                }
            }.frame(height: 10)
            HStack { ForEach([-60, -48, -36, -24, -12, 0], id: \.self) { db in Text("\(db)"); if db != 0 { Spacer() } } }
                .font(.system(size: 8, design: .monospaced)).foregroundStyle(Color.quiet)
        }.accessibilityElement(children: .combine)
    }
    private func metric(_ title: String, _ value: String) -> some View {
        HStack(spacing: 5) {
            Text(title).font(.system(size: 9)).foregroundStyle(Color.quiet)
            Text(value).font(.system(size: 13, weight: .medium, design: .monospaced)).foregroundStyle(Color.ink)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
