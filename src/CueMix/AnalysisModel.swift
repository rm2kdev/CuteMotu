import SwiftUI
import AVFoundation

// The queue owns capture, ring reads, FFT/YIN and finite chart history.
// Only small immutable display snapshots cross to the main actor.
private final class AnalysisWorker: @unchecked Sendable {
    let queue = DispatchQueue(label: "org.cutemix.analysis", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var capture: UnsafeMutableRawPointer?
    private let engine = analysisEngineCreate()
    private let meter = analysisMeterCreate()
    private var historyL: [Float] = [], historyR: [Float] = []
    private var scratchL = [Float](repeating: 0, count: Int(AnalysisWindow))
    private var scratchR = [Float](repeating: 0, count: Int(AnalysisWindow))
    private let temporal = AnalysisTemporal()
    private var device: UInt32 = 0, tickCount = 0
    private var rate = 0.0, lastAudio = Date.distantPast
    private var dropped: UInt64 = 0
    private var leftID = "return.0", rightID = "return.1", tunerRight = false
    private var timing = AnalysisTiming(), gain = 1.0
    private var scope = AnalysisScopeSettings()
    private var displayRevision = 0
    private var deliver: ((AnalysisFrame?, Double, String) -> Void)?
    deinit { timer?.cancel(); analysisCaptureClose(capture); analysisEngineDestroy(engine); analysisMeterDestroy(meter) }
    func stop() {
        timer?.cancel(); timer = nil
        analysisCaptureClose(capture); capture = nil; device = 0; rate = 0
        historyL = []; historyR = []; temporal.reset(); deliver = nil
        analysisMeterReset(meter, 0)
    }
    func start(left: String, right: String, tunerRight: Bool, timing: AnalysisTiming, gain: Double, scope: AnalysisScopeSettings, revision: Int,
               deliver: @escaping (AnalysisFrame?, Double, String) -> Void) {
        let active = timer != nil
        if !active { stop(); dropped = 0 }
        leftID = left; rightID = right; self.tunerRight = tunerRight
        self.timing = timing.normalized; self.gain = gain; displayRevision = revision
        self.scope = scope.normalized
        self.deliver = deliver; tickCount = 0; clear()
        if active {
            if let capture {
                let channels = AnalysisChannel.channels(rate: rate)
                if let l = channels.first(where: { $0.id == left }), let r = channels.first(where: { $0.id == right }),
                   analysisCaptureSelect(capture, UInt32(l.index), UInt32(r.index)) != 0 {
                    lastAudio = Date()
                } else { analysisCaptureClose(capture); self.capture = nil }
            }
            return
        }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(50), leeway: .milliseconds(5))
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t; t.resume()
    }
    func resetPeak() { temporal.resetPeaks() }
    func updateTiming(_ timing: AnalysisTiming, gain: Double, scope: AnalysisScopeSettings, tunerRight: Bool, revision: Int) {
        self.timing = timing.normalized; self.gain = gain; displayRevision = revision
        self.tunerRight = tunerRight
        self.scope = scope.normalized
        temporal.reset()
    }
    func resetMeters(revision: Int) { analysisMeterReset(meter, rate); displayRevision = revision }
    func lastMeasurement() -> AnalysisMeterResult {
        var result = AnalysisMeterResult(); analysisMeterRead(meter, &result); return result
    }
    private func clear() {
        historyL.removeAll(keepingCapacity: true); historyR.removeAll(keepingCapacity: true); temporal.reset()
        analysisMeterReset(meter, rate)
    }
    private func tick() {
        defer { tickCount += 1 }
        if tickCount % 20 == 0 {
            let state = AudioRateAccess.read()
            if state.device != device || state.rate != rate || capture == nil {
                analysisCaptureClose(capture); capture = nil
                device = state.device; rate = state.rate; clear()
                guard device != 0 else { deliver?(nil, 0, "Connect Cute Motu 828x to begin."); return }
                let channels = AnalysisChannel.channels(rate: rate)
                guard let l = channels.first(where: { $0.id == leftID }), let r = channels.first(where: { $0.id == rightID }),
                      l.index < state.inputs, r.index < state.inputs else {
                    deliver?(nil, rate, "This source is unavailable at the current sample rate. Choose another input."); return
                }
                var error: Int32 = 0
                capture = analysisCaptureOpen(device, UInt32(l.index), UInt32(r.index), &error)
                guard capture != nil else {
                    NSLog("Analysis input open failed: %d", error)
                    deliver?(nil, rate, "Couldn’t open the audio input. Check microphone access in System Settings, then retry."); return
                }
                lastAudio = Date(); dropped = 0
                deliver?(nil, rate, "Listening…")
            }
        }
        guard let capture, engine != nil else { return }
        var newDropped: UInt64 = 0, error: Int32 = 0
        let count = Int(analysisCaptureRead(capture, &scratchL, &scratchR, UInt32(AnalysisWindow), &newDropped, &error))
        if error != 0 || newDropped != dropped {
            dropped = newDropped; clear()
            analysisCaptureClose(capture); self.capture = nil
            deliver?(nil, rate, "Audio interrupted. Reconnecting…"); return
        }
        guard count > 0 else {
            if Date().timeIntervalSince(lastAudio) > 1 {
                clear(); analysisCaptureClose(capture); self.capture = nil
                deliver?(nil, rate, "Waiting for audio from the interface…")
            }
            return
        }
        lastAudio = Date()
        // Meter only new samples; rolling FFT/scope windows overlap heavily.
        analysisMeterPush(meter, scratchL, scratchR, UInt32(count))
        historyL.append(contentsOf: scratchL.prefix(count)); historyR.append(contentsOf: scratchR.prefix(count))
        let xyCount = timing.xySampleCount(rate: rate)
        let required = max(Int(AnalysisWindow), xyCount, scope.sampleCount(rate: rate) * 2)
        let excess = historyL.count - required
        if excess > 0 { historyL.removeFirst(excess); historyR.removeFirst(excess) }
        guard historyL.count >= required else { return }
        var frame = AnalysisFrame(); frame.rate = rate
        analysisMeterRead(meter, &frame.meter)
        frame.scope = AnalysisScope.make(left: historyL, right: historyR, rate: rate, settings: scope)
        let offset = historyL.count - Int(AnalysisWindow)
        historyL.withUnsafeBufferPointer { left in
            historyR.withUnsafeBufferPointer { right in
                analysisProcess(engine, left.baseAddress! + offset, right.baseAddress! + offset, UInt32(AnalysisWindow), rate, tunerRight ? 1 : 0,
                                &frame.levels, &frame.left, &frame.right, &frame.phase)
            }
        }
        frame.phaseLevel = zip(frame.left, frame.right).map { min($0, $1) }
        let start = max(0, historyL.count - xyCount)
        let strideSize = max(1, Int(ceil(Double(historyL.count - start) / 2048)))
        frame.xy = stride(from: start, to: historyL.count, by: strideSize).map { i in
            CGPoint(x: historyL[i].isFinite ? Double(historyL[i]) : 0, y: historyR[i].isFinite ? Double(historyR[i]) : 0)
        }
        frame.displayRevision = displayRevision
        deliver?(temporal.process(frame, duration: Double(count) / rate, timing: timing, gain: gain), rate, "Live")
    }
}

@MainActor final class AnalysisModel: ObservableObject {
    @Published private(set) var frame: AnalysisFrame?
    @Published private(set) var running = false
    @Published private(set) var paused = false
    @Published private(set) var status = "Choose a source, then start analysis."
    @Published private(set) var rate = 48000.0
    @Published private(set) var leftID = "return.0"
    @Published private(set) var rightID = "return.1"
    @Published var tunerRight = false { didSet { if tunerRight != oldValue { clearHistory() } } }
    @Published var timing = AnalysisTiming() { didSet { if timing != oldValue { clearHistory() } } }
    @Published var scope = AnalysisScopeSettings() { didSet { if scope != oldValue { clearHistory() } } }
    @Published private(set) var completedMeter: AnalysisMeterResult?
    @Published var reference = 440.0
    @Published var peakHold = true
    @Published var phasePolar = false
    @Published var phaseFloor = -60.0
    @Published var xyGain = 1.0 { didSet { if xyGain != oldValue { clearHistory() } } }
    var isPreview: Bool {
        #if ANALYSIS_PREVIEW
        return true
        #else
        return false
        #endif
    }
    private let worker = AnalysisWorker()
    private var generation = 0
    private var displayRevision = 0
    init() {
        #if ANALYSIS_PREVIEW
        renderPreview()
        #endif
    }
    #if ANALYSIS_PREVIEW
    private func renderPreview() {
        // This branch exists only in the separate offline visual-test bundle.
        // It neither opens hardware nor requests microphone permission.
        let temporal = AnalysisTemporal()
        var left = [Float](repeating: 0, count: Int(AnalysisWindow)), right = left
        let e = analysisEngineCreate()
        let m = analysisMeterCreate()
        analysisMeterReset(m, 48000)
        defer { analysisEngineDestroy(e); analysisMeterDestroy(m) }
        for step in 0..<16 {
            var f = AnalysisFrame()
            let shift = Double(step) * 0.025
            for i in left.indices {
                let t = Double(i) / 48000
                left[i] = Float(0.45 * sin(2 * .pi * 440 * t) + 0.15 * sin(2 * .pi * 880 * t) + 0.05 * sin(2 * .pi * 1320 * t))
                right[i] = Float(0.38 * sin(2 * .pi * 440 * t - 0.4 - shift) + 0.11 * sin(2 * .pi * 880 * t - 0.8 - shift) + 0.08 * sin(2 * .pi * 1320 * t - 1.2 - shift))
            }
            analysisProcess(e, left, right, UInt32(AnalysisWindow), 48000, tunerRight ? 1 : 0, &f.levels, &f.left, &f.right, &f.phase)
            analysisMeterPush(m, left, right, UInt32(left.count)); analysisMeterRead(m, &f.meter)
            f.scope = AnalysisScope.make(left: left, right: right, rate: 48000, settings: scope)
            f.hold = zip(f.left, f.right).map { max($0, $1) }
            f.phaseLevel = zip(f.left, f.right).map { min($0, $1) }
            let start = max(0, left.count - timing.xySampleCount(rate: 48000))
            f.xy = stride(from: start, to: left.count, by: max(1, Int(ceil(Double(left.count - start) / 2048)))).map { CGPoint(x: Double(left[$0]), y: Double(right[$0])) }
            f.displayRevision = displayRevision
            frame = temporal.process(f, duration: 0.05, timing: timing, gain: xyGain)
        }
        status = "Offline test signal · 440 Hz with harmonics"
    }
    #endif
    var channels: [AnalysisChannel] { AnalysisChannel.channels(rate: rate) }
    var meterReading: AnalysisMeterResult? { frame?.meter ?? (running ? nil : completedMeter) }
    var usesReturn: Bool { leftID.hasPrefix("return") || rightID.hasPrefix("return") }
    func updateAvailableRate(_ value: Double) { if !running && value > 0 { rate = value } }
    func select(left: String, right: String) { leftID = left; rightID = right; restart() }
    func start() {
        guard !running else { return }
        completedMeter = nil
        running = true; paused = false; status = "Requesting audio access…"
        generation += 1; let request = generation
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: begin()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] allowed in
                Task { @MainActor in
                    guard let self, self.running, self.generation == request else { return }
                    if allowed { self.begin() } else { self.permissionDenied() }
                }
            }
        default: permissionDenied()
        }
    }
    private func permissionDenied() { running = false; status = "Allow Cute Mix USB in System Settings → Privacy & Security → Microphone, then start again." }
    private func begin() {
        generation += 1; let request = generation
        let l = leftID, r = rightID, tune = tunerRight, timing = timing.normalized, gain = xyGain, scope = scope.normalized, revision = displayRevision
        frame = nil; paused = false; status = "Connecting to your input…"
        worker.queue.async { [worker, weak self] in
            worker.start(left: l, right: r, tunerRight: tune, timing: timing, gain: gain, scope: scope, revision: revision) { frame, rate, status in
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.running, self.generation == request else { return }
                    if let frame, frame.displayRevision != self.displayRevision { return }
                    if rate > 0 { self.rate = rate }
                    // Disconnect/rate failures invalidate even a frozen frame.
                    if frame == nil { self.paused = false }
                    if frame == nil || !self.paused { self.frame = frame; self.status = status }
                }
            }
        }
    }
    private func restart() {
        completedMeter = nil; frame = nil
        if !running { generation += 1 }
        else if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized { begin() }
    }
    func stop() {
        let wasRunning = running
        if let meter = frame?.meter { completedMeter = meter }
        generation += 1; running = false; paused = false; frame = nil
        let request = generation
        status = completedMeter == nil ? "Choose a source, then start analysis." : "Stopped. Start for a new measurement."
        worker.queue.async { [worker, weak self] in
            let final = worker.lastMeasurement(); worker.stop()
            if wasRunning && final.seconds > 0 {
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.running, self.generation == request else { return }
                    self.completedMeter = final; self.status = "Stopped. Start for a new measurement."
                }
            }
        }
    }
    func togglePause() { paused.toggle(); if !paused { frame = nil; status = "Listening…" } }
    func resetPeak() { worker.queue.async { [worker] in worker.resetPeak() }; frame?.hold = [Float](repeating: -120, count: Int(AnalysisBins)) }
    func clearHistory() {
        displayRevision += 1; frame = nil; paused = false
        if running { status = "Listening…" }
        let settings = timing.normalized, gain = xyGain, scope = scope.normalized, tune = tunerRight, revision = displayRevision
        worker.queue.async { [worker] in worker.updateTiming(settings, gain: gain, scope: scope, tunerRight: tune, revision: revision) }
        #if ANALYSIS_PREVIEW
        renderPreview()
        #endif
    }
    func resetMeasurement() {
        if !running { generation += 1 }
        displayRevision += 1; frame = nil; completedMeter = nil; paused = false
        let revision = displayRevision
        status = running ? "Measuring…" : "Choose a source, then start analysis."
        worker.queue.async { [worker] in worker.resetMeters(revision: revision) }
        #if ANALYSIS_PREVIEW
        renderPreview()
        #endif
    }
}
