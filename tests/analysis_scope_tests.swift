import Foundation
@main struct ScopeTests {
    static var checks = 0
    static func check(_ valid: @autoclosure () -> Bool, _ message: String) { checks += 1; if !valid() { fatalError(message) } }
    static func main() {
        let rate = 48000.0
        let left = (0..<16384).map { Float(0.8 * sin(2 * .pi * Double($0) / 48)) }
        let right = left.map { -$0 }
        var settings = AnalysisScopeSettings(windowMS: 5)
        var result = AnalysisScope.make(left:left,right:right,rate:rate,settings:settings)
        check(result.triggered && result.columns.count == 240, "Rising trigger and 5-ms window")
        let crossing = Int((result.triggerFraction * 240).rounded())
        check(abs(result.triggerFraction - 0.1) < 1e-12, "Trigger time is 10% of the full sample window")
        check(result.columns[crossing-1].left < 0 && result.columns[crossing].left >= 0, "Rising crossing at trigger marker")
        let low = (0..<16384).map { Float(sin(2 * .pi * Double($0) / 2400)) }
        check(AnalysisScope.make(left:low,right:low,rate:rate,settings:AnalysisScopeSettings(windowMS:1)).triggered,
              "Short time base searches retained audio for a low-frequency crossing")
        settings.trigger = .right; settings.rising = false
        result = AnalysisScope.make(left:left,right:right,rate:rate,settings:settings)
        check(result.triggered && result.columns[crossing-1].right > 0 && result.columns[crossing].right <= 0, "Right-channel falling trigger")
        settings.level = 0.95
        result = AnalysisScope.make(left:left,right:right,rate:rate,settings:settings)
        check(!result.triggered && result.columns.last!.left == Double(left.last!), "No crossing falls back to latest complete window")
        settings.trigger = .free; settings.windowMS = 200
        var impulse = [Float](repeating:0,count:19200); impulse[12345] = 1
        result = AnalysisScope.make(left:impulse,right:impulse,rate:rate,settings:settings)
        check(result.columns.count == 1024 && result.columns.contains { $0.maxL == 1 }, "Min/max preserves a single-sample peak when decimated")
        impulse[15000] = .nan; impulse[15001] = .infinity
        result = AnalysisScope.make(left:impulse,right:impulse,rate:rate,settings:settings)
        check(result.columns.allSatisfy { $0.minL.isFinite && $0.maxR.isFinite }, "Scope sanitizes nonfinite input")
        check(AnalysisScope.make(left:left,right:[],rate:rate,settings:settings).columns.isEmpty, "Mismatched buffers safe")
        check(AnalysisScope.make(left:left,right:right,rate:.nan,settings:settings).columns.isEmpty, "Invalid sample rate safe")
        check(AnalysisScope.make(left:[0],right:[0],rate:rate,settings:settings).columns.isEmpty, "Incomplete window is not stretched")
        for sr in [44100.0,48000,88200,96000,176400,192000] {
            check(settings.sampleCount(rate:sr) == Int(sr/5), "200-ms time base follows sample rate")
        }
        check(AnalysisScopeSettings(windowMS: .nan, level: .infinity, gain: -10).normalized == AnalysisScopeSettings(windowMS:20,level:0,gain:1), "Invalid settings normalize")
        print("Analysis scope: \(checks) checks passed (trigger, time base, envelopes and bounds).")
    }
}
