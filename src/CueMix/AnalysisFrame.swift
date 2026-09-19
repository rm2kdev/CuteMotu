import Foundation

struct AnalysisFrame {
    var left = [Float](repeating: -120, count: Int(AnalysisBins))
    var right = [Float](repeating: -120, count: Int(AnalysisBins))
    var hold = [Float](repeating: -120, count: Int(AnalysisBins))
    var phase = [Float](repeating: 0, count: Int(AnalysisBins))
    var phaseLevel = [Float](repeating: -120, count: Int(AnalysisBins))
    var xy: [CGPoint] = []
    var xyDensity: [AnalysisDensityPoint] = []
    var densityGain = 1.0
    var trails: [AnalysisTrail] = []
    var timing = AnalysisTiming()
    var displayRevision = 0
    var levels = AnalysisResult()
    var meter = AnalysisMeterResult()
    var scope = AnalysisScopeFrame()
    var rate = 48000.0
    var hasSignal: Bool { max(levels.peakLeft, levels.peakRight) > -90 }
}
