import Foundation

func parsedParameterValue(_ text:String,range:ClosedRange<Double>,step:Double)->Double? {
    let normalized=text.trimmingCharacters(in:.whitespacesAndNewlines).replacingOccurrences(of:"−",with:"-").replacingOccurrences(of:",",with:".")
    guard let number=Double(normalized),number.isFinite,range.contains(number) else{return nil}
    let rounded=step>0 ? (number/step).rounded()*step:number
    return min(range.upperBound,max(range.lowerBound,rounded))
}
