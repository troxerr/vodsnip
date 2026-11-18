import Foundation

/// Parses and prints "HH:MM:SS" style times.
public enum TimeCode {
    /// "90", "1:30", "01:02:03", "1:02:03.5" -> seconds. nil when it is not a time.
    public static func parse(_ text: String) -> Double? {
        let t = text.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return nil }
        let parts = t.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count <= 3 else { return nil }
        var values: [Double] = []
        for p in parts {
            guard let v = Double(p), v >= 0, v.isFinite else { return nil }
            values.append(v)
        }
        // Minutes and seconds after the first part must be under 60.
        if values.dropFirst().contains(where: { $0 >= 60 }) { return nil }
        return values.reduce(0) { $0 * 60 + $1 }
    }

    /// 3725 -> "01:02:05".
    public static func format(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    /// 3725 -> "01-02-05", safe inside a file name.
    public static func fileSafe(_ seconds: Double) -> String {
        format(seconds).replacingOccurrences(of: ":", with: "-")
    }
}
