//
//  RuleEditorScreen.swift
//  Gate
//
//  V1-2 / V1-5 / V1-6 (docs/04-product-spec.md), build plan step 5.2.
//
//  A rule is a name, a `FamilyActivitySelection`, a mode, an optional window and
//  an on/off state. This screen edits all five, plus the static line the shield
//  shows (V1-6), and commits them as a **sequence of `Mutation`s** so each one is
//  classified on its own: renaming is free, widening a blocklist is free,
//  shrinking one waits out the Lock. The screen shows that verdict *before* the
//  user commits, computed by the same `Ratchet.assess` that will run on save.
//
//  ─────────────────────────────────────────────────────────────────────────────
//  THE 50-TOKEN CAP IS ENFORCED HERE, IN THE UI, ON PURPOSE
//  ─────────────────────────────────────────────────────────────────────────────
//  Each of `shield.applications`, `shield.webDomains`, `shield.applicationCategories`
//  and `shield.webDomainCategories` is capped at 50 tokens, and **the failure is
//  silent**: past the cap the store shields *nothing* and the property reads back
//  `nil` (docs/02-api-reference.md §14, docs/03-hard-constraints.md #34). A rule
//  that looks armed and does nothing is the worst possible outcome for a
//  commitment device, so the count is live while the picker is open, Save is
//  blocked over the cap, and `TokenGuard` re-checks it in the kernel before any
//  write. Three layers, because the API gives no error to catch.
//

import FamilyControls
import SwiftUI
import os

import GateKernel
import GateKernelUI

private var editorLog: Logger {
    Logger(subsystem: GateID.Subsystem.app, category: "RuleEditor")
}

/// One change a save would make, with the `Mutation` that makes it.
///
/// A named struct rather than a tuple because `ForEach(_:id:)` needs a key path
/// and Swift has no key paths into tuple elements. `label` doubles as the
/// identity: two planned changes never share one.
private struct PlannedChange: Identifiable {
    var id: String { label }
    let label: String
    let mutation: Mutation
}

struct RuleEditorScreen: View {

    /// `nil` creates a rule; otherwise it edits that one.
    let ruleID: UUID?

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    // MARK: Draft

    @State private var name = ""
    @State private var mode: RuleMode = .blocklist
    @State private var selection = FamilyActivitySelection()
    @State private var hasSchedule = false
    @State private var startTime = Date()
    @State private var endTime = Date()
    @State private var weekdays: WeekdayMask = .everyday
    @State private var warns = true
    @State private var shieldMessage = ""

    /// The picked selection, encoded once when the picker closes. Encoding early
    /// means the digest that drives every count on screen is the *same* digest
    /// that gets persisted, so the warning the user saw is the warning the kernel
    /// enforces.
    @State private var staged: StagedSelection?

    @State private var originalSelection: FamilyActivitySelection?
    @State private var isPickerPresented = false
    @State private var confirmingDelete = false
    @State private var didLoad = false
    @State private var saveFailure: String?

    /// Identity for a rule that does not exist yet.
    ///
    /// Stable across renders on purpose: `draftRule` is recomputed on every body
    /// evaluation, and minting a fresh `UUID` there would mean the rule that gets
    /// created is not the rule the cost preview was computed for.
    @State private var draftID = UUID()
    @State private var draftCreatedAt = Date()

    private var existingRule: Rule? { ruleID.flatMap { model.rule(id: $0) } }

    var body: some View {
        Form {
            nameSection
            appsSection
            modeSection
            scheduleSection
            shieldSection
            costSection
            if existingRule != nil { deleteSection }
        }
        .scrollContentBackground(.hidden)
        .background(GateTheme.background)
        .navigationTitle(existingRule == nil ? "New rule" : "Edit rule")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
                    .disabled(!canSave)
            }
        }
        .modifier(
            FamilyActivityPickerModifier(
                isPresented: $isPickerPresented,
                selection: $selection,
                title: "Choose what to block",
                headerText: mode == .blocklist
                    ? "Gate will shield everything you pick here."
                    : "Gate will shield everything EXCEPT what you pick here.",
                footerText: "iOS never tells Gate which apps these are. It hands over an "
                    + "opaque handle per app, and that is all Gate ever sees."
            )
        )
        .onChange(of: selection) { _, newValue in
            // Encode as soon as the picker closes so the digest on screen and the
            // digest in `selections.plist` cannot disagree.
            stage(newValue)
        }
        .onAppear(perform: loadOnce)
        .alert(
            "Gate could not save that",
            isPresented: Binding(
                get: { saveFailure != nil },
                set: { if !$0 { saveFailure = nil } }
            ),
            presenting: saveFailure
        ) { _ in
            Button("OK", role: .cancel) { saveFailure = nil }
        } message: { detail in
            Text(detail)
        }
        .confirmationDialog(
            "Delete this rule?",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button(deleteButtonTitle, role: .destructive) { delete() }
            Button("Keep it", role: .cancel) {}
        } message: {
            Text(deleteDialogMessage)
        }
    }

    // MARK: Name

    private var nameSection: some View {
        Section {
            TextField("Name", text: $name)
                .textInputAutocapitalization(.sentences)
                .onChange(of: name) { _, value in
                    if value.count > Rule.maxNameLength {
                        name = String(value.prefix(Rule.maxNameLength))
                    }
                }
        } header: {
            Text("Name")
        } footer: {
            Text("This is what the shield says when you try to open something blocked.")
        }
    }

    // MARK: Apps (V1-2)

    private var appsSection: some View {
        Section {
            Button {
                isPickerPresented = true
            } label: {
                HStack {
                    Label("Choose apps and sites", systemImage: "square.grid.2x2")
                    Spacer()
                    Text(selectionSummary)
                        .font(GateTheme.Typography.footnote)
                        .foregroundStyle(GateTheme.textSecondary)
                }
                .frame(minHeight: GateTheme.Spacing.minimumTapTarget)
            }
            .tint(GateTheme.accent)

            ForEach(TokenCollection.allCases, id: \.self) { collection in
                let count = counts[collection] ?? 0
                if count > 0 || overflow(collection) != nil {
                    TokenCountRow(
                        collection: collection,
                        count: count,
                        limit: GateLimits.maxTokensPerShieldCollection
                    )
                }
            }
        } header: {
            Text("What this rule covers")
        } footer: {
            VStack(alignment: .leading, spacing: GateTheme.Spacing.xs) {
                if let worst = capMessages.first {
                    Text(worst)
                        .foregroundStyle(GateTheme.danger)
                } else if let headroom = tightestHeadroom {
                    Text("Room for \(headroom.remaining) more "
                         + "\(RuleRow.collectionNoun(headroom.collection, plural: headroom.remaining != 1)).")
                }
                Text("Gate never learns the names of what you pick. That is an iOS "
                     + "guarantee, not a Gate policy.")
            }
        }
    }

    // MARK: Mode

    private var modeSection: some View {
        Section {
            Picker("Mode", selection: $mode) {
                Text("Block these").tag(RuleMode.blocklist)
                Text("Allow only these").tag(RuleMode.allowlist)
            }
            .pickerStyle(.segmented)
        } header: {
            Text("Mode")
        } footer: {
            if mode == .blocklist {
                Text("Everything you picked is shielded; everything else is left alone.")
            } else {
                // `.all(except:)` — "block everything except these" without
                // enumerating 50 tokens (docs/02-api-reference.md §6).
                Text("Everything is shielded except what you picked. Switching to this "
                     + "blocks more, so it applies immediately; switching back blocks "
                     + "less and goes through the Lock.")
            }
        }
    }

    // MARK: Schedule (V1-5)

    private var scheduleSection: some View {
        Section {
            Toggle("Only during a window", isOn: $hasSchedule)
                .tint(GateTheme.accent)

            if hasSchedule {
                DatePicker("Starts", selection: $startTime, displayedComponents: .hourAndMinute)
                DatePicker("Ends", selection: $endTime, displayedComponents: .hourAndMinute)
                WeekdayPicker(mask: $weekdays)
                Toggle("Warn me \(RuleSchedule.defaultWarningMinutes) minutes before it ends",
                       isOn: $warns)
                    .tint(GateTheme.accent)
            }
        } header: {
            Text("When")
        } footer: {
            VStack(alignment: .leading, spacing: GateTheme.Spacing.xs) {
                if hasSchedule {
                    if draftSchedule?.crossesMidnight == true {
                        Text("This window crosses midnight. The weekdays above are the days "
                             + "it *starts* on.")
                    }
                    // The honest note V1-5 asks for, verbatim from KernelUI so the
                    // list and the editor cannot drift.
                    Text(RuleRow.scheduleLatencyNote)
                } else {
                    Text("With no window, this rule is in force whenever it is switched on. "
                         + "Adding a window blocks less of the time, so it goes through the "
                         + "Lock; removing one blocks more and is free.")
                }
                ForEach(scheduleIssueMessages, id: \.self) { message in
                    Text(message).foregroundStyle(GateTheme.danger)
                }
            }
        }
    }

    // MARK: Shield copy (V1-6)

    private var shieldSection: some View {
        Section {
            TextField("Why you set this up", text: $shieldMessage, axis: .vertical)
                .lineLimit(1...3)
                .textInputAutocapitalization(.sentences)
                .onChange(of: shieldMessage) { _, value in
                    if value.count > ShieldCopy.maxSubtitleLength {
                        shieldMessage = String(value.prefix(ShieldCopy.maxSubtitleLength))
                    }
                }
        } header: {
            Text("Shield message")
        } footer: {
            // No countdown, no counter, no state: shield configurations are
            // cached and recycled and will render stale (FB14237883,
            // docs/02-api-reference.md §9). `ShieldCopy` structurally cannot hold
            // a date, which is the guarantee — this note just explains it.
            Text("A fixed line shown on the shield, like \u{201C}You said you'd read "
                 + "instead.\u{201D} It cannot change or count down: iOS caches the shield "
                 + "and would show you a stale one.")
        }
    }

    // MARK: What this will cost

    @ViewBuilder
    private var costSection: some View {
        let planned = plannedMutations
        if !planned.isEmpty {
            Section {
                ForEach(planned) { item in
                    VStack(alignment: .leading, spacing: GateTheme.Spacing.xxs) {
                        Text(item.label)
                            .font(GateTheme.Typography.body)
                            .foregroundStyle(GateTheme.textPrimary)
                        LockCostNote(assessment: model.assess(item.mutation))
                    }
                    .padding(.vertical, GateTheme.Spacing.xxs)
                }
            } header: {
                Text("What saving will do")
            } footer: {
                Text("Each change is judged on its own. Some can land now while others "
                     + "wait — that is the point.")
            }
        }
    }

    // MARK: Delete

    private var deleteSection: some View {
        Section {
            Button(role: .destructive) {
                confirmingDelete = true
            } label: {
                Label("Delete this rule", systemImage: "trash")
                    .frame(minHeight: GateTheme.Spacing.minimumTapTarget)
            }
        }
    }

    private var deleteButtonTitle: String {
        guard let ruleID else { return "Delete" }
        return model.assess(.deleteRule(ruleID: ruleID)).goesThroughLock
            ? "Queue the deletion"
            : "Delete"
    }

    private var deleteDialogMessage: String {
        guard let ruleID else { return "" }
        let assessment = model.assess(.deleteRule(ruleID: ruleID))
        guard assessment.goesThroughLock else {
            return "This rule and its shield go away immediately."
        }
        if assessment.releasePaths.hasCountdown, assessment.cost > 0 {
            return "Deleting a rule blocks less, so it goes through the Lock. It will be "
                + "removed in \(GateCountdown.durationText(for: assessment.cost)); until then "
                + "the rule keeps working, and cancelling is free."
        }
        // No countdown: a passphrase-only Lock never ripens on elapsed time.
        return "Deleting a rule blocks less, so it goes through the Lock. It needs the "
            + "partner passphrase; until then the rule keeps working."
    }

    // MARK: - Derived

    private var counts: [TokenCollection: Int] { AppModel.counts(of: selection) }

    private func overflow(_ collection: TokenCollection) -> Int? {
        let count = counts[collection] ?? 0
        return count > GateLimits.maxTokensPerShieldCollection ? count : nil
    }

    /// One sentence per over-cap collection. `TokenGuard` is the authority; this
    /// only turns its errors into copy.
    private var capMessages: [String] {
        TokenGuard.issues(forCounts: counts).compactMap { issue in
            guard case .collectionOverflow(let collection, let count, let limit) = issue else {
                return nil
            }
            return "Too many \(RuleRow.collectionNoun(collection, plural: true)): "
                + "\(count) of \(limit). iOS silently shields nothing past the cap, so "
                + "Gate will not save this."
        }
    }

    private var tightestHeadroom: (collection: TokenCollection, remaining: Int)? {
        TokenCollection.allCases
            .map { ($0, TokenGuard.headroom(after: counts[$0] ?? 0)) }
            .filter { $0.1 >= 0 }
            .min { $0.1 < $1.1 }
            .map { (collection: $0.0, remaining: $0.1) }
    }

    private var selectionSummary: String {
        let total = counts.values.reduce(0, +)
        if total == 0 { return "Nothing yet" }
        return counts
            .sorted { $0.key.rawValue < $1.key.rawValue }
            .filter { $0.value > 0 }
            .map { "\($0.value) \(RuleRow.collectionNoun($0.key, plural: $0.value != 1))" }
            .joined(separator: " \u{00B7} ")
    }

    private var draftSchedule: RuleSchedule? {
        guard hasSchedule else { return nil }
        return RuleSchedule(
            start: timeOfDay(from: startTime),
            end: timeOfDay(from: endTime),
            weekdays: weekdays,
            warningMinutes: warns ? RuleSchedule.defaultWarningMinutes : nil
        )
    }

    /// The rule as it would be after a save, for validation only. Never persisted
    /// from here — `Ratchet` produces the persisted value.
    private var draftRule: Rule {
        Rule(
            id: ruleID ?? draftID,
            name: name,
            mode: mode,
            isEnabled: existingRule?.isEnabled ?? true,
            schedule: draftSchedule,
            selection: staged?.ref ?? existingRule?.selection,
            sortIndex: existingRule?.sortIndex ?? model.state.rules.count,
            createdAt: existingRule?.createdAt ?? draftCreatedAt,
            updatedAt: draftCreatedAt
        )
    }

    private var scheduleIssueMessages: [String] {
        draftSchedule?.validate().compactMap(Self.message(for:)) ?? []
    }

    private var blockingIssues: [RuleIssue] {
        draftRule.validate().filter(\.isBlocking)
    }

    /// The shield line lives in `shield.plist`, not in `GateState`, so it has no
    /// `Mutation` and never appears in `plannedMutations`. Save still has to
    /// notice it, or editing only the shield message would leave the button
    /// permanently disabled.
    private var shieldMessageChanged: Bool {
        guard let rule = existingRule else {
            return !shieldMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return shieldMessage != model.shieldMessage(forRuleID: rule.id)
    }

    private var canSave: Bool {
        model.isOperational
            && blockingIssues.isEmpty
            && capMessages.isEmpty
            && (!plannedMutations.isEmpty || shieldMessageChanged)
    }

    /// The mutations a save would issue, in the order it would issue them.
    ///
    /// Order is deliberate: the mode change lands before the selection change, so
    /// a selection is judged against the mode the user just chose. `Ratchet`
    /// inverts breadth for allowlists — a *wider* allowed set un-blocks an app —
    /// and getting the order backwards would classify that change under the old
    /// mode.
    private var plannedMutations: [PlannedChange] {
        guard didLoad else { return [] }

        guard let rule = existingRule else {
            return [PlannedChange(
                label: "Create \u{201C}\(displayName)\u{201D}",
                mutation: .createRule(draftRule)
            )]
        }

        var planned: [PlannedChange] = []

        if name != rule.name {
            planned.append(PlannedChange(
                label: "Rename to \u{201C}\(displayName)\u{201D}",
                mutation: .renameRule(ruleID: rule.id, name: name)
            ))
        }
        if mode != rule.mode {
            planned.append(PlannedChange(
                label: mode == .allowlist ? "Switch to allow-list" : "Switch to block-list",
                mutation: .setRuleMode(ruleID: rule.id, mode: mode)
            ))
        }
        if draftSchedule != rule.schedule {
            planned.append(PlannedChange(
                label: draftSchedule == nil ? "Remove the window" : "Change the window",
                mutation: .setSchedule(ruleID: rule.id, schedule: draftSchedule)
            ))
        }
        if let staged, staged.ref != rule.selection {
            planned.append(PlannedChange(
                label: "Change what it covers",
                mutation: .setSelection(
                    ruleID: rule.id,
                    selection: staged.ref,
                    // Computed here because the kernel never sees a token
                    // (docs/03-hard-constraints.md #25). `.reshaped` whenever the
                    // answer is not certain, which `Ratchet` treats as a
                    // loosening in both modes.
                    change: AppModel.breadth(from: originalSelection, to: selection)
                )
            ))
        }
        return planned
    }

    private var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? RuleRow.untitledName : trimmed
    }

    // MARK: - Actions

    private func loadOnce() {
        guard !didLoad else { return }
        didLoad = true

        guard let rule = existingRule else {
            name = ""
            mode = .blocklist
            hasSchedule = false
            startTime = Self.date(hour: 9, minute: 0)
            endTime = Self.date(hour: 17, minute: 0)
            return
        }

        name = rule.name
        mode = rule.mode
        shieldMessage = model.shieldMessage(forRuleID: rule.id)

        if let schedule = rule.schedule {
            hasSchedule = true
            startTime = Self.date(hour: schedule.start.hour, minute: schedule.start.minute)
            endTime = Self.date(hour: schedule.end.hour, minute: schedule.end.minute)
            weekdays = schedule.weekdays
            warns = schedule.warningMinutes != nil
        } else {
            startTime = Self.date(hour: 9, minute: 0)
            endTime = Self.date(hour: 17, minute: 0)
        }

        // Re-seeding the picker from what is actually enforced is what makes an
        // edit an edit rather than a fresh pick. A `nil` here means the blob is
        // gone or corrupt, which is a recovery situation (V1-9), not an empty
        // selection — so nothing is cleared.
        if let current = model.currentSelection(forRuleID: rule.id) {
            selection = current
            originalSelection = current
        }
    }

    private func stage(_ newValue: FamilyActivitySelection) {
        guard newValue != originalSelection else {
            staged = nil
            return
        }
        do {
            staged = try AppModel.stage(newValue, now: Date())
        } catch {
            staged = nil
            saveFailure = "Gate could not read that selection back from iOS. "
                + "Try picking again."
        }
    }

    private func save() {
        var queued = 0
        var applied = 0

        for item in plannedMutations {
            guard let outcome = model.apply(
                item.mutation,
                selection: selectionPayload(for: item.mutation)
            ) else {
                saveFailure = "Gate could not save \u{201C}\(item.label)\u{201D}. "
                    + "Nothing was changed."
                return
            }
            if let refusal = outcome.refusal {
                saveFailure = LockCostNote.refusalText(refusal)
                return
            }
            switch outcome.disposition {
            case .queued: queued += 1
            case .applied: applied += 1
            case .noChange, .refused: break
            }
        }

        // Presentation copy only; see `AppModel.setShieldMessage`. `draftID` is
        // the id `.createRule` was built with, so this lands on the new rule
        // without having to guess which one it is.
        model.setShieldMessage(shieldMessage, forRuleID: existingRule?.id ?? draftID)

        // No toast: the pending banner on the home screen is the durable,
        // cancellable record of anything that queued, and a transient alert on
        // top of it would be a second place to look.
        editorLog.log("""
            saved rule: \(applied, privacy: .public) applied, \(queued, privacy: .public) queued
            """)
        dismiss()
    }

    /// The staged blob belongs with the one mutation that references it.
    private func selectionPayload(for mutation: Mutation) -> StagedSelection? {
        switch mutation {
        case .createRule, .setSelection, .reselectSelection: staged
        default: nil
        }
    }

    private func delete() {
        guard let ruleID else { return }
        guard let outcome = model.apply(.deleteRule(ruleID: ruleID)) else {
            saveFailure = "Gate could not save that deletion. Nothing was changed."
            return
        }
        if let refusal = outcome.refusal {
            saveFailure = LockCostNote.refusalText(refusal)
            return
        }
        dismiss()
    }

    // MARK: - Time helpers

    private func timeOfDay(from date: Date) -> TimeOfDay {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        return TimeOfDay(hour: parts.hour ?? 0, minute: parts.minute ?? 0)
    }

    private static func date(hour: Int, minute: Int) -> Date {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date())
        return calendar.date(byAdding: DateComponents(hour: hour, minute: minute), to: start)
            ?? start
    }

    private static func message(for issue: RuleIssue) -> String? {
        switch issue {
        case .scheduleTooShort(_, let minimum):
            "iOS needs a window of at least \(GateCountdown.durationText(for: minimum))."
        case .scheduleTooLong(_, let maximum):
            "iOS needs a window no longer than \(GateCountdown.durationText(for: maximum))."
        case .degenerateSchedule:
            "The start and end times are the same."
        case .scheduleHasNoWeekdays:
            "Pick at least one day."
        case .warningTimeTooLong:
            "The warning would land before the window opens, so Gate will skip it."
        case .emptyName, .nameTooLong, .noSelection, .emptySelection, .tokenCapExceeded:
            nil
        }
    }
}

// MARK: - FamilyActivityPickerModifier

/// The picker, with the iOS 26.2 five-argument modifier where it exists.
///
/// **Always the `.familyActivityPicker(...)` modifier, never a raw
/// `.sheet { FamilyActivityPicker(...) }`** — the raw sheet is a known source of
/// layout bugs (docs/02-api-reference.md §5). The picker runs out of process; the
/// host app never learns what was chosen, which is why every count on this screen
/// comes from the returned token sets rather than from anything nameable.
private struct FamilyActivityPickerModifier: ViewModifier {

    @Binding var isPresented: Bool
    @Binding var selection: FamilyActivitySelection
    let title: String
    let headerText: String
    let footerText: String

    func body(content: Content) -> some View {
        if #available(iOS 26.2, *) {
            content.familyActivityPicker(
                title: title,
                headerText: headerText,
                footerText: footerText,
                isPresented: $isPresented,
                selection: $selection
            )
        } else {
            // The 2-argument form is iOS 15.0 and carries no copy of its own, so
            // the same guidance is rendered above the button instead of inside
            // the sheet. Functionally identical; the picker is the same
            // out-of-process view either way.
            content.familyActivityPicker(
                isPresented: $isPresented,
                selection: $selection
            )
        }
    }
}

// MARK: - TokenCountRow

private struct TokenCountRow: View {

    let collection: TokenCollection
    let count: Int
    let limit: Int

    private var isOver: Bool { count > limit }

    var body: some View {
        HStack {
            Text(RuleRow.collectionNoun(collection, plural: true).capitalized)
                .foregroundStyle(GateTheme.textSecondary)
            Spacer()
            Text("\(count) / \(limit)")
                .font(GateTheme.Typography.numeric)
                .foregroundStyle(isOver ? GateTheme.danger : GateTheme.textPrimary)
            if isOver {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(GateTheme.danger)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            isOver
                ? "\(count) \(RuleRow.collectionNoun(collection, plural: true)), over the limit of \(limit)"
                : "\(count) of \(limit) \(RuleRow.collectionNoun(collection, plural: true))"
        )
    }
}

// MARK: - WeekdayPicker

/// Weekday scoping (V1-5).
///
/// One `DeviceActivityName` per rule, never one per weekday: a name per
/// rule-per-weekday blows the 20-activity cap at rule #3, so the mask is carried
/// in `RuleSchedule` and checked when the interval fires
/// (docs/05-architecture.md, activity budget).
private struct WeekdayPicker: View {

    @Binding var mask: WeekdayMask

    /// Calendar weekday numbers, Sunday == 1, in the user's own week order.
    private var orderedWeekdays: [Int] {
        let first = Calendar.current.firstWeekday
        return (0..<7).map { ((first - 1 + $0) % 7) + 1 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: GateTheme.Spacing.s) {
            HStack(spacing: GateTheme.Spacing.xs) {
                ForEach(orderedWeekdays, id: \.self) { weekday in
                    let isOn = mask.contains(calendarWeekday: weekday)
                    Button {
                        toggle(weekday)
                    } label: {
                        Text(Self.symbol(for: weekday))
                            .font(GateTheme.Typography.chip)
                            .frame(maxWidth: .infinity, minHeight: GateTheme.Spacing.minimumTapTarget)
                    }
                    .buttonStyle(.plain)
                    .background(
                        RoundedRectangle(cornerRadius: GateTheme.Radius.control, style: .continuous)
                            .fill(isOn ? GateTheme.accent : GateTheme.surface)
                    )
                    .foregroundStyle(isOn ? GateTheme.onAccent : GateTheme.textSecondary)
                    .accessibilityLabel(Self.accessibleName(for: weekday))
                    .accessibilityAddTraits(isOn ? [.isSelected, .isButton] : .isButton)
                }
            }

            HStack(spacing: GateTheme.Spacing.s) {
                Button("Every day") { mask = .everyday }
                Button("Weekdays") { mask = .workweek }
                Button("Weekends") { mask = .weekend }
            }
            .font(GateTheme.Typography.footnote)
            .buttonStyle(.bordered)
            .tint(GateTheme.accent)
        }
        .padding(.vertical, GateTheme.Spacing.xs)
    }

    private func toggle(_ weekday: Int) {
        let bit = WeekdayMask(calendarWeekday: weekday)
        if mask.contains(calendarWeekday: weekday) {
            mask.subtract(bit)
        } else {
            mask.formUnion(bit)
        }
    }

    private static func symbol(for weekday: Int) -> String {
        let symbols = Calendar.current.veryShortWeekdaySymbols
        let index = weekday - 1
        guard symbols.indices.contains(index) else { return "?" }
        return symbols[index]
    }

    private static func accessibleName(for weekday: Int) -> String {
        let symbols = Calendar.current.weekdaySymbols
        let index = weekday - 1
        guard symbols.indices.contains(index) else { return "Day \(weekday)" }
        return symbols[index]
    }
}
