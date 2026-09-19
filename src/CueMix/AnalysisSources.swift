import Foundation

struct AnalysisChannel: Identifiable, Equatable {
    let id: String
    let name: String
    let index: Int
    static func channels(rate: Double) -> [Self] {
        var names = [("mic.0", "Mic 1"), ("mic.1", "Mic 2")]
        names += (0..<8).map { ("analog.\($0)", "Analog \($0 + 1)") }
        if rate <= 48000 { names += [("reverb.0", "Reverb Return L"), ("reverb.1", "Reverb Return R")] }
        names += [("return.0", "Stereo Return L"), ("return.1", "Stereo Return R")]
        if rate <= 96000 {
            names += [("spdif.0", "S/PDIF L"), ("spdif.1", "S/PDIF R")]
            for bank in ["A", "B"] {
                names += (0..<(rate <= 48000 ? 8 : 4)).map { ("adat\(bank).\($0)", "ADAT \(bank) \($0 + 1)") }
            }
        }
        return names.enumerated().map { Self(id: $0.element.0, name: $0.element.1, index: $0.offset) }
    }
}
