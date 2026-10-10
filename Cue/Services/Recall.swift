import Foundation

/// When each word comes up in review: FSRS-6, the Free Spaced Repetition Scheduler, the most accurate open model of
/// forgetting (Anki has it built in), with its published default parameters. Each word keeps how firmly it is held
/// (stability: the days until the chance of recalling it falls to 90%) and how hard it is (difficulty, 1–10); with
/// the time since it was last seen, they give the chance it is remembered now, and review shows the word most likely
/// forgotten. The user never sees any of it: review has no counts and no end (user, 2026-10-07: "我们自己…单词什么时候
/// 出现是有科学的这个方法来计算的"). Checked on the day: remembered whenever due, a word's intervals run 2.3, 11.9, 50,
/// 174 days; twenty more reviews the same day leave it as firmly held as one; a 30-day word forgotten drops to 2.4.
enum Recall {
    struct State: Codable, Hashable {
        var stability: Double
        var difficulty: Double
        var reviewedAt: Date
        /// Not remembered the last time it came up, and not since: review owes it until it is. Nil in states kept
        /// before review knew (2026-10-10).
        var forgotten: Bool?
    }

    /// The chance of recall below which a word is due: FSRS's usual 90%.
    static let dueBelow = 0.9

    /// Whether a word is to be reviewed now: forgotten and not remembered since, or more likely forgotten than
    /// `dueBelow` allows.
    static func isDue(_ state: State?, since saved: Date, at now: Date) -> Bool {
        state?.forgotten == true || chance(of: state, since: saved, at: now) < dueBelow
    }

    /// When review's day began: at 4 in the morning, as Anki's does, so a review late at night counts for the day it
    /// belongs to.
    static func dayStart(at now: Date) -> Date {
        let calendar = Calendar.current
        let shifted = calendar.date(byAdding: .hour, value: -4, to: now) ?? now
        return calendar.date(byAdding: .hour, value: 4, to: calendar.startOfDay(for: shifted)) ?? now
    }

    /// FSRS-6's defaults, w0…w20 (open-spaced-repetition, "The Algorithm").
    private static let w: [Double] = [0.212, 1.2931, 2.3065, 8.2956, 6.4133, 0.8334, 3.0194, 0.001, 1.8722, 0.1666,
                                      0.796, 1.4835, 0.0614, 0.2629, 1.6483, 0.6014, 1.8729, 0.5425, 0.0912, 0.0658,
                                      0.1542]
    private static let decay = -w[20]
    /// Makes the chance of recall exactly 90% after `stability` days.
    private static let factor = pow(0.9, 1 / decay) - 1

    /// The chance of recalling a word `days` after it was last seen.
    static func chance(days: Double, stability: Double) -> Double {
        pow(1 + factor * max(days, 0) / stability, decay)
    }

    /// The chance the word is remembered now. A word never reviewed counts as seen once, and not known, when it was
    /// added (it was looked up because it wasn't): one added a day ago comes up before one added a minute ago.
    static func chance(of word: Word, at now: Date) -> Double {
        chance(of: word.recall, since: word.createdAt, at: now)
    }

    /// The same, from a word's state as review keeps it, and when the word was saved.
    static func chance(of state: State?, since saved: Date, at now: Date) -> Double {
        if let state {
            return chance(days: now.timeIntervalSince(state.reviewedAt) / 86_400, stability: state.stability)
        }
        return chance(days: now.timeIntervalSince(saved) / 86_400, stability: w[0])
    }

    /// The state after a review. Review asks only whether the word was remembered: FSRS's Good (3) or Again (1).
    static func reviewed(_ state: State?, remembered: Bool, at now: Date) -> State {
        let g: Double = remembered ? 3 : 1
        guard let state else {
            return State(stability: w[remembered ? 2 : 0], difficulty: clamped(initialDifficulty(g)), reviewedAt: now,
                         forgotten: !remembered)
        }
        let s = state.stability, d = state.difficulty
        let days = now.timeIntervalSince(state.reviewedAt) / 86_400
        var stability: Double
        if days < 1 {
            // Again the same day: remembering it then adds next to nothing, and less the firmer it is held.
            var increase = exp(w[17] * (g - 3 + w[18])) * pow(s, -w[19])
            if remembered { increase = max(increase, 1) }
            stability = s * increase
        } else {
            let r = chance(days: days, stability: s)
            if remembered {
                stability = s * (1 + exp(w[8]) * (11 - d) * pow(s, -w[9]) * (exp((1 - r) * w[10]) - 1))
            } else {
                let longTerm = w[11] * pow(d, -w[12]) * (pow(s + 1, w[13]) - 1) * exp((1 - r) * w[14])
                stability = min(longTerm, s / exp(w[17] * w[18]))
            }
        }
        // Harder for each word forgotten, with a pull towards the easiest a word starts as.
        let damped = d - w[6] * (g - 3) * (10 - d) / 9
        let difficulty = clamped(w[7] * initialDifficulty(4) + (1 - w[7]) * damped)
        return State(stability: max(stability, 0.001), difficulty: difficulty, reviewedAt: now, forgotten: !remembered)
    }

    private static func initialDifficulty(_ g: Double) -> Double { w[4] - exp(w[5] * (g - 1)) + 1 }
    private static func clamped(_ difficulty: Double) -> Double { min(max(difficulty, 1), 10) }
}
