import Foundation

public enum QuotaTimeFormatter {
    public static func countdown(
        until resetDate: Date,
        from referenceDate: Date = Date()
    ) -> String {
        let interval = resetDate.timeIntervalSince(referenceDate)
        guard interval > 0 else { return "即将重置" }

        if interval >= 86_400 {
            let totalHours = Int(ceil(interval / 3_600))
            let days = totalHours / 24
            let hours = totalHours % 24
            return hours == 0
                ? "\(days) 天"
                : "\(days) 天 \(hours) 小时"
        }

        let totalMinutes = max(1, Int(ceil(interval / 60)))
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours > 0 {
            return minutes == 0
                ? "\(hours) 小时"
                : "\(hours) 小时 \(minutes) 分钟"
        }
        return "\(minutes) 分钟"
    }
}
