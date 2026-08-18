import ActivityKit
import SwiftUI
import WidgetKit

@main
struct DoNotTypeActivityWidgetBundle: WidgetBundle {
    var body: some Widget {
        DictationLiveActivityWidget()
    }
}

struct DictationLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DictationActivityAttributes.self) { context in
            HStack(spacing: 14) {
                Image(systemName: context.state.phase.systemImage)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(tint(for: context.state.phase))
                    .symbolEffect(.pulse, isActive: context.state.phase != .ready)

                VStack(alignment: .leading, spacing: 3) {
                    Text("DoNotType · \(context.state.phase.label)")
                        .font(.headline)
                    Text(context.state.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let readyUntil = context.state.readyUntil {
                        Text(timerInterval: Date()...readyUntil, countsDown: true)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal)
            .activityBackgroundTint(Color(.secondarySystemBackground))
            .activitySystemActionForegroundColor(.primary)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: context.state.phase.systemImage)
                        .foregroundStyle(tint(for: context.state.phase))
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.phase.label).font(.headline)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.state.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } compactLeading: {
                Image(systemName: "mic.fill")
                    .foregroundStyle(tint(for: context.state.phase))
            } compactTrailing: {
                Image(systemName: context.state.phase.systemImage)
            } minimal: {
                Image(systemName: context.state.phase.systemImage)
                    .foregroundStyle(tint(for: context.state.phase))
            }
            .keylineTint(tint(for: context.state.phase))
        }
    }

    private func tint(
        for phase: DictationActivityAttributes.ContentState.Phase
    ) -> Color {
        switch phase {
        case .listening: .red
        case .transcribing: .orange
        case .ready: .blue
        }
    }
}
