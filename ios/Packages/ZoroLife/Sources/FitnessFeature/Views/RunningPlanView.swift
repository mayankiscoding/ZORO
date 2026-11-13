import LifeSupport
import SwiftUI
import ZoroDesign

/// The running-plan builder: goal, length, days a week and current weekly distance in; a week-by-week plan out, with the rules the
/// server used and every assumption it had to make.
struct RunningPlanView: View {
    @Bindable var model: RunningPlanViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ZoroSpace.xl.value) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Running plan").zoroText(.title).accessibilityAddTraits(.isHeader)
                    Spacer()
                    Button("Done") { dismiss() }.buttonStyle(.zoroLink)
                }
                form
                result
                Text(FitnessCardModel.disclaimer).zoroText(.caption).foregroundStyle(.secondary)
            }
            .padding(ZoroSpace.l.value)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(ZoroNeutral.background)
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 560)
        #endif
    }

    private var form: some View {
        ZoroCard {
            VStack(alignment: .leading, spacing: ZoroSpace.l.value) {
                Picker("Goal", selection: $model.goal) {
                    ForEach(RunningGoal.allCases) { Text($0.title).tag($0) }
                }
                Stepper(value: $model.daysPerWeek, in: RunningPlanRequest.daysRange) {
                    Text("Run \(model.daysPerWeek) days a week")
                }
                Toggle("Choose how many weeks", isOn: Binding(get: { model.weeks != nil }, set: { model.weeks = $0 ? 8 : nil }))
                if let weeks = model.weeks {
                    Stepper(
                        value: Binding(get: { weeks }, set: { model.weeks = $0 }), in: RunningPlanRequest.weeksRange
                    ) { Text("\(weeks) weeks") }
                } else {
                    Text("The plan uses the usual length for this goal.").zoroText(.caption).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: ZoroSpace.xs.value) {
                    Text("Distance you run now, in km a week").zoroText(.detail)
                    TextField("Leave empty to use your synced runs", text: $model.currentKmText)
                        #if os(iOS)
                        .keyboardType(.decimalPad)
                        #endif
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Kilometres you run each week now")
                }
                ForEach(model.problems, id: \.self) { problem in
                    Label(problem, systemImage: "exclamationmark.circle").zoroText(.detail)
                        .foregroundStyle(ZoroRole.critical.hue.color(scheme: scheme, contrast: .increased))
                }
                Button("Build plan") { Task { await model.build() } }
                    .buttonStyle(.zoroPrimary).disabled(!model.canBuild).frame(maxWidth: 320)
            }
        }
    }

    @Environment(\.colorScheme) private var scheme

    @ViewBuilder private var result: some View {
        switch model.plan {
        case .idle:
            ZoroStateView(.empty, message: "Choose a goal and tap Build plan. The plan lists its rules and what it assumed.")
        case .loading:
            ZoroStateView(.loading, message: "Building your plan.")
        case .failed(let failure):
            ZoroStateView(
                failure.kind == .disconnected ? .disconnected : .error, message: failure.message,
                action: failure.retryable ? ZoroStateAction("Try again") { Task { await model.build() } } : nil)
        case .loaded(let out):
            if let plan = out.plan, out.sourcing.available {
                PlanResultView(plan: plan, sourcing: out.sourcing, now: model.now)
            } else {
                ZoroStateView(.empty, message: FitnessUnavailableText.sentence(reason: out.sourcing.reason))
            }
        }
    }
}

struct PlanResultView: View {
    let plan: RunningPlan
    let sourcing: FitnessSourcing
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: ZoroSpace.l.value) {
            ZoroSectionHeader(PlanPresenter.goalTitle(plan.goal), detail: "\(plan.weeks.count) weeks, \(plan.daysPerWeek) runs a week")
            ZoroCard {
                VStack(alignment: .leading, spacing: ZoroSpace.s.value) {
                    Text(PlanPresenter.startBasisSentence(plan)).zoroText(.body)
                    if !plan.reachesTargetDistance {
                        Label("In this many weeks the longest run stops short of \(LifeFormat.number(plan.raceKm, places: 1)) km. A longer plan gets you there.", systemImage: "info.circle")
                            .zoroText(.detail)
                    }
                    ForEach(plan.assumptions, id: \.self) { Text($0).zoroText(.detail).foregroundStyle(.secondary) }
                }
            }
            ForEach(plan.weeks) { week in
                ZoroCard {
                    VStack(alignment: .leading, spacing: ZoroSpace.s.value) {
                        Text(PlanPresenter.weekTitle(week)).zoroText(.heading)
                        ForEach(week.sessions) { session in
                            Text(PlanPresenter.sessionLine(session)).zoroText(.detail).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            ZoroSectionHeader("Rules the plan follows")
            ZoroCard {
                VStack(alignment: .leading, spacing: ZoroSpace.s.value) {
                    ForEach(plan.rules, id: \.self) { Text($0).zoroText(.detail) }
                    ForEach(plan.notes, id: \.self) { Text($0).zoroText(.detail).foregroundStyle(.secondary) }
                }
            }
            FreshnessFooter(source: sourcing.dataSource, freshness: sourcing.freshness, now: now)
        }
    }
}
