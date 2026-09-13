import Foundation

/// 时间码的解析与格式化。界面输入框和命令行共用同一套规则。
public enum Timecode {

    /// 接受 "12.5"、"1:02.5"、"01:02:03.5" 三种写法。
    public static func parse(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count <= 3 else { return nil }
        var total = 0.0
        for part in parts {
            guard let value = Double(part), value >= 0, value.isFinite else { return nil }
            // 分和秒不该超过 60，写成 1:75 多半是笔误
            if parts.count > 1, part != parts[0], value >= 60 { return nil }
            total = total * 60 + value
        }
        return total
    }

    public static func format(_ seconds: Double) -> String {
        let clamped = max(0, seconds)
        let minutes = Int(clamped) / 60
        let rest = clamped - Double(minutes * 60)
        return String(format: "%d:%05.2f", minutes, rest)
    }
}
