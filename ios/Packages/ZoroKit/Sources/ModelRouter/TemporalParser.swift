import Foundation

/// Everything the parser found about "when" in one utterance.
struct TemporalParse: Sendable, Equatable {
    /// Start of a single named day (today, tomorrow, Friday, 12 November).
    var dayStart: Date?
    /// A multi-day range (last week, this month, the last 3 days).
    var range: DateInterval?
    var hour: Int?
    var minute: Int = 0
    /// "6 am", "18:30", "subah 6 baje": the hour needs no guessing.
    var hourIsExplicit = false
    var durationSeconds: Int?
    /// Weekday codes ("mon"...) for repeating alarms.
    var repeatDays: [String] = []
    var repeating = false

    var hasTime: Bool { hour != nil }
    var isEmpty: Bool { dayStart == nil && range == nil && hour == nil && durationSeconds == nil && repeatDays.isEmpty && !repeating }
}

enum TimeDirection: Sendable { case future, past }

/// How an hour without am/pm is read when the day is not today: alarms lean to the morning, other
/// things to the daytime.
enum AmbiguousHourStyle: Sendable { case morning, daytime }

/// Extracts dates, clock times, durations and repeat rules in English, Hindi and Hinglish.
/// Everything is relative to an injected `now` and time zone, so it is fully deterministic.
struct TemporalParser: Sendable {
    let now: Date
    let calendar: Calendar

    init(now: Date, timeZone: TimeZone) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        cal.firstWeekday = 2
        cal.minimumDaysInFirstWeek = 4
        self.calendar = cal
        self.now = now
    }

    var today: Date { calendar.startOfDay(for: now) }

    func addDays(_ n: Int, to date: Date) -> Date { calendar.date(byAdding: .day, value: n, to: date) ?? date }

    /// Parses every temporal expression and marks its words consumed.
    func parse(_ u: inout Utterance, direction: TimeDirection, allowBareHour: Bool = true) -> TemporalParse {
        var p = TemporalParse()
        p.durationSeconds = parseDuration(&u)
        parseRepeat(&u, into: &p)
        parseDay(&u, direction: direction, into: &p)
        parseClock(&u, allowBareHour: allowBareHour, into: &p)
        return p
    }

    // MARK: Durations

    private func unitSeconds(_ norm: String) -> Double? {
        if Lexicon.secondUnits.contains(norm) { return 1 }
        if Lexicon.minuteUnits.contains(norm) { return 60 }
        if Lexicon.hourUnits.contains(norm) { return 3600 }
        return nil
    }

    private func parseDuration(_ u: inout Utterance) -> Int? {
        var total = 0.0
        var found = false
        var i = 0
        var firstStart: Int?
        var lastEnd = 0
        while i < u.count {
            guard u.isFree(i), let q = NumberParsing.quantity(in: u, at: i),
                  let unit = u.norm(i + q.length).flatMap(unitSeconds), u.isFree(i + q.length)
            else { i += 1; continue }
            // "a" / "an" only count directly before a unit ("an hour").
            total += q.value * unit
            found = true
            if firstStart == nil { firstStart = i }
            let end = i + q.length + 1
            lastEnd = end
            u.consume(i..<end)
            i = end
            if u.isFree(i), ["and", "aur", "और"].contains(u.norm(i) ?? ""), NumberParsing.quantity(in: u, at: i + 1) != nil {
                u.consume(i)
                lastEnd = i + 1
                i += 1
            }
        }
        guard found, let start = firstStart else { return nil }
        if start > 0, u.isFree(start - 1), Lexicon.durationLeads.contains(u.norm(start - 1) ?? "") { u.consume(start - 1) }
        if u.isFree(lastEnd), Lexicon.durationTrails.contains(u.norm(lastEnd) ?? "") { u.consume(lastEnd) }
        // Longer than ten years is not a timer or a reminder offset.
        guard total.isFinite, total <= 315_360_000 else { return nil }
        return Int(total.rounded())
    }

    // MARK: Repeat rules

    private func parseRepeat(_ u: inout Utterance, into p: inout TemporalParse) {
        var days: Set<String> = []
        if let i = u.firstIndex(in: Lexicon.repeatWords) {
            p.repeating = true
            u.consume(i)
            // "every monday", "har somvar"
            var j = i + 1
            while u.isFree(j) {
                if let wd = u.norm(j).flatMap({ Lexicon.weekdays[$0] }), let code = Lexicon.weekdayCodes[wd] {
                    days.insert(code)
                    u.consume(j)
                    j += 1
                    if u.isFree(j), ["and", "aur", "और"].contains(u.norm(j) ?? "") { u.consume(j); j += 1 }
                } else { break }
            }
        }
        if let i = u.firstIndex(in: Lexicon.weekdaysOnly) {
            p.repeating = true
            days.formUnion(["mon", "tue", "wed", "thu", "fri"])
            u.consume(i)
        }
        if p.repeating, let i = u.firstIndex(in: Lexicon.weekends) {
            days.formUnion(["sat", "sun"])
            u.consume(i)
        }
        if p.repeating, days.isEmpty { days = Set(Lexicon.allDayCodes) }
        p.repeatDays = Lexicon.allDayCodes.filter(days.contains)
    }

    // MARK: Days and ranges

    private func parseDay(_ u: inout Utterance, direction: TimeDirection, into p: inout TemporalParse) {
        // Phrases first.
        if let i = u.index(ofPhrase: ["day", "after", "tomorrow"]) {
            p.dayStart = addDays(2, to: today)
            u.consume(i..<(i + 3))
            return finishDay(&u, around: i..<(i + 3))
        }
        if let i = u.index(ofPhrase: ["day", "before", "yesterday"]) {
            p.dayStart = addDays(-2, to: today)
            u.consume(i..<(i + 3))
            return finishDay(&u, around: i..<(i + 3))
        }
        if parseRange(&u, direction: direction, into: &p) { return }

        for i in 0..<u.count where u.isFree(i) {
            let w = u.tokens[i].norm
            var day: Date?
            if Lexicon.today.contains(w) { day = today }
            else if Lexicon.tonight.contains(w) { day = today }
            else if Lexicon.tomorrow.contains(w) { day = addDays(1, to: today) }
            else if Lexicon.yesterday.contains(w) { day = addDays(-1, to: today) }
            else if Lexicon.kal.contains(w) { day = addDays(direction == .future ? 1 : -1, to: today) }
            else if Lexicon.parso.contains(w) { day = addDays(direction == .future ? 2 : -2, to: today) }
            if let day {
                p.dayStart = day
                u.consume(i)
                return finishDay(&u, around: i..<(i + 1))
            }
        }
        // Weekdays (not repeating ones; those were consumed already).
        for i in 0..<u.count where u.isFree(i) {
            guard let wd = Lexicon.weekdays[u.tokens[i].norm] else { continue }
            var dir = direction
            var inclusive = false
            var span = i..<(i + 1)
            if i > 0, u.isFree(i - 1) {
                let prev = u.tokens[i - 1].norm
                if Lexicon.nextWords.contains(prev) { dir = .future; span = (i - 1)..<(i + 1) }
                else if Lexicon.lastWords.contains(prev) { dir = .past; span = (i - 1)..<(i + 1) }
                else if Lexicon.thisWords.contains(prev) { dir = .future; inclusive = true; span = (i - 1)..<(i + 1) }
            }
            p.dayStart = nearestWeekday(wd, direction: dir, inclusive: inclusive)
            u.consume(span)
            return finishDay(&u, around: span)
        }
        parseExplicitDate(&u, direction: direction, into: &p)
    }

    /// Eats a connecting word before ("on friday") and after ("friday ko").
    private func finishDay(_ u: inout Utterance, around span: Range<Int>) {
        if span.lowerBound > 0, u.isFree(span.lowerBound - 1), Lexicon.datePrepositions.contains(u.norm(span.lowerBound - 1) ?? "") {
            u.consume(span.lowerBound - 1)
        }
        if u.isFree(span.upperBound), ["ko", "को", "ka", "ki", "ke", "का", "की", "के"].contains(u.norm(span.upperBound) ?? "") {
            u.consume(span.upperBound)
        }
    }

    func nearestWeekday(_ weekday: Int, direction: TimeDirection, inclusive: Bool) -> Date {
        let current = calendar.component(.weekday, from: today)
        switch direction {
        case .future:
            var delta = (weekday - current + 7) % 7
            if delta == 0, !inclusive { delta = 7 }
            return addDays(delta, to: today)
        case .past:
            var delta = (current - weekday + 7) % 7
            if delta == 0 { delta = 7 }
            return addDays(-delta, to: today)
        }
    }

    private func weekInterval(offset: Int) -> DateInterval? {
        guard let base = calendar.dateInterval(of: .weekOfYear, for: addDays(7 * offset, to: today)) else { return nil }
        return base
    }

    private func monthInterval(offset: Int) -> DateInterval? {
        guard let shifted = calendar.date(byAdding: .month, value: offset, to: today) else { return nil }
        return calendar.dateInterval(of: .month, for: shifted)
    }

    private func yearInterval(offset: Int) -> DateInterval? {
        guard let shifted = calendar.date(byAdding: .year, value: offset, to: today) else { return nil }
        return calendar.dateInterval(of: .year, for: shifted)
    }

    private func weekendInterval(direction: TimeDirection, thisOne: Bool) -> DateInterval {
        let current = calendar.component(.weekday, from: today)  // 1 = Sunday ... 7 = Saturday
        let saturday: Date
        if thisOne {
            // The weekend in progress, or the coming one.
            saturday = addDays(current == 1 ? -1 : 7 - current, to: today)
        } else if direction == .past {
            // The last weekend that is over.
            let back = current == 1 ? 8 : (current % 7 == 0 ? 7 : current % 7)
            saturday = addDays(-back, to: today)
        } else {
            let ahead = (7 - current + 7) % 7
            saturday = addDays(ahead == 0 ? 7 : ahead, to: today)
        }
        return DateInterval(start: saturday, end: addDays(2, to: saturday))
    }

    /// "last week", "this month", "pichle hafte", "last 3 days", "last weekend", "is saal".
    private func parseRange(_ u: inout Utterance, direction: TimeDirection, into p: inout TemporalParse) -> Bool {
        for i in 0..<u.count where u.isFree(i) {
            let w = u.tokens[i].norm
            let isNext = Lexicon.nextWords.contains(w)
            let isLast = Lexicon.lastWords.contains(w)
            let isThis = Lexicon.thisWords.contains(w)
            guard isNext || isLast || isThis else { continue }

            // "last 3 days / pichle 2 hafte"
            if isLast, let n = NumberParsing.integer(in: u, at: i + 1), n.value <= 3660, u.isFree(i + 1 + n.length), let unit = u.norm(i + 1 + n.length) {
                let end = i + 1 + n.length + 1
                var days: Int?
                if Lexicon.dayUnits.contains(unit) { days = n.value }
                else if Lexicon.weekUnits.contains(unit) { days = n.value * 7 }
                else if Lexicon.monthUnits.contains(unit) { days = n.value * 30 }
                if let days, days > 0, days <= 3660 {
                    p.range = DateInterval(start: addDays(-days, to: today), end: addDays(1, to: today))
                    u.consume(i..<end)
                    return true
                }
            }
            guard let unit = u.norm(i + 1), u.isFree(i + 1) else { continue }
            let offset = isNext ? 1 : isLast ? -1 : 0
            var interval: DateInterval?
            if Lexicon.weekUnits.contains(unit) { interval = weekInterval(offset: offset) }
            else if Lexicon.monthUnits.contains(unit) { interval = monthInterval(offset: offset) }
            else if Lexicon.yearUnits.contains(unit) { interval = yearInterval(offset: offset) }
            else if Lexicon.weekends.contains(unit) {
                interval = weekendInterval(direction: isLast ? .past : .future, thisOne: isThis)
            }
            if let interval {
                p.range = interval
                u.consume(i..<(i + 2))
                finishDay(&u, around: i..<(i + 2))
                return true
            }
        }
        return false
    }

    /// "12 november", "november 12", "12th nov 2025", "in october", "अक्टूबर में".
    private func parseExplicitDate(_ u: inout Utterance, direction: TimeDirection, into p: inout TemporalParse) {
        for i in 0..<u.count where u.isFree(i) {
            guard let month = Lexicon.months[u.tokens[i].norm] else { continue }
            let name = u.tokens[i].norm
            var dayNumber: Int?
            var span = i..<(i + 1)
            // number before: "12 november", "12th november"
            if i >= 1, u.isFree(i - 1), let d = u.tokens[i - 1].intValue, (1...31).contains(d) {
                dayNumber = d
                span = (i - 1)..<(i + 1)
            } else if i >= 2, u.isFree(i - 1), Lexicon.ordinalSuffixes.contains(u.tokens[i - 1].norm), u.isFree(i - 2),
                      let d = u.tokens[i - 2].intValue, (1...31).contains(d) {
                dayNumber = d
                span = (i - 2)..<(i + 1)
            } else if u.isFree(i + 1), let d = u.tokens[i + 1].intValue, (1...31).contains(d), d < 1000 {
                dayNumber = d
                span = i..<(i + 2)
                if u.isFree(i + 2), Lexicon.ordinalSuffixes.contains(u.norm(i + 2) ?? "") { span = i..<(i + 3) }
            }
            if dayNumber == nil, Lexicon.ambiguousMonths.contains(name) {
                let prev = i > 0 ? u.norm(i - 1) : nil
                guard let prev, ["in", "of", "during", "mein", "में"].contains(prev) else { continue }
            }
            var year: Int?
            let after = span.upperBound
            if u.isFree(after), let y = u.tokens[after].intValue, (1990...2100).contains(y) {
                year = y
                span = span.lowerBound..<(after + 1)
            }
            let nowYear = calendar.component(.year, from: today)
            if let dayNumber {
                func make(_ y: Int) -> Date? {
                    calendar.date(from: DateComponents(year: y, month: month, day: dayNumber))
                }
                var date = make(year ?? nowYear)
                if year == nil, let d = date {
                    if direction == .future, d < today { date = make(nowYear + 1) }
                    if direction == .past, d > today { date = make(nowYear - 1) }
                }
                guard let resolved = date, calendar.component(.day, from: resolved) == dayNumber else { continue }
                p.dayStart = resolved
            } else {
                // A whole month.
                func monthStart(_ y: Int) -> Date? { calendar.date(from: DateComponents(year: y, month: month, day: 1)) }
                var start = monthStart(year ?? nowYear)
                if year == nil, let s = start {
                    if direction == .past, s > today { start = monthStart(nowYear - 1) }
                    if direction == .future, let end = calendar.date(byAdding: .month, value: 1, to: s), end <= today {
                        start = monthStart(nowYear + 1)
                    }
                }
                guard let s = start, let e = calendar.date(byAdding: .month, value: 1, to: s) else { continue }
                p.range = DateInterval(start: s, end: e)
            }
            u.consume(span)
            finishDay(&u, around: span)
            return
        }
    }

    // MARK: Clock times

    private struct Clock { var hour: Int; var minute: Int; var explicit: Bool; var span: Range<Int> }

    private func parseClock(_ u: inout Utterance, allowBareHour: Bool, into p: inout TemporalParse) {
        guard let clock = findClock(u, allowBareHour: allowBareHour) else {
            // "tonight" / "aaj raat" with no clock: nothing to set.
            return
        }
        var hour = clock.hour
        var explicit = clock.explicit
        var span = clock.span
        u.consume(span)

        // A word like "at" in front.
        if span.lowerBound > 0, u.isFree(span.lowerBound - 1), Lexicon.timePrepositions.contains(u.norm(span.lowerBound - 1) ?? "") {
            u.consume(span.lowerBound - 1)
            span = (span.lowerBound - 1)..<span.upperBound
        }
        // am / pm / period of day within two words either side.
        var period: Period?
        let lo = max(0, span.lowerBound - 2), hi = min(u.count, span.upperBound + 2)
        for j in lo..<hi where u.isFree(j) {
            let w = u.tokens[j].norm
            if Lexicon.amWords.contains(w) { period = .am; u.consume(j); explicit = true }
            else if Lexicon.pmWords.contains(w) { period = .pm; u.consume(j); explicit = true }
            else if Lexicon.morning.contains(w) { period = period ?? .morning; u.consume(j) }
            else if Lexicon.afternoon.contains(w) { period = period ?? .afternoon; u.consume(j) }
            else if Lexicon.evening.contains(w) { period = period ?? .evening; u.consume(j) }
            else if Lexicon.night.contains(w) { period = period ?? .night; u.consume(j) }
            else if Lexicon.clockIndicators.contains(w) { u.consume(j) }
        }
        if let period, hour <= 12 || period == .am || period == .pm {
            if let converted = Self.apply(period, to: hour) {
                hour = converted
                explicit = true
            }
        }
        p.hour = hour
        p.minute = clock.minute
        p.hourIsExplicit = explicit
    }

    private enum Period { case am, pm, morning, afternoon, evening, night }

    /// nil when the period does not decide the hour.
    private static func apply(_ period: Period, to hour: Int) -> Int? {
        guard (0...12).contains(hour) else { return hour }
        switch period {
        case .am, .morning: return hour == 12 ? 0 : hour
        case .pm, .afternoon, .evening: return hour == 12 ? 12 : hour + 12
        case .night:
            if hour == 12 { return 0 }
            if hour >= 6 { return hour + 12 }
            return hour  // "raat 2 baje" is 2 am
        }
    }

    private func findClock(_ u: Utterance, allowBareHour: Bool) -> Clock? {
        for i in 0..<u.count where u.isFree(i) {
            let t = u.tokens[i]
            let w = t.norm

            if w == "noon" || w == "midday" { return Clock(hour: 12, minute: 0, explicit: true, span: i..<(i + 1)) }
            if w == "midnight" { return Clock(hour: 0, minute: 0, explicit: true, span: i..<(i + 1)) }

            // "half past 6", "quarter past 6", "quarter to 7"
            if (w == "half" || w == "quarter"), u.isFree(i + 1), let rel = u.norm(i + 1), rel == "past" || (rel == "to" && w == "quarter"),
               let n = NumberParsing.integer(in: u, at: i + 2), (1...12).contains(n.value) {
                let span = i..<(i + 2 + n.length)
                if w == "half" { return Clock(hour: n.value, minute: 30, explicit: false, span: span) }
                if rel == "past" { return Clock(hour: n.value, minute: 15, explicit: false, span: span) }
                return Clock(hour: (n.value + 10) % 12 + 1, minute: 45, explicit: false, span: span)
            }

            // Hindi fractions: "sava 6 baje", "saade paanch baje", "paune saat baje", "dedh baje", "dhai baje"
            if Lexicon.savaWords.contains(w) || Lexicon.saadeWords.contains(w) || Lexicon.pauneWords.contains(w) {
                if let n = NumberParsing.integer(in: u, at: i + 1), (1...12).contains(n.value) {
                    let next = i + 1 + n.length
                    if Lexicon.clockIndicators.contains(u.norm(next) ?? "") || allowBareHour {
                        let span = i..<(next + (Lexicon.clockIndicators.contains(u.norm(next) ?? "") ? 1 : 0))
                        if Lexicon.savaWords.contains(w) { return Clock(hour: n.value, minute: 15, explicit: false, span: span) }
                        if Lexicon.saadeWords.contains(w) { return Clock(hour: n.value, minute: 30, explicit: false, span: span) }
                        return Clock(hour: (n.value + 10) % 12 + 1, minute: 45, explicit: false, span: span)
                    }
                }
            }
            if let f = Lexicon.fractionWords[w], f == 1.5 || f == 2.5, Lexicon.clockIndicators.contains(u.norm(i + 1) ?? "") {
                return Clock(hour: f == 1.5 ? 1 : 2, minute: 30, explicit: false, span: i..<(i + 2))
            }

            // "6:30", "18:45", "06.30"
            if t.isNumeric, w.contains(":") || (w.contains(".") && w.count == 5) {
                let parts = w.split(whereSeparator: { ":.".contains($0) })
                if parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]), (0...24).contains(h), (0...59).contains(m) {
                    let explicit = h > 12 || h == 0 || (parts[0].count == 2 && parts[0].hasPrefix("0"))
                    return Clock(hour: h % 24, minute: m, explicit: explicit, span: i..<(i + 1))
                }
                continue
            }

            // A whole hour: digits or a number word followed by "baje" / am / pm / o'clock, or after "at".
            if let n = NumberParsing.integer(in: u, at: i), (0...24).contains(n.value) {
                let next = i + n.length
                let nextWord = u.isFree(next) ? u.norm(next) : nil
                let prevWord = i > 0 && u.isFree(i - 1) ? u.norm(i - 1) : nil
                if let nextWord, Lexicon.clockIndicators.contains(nextWord) || Lexicon.amWords.contains(nextWord) || Lexicon.pmWords.contains(nextWord) {
                    // "6 baje" may be followed by minutes: "6 bajkar 10 minute" is not handled; keep the hour.
                    return Clock(hour: n.value % 24, minute: 0, explicit: n.value > 12 || n.value == 0, span: i..<(i + n.length))
                }
                if allowBareHour, t.isNumeric, let prevWord, prevWord == "at" || prevWord == "@", (1...24).contains(n.value) {
                    return Clock(hour: n.value % 24, minute: 0, explicit: n.value > 12, span: i..<(i + n.length))
                }
            }
        }
        return nil
    }

    // MARK: Resolving

    /// Turns a parse into one instant. Date-only expressions resolve to `defaultHour` that day.
    func resolveInstant(_ p: TemporalParse, style: AmbiguousHourStyle, defaultHour: Int) -> Date? {
        if let hour = p.hour {
            if let day = p.dayStart {
                let resolvedHour = resolveHour(hour, explicit: p.hourIsExplicit, day: day, style: style, minute: p.minute)
                return calendar.date(bySettingHour: resolvedHour, minute: p.minute, second: 0, of: day)
            }
            return nextOccurrence(hour: hour, minute: p.minute, explicit: p.hourIsExplicit)
        }
        if let day = p.dayStart { return calendar.date(bySettingHour: defaultHour, minute: 0, second: 0, of: day) }
        if let seconds = p.durationSeconds { return now.addingTimeInterval(TimeInterval(seconds)) }
        return nil
    }

    private func resolveHour(_ hour: Int, explicit: Bool, day: Date, style: AmbiguousHourStyle, minute: Int) -> Int {
        if explicit || hour > 12 || hour == 0 { return hour % 24 }
        if calendar.isDate(day, inSameDayAs: today) {
            // Later today, the first of the two readings that is still ahead.
            for candidate in Self.readings(of: hour) {
                if let d = calendar.date(bySettingHour: candidate, minute: minute, second: 0, of: day), d > now { return candidate }
            }
            return Self.readings(of: hour)[0]
        }
        switch style {
        case .morning: return hour == 12 ? 12 : hour
        case .daytime: return (hour == 12 || hour <= 6) ? (hour == 12 ? 12 : hour + 12) : hour
        }
    }

    private static func readings(of hour: Int) -> [Int] {
        hour == 12 ? [12, 0] : [hour, hour + 12]
    }

    /// The next time the clock shows `hour:minute` (am or pm when not explicit).
    private func nextOccurrence(hour: Int, minute: Int, explicit: Bool) -> Date? {
        let hours = (explicit || hour > 12 || hour == 0) ? [hour % 24] : Self.readings(of: hour)
        var best: Date?
        for h in hours {
            guard var d = calendar.date(bySettingHour: h, minute: minute, second: 0, of: today) else { continue }
            if d <= now { d = addDays(1, to: d) }
            if best == nil || d < best! { best = d }
        }
        return best
    }

    /// "HH:MM" local wall-clock time of an instant (device contract format for alarms).
    func clockString(_ date: Date) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    /// ISO-8601 with the zone offset ("2026-11-13T18:00:00+05:30").
    func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = calendar.timeZone
        formatter.formatOptions = [.withInternetDateTime, .withColonSeparatorInTimeZone]
        return formatter.string(from: date)
    }

    /// "yyyy-MM-dd" in the parser's zone.
    func dayString(_ date: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
