import Foundation

struct AnalysisTiming: Equatable, Sendable {
    var averageMS = 250.0
    var holdMS = 500.0
    var xyWindowMS = 50.0
    var normalized: Self {
        func bounded(_ x: Double, _ range: ClosedRange<Double>, _ fallback: Double) -> Double {
            x.isFinite ? min(range.upperBound, max(range.lowerBound, x)) : fallback
        }
        return Self(averageMS: bounded(averageMS, 0...2000, 250),
                    holdMS: bounded(holdMS, 0...2000, 500),
                    xyWindowMS: bounded(xyWindowMS, 5...200, 50))
    }
    func xySampleCount(rate: Double) -> Int {
        guard rate.isFinite, rate > 0, rate <= 192000 else { return 1 }
        return max(1, Int((normalized.xyWindowMS * rate / 1000).rounded()))
    }
}

struct AnalysisPhasePoint {
    var frequency: Double
    var angle: Double
    var level: Double
}
struct AnalysisTrail {
    var opacity: Double
    var xy: [CGPoint]
    var phase: [AnalysisPhasePoint]
}
struct AnalysisDensityPoint {
    // Already in display coordinates, including the selected X–Y display gain.
    var x: Double
    var y: Double
    var strength: Double
}

// Worker-only, finite audio-time windows. Holding display history never blocks
// capture. Use power and complex cross-power so ±180° does not average to 0°.
final class AnalysisTemporal {
    private struct Entry {
        var end: Double
        var duration: Double
        var frame: AnalysisFrame
        var powerL: [Double]
        var powerR: [Double]
        var crossReal: [Double]
        var crossImag: [Double]
    }
    private var entries: [Entry] = []
    private var elapsed = 0.0
    private var peakResetTime = -Double.infinity
    private var configuration: AnalysisTiming?
    private var displayGain = 1.0
    private var sampleRate = 0.0
    var historyCount: Int { entries.count }
    func reset() { entries.removeAll(keepingCapacity: true); elapsed = 0; peakResetTime = -.infinity }
    func resetPeaks() { peakResetTime = elapsed }
    private func power(_ db: Float) -> Double { db > -120 && db.isFinite ? pow(10, Double(db) / 10) : 0 }
    private func decibels(_ power: Double) -> Float { Float(10 * log10(max(1e-12, power))) }

    func process(_ raw: AnalysisFrame, duration: Double, timing requested: AnalysisTiming, gain: Double) -> AnalysisFrame {
        let timing = requested.normalized
        let gain = gain.isFinite ? min(8, max(1, gain)) : 1
        if configuration != timing || displayGain != gain || sampleRate != raw.rate {
            reset(); configuration = timing; displayGain = gain; sampleRate = raw.rate
        }
        guard duration.isFinite, duration > 0, raw.rate.isFinite, raw.rate > 0,
              !raw.left.isEmpty, raw.left.count == raw.right.count, raw.phase.count == raw.left.count,
              raw.phaseLevel.count == raw.left.count else {
            reset(); return raw
        }
        elapsed += duration
        let left = raw.left.map(power), right = raw.right.map(power)
        var real = [Double](repeating: 0, count: left.count), imag = real
        for i in left.indices {
            let magnitude = sqrt(left[i] * right[i])
            if raw.phase[i].isFinite {
                real[i] = magnitude * cos(Double(raw.phase[i])); imag[i] = magnitude * sin(Double(raw.phase[i]))
            }
        }
        entries.append(Entry(end: elapsed, duration: duration, frame: raw, powerL: left, powerR: right, crossReal: real, crossImag: imag))
        let window = max(timing.holdMS, timing.averageMS) / 1000
        entries.removeAll { $0.end <= elapsed - window && $0.end < elapsed }
        // Normal 20-Hz capture needs at most 41 entries for the 2-second range.
        // This hard bound also protects against unexpectedly tiny input blocks.
        if entries.count > 128 { entries.removeFirst(entries.count - 128) }

        var result = raw
        result.timing = timing; result.densityGain = gain
        result.hold = zip(raw.left, raw.right).map { max($0, $1) }
        if timing.holdMS > 0 {
            for e in entries where e.end > elapsed - timing.holdMS / 1000 && e.end > peakResetTime {
                for i in result.hold.indices { result.hold[i] = max(result.hold[i], e.frame.left[i], e.frame.right[i]) }
            }
        }

        if timing.averageMS > 0 {
            var sumL = [Double](repeating: 0, count: left.count), sumR = sumL, sumReal = sumL, sumImag = sumL
            let cutoff = elapsed - timing.averageMS / 1000
            let side = 128
            var density = [Double](repeating: 0, count: side * side)
            var total = 0.0
            for e in entries {
                // Weight partial oldest intervals: a 75-ms average at a 50-ms
                // analysis cadence uses 25 ms of the old and 50 ms of the new.
                let weight = max(0, e.end - max(cutoff, e.end - e.duration))
                guard weight > 0 else { continue }
                total += weight
                for i in left.indices {
                    sumL[i] += e.powerL[i] * weight; sumR[i] += e.powerR[i] * weight
                    sumReal[i] += e.crossReal[i] * weight; sumImag[i] += e.crossImag[i] * weight
                }
                if e.frame.hasSignal && !e.frame.xy.isEmpty {
                    let perPoint = weight / Double(e.frame.xy.count)
                    for p in e.frame.xy where p.x.isFinite && p.y.isFinite {
                        let x = min(side - 1, max(0, Int(((min(1, max(-1, p.x * gain)) + 1) / 2 * Double(side - 1)).rounded())))
                        let y = min(side - 1, max(0, Int(((min(1, max(-1, p.y * gain)) + 1) / 2 * Double(side - 1)).rounded())))
                        density[y * side + x] += perPoint
                    }
                }
            }
            if total > 0 {
                for i in left.indices {
                    result.left[i] = decibels(sumL[i] / total); result.right[i] = decibels(sumR[i] / total)
                    let crossMagnitude = hypot(sumReal[i], sumImag[i]) / total
                    result.phase[i] = Float(atan2(sumImag[i], sumReal[i]))
                    // Suppress undefined angles when opposing vectors cancel.
                    result.phaseLevel[i] = min(result.left[i], result.right[i], decibels(crossMagnitude))
                }
                result.xyDensity = density.enumerated().compactMap { index, weight in
                    guard weight > 0 else { return nil }
                    return AnalysisDensityPoint(x: 2 * Double(index % side) / Double(side - 1) - 1,
                        y: 2 * Double(index / side) / Double(side - 1) - 1,
                        strength: min(1, sqrt(weight / total * 80)))
                }
            }
        } else { result.xyDensity = [] }

        result.trails = []
        if timing.holdMS > 0 {
            let held = entries.filter { $0.end > elapsed - timing.holdMS / 1000 && $0.end < elapsed }
            let strideSize = max(1, Int(ceil(Double(held.count) / 24)))
            for index in stride(from: 0, to: held.count, by: strideSize) {
                let e = held[index]
                let opacity = max(0, 1 - (elapsed - e.end) * 1000 / timing.holdMS)
                let points = e.frame.hasSignal ? stride(from: 0, to: e.frame.xy.count, by: max(1, Int(ceil(Double(e.frame.xy.count) / 512)))).map { e.frame.xy[$0] } : []
                result.trails.append(AnalysisTrail(opacity: opacity, xy: points, phase: phasePoints(e.frame)))
            }
        }
        return result
    }
    private func phasePoints(_ frame: AnalysisFrame) -> [AnalysisPhasePoint] {
        // Keep the strongest bin in each log-frequency cell for old trails.
        // The current plot still uses all FFT bins.
        var points = [AnalysisPhasePoint?](repeating: nil, count: 256)
        for bin in 1..<frame.phase.count {
            let frequency = Double(bin) * frame.rate / Double(AnalysisFFT)
            let level = Double(min(frame.left[bin], frame.right[bin]))
            guard frequency >= 20, frequency <= 20000, level > -90 else { continue }
            let cell = min(255, max(0, Int(log10(frequency / 20) / 3 * 255)))
            if points[cell] == nil || level > points[cell]!.level {
                points[cell] = AnalysisPhasePoint(frequency: frequency, angle: Double(frame.phase[bin]), level: level)
            }
        }
        return points.compactMap { $0 }
    }
}
