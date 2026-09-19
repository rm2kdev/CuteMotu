import Foundation
@main enum AnalysisSourceTests {
    static func main() {
        for rate in [44100.0, 48000, 88200, 96000, 176400, 192000] {
            let channels = AnalysisChannel.channels(rate: rate)
            let expected = rate <= 48000 ? 32 : rate <= 96000 ? 22 : 12
            precondition(channels.count == expected)
            precondition(Set(channels.map(\.id)).count == expected)
            precondition(channels.map(\.index) == Array(0..<expected))
            precondition(channels[0].id == "mic.0" && channels[9].id == "analog.7")
            // Stereo Return moves in Core Audio's input map when reverb goes away.
            let stereoReturn = channels.first { $0.id == "return.0" }!
            precondition(stereoReturn.index == (rate <= 48000 ? 12 : 10))
            precondition(channels.last?.id == (rate <= 48000 ? "adatB.7" : rate <= 96000 ? "adatB.3" : "return.1"))
            if rate <= 96000 {
                precondition(channels.first { $0.id == "spdif.0" }!.index == (rate <= 48000 ? 14 : 12))
                precondition(channels.first { $0.id == "adatB.0" }!.index == (rate <= 48000 ? 24 : 18))
            }
            precondition(channels.contains { $0.id == "reverb.0" } == (rate <= 48000))
        }
        print("PASS: Analysis channel identities and Core Audio offsets at all six sample rates")
    }
}
