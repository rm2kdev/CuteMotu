import Foundation

@main struct AnalysisTimingTests {
    static var checks = 0
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !condition() { fatalError(message) }
    }
    static func near(_ actual: Double, _ expected: Double, _ message: String, tolerance: Double = 0.0001) {
        check(abs(actual - expected) < tolerance, "\(message): got \(actual), expected \(expected)")
    }
    static func signal(_ db: Float, phase: Float = 0, xy: [CGPoint] = [CGPoint(x: 0.5, y: 0.5)], rate: Double = 48000) -> AnalysisFrame {
        var frame = AnalysisFrame()
        frame.left = [Float](repeating: db, count: 16); frame.right = frame.left
        frame.phase = [Float](repeating: phase, count: 16); frame.phaseLevel = frame.left; frame.hold = frame.left
        frame.xy = xy; frame.rate = rate
        frame.levels.peakLeft = Double(db); frame.levels.peakRight = Double(db)
        return frame
    }
    static func main() {
        let processor = AnalysisTemporal()
        let average = AnalysisTiming(averageMS: 100, holdMS: 0, xyWindowMS: 5)
        _ = processor.process(signal(0), duration: 0.05, timing: average, gain: 1)
        var result = processor.process(signal(-20), duration: 0.05, timing: average, gain: 1)
        near(Double(result.left[0]), 10 * log10(0.505), "Average linear power, not dB")
        processor.reset()
        let partial = AnalysisTiming(averageMS: 75, holdMS: 0, xyWindowMS: 5)
        _ = processor.process(signal(0), duration: 0.05, timing: partial, gain: 1)
        result = processor.process(signal(-20), duration: 0.05, timing: partial, gain: 1)
        near(Double(result.left[0]), 10 * log10((0.025 + 0.01 * 0.05) / 0.075), "Partial oldest interval")
        processor.reset()
        _ = processor.process(signal(-6, phase: Float(179 * Double.pi / 180)), duration: 0.05, timing: average, gain: 1)
        result = processor.process(signal(-6, phase: Float(-179 * Double.pi / 180)), duration: 0.05, timing: average, gain: 1)
        near(abs(Double(result.phase[0])), .pi, "Circular phase average wraps at 180 degrees")
        check(result.phaseLevel[0] > -7, "Coherent near-180 phase remains visible")
        processor.reset()
        _ = processor.process(signal(-6, phase: 0), duration: 0.05, timing: average, gain: 1)
        result = processor.process(signal(-6, phase: .pi), duration: 0.05, timing: average, gain: 1)
        check(result.phaseLevel[0] < -75, "Cancelling phase vectors are hidden below the floor")

        let held = AnalysisTiming(averageMS: 0, holdMS: 150, xyWindowMS: 50)
        _ = processor.process(signal(-3), duration: 0.05, timing: held, gain: 1)
        result = processor.process(signal(-30), duration: 0.05, timing: held, gain: 1)
        near(Double(result.hold[0]), -3, "Finite peak hold retains recent peak")
        check(!result.trails.isEmpty, "History produces trails")
        processor.resetPeaks()
        result = processor.process(signal(-40), duration: 0.05, timing: held, gain: 1)
        near(Double(result.hold[0]), -40, "Reset peaks discards old maxima")
        check(!result.trails.isEmpty, "Reset peaks leaves other chart history intact")
        processor.reset()
        _ = processor.process(signal(-3), duration: 0.05, timing: held, gain: 1)
        for _ in 0..<4 { result = processor.process(signal(-120, xy: []), duration: 0.05, timing: held, gain: 1) }
        near(Double(result.hold[0]), -120, "Held peak expires")
        check(!result.trails.contains { !$0.xy.isEmpty || !$0.phase.isEmpty }, "Silent input drains held XY and phase history")
        processor.reset()
        let exact = AnalysisTiming(averageMS: 0, holdMS: 125, xyWindowMS: 50)
        _ = processor.process(signal(-3), duration: 0.0625, timing: exact, gain: 1)
        _ = processor.process(signal(-30), duration: 0.0625, timing: exact, gain: 1)
        result = processor.process(signal(-40), duration: 0.0625, timing: exact, gain: 1)
        near(Double(result.hold[0]), -30, "A peak exactly at the hold boundary expires")

        processor.reset()
        _ = processor.process(signal(-6, xy: [CGPoint(x: 0.5, y: 0.5)]), duration: 0.05, timing: average, gain: 1)
        result = processor.process(signal(-6, xy: [CGPoint(x: -0.5, y: -0.5)]), duration: 0.05, timing: average, gain: 1)
        check(result.xyDensity.count == 2, "XY averaging retains spatial density, not coordinate mean")
        check(result.xyDensity.allSatisfy { abs($0.x) > 0.4 }, "Opposite points do not collapse to zero")
        for _ in 0..<3 { result = processor.process(signal(-120, xy: []), duration: 0.05, timing: average, gain: 1) }
        check(result.xyDensity.isEmpty, "Silent input drains averaged density")
        near(Double(result.left[0]), -120, "Silent input drains average power")
        result = processor.process(signal(-6), duration: 0.05, timing: average, gain: 2)
        check(processor.historyCount == 1 && result.xyDensity[0].x == 1, "Display gain resets history and scales density once")
        result = processor.process(signal(-18, rate: 96000), duration: 0.05, timing: average, gain: 2)
        near(Double(result.left[0]), -18, "Sample-rate change clears history")
        check(processor.historyCount == 1, "Rate change leaves only fresh history")
        processor.reset()
        result = processor.process(signal(-24, rate: 96000), duration: 0.05, timing: average, gain: 2)
        near(Double(result.left[0]), -24, "Source reset cannot reuse old energy")
        let off = AnalysisTiming(averageMS: 0, holdMS: 0, xyWindowMS: 50)
        result = processor.process(signal(-30), duration: 0.05, timing: off, gain: 1)
        near(Double(result.left[0]), -30, "Average off delivers current spectrum")
        check(result.xyDensity.isEmpty && result.trails.isEmpty && processor.historyCount == 1, "Hold off retains no trails")
        let maximum = AnalysisTiming(averageMS: 2000, holdMS: 2000, xyWindowMS: 200)
        for _ in 0..<160 { result = processor.process(signal(-12), duration: 0.0001, timing: maximum, gain: 1) }
        check(processor.historyCount <= 128 && result.trails.count <= 24, "Unexpected tiny blocks cannot grow history without bound")
        check(result.trails.allSatisfy { $0.xy.count <= 512 && $0.phase.count <= 256 }, "Held rendering has bounded point counts")
        let normalized = AnalysisTiming(averageMS: .nan, holdMS: .infinity, xyWindowMS: -1).normalized
        check(normalized.averageMS == 250 && normalized.holdMS == 500 && normalized.xyWindowMS == 5, "Invalid timing values normalize safely")
        check(AnalysisTiming(averageMS: -10, holdMS: 9000, xyWindowMS: 999).normalized == AnalysisTiming(averageMS: 0, holdMS: 2000, xyWindowMS: 200), "Timing bounds")
        check(off.xySampleCount(rate: 48000) == 2400, "50 ms at 48 kHz")
        check(average.xySampleCount(rate: 48000) == 240, "5 ms at 48 kHz")
        check(maximum.xySampleCount(rate: 192000) == 38400, "200 ms at 192 kHz")
        check(maximum.xySampleCount(rate: .nan) == 1, "Invalid sample rate is safe")
        _ = processor.process(signal(-6), duration: .nan, timing: maximum, gain: 1)
        check(processor.historyCount == 0, "Invalid capture duration clears history")
        print("Analysis timing: \(checks) checks passed (power, phase, expiry, density, resets and bounds).")

        // Exercise the real bin count and longest normal history in release mode.
        // Report time without a flaky machine-speed assertion.
        var full = AnalysisFrame()
        full.left = [Float](repeating: -12, count: Int(AnalysisBins)); full.right = full.left; full.phaseLevel = full.left
        full.xy = (0..<2048).map { CGPoint(x: sin(Double($0) / 20), y: cos(Double($0) / 20)) }
        full.levels.peakLeft = -6; full.levels.peakRight = -6
        for _ in 0..<40 { _ = processor.process(full, duration: 0.05, timing: maximum, gain: 1) }
        let began = Date()
        for _ in 0..<100 { _ = processor.process(full, duration: 0.05, timing: maximum, gain: 1) }
        print(String(format: "Longest-window chart processing: %.2f ms per frame (4097 bins, 2000 ms history, 2048 XY points).", Date().timeIntervalSince(began) * 10))
    }
}
