import Foundation

enum AnalysisTrigger: String, CaseIterable { case left = "Left", right = "Right", free = "Free run" }
struct AnalysisScopeSettings: Equatable {
    var windowMS = 20.0
    var trigger = AnalysisTrigger.left
    var level = 0.0
    var rising = true
    var gain = 1.0
    var normalized: Self {
        Self(windowMS: windowMS.isFinite ? min(200, max(1, windowMS)) : 20, trigger: trigger,
             level: level.isFinite ? min(1, max(-1, level)) : 0, rising: rising,
             gain: gain.isFinite ? min(8, max(1, gain)) : 1)
    }
    func sampleCount(rate: Double) -> Int {
        guard rate.isFinite, rate >= 8000, rate <= 192000 else { return 1 }
        return max(2, Int((normalized.windowMS * rate / 1000).rounded()))
    }
}
struct AnalysisScopeColumn {
    var minL: Double, maxL: Double, minR: Double, maxR: Double
    var left: Double, right: Double
}
struct AnalysisScopeFrame {
    var columns: [AnalysisScopeColumn] = []
    var triggered = false
    var triggerFraction = 0.0
    var settings = AnalysisScopeSettings()
}
enum AnalysisScope {
    static func make(left: [Float], right: [Float], rate: Double, settings: AnalysisScopeSettings) -> AnalysisScopeFrame {
        let settings = settings.normalized, count = settings.sampleCount(rate: rate)
        var result = AnalysisScopeFrame(settings: settings)
        guard rate.isFinite, rate >= 8000, rate <= 192000,
              left.count == right.count, left.count >= count else { return result }
        func clean(_ x: Float) -> Double { x.isFinite ? min(4, max(-4, Double(x))) : 0 }
        var start = left.count - count
        let pre = max(1, count / 10)
        if settings.trigger != .free {
            let source = settings.trigger == .left ? left : right
            let latest = left.count - count + pre
            if latest >= pre {
                for i in stride(from: latest, through: pre, by: -1) {
                    let a = clean(source[i-1]), b = clean(source[i])
                    let crossing = settings.rising ? (a < settings.level && b >= settings.level) : (a > settings.level && b <= settings.level)
                    if crossing {
                        start = i - pre; result.triggered = true
                        result.triggerFraction = Double(pre) / Double(count); break
                    }
                }
            }
        }
        // Min/max envelopes retain short peaks when many samples share a pixel.
        let columns = min(1024, count)
        result.columns.reserveCapacity(columns)
        for column in 0..<columns {
            let lo = start + column * count / columns, hi = start + (column+1) * count / columns
            var minL = Double.infinity, maxL = -Double.infinity, minR = minL, maxR = maxL
            for i in lo..<hi {
                let l = clean(left[i]), r = clean(right[i])
                minL = min(minL, l); maxL = max(maxL, l); minR = min(minR, r); maxR = max(maxR, r)
            }
            result.columns.append(AnalysisScopeColumn(minL: minL, maxL: maxL, minR: minR, maxR: maxR,
                left: clean(left[lo]), right: clean(right[lo])))
        }
        return result
    }
}
