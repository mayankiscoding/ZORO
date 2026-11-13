// UNVERIFIED-ON-HOST
// Lock Screen and Dynamic Island presentation of ZoroTaskActivityAttributes.
// Checked against Apple's documentation: ActivityConfiguration(for:content:dynamicIsland:),
// ActivityViewContext.state / .attributes, DynamicIsland(expanded:compactLeading:compactTrailing:minimal:),
// DynamicIslandExpandedRegion(_:content:), .keylineTint(_:), .widgetURL(_:).
#if os(iOS) && canImport(ActivityKit)
import ActivityKit
import SwiftUI
import WidgetKit

struct AgentTaskLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ZoroTaskActivityAttributes.self) { context in
            VStack(alignment: .leading, spacing: 6) {
                Text(context.attributes.request).font(.headline).lineLimit(1)
                Text(context.state.status).font(.subheadline).lineLimit(2)
                if !context.state.agents.isEmpty {
                    Text(context.state.agents.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding()
            .accessibilityElement(children: .combine)
            .widgetURL(URL(string: "zoro://section/activity"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: context.state.needsApproval ? "hand.raised" : "circle.circle")
                        .accessibilityLabel(context.state.needsApproval ? "Needs your approval" : "ZORO is working")
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.state.status).font(.subheadline).lineLimit(2)
                }
            } compactLeading: {
                Image(systemName: "circle.circle").accessibilityLabel("ZORO")
            } compactTrailing: {
                Image(systemName: context.state.needsApproval ? "hand.raised" : "ellipsis")
                    .accessibilityLabel(context.state.needsApproval ? "Needs your approval" : "Working")
            } minimal: {
                Image(systemName: "circle.circle").accessibilityLabel("ZORO")
            }
            .widgetURL(URL(string: "zoro://section/activity"))
        }
    }
}
#endif
