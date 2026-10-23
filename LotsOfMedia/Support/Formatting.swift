import Foundation

enum Fmt {
    static func duration(ms: Int?) -> String? {
        guard let ms, ms > 0 else { return nil }
        let totalMinutes = ms / 60_000
        let h = totalMinutes / 60, m = totalMinutes % 60
        if h > 0 { return m > 0 ? "\(h)h \(m)m" : "\(h)h" }
        return "\(max(m, 1))m"
    }

    static func clock(seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let s = Int(seconds)
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    static func bytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func remaining(ms: Int?, offset: Int?) -> String? {
        guard let ms, let offset, offset > 0, ms > offset else { return nil }
        return Fmt.duration(ms: ms - offset).map { "\($0) left" }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "h:mm"; return f
    }()
    private static let timeWithPeriod: DateFormatter = {
        let f = DateFormatter(); f.timeStyle = .short; return f
    }()

    /// "3:00 PM"
    static func time(_ date: Date) -> String { timeWithPeriod.string(from: date) }

    /// "3:00–3:30 PM", with the day added when it isn't today ("Tue 8:00–9:00 PM").
    static func timeRange(_ start: Date, _ end: Date) -> String {
        var range = timeFormatter.string(from: start) + "–" + timeWithPeriod.string(from: end)
        let cal = Calendar.current
        if !cal.isDateInToday(start) {
            range = (cal.isDateInTomorrow(start) ? "Tomorrow" : start.formatted(.dateTime.weekday(.abbreviated))) + " " + range
        }
        return range
    }

    /// "Ends in 12m", "Starts in 1h 5m"
    static func relative(minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        if h > 0 { return m > 0 ? "\(h)h \(m)m" : "\(h)h" }
        return "\(max(m, 1))m"
    }
}
