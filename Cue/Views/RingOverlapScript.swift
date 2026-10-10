#if DEBUG
import SwiftUI

/// Review's own ring (`TodayRing`) put through changes that come on top of each other faster than a person swipes in
/// the simulator: a word forgotten and others answered while the check is on its way back to the ring, and the day
/// done and undone while the line is still running. Launch with `-ringOverlap YES`; enlarged, to be recorded.
struct RingOverlapScript: View {
    @State private var progress = 0.67

    /// Seconds into the loop, and the progress then.
    private static let script: [(TimeInterval, Double)] = [
        (0.0, 0.67), (0.9, 1.0),
        (3.2, 0.9), (3.6, 0.91), (3.9, 0.85),
        (6.0, 1.0), (6.5, 0.9), (6.8, 1.0),
        (9.0, 0.9),
    ]

    var body: some View {
        TodayRing(progress: progress)
            .scaleEffect(4)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .task {
                while !Task.isCancelled {
                    let start = Date.now
                    for (at, value) in Self.script {
                        try? await Task.sleep(for: .seconds(max(at - Date.now.timeIntervalSince(start), 0)))
                        progress = value
                    }
                    try? await Task.sleep(for: .seconds(2.5))
                }
            }
    }
}

#endif
