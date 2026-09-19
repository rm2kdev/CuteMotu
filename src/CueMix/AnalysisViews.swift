import SwiftUI

private enum AnalysisTool: String, CaseIterable {
    case tuner = "Tuner", fft = "FFT", xy = "X–Y Plot", phase = "Phase", scope = "Scope", meters = "Meters"
    var usesTiming: Bool { self == .fft || self == .xy || self == .phase }
    var title: String {
        switch self {
        case .tuner: return "Chromatic tuner"
        case .fft: return "Frequency spectrum"
        case .xy: return "Stereo field"
        case .phase: return "Phase relationship"
        case .scope: return "Oscilloscope"
        case .meters: return "Level & loudness"
        }
    }
    var icon: String {
        switch self { case .tuner: return "tuningfork"; case .fft: return "waveform.path"; case .xy: return "point.3.connected.trianglepath.dotted"; case .phase: return "circle.lefthalf.filled"; case .scope: return "waveform.path.ecg"; case .meters: return "chart.bar.fill" }
    }
    var detail: String {
        switch self {
        case .tuner: return "Find the fundamental. Tune with confidence."
        case .fft: return "See the balance of energy across the spectrum."
        case .xy: return "Read the shape and relationship of two channels."
        case .phase: return "Compare phase at each frequency."
        case .scope: return "Follow the waveform through time."
        case .meters: return "Sample peaks, RMS and stereo programme loudness."
        }
    }
}

struct AnalysisPage: View {
    @EnvironmentObject private var mixer: MixerModel
    @StateObject private var analysis = AnalysisModel()
    @State private var tool = AnalysisTool.fft
    var body: some View {
        GeometryReader { geometry in
        ScrollView(.vertical) {
        VStack(spacing: 16) {
            HStack(spacing: 6) {
                ForEach(AnalysisTool.allCases, id: \.self) { item in
                    Button { tool = item } label: {
                        Label(item.rawValue, systemImage: item.icon)
                            .font(.system(size: 11, weight: .semibold)).padding(.horizontal, 10).frame(height: 38)
                            .foregroundStyle(tool == item ? Color.ink : Color.quiet)
                            .background(tool == item ? Color.strip : .clear, in: RoundedRectangle(cornerRadius: 7))
                            .overlay(alignment: .bottom) { if tool == item { Capsule().fill(Color.ice).frame(height: 2).padding(.horizontal, 16) } }
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityAddTraits(tool == item ? .isSelected : [])
                }
                Spacer(minLength: 4)
                if analysis.running {
                    Button { analysis.togglePause() } label: { Label(analysis.paused ? "Resume" : "Freeze", systemImage: analysis.paused ? "play.fill" : "pause.fill") }
                        .buttonStyle(ConsoleButtonStyle()).disabled(analysis.frame == nil && !analysis.paused)
                }
                Button { if analysis.running { analysis.stop() } else { analysis.start() } } label: {
                    Label(analysis.running ? "Stop" : "Start analysis", systemImage: analysis.running ? "stop.fill" : "play.fill")
                }.buttonStyle(ConsoleButtonStyle(accent: .ice)).disabled(analysis.isPreview)
            }
            sourceBar
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(tool.title)
                                .font(.system(size: 18, weight: .semibold))
                            Text(tool.detail).font(.system(size: 11)).foregroundStyle(Color.quiet)
                        }
                        Spacer()
                        HStack(spacing: 6) {
                            Circle().fill(analysis.paused ? Color.orange : analysis.frame != nil ? Color.mint : Color.quiet).frame(width: 5, height: 5)
                            Text(analysis.isPreview ? "TEST SIGNAL" : analysis.paused ? "FROZEN" : analysis.frame != nil ? "LIVE" : tool == .meters && analysis.completedMeter != nil ? "STOPPED" : "STANDBY").font(.system(size: 9, weight: .semibold, design: .monospaced)).tracking(1)
                        }.foregroundStyle(Color.quiet).padding(.top, 4)
                    }.padding(20)
                    Group {
                        switch tool {
                        case .tuner: TunerDisplay(frame: analysis.frame, reference: analysis.reference)
                        case .fft: SpectrumDisplay(frame: analysis.frame, peakHold: analysis.peakHold && analysis.timing.holdMS > 0)
                        case .xy: XYDisplay(frame: analysis.frame, gain: analysis.xyGain)
                        case .phase: PhaseDisplay(frame: analysis.frame, polar: analysis.phasePolar, floor: analysis.phaseFloor)
                        case .scope: OscilloscopeDisplay(frame: analysis.frame?.scope)
                        case .meters: MeteringDisplay(reading: analysis.meterReading)
                        }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(.horizontal, 12).padding(.bottom, 12)
                    if tool.usesTiming {
                        HStack(spacing: 14) {
                            if tool == .xy { Text("TIME BASE  \(Int(analysis.timing.xyWindowMS)) ms") }
                            Text(analysis.timing.averageMS == 0 ? "AVERAGE  OFF" : "AVERAGE  \(Int(analysis.timing.averageMS)) ms")
                            Text(analysis.timing.holdMS == 0 ? "HOLD  OFF" : "HOLD  \(Int(analysis.timing.holdMS)) ms")
                            Spacer(minLength: 0)
                        }.font(.system(size: 9, weight: .medium, design: .monospaced)).foregroundStyle(Color.quiet)
                            .padding(.horizontal, 20).padding(.bottom, 14)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.black.opacity(0.17), in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.edge))
                ScrollView(.vertical) { inspector }.frame(width: 190)
            }.frame(height: max(tool == .meters ? 380 : 330, geometry.size.height - 268))
            HStack(spacing: 16) {
                AnalysisLevel(label: "L", db: analysis.frame?.meter.momentaryReady == 1 ? analysis.frame?.meter.rmsLeft : nil, peak: analysis.frame?.meter.peakLeft, color: .ice)
                AnalysisLevel(label: "R", db: analysis.frame?.meter.momentaryReady == 1 ? analysis.frame?.meter.rmsRight : nil, peak: analysis.frame?.meter.peakRight, color: .mint)
                Divider().frame(height: 34)
                CorrelationDisplay(frame: analysis.frame).frame(width: 240)
            }.padding(16).background(Color.rail, in: RoundedRectangle(cornerRadius: 10))
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: analysis.usesReturn ? "arrow.uturn.down" : "info.circle").foregroundStyle(Color.ice)
                Text(analysis.usesReturn ? "Stereo Return follows “Return to computer” in Overview → Talkback & routing. Choose Main L/R there to inspect that output." : "Analysis reads your selected inputs. For the tuner, play one sustained note on a single channel.")
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }.font(.system(size: 11)).foregroundStyle(Color.quiet)
        }.padding(.horizontal, 24).padding(.bottom, 20)
        }
        }
        .onAppear { analysis.updateAvailableRate(Double(mixer.sampleRate)) }
        .onChange(of: mixer.sampleRate) { analysis.updateAvailableRate(Double($0)) }
        .onDisappear { analysis.stop() }
    }
    private var sourceBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform.badge.mic").font(.system(size: 18)).foregroundStyle(Color.ice).frame(width: 28)
            sourcePicker("L", selected: analysis.leftID) { analysis.select(left: $0, right: analysis.rightID) }
            sourcePicker("R", selected: analysis.rightID) { analysis.select(left: analysis.leftID, right: $0) }
            Menu {
                Button("Stereo Return") { analysis.select(left: "return.0", right: "return.1") }
                Button("Mic 1 + 2") { analysis.select(left: "mic.0", right: "mic.1") }
                ForEach(0..<4, id: \.self) { pair in
                    Button("Analog \(pair * 2 + 1) + \(pair * 2 + 2)") { analysis.select(left: "analog.\(pair * 2)", right: "analog.\(pair * 2 + 1)") }
                }
            } label: { Image(systemName: "link").frame(width: 24) }.menuStyle(.borderlessButton).fixedSize().help("Choose an input pair")
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 4) {
                Text("CUTE MOTU 828x").font(.system(size: 9, weight: .semibold, design: .monospaced)).tracking(1)
                Text(String(format: "%g kHz", analysis.rate / 1000)).font(.system(size: 11, design: .monospaced)).foregroundStyle(Color.quiet)
            }
        }.padding(14).background(Color.rail, in: RoundedRectangle(cornerRadius: 10))
    }
    private func sourcePicker(_ label: String, selected: String, set: @escaping (String) -> Void) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(label == "L" ? Color.ice : Color.mint)
            Picker("\(label) analysis source", selection: Binding(get: { selected }, set: set)) {
                ForEach(analysis.channels) { ch in Text(ch.name).tag(ch.id) }
                if !analysis.channels.contains(where: { $0.id == selected }) { Text("Unavailable input").tag(selected) }
            }.labelsHidden().frame(maxWidth: 210)
        }
    }
    private var inspector: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Caption(text: "Session")
                Text(analysis.paused && analysis.frame != nil ? "Display frozen" : analysis.status)
                    .font(.system(size: 12, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                if !analysis.running { Text("Audio stays on this Mac. Nothing is recorded or saved.").font(.system(size: 11)).foregroundStyle(Color.quiet) }
            }
            Divider().overlay(Color.edge)
            if tool.usesTiming {
                VStack(alignment: .leading, spacing: 12) {
                    Caption(text: "Timing")
                    if tool == .xy {
                        AnalysisMilliseconds(label: "Time base", value: $analysis.timing.xyWindowMS, range: 5...200, presets: [5, 10, 20, 50, 100, 200])
                    }
                    AnalysisMilliseconds(label: "Average", value: $analysis.timing.averageMS, range: 0...2000, presets: [0, 50, 100, 250, 500, 1000, 2000])
                    AnalysisMilliseconds(label: "Hold", value: $analysis.timing.holdMS, range: 0...2000, presets: [0, 50, 100, 250, 500, 1000, 2000])
                    Text(tool == .xy ? "Time base sets each trace’s audio span. Average builds a density map; Hold leaves a fading trail." : tool == .fft ? "Average steadies energy over time. Hold keeps recent peaks as a dashed trace." : "Average steadies phase over time. Hold leaves a fading trail of earlier readings.")
                        .font(.system(size: 11)).foregroundStyle(Color.quiet).fixedSize(horizontal: false, vertical: true)
                    Text("0 ms turns Average or Hold off. Display updates every 50 ms.")
                        .font(.system(size: 10)).foregroundStyle(Color.quiet).fixedSize(horizontal: false, vertical: true)
                    Button("Clear history") { analysis.clearHistory() }.buttonStyle(ConsoleButtonStyle()).disabled(analysis.frame == nil)
                }
                Divider().overlay(Color.edge)
            }
            switch tool {
            case .tuner:
                VStack(alignment: .leading, spacing: 12) {
                    Caption(text: "Tune channel")
                    Picker("Tuner channel", selection: $analysis.tunerRight) { Text("L").tag(false); Text("R").tag(true) }.pickerStyle(.segmented).labelsHidden()
                    Caption(text: "Reference A4").padding(.top, 8)
                    HStack {
                        Text(String(format: "%.0f Hz", analysis.reference)).font(.system(size: 20, weight: .medium, design: .monospaced))
                        Spacer()
                        Stepper("Reference pitch", value: $analysis.reference, in: 430...450, step: 1).labelsHidden()
                    }
                    Button("Reset to 440 Hz") { analysis.reference = 440 }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Color.ice)
                }
                note("One note at a time", "Use a clean, sustained note. The tuner covers 40 Hz–1.5 kHz and hides uncertain readings.")
            case .fft:
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Peak trace", isOn: $analysis.peakHold).toggleStyle(.switch).controlSize(.small).disabled(analysis.timing.holdMS == 0)
                    Button("Reset peaks") { analysis.resetPeak() }.buttonStyle(ConsoleButtonStyle()).disabled(analysis.frame == nil)
                }
                VStack(alignment: .leading, spacing: 10) { legend("Left channel", .ice); legend("Right channel", .mint); if analysis.peakHold && analysis.timing.holdMS > 0 { legend("Recent peaks", .white.opacity(0.4)) } }
                note("8,192-point FFT", "Hann window · logarithmic frequency. Averaging uses signal power. FFT resolution stays fixed.")
            case .xy:
                VStack(alignment: .leading, spacing: 12) {
                    Caption(text: "Display gain")
                    Picker("X–Y display gain", selection: $analysis.xyGain) { ForEach([1.0, 2, 4, 8], id: \.self) { Text(String(format: "×%.0f", $0)).tag($0) } }.pickerStyle(.segmented).labelsHidden()
                    Text("Magnifies the trace only.").font(.system(size: 11)).foregroundStyle(Color.quiet)
                }
                note("Read the shape", "A rising diagonal means the channels match. A falling diagonal means opposite polarity. A wider cloud means more stereo difference.")
                note("Axes", "Horizontal: left input\nVertical: right input\nEdges: ±1 full scale")
            case .phase:
                VStack(alignment: .leading, spacing: 12) {
                    Caption(text: "Projection")
                    Picker("Phase projection", selection: $analysis.phasePolar) { Text("Rectangular").tag(false); Text("Polar").tag(true) }.labelsHidden()
                    HStack { Caption(text: "Signal floor"); Spacer(); Text(String(format: "%.0f dB", analysis.phaseFloor)).font(.system(size: 11, design: .monospaced)) }
                    Slider(value: $analysis.phaseFloor, in: -90 ... -24, step: 3).accessibilityLabel("Phase signal floor")
                    LinearGradient(colors: [.ice, .mint, .orange], startPoint: .leading, endPoint: .trailing).frame(height: 4).clipShape(Capsule())
                    HStack { Text("Quiet"); Spacer(); Text("Loud") }.font(.system(size: 9)).foregroundStyle(Color.quiet)
                }
                note("Left minus right", analysis.phasePolar ? "Aligned signals point up. Opposite polarity points down. Radius shows frequency on a logarithmic scale." : "Aligned signals sit at 0°. Opposite polarity sits at ±180°. Height shows frequency on a logarithmic scale.")
                note("Two active channels", "Bins are shown only when both channels exceed the signal floor.")
            case .scope:
                VStack(alignment: .leading, spacing: 12) {
                    Caption(text: "Time base")
                    AnalysisMilliseconds(label: "Full width", value: $analysis.scope.windowMS, range: 1...200, presets: [1, 2, 5, 10, 20, 50, 100, 200])
                    Caption(text: "Trigger").padding(.top, 4)
                    Picker("Scope trigger", selection: $analysis.scope.trigger) {
                        ForEach(AnalysisTrigger.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.labelsHidden()
                    if analysis.scope.trigger != .free {
                        Picker("Trigger edge", selection: $analysis.scope.rising) { Text("Rising").tag(true); Text("Falling").tag(false) }.pickerStyle(.segmented).labelsHidden()
                        HStack { Text("Level"); Spacer(); Text(String(format: "%+.2f", analysis.scope.level)).monospacedDigit() }.font(.system(size: 11)).foregroundStyle(Color.quiet)
                        Slider(value: $analysis.scope.level, in: -1...1, step: 0.01).accessibilityLabel("Scope trigger level")
                    }
                    Caption(text: "Display gain")
                    Picker("Scope display gain", selection: $analysis.scope.gain) { ForEach([1.0, 2, 4, 8], id: \.self) { Text(String(format: "×%.0f", $0)).tag($0) } }.pickerStyle(.segmented).labelsHidden()
                }
                note("Steady the waveform", "Trigger aligns the selected channel at the chosen level. Without a crossing, Auto shows the latest audio. Freeze keeps a still frame.")
                note("Read the axes", "Time runs horizontally. Each channel has its own amplitude lane. Display gain magnifies the trace only.")
            case .meters:
                VStack(alignment: .leading, spacing: 12) {
                    Caption(text: "Measurement")
                    Text(analysis.meterReading.map { String(format: "%02d:%02d", Int($0.seconds) / 60, Int($0.seconds) % 60) } ?? "00:00")
                        .font(.system(size: 26, weight: .medium, design: .monospaced))
                    Text("Captured audio since reset").font(.system(size: 10)).foregroundStyle(Color.quiet)
                    Button("Reset measurement") { analysis.resetMeasurement() }.buttonStyle(ConsoleButtonStyle())
                        .disabled(!analysis.running && analysis.meterReading == nil)
                    if analysis.meterReading?.integratedFull == 1 {
                        Text("Integrated measurement reached 24 hours. Reset to begin a new measurement.").font(.system(size: 11)).foregroundStyle(Color.orange)
                    }
                }
                note("Loudness · LUFS", "Momentary: 400 ms\nShort-term: 3 seconds\nIntegrated: gated since reset\n\nK-weighted, selected L/R pair treated as stereo.")
                note("Level · dBFS", "Peak reads the latest audio block. RMS uses 400 ms. Max and the 0 dBFS indicator stay until reset. Peaks measure samples, not inter-sample true peak.")
                note("Measurement controls", "Stop retains the final meter readings. Start begins a new measurement. Freeze pauses the display while measurement continues.")
                note("Independent timing", "Chart averaging, hold and scope settings do not change loudness measurement. Changing source or losing audio resets it.")
            }
            Spacer(minLength: 0)
        }.padding(.top, 6)
    }
    private func note(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 11, weight: .semibold))
            Text(text).font(.system(size: 11)).foregroundStyle(Color.quiet).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
        }
    }
    private func legend(_ text: String, _ color: Color) -> some View {
        HStack(spacing: 8) { Capsule().fill(color).frame(width: 16, height: 2); Text(text).font(.system(size: 11)).foregroundStyle(Color.quiet) }
    }
}

private struct AnalysisMilliseconds: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let presets: [Double]
    @State private var draft = ""
    @FocusState private var editing: Bool
    private func commit() {
        if let number = Double(draft), number.isFinite { value = min(range.upperBound, max(range.lowerBound, number.rounded())) }
        draft = String(format: "%.0f", value)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 11, weight: .medium))
            HStack(spacing: 5) {
                TextField(label + " milliseconds", text: $draft)
                    .textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced))
                    .multilineTextAlignment(.trailing).frame(width: 62).focused($editing).onSubmit { commit() }
                    .onChange(of: editing) { if !$0 { commit() } }
                Text("ms").font(.system(size: 10)).foregroundStyle(Color.quiet).fixedSize()
                Spacer(minLength: 0)
                Menu {
                    ForEach(presets, id: \.self) { preset in
                        Button(preset == 0 ? "Off" : "\(Int(preset)) ms") { value = preset; draft = String(format: "%.0f", value) }
                    }
                } label: { Text("Presets").font(.system(size: 10)) }
                    .menuStyle(.borderlessButton).fixedSize().accessibilityLabel(label + " presets")
            }
        }.onAppear { draft = String(format: "%.0f", value) }
            .onChange(of: value) { draft = String(format: "%.0f", $0) }
            .help("\(Int(range.lowerBound))–\(Int(range.upperBound)) ms. Type a value and press Return.")
    }
}

private struct AnalysisLevel: View {
    let label: String, db: Double?, peak: Double?, color: Color
    var body: some View {
        VStack(spacing: 8) {
            HStack { Text("\(label)  INPUT").tracking(1); Spacer(); Text(db.map { $0 > -119 ? String(format: "%.1f dBFS", $0) : "−∞ dBFS" } ?? "—").monospacedDigit() }
                .font(.system(size: 10, weight: .medium)).foregroundStyle(Color.quiet)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.07))
                    Capsule().fill((peak ?? -120) >= -0.1 ? Color.orange : color).frame(width: max(0, g.size.width * min(1, max(0, ((db ?? -120) + 72) / 72))))
                }
            }.frame(height: 4)
        }.accessibilityElement(children: .combine)
    }
}
private struct CorrelationDisplay: View {
    let frame: AnalysisFrame?
    var value: Double? { guard let f = frame, f.levels.correlationValid != 0 else { return nil }; return f.levels.correlation }
    var body: some View {
        VStack(spacing: 6) {
            HStack { Text("CORRELATION").tracking(1); Spacer(); Text(value.map { String(format: "%+.2f", $0) } ?? "—").monospacedDigit() }.font(.system(size: 9, weight: .medium)).foregroundStyle(Color.quiet)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(LinearGradient(colors: [.orange.opacity(0.5), .quiet.opacity(0.2), .mint.opacity(0.5)], startPoint: .leading, endPoint: .trailing)).frame(height: 3)
                    Rectangle().fill(Color.quiet).frame(width: 1, height: 7).offset(x: g.size.width / 2)
                    if let v = value { Circle().fill(v < 0 ? Color.orange : Color.mint).frame(width: 7, height: 7).offset(x: max(0, min(g.size.width - 7, (v + 1) / 2 * g.size.width - 3.5))) }
                }
            }.frame(height: 7)
            HStack { Text("−1"); Spacer(); Text("0"); Spacer(); Text("+1") }.font(.system(size: 8, design: .monospaced)).foregroundStyle(Color.quiet)
        }.accessibilityElement(children: .ignore).accessibilityLabel("Stereo correlation").accessibilityValue(value.map { String(format: "%.2f", $0) } ?? "No signal")
    }
}

private struct TunerDisplay: View {
    let frame: AnalysisFrame?, reference: Double
    private var frequency: Double? { guard let f = frame, f.levels.frequency > 0, f.levels.confidence >= 0.85 else { return nil }; return f.levels.frequency }
    private var midi: Double { frequency.map { 69 + 12 * log2($0 / reference) } ?? 69 }
    private var cents: Double { (midi - midi.rounded()) * 100 }
    private var note: String { let names = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]; return names[(Int(midi.rounded()) % 12 + 12) % 12] }
    private var accent: Color { abs(cents) <= 3 ? .mint : .ice }
    var body: some View {
        GeometryReader { geometry in
        VStack(spacing: 8) {
            Spacer(minLength: 0)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(frequency == nil ? "—" : note).font(.custom("Avenir Next", size: min(96, max(52, geometry.size.height * 0.32))).weight(.medium)).foregroundStyle(frequency == nil ? Color.quiet.opacity(0.35) : accent)
                if frequency != nil { Text("\(Int(midi.rounded()) / 12 - 1)").font(.system(size: 32, weight: .light)).foregroundStyle(Color.quiet) }
            }.frame(height: min(108, geometry.size.height * 0.34))
            HStack(spacing: 16) {
                Text(frequency.map { String(format: "%.2f Hz", $0) } ?? "No stable note").foregroundStyle(Color.quiet)
                if frequency != nil { Rectangle().fill(Color.edge).frame(width: 1, height: 14); Text(String(format: "%+.1f cents", cents)).foregroundStyle(accent) }
            }.font(.system(size: 15, weight: .medium, design: .monospaced))
            Canvas { context, size in
                let mid = size.width / 2, y = 34.0, span = size.width - 32
                let band = CGRect(x: mid - span * 0.03, y: 5, width: span * 0.06, height: 48)
                context.fill(Path(roundedRect: band, cornerRadius: 5), with: .color(.mint.opacity(0.09)))
                for value in stride(from: -50, through: 50, by: 5) {
                    let x = 16 + (Double(value) + 50) / 100 * span
                    var p = Path(); p.move(to: CGPoint(x: x, y: y - (value % 25 == 0 ? 12 : 6))); p.addLine(to: CGPoint(x: x, y: y + 6))
                    context.stroke(p, with: .color(value == 0 ? .mint : .quiet.opacity(0.45)), lineWidth: 1)
                    if value % 25 == 0 { plotText(&context, value == 0 ? "0" : String(format: "%+d", value), x, 67) }
                }
                if frequency != nil {
                    let x = 16 + min(span, max(0, (cents + 50) / 100 * span))
                    var needle = Path(); needle.move(to: CGPoint(x: x, y: 6)); needle.addLine(to: CGPoint(x: x, y: 50))
                    context.stroke(needle, with: .color(accent), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    context.fill(Path(ellipseIn: CGRect(x: x - 4, y: 3, width: 8, height: 8)), with: .color(accent))
                }
            }.frame(height: 80).padding(.horizontal, 32).padding(.top, 4)
            Text(frequency == nil ? "Play a single, sustained note" : abs(cents) <= 3 ? "In tune" : cents < 0 ? "A little flat  ·  tune up" : "A little sharp  ·  tune down")
                .font(.system(size: 12, weight: .medium)).foregroundStyle(frequency == nil ? Color.quiet : accent)
            Spacer(minLength: 0)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.accessibilityElement(children: .combine)
    }
}

private let frequencyTicks: [Double] = [20, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000]
private func frequencyLabel(_ f: Double) -> String { f >= 1000 ? String(format: "%gk", f / 1000) : String(format: "%g", f) }
private func plotText(_ context: inout GraphicsContext, _ text: String, _ x: Double, _ y: Double, anchor: UnitPoint = .center, color: Color = .quiet) {
    context.draw(Text(text).font(.system(size: 10, design: .monospaced)).foregroundColor(color), at: CGPoint(x: x, y: y), anchor: anchor)
}
private func gridLine(_ context: inout GraphicsContext, _ a: CGPoint, _ b: CGPoint, strong: Bool = false) {
    var p = Path(); p.move(to: a); p.addLine(to: b)
    context.stroke(p, with: .color(.white.opacity(strong ? 0.22 : 0.065)), lineWidth: 1)
}

private struct SpectrumDisplay: View {
    let frame: AnalysisFrame?, peakHold: Bool
    @State private var cursor: CGPoint?
    var body: some View {
        Canvas { context, size in
            let rect = CGRect(x: 40, y: 12, width: max(1, size.width - 56), height: max(1, size.height - 44))
            func x(_ f: Double) -> Double { rect.minX + log10(f / 20) / 3 * rect.width }
            func y(_ db: Double) -> Double { rect.maxY - min(120, max(0, db + 120)) / 120 * rect.height }
            for db in stride(from: -120, through: 0, by: 20) {
                gridLine(&context, CGPoint(x: rect.minX, y: y(Double(db))), CGPoint(x: rect.maxX, y: y(Double(db))))
                plotText(&context, "\(db)", rect.minX - 10, y(Double(db)), anchor: .trailing)
            }
            for f in frequencyTicks { gridLine(&context, CGPoint(x: x(f), y: rect.minY), CGPoint(x: x(f), y: rect.maxY)); plotText(&context, frequencyLabel(f), x(f), rect.maxY + 15) }
            plotText(&context, "dBFS", rect.minX, rect.minY - 9, anchor: .leading)
            guard let frame else { plotText(&context, "Start analysis to see the spectrum", rect.midX, rect.midY); return }
            func curve(_ values: [Float]) -> Path {
                var path = Path()
                let steps = max(100, Int(rect.width))
                for i in 0...steps {
                    let f = 20 * pow(1000, Double(i) / Double(steps))
                    let next = 20 * pow(1000, Double(i + 1) / Double(steps))
                    let lo = max(1, Int(f * Double(AnalysisFFT) / frame.rate)), hi = min(values.count - 1, max(lo, Int(next * Double(AnalysisFFT) / frame.rate)))
                    var db = -120.0
                    if lo <= hi { for bin in lo...hi { db = max(db, Double(values[bin])) } }
                    let point = CGPoint(x: rect.minX + Double(i) / Double(steps) * rect.width, y: y(db))
                    if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
                return path
            }
            if peakHold { context.stroke(curve(frame.hold), with: .color(.white.opacity(0.25)), style: StrokeStyle(lineWidth: 1, dash: [3, 3])) }
            for (values, color) in [(frame.right, Color.mint), (frame.left, Color.ice)] {
                let path = curve(values)
                var fill = path; fill.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY)); fill.addLine(to: CGPoint(x: rect.minX, y: rect.maxY)); fill.closeSubpath()
                context.fill(fill, with: .linearGradient(Gradient(colors: [color.opacity(0.2), color.opacity(0.01)]), startPoint: rect.origin, endPoint: CGPoint(x: rect.minX, y: rect.maxY)))
                context.stroke(path, with: .color(color.opacity(0.9)), lineWidth: 1.4)
            }
            if !frame.hasSignal { plotText(&context, "No signal on the selected inputs", rect.midX, rect.midY) }
            if let cursor, rect.contains(cursor) {
                let frequency = 20 * pow(1000, (cursor.x - rect.minX) / rect.width)
                let bin = min(frame.left.count - 1, max(1, Int((frequency * Double(AnalysisFFT) / frame.rate).rounded())))
                var line = Path(); line.move(to: CGPoint(x: cursor.x, y: rect.minY)); line.addLine(to: CGPoint(x: cursor.x, y: rect.maxY))
                context.stroke(line, with: .color(.white.opacity(0.35)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                let label = String(format: "%.0f Hz   L %.1f   R %.1f dBFS", Double(bin) * frame.rate / Double(AnalysisFFT), frame.left[bin], frame.right[bin])
                context.fill(Path(roundedRect: CGRect(x: rect.minX + 6, y: rect.minY + 5, width: min(300, rect.width - 12), height: 25), cornerRadius: 4), with: .color(.black.opacity(0.8)))
                plotText(&context, label, rect.minX + 14, rect.minY + 18, anchor: .leading, color: .ink)
            }
        }.onContinuousHover { phase in
            switch phase { case .active(let location): cursor = location; case .ended: cursor = nil }
        }.accessibilityLabel("Frequency spectrum from 20 Hz to 20 kHz, −120 to 0 dBFS")
            .help("Move over the plot to read frequency and channel levels.")
    }
}

private struct XYDisplay: View {
    let frame: AnalysisFrame?, gain: Double
    var body: some View {
        Canvas { context, size in
            let side = max(1, min(size.width - 64, size.height - 36))
            let rect = CGRect(x: (size.width - side) / 2, y: (size.height - side) / 2 - 4, width: side, height: side)
            func point(_ l: Double, _ r: Double) -> CGPoint { CGPoint(x: rect.midX + l * side / 2, y: rect.midY - r * side / 2) }
            for v in [-1.0, -0.5, 0, 0.5, 1] {
                gridLine(&context, point(v, -1), point(v, 1), strong: v == 0)
                gridLine(&context, point(-1, v), point(1, v), strong: v == 0)
                plotText(&context, String(format: "%g", v), rect.minX - 10, point(0, v).y, anchor: .trailing)
                plotText(&context, String(format: "%g", v), point(v, 0).x, rect.maxY + 13)
            }
            var diagonals = Path(); diagonals.move(to: point(-1, -1)); diagonals.addLine(to: point(1, 1)); diagonals.move(to: point(-1, 1)); diagonals.addLine(to: point(1, -1))
            context.stroke(diagonals, with: .color(.white.opacity(0.14)), style: StrokeStyle(lineWidth: 1, dash: [4, 5]))
            plotText(&context, "R", rect.minX - 24, rect.minY, color: .mint); plotText(&context, "L", rect.maxX + 18, rect.maxY + 13, color: .ice)
            guard let frame else { plotText(&context, "Start analysis to see the stereo field", rect.midX, rect.midY + 24); return }
            func trace(_ points: [CGPoint]) -> Path {
                var path = Path()
                for (index, p) in points.enumerated() {
                    let position = point(max(-1, min(1, p.x * gain)), max(-1, min(1, p.y * gain)))
                    if index == 0 { path.move(to: position) } else { path.addLine(to: position) }
                }
                return path
            }
            for old in frame.trails where !old.xy.isEmpty {
                context.stroke(trace(old.xy), with: .color(.ice.opacity(0.13 * old.opacity)), lineWidth: 0.65)
            }
            // Group density cells by brightness to keep Canvas draw calls bounded.
            var density = [Path](repeating: Path(), count: 8)
            for cell in frame.xyDensity {
                let p = point(cell.x, cell.y), diameter = max(2, side / 128)
                let bucket = min(7, max(0, Int(cell.strength * 7)))
                density[bucket].addEllipse(in: CGRect(x: p.x - diameter/2, y: p.y - diameter/2, width: diameter, height: diameter))
            }
            for index in density.indices {
                context.fill(density[index], with: .color(.mint.opacity(0.15 + 0.75 * Double(index) / 7)))
            }
            if frame.hasSignal {
                let path = trace(frame.xy)
                context.stroke(path, with: .color(.ice.opacity(0.07)), lineWidth: 3)
                context.stroke(path, with: .color(.mint.opacity(frame.xyDensity.isEmpty ? 0.5 : 0.2)), lineWidth: 0.8)
            } else if frame.xyDensity.isEmpty && !frame.trails.contains(where: { !$0.xy.isEmpty }) {
                plotText(&context, "No signal on the selected inputs", rect.midX, rect.midY + 24)
            }
        }.accessibilityLabel("X–Y plot. Horizontal left input, vertical right input. Full scale plus or minus one.")
    }
}

private struct PhaseDisplay: View {
    let frame: AnalysisFrame?, polar: Bool, floor: Double
    var body: some View {
        Canvas { context, size in
            let rect = CGRect(x: 45, y: 20, width: max(1, size.width - 68), height: max(1, size.height - 48))
            let radius = min(rect.width, rect.height) / 2
            func normalized(_ frequency: Double) -> Double { max(0, min(1, log10(frequency / 20) / 3)) }
            func point(_ frequency: Double, _ angle: Double) -> CGPoint {
                if polar { return CGPoint(x: rect.midX + sin(angle) * radius * normalized(frequency), y: rect.midY - cos(angle) * radius * normalized(frequency)) }
                return CGPoint(x: rect.midX + angle / .pi * rect.width / 2, y: rect.maxY - normalized(frequency) * rect.height)
            }
            if polar {
                for f in [100.0, 1000, 10000, 20000] {
                    let r = radius * normalized(f)
                    context.stroke(Path(ellipseIn: CGRect(x: rect.midX - r, y: rect.midY - r, width: 2*r, height: 2*r)), with: .color(.white.opacity(0.09)), lineWidth: 1)
                    plotText(&context, frequencyLabel(f), rect.midX + 5, rect.midY - r + 9, anchor: .leading)
                }
                gridLine(&context, CGPoint(x: rect.midX - radius, y: rect.midY), CGPoint(x: rect.midX + radius, y: rect.midY), strong: true)
                gridLine(&context, CGPoint(x: rect.midX, y: rect.midY - radius), CGPoint(x: rect.midX, y: rect.midY + radius), strong: true)
                plotText(&context, "0°", rect.midX, rect.midY - radius - 12, color: .mint)
                plotText(&context, "±180°", rect.midX, rect.midY + radius + 12)
                plotText(&context, "−90°", rect.midX - radius - 7, rect.midY, anchor: .trailing)
                plotText(&context, "+90°", rect.midX + radius + 7, rect.midY, anchor: .leading)
            } else {
                for f in frequencyTicks { let y = point(f, 0).y; gridLine(&context, CGPoint(x: rect.minX, y: y), CGPoint(x: rect.maxX, y: y)); plotText(&context, frequencyLabel(f), rect.minX - 10, y, anchor: .trailing) }
                for degrees in [-180, -90, 0, 90, 180] {
                    let x = point(20, Double(degrees) / 180 * .pi).x
                    gridLine(&context, CGPoint(x: x, y: rect.minY), CGPoint(x: x, y: rect.maxY), strong: degrees == 0)
                    plotText(&context, "\(degrees)°", x, rect.maxY + 15, color: degrees == 0 ? .mint : .quiet)
                }
            }
            guard let frame else { plotText(&context, "Start analysis to compare phase", rect.midX, rect.midY + 24); return }
            var visible = 0
            for old in frame.trails {
                var paths = [Path](repeating: Path(), count: 3)
                for bin in old.phase where bin.level > floor {
                    let power = max(0, min(1, (bin.level - floor) / -floor))
                    let bucket = power < 0.45 ? 0 : power < 0.8 ? 1 : 2
                    let p = point(bin.frequency, bin.angle)
                    paths[bucket].addEllipse(in: CGRect(x: p.x - 1, y: p.y - 1, width: 2, height: 2))
                    visible += 1
                }
                for (index, color) in [Color.ice, .mint, .orange].enumerated() {
                    context.fill(paths[index], with: .color(color.opacity(0.25 * old.opacity)))
                }
            }
            for bin in 1..<frame.phase.count {
                let f = Double(bin) * frame.rate / Double(AnalysisFFT)
                guard f >= 20, f <= 20000 else { continue }
                let level = Double(frame.phaseLevel[bin])
                guard level > floor else { continue }
                let power = max(0, min(1, (level - floor) / -floor))
                let color = power < 0.45 ? Color.ice : power < 0.8 ? Color.mint : Color.orange
                let p = point(f, Double(frame.phase[bin])), dot = 2.0 + 1.5 * power
                context.fill(Path(ellipseIn: CGRect(x: p.x - dot/2, y: p.y - dot/2, width: dot, height: dot)), with: .color(color.opacity(0.35 + 0.65 * power)))
                visible += 1
            }
            if visible == 0 { plotText(&context, "Waiting for signal on both channels", rect.midX, rect.midY + 24) }
        }.accessibilityLabel(polar ? "Polar phase plot. Angle is left minus right phase. Radius is frequency." : "Rectangular phase plot. Horizontal phase difference, vertical frequency.")
    }
}
