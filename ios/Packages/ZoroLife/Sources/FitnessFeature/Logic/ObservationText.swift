import Foundation

/// English sentences for the server's recovery observations. The server sends a code and numbers; these
/// templates are the same words as `backend/app/fitness/observations.py` (a fixture test compares them).
/// Fitness information only: a rule over the owner's own numbers, never a reading of health status.
public enum ObservationText {
    public static func sentence(for observation: FitnessObservation) -> String? {
        let v = observation.values
        func n(_ key: String) -> String? { v[key].map { String(format: "%.0f", $0) } }
        switch observation.code {
        case "rhr_above_baseline":
            guard let days = n("days"), let delta = n("delta") else { return nil }
            return "Your resting heart rate over the last \(days) days is \(delta) bpm above your recent average. "
                + "That often goes with a hard training week or short sleep; an easy day is a common choice."
        case "rhr_below_baseline":
            guard let days = n("days"), let delta = n("delta") else { return nil }
            return "Your resting heart rate over the last \(days) days is \(delta) bpm below your recent average, "
                + "which often goes with good recovery between sessions."
        case "short_sleep_run":
            guard let hours = n("hours"), let nights = n("nights") else { return nil }
            return "You logged under \(hours) hours of sleep on each of the last \(nights) nights; "
                + "shorter sleep usually makes hard sessions feel harder."
        case "load_up":
            guard let pct = n("ratio_pct") else { return nil }
            return "Your exercise minutes this week are \(pct) percent of your recent weekly average; "
                + "a lighter day or two is a common way to absorb a jump like that."
        default:
            return nil
        }
    }

    /// The sentences for every observation this app knows how to word.
    public static func sentences(_ observations: [FitnessObservation]) -> [String] {
        observations.compactMap(sentence(for:))
    }
}

/// Why a figure is missing, and what to do about it.
public enum FitnessUnavailableText {
    public static func sentence(reason: String?) -> String {
        switch reason {
        case "never_synced":
            "Nothing has been synced from Apple Health yet. Allow Health access on your iPhone, then tap Sync now."
        case "no_data_for_date":
            "There is no data for that day. Sync again after your iPhone or watch has recorded it."
        case "no_data_in_window":
            "There is no data in this period yet. Sync again after your iPhone or watch has recorded more."
        case "not_enough_data":
            "There are too few days of data to say anything yet. Keep wearing your watch and sync again in a few days."
        case "no_running_data":
            "No runs have been synced yet. Record a run with your watch or phone, then tap Sync now."
        default:
            "This is not available yet. Tap Sync now, then try again."
        }
    }
}
