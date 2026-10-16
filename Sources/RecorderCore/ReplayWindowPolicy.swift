import Foundation

/// Bound both the retained recording and its small segment-boundary overlap.
public enum ReplayWindowPolicy {
    public static let minuteOptions = [1, 2, 5, 10, 15, 30]
    public static let segmentDuration: TimeInterval = 15

    public static func minutes(_ stored: Int) -> Int {
        minuteOptions.contains(stored) ? stored : 10
    }

    public static func retainedRange(end: TimeInterval, duration: TimeInterval) -> Range<TimeInterval> {
        let end = end.isFinite ? max(end, 0) : 0
        let duration = duration.isFinite ? max(duration, 0) : 0
        return max(0, end - duration)..<end
    }

    public static func shouldRetain(segmentEnd: TimeInterval, latestTime: TimeInterval,
                                    duration: TimeInterval) -> Bool {
        segmentEnd > max(0, latestTime - duration)
    }
}
