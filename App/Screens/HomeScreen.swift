//
//  HomeScreen.swift
//  Gate
//
//  V1-2 / V1-4 / V1-8 / V1-10 (docs/04-product-spec.md), build plan step 5.4.
//
//  The rule list, the persistent pending-changes banner with its live countdown,
//  the live grants, install protection, and the routes to everything else.
//
//  Two things this screen is careful about:
//
//  * **No ticking timer.** `PendingBanner` and `RuleRow` each drive their own
//    `TimelineView` through `GateCountdownSchedule`, which fires exactly when the
//    displayed string changes rather than once a second. A boundary passing calls
//    back into a reconcile, which updates `GateState`, which re-renders the row.
//  * **Every control shows its cost before the tap.** `Ratchet.assess` is pure
//    and cheap, so the lock glyph on a row, the confirmation on a toggle and the
//    wording of a destructive button are all derived from the same classification
//    that will run when the user commits. What the screen promises and what the
//    kernel does cannot drift.
//

import SwiftUI

import GateKernel
import GateKernelUI

struct HomeScreen: View {

    @Environment(AppModel.self) private var model

    @State private var path: [HomeRoute] = []
    @State private var passwordPrompt: PasswordPrompt?
    @State private var confirmingTeardown = false
    @State private var now = Date()

    var body: some View {
        // `refreshable(action:)` takes a `@Sendable` closure, which does not
        // inherit this view's main-actor isolation. Capturing the `AppModel`
        // value — a `@MainActor` class, and therefore `Sendable` — is what makes
        // the pull-to-refresh below well-typed without reaching through `self`.
        let model = self.model

        return NavigationStack(path: $path) {
            List {
                pendingSection
                rulesSection
                grantsSection
                protectionSection
                maintenanceSection
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(GateTheme.background)
            .navigationTitle("Gate")
            .toolbar { toolbar }
            .navigationDestination(for: HomeRoute.self) { route in
                destination(for: route)
            }
            .refreshable {
                await model.activate(trigger: .foreground)
            }
        }
        .sheet(item: $passwordPrompt) { prompt in
            PartnerPasswordSheet(prompt: prompt)
                .environment(model)
        }
        .confirmationDialog(
            "Remove every block Gate has applied?",
            isPresented: $confirmingTeardown,
            titleVisibility: .visible
        ) {
            Button("Remove everything", role: .destructive) {
                model.tearDownEverything()
            }
            Button("Keep my blocks", role: .cancel) {}
        } message: {
            Text("This clears every shield, stops every schedule and deletes Gate's rules "
                 + "from this device. The Lock's deadline lives in the Keychain and is erased "
                 + "too. Nothing here is recoverable.")
        }
        .onAppear { now = Date() }
    }

    // MARK: Pending changes (V1-4)

    @ViewBuilder
    private var pendingSection: some View {
        let open = model.openChanges
        if !open.isEmpty {
            Section {
                PendingBanner(
                    changes: open,
                    lock: model.state.lock,
                    now: now,
                    ruleNames: model.ruleNames,
                    onCancel: { change in
                        // Cancelling is itself a tightening and is free (V1-4).
                        cancel(change)
                    },
                    onEnterPassword: {
                        if let first = PendingBanner.ordered(open).first {
                            passwordPrompt = PasswordPrompt(changeID: first.id)
                        }
                    },
                    onDeadlineElapsed: {
                        // A ripe change is folded in by the reconciler, not by
                        // the banner. Asking for one is the whole job here.
                        refresh()
                    }
                )
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }
        }
    }

    // MARK: Rules (V1-2)

    private var rulesSection: some View {
        Section {
            ForEach(model.state.rules) { rule in
                RuleRow(
                    rule: rule,
                    now: now,
                    hasPendingChange: model.openChanges.contains { $0.ruleID == rule.id },
                    disablingGoesThroughLock: model.disablingGoesThroughLock(ruleID: rule.id),
                    onSetEnabled: { enabled in
                        // The row's switch is not mirrored into `@State`: if this
                        // queues instead of applying, the binding reads
                        // `rule.isEnabled` again on the next render and the switch
                        // snaps back — which is the truth, because the rule is
                        // still enforcing.
                        setRuleEnabled(rule.id, enabled)
                    },
                    onSelect: { path.append(.rule(rule.id)) },
                    onBoundaryPassed: { refresh() }
                )
                .listRowBackground(GateTheme.surface)
            }

            if model.state.rules.count < GateLimits.maxRules {
                Button {
                    path.append(.newRule)
                } label: {
                    Label("New rule", systemImage: "plus.circle.fill")
                        .frame(minHeight: GateTheme.Spacing.minimumTapTarget)
                }
                .tint(GateTheme.accent)
                .disabled(!model.isOperational)
                .listRowBackground(GateTheme.surface)
            }
        } header: {
            Text("Rules")
        } footer: {
            VStack(alignment: .leading, spacing: GateTheme.Spacing.xs) {
                if model.state.rules.isEmpty {
                    Text("Nothing is blocked yet.")
                }
                // V1-5's honest note, rendered once under the list. Apple's
                // documented behaviour, not a bug: intervals begin when the
                // device is first used inside the window
                // (docs/03-hard-constraints.md #27).
                Text(RuleRow.scheduleLatencyNote)
                if model.state.rules.count >= GateLimits.maxRules {
                    Text("Gate caps rules at \(GateLimits.maxRules) so it stays inside "
                         + "iOS's limits on stores and schedules.")
                }
            }
        }
    }

    // MARK: Grants (V1-7)

    @ViewBuilder
    private var grantsSection: some View {
        let grants = model.activeGrants(at: now)
        let budget = model.grantBudget(at: now)

        Section {
            ForEach(grants) { grant in
                GrantRow(
                    grant: grant,
                    now: now,
                    ruleName: model.ruleNames[grant.ruleID],
                    // Ending a grant early is a tightening: free, immediate, and
                    // the fast "this was wrong" path the false-positive design
                    // calls for (docs/03-hard-constraints.md #35).
                    onRevoke: { model.revokeGrant(id: grant.id) },
                    // A grant that runs out while the list is on screen should
                    // leave it. The countdown already knows the instant.
                    onExpired: { refresh() }
                )
                .listRowBackground(GateTheme.surface)
            }

            HStack {
                Text("Unblocks left today")
                    .foregroundStyle(GateTheme.textSecondary)
                Spacer()
                Text("\(budget.remaining) of \(budget.limit)")
                    .font(GateTheme.Typography.numeric)
                    .foregroundStyle(budget.isExhausted ? GateTheme.danger : GateTheme.textPrimary)
            }
            .listRowBackground(GateTheme.surface)
        } header: {
            Text(grants.isEmpty ? "Unblocks" : "Unblocked right now")
        } footer: {
            if budget.isExhausted {
                // Running out is a tightening: no lock, no wait, no appeal.
                Text("You are out of unblocks for today. They come back at midnight — "
                     + "there is no way to buy more, on purpose.")
            } else {
                Text("Each unblock is time-boxed and scoped to the app you asked for. "
                     + "Gate cannot open that app for you; you press Home and tap it.")
            }
        }
    }

    // MARK: Install protection (V1-8, "Solid")

    private var protectionSection: some View {
        let assessment = model.assess(.setInstallProtection(enabled: !model.state.installProtectionEnabled))

        return Section {
            Toggle(isOn: Binding(
                get: { model.state.installProtectionEnabled },
                set: { setInstallProtection($0) }
            )) {
                VStack(alignment: .leading, spacing: GateTheme.Spacing.xxs) {
                    HStack(spacing: GateTheme.Spacing.xs) {
                        Text("Block new app installs")
                        if assessment.goesThroughLock {
                            Image(systemName: "lock.fill")
                                .font(GateTheme.Typography.caption)
                                .foregroundStyle(GateTheme.pending)
                                .accessibilityLabel("Turning this off goes through the Lock")
                        }
                    }
                    Text("No new apps can be installed while this is on.")
                        .font(GateTheme.Typography.footnote)
                        .foregroundStyle(GateTheme.textSecondary)
                }
            }
            .tint(GateTheme.accent)
            .disabled(!model.isOperational)
            .listRowBackground(GateTheme.surface)
        } header: {
            Text("Solid")
        } footer: {
            // Exactly what it is, and exactly what it is not. There is no
            // install-event callback on iOS, so there is no "Smart" mode to
            // ship (V1-8) — and `denyAppRemoval` is device-wide, honored only
            // under `.child`, and has been reported to get stuck on after
            // uninstall (docs/03-hard-constraints.md #15). Gate never writes it.
            Text("Turning this on is free. Turning it off goes through the Lock. "
                 + "It does not stop apps being deleted, and it does not stop Gate "
                 + "being deleted.")
        }
    }

    // MARK: Maintenance

    private var maintenanceSection: some View {
        Section {
            Button {
                // V1-9 is a first-class screen, not an error path. The user is
                // the most reliable detector of a rule that silently stopped
                // working, so they always have a way in.
                model.recovery = .userReported
            } label: {
                Label("A rule stopped working", systemImage: "arrow.triangle.2.circlepath")
                    .frame(minHeight: GateTheme.Spacing.minimumTapTarget)
            }
            .tint(GateTheme.accent)
            .listRowBackground(GateTheme.surface)

            Button(role: .destructive) {
                confirmingTeardown = true
            } label: {
                Label("Remove everything", systemImage: "trash")
                    .frame(minHeight: GateTheme.Spacing.minimumTapTarget)
            }
            .listRowBackground(GateTheme.surface)
        } header: {
            Text("If something looks wrong")
        } footer: {
            // hard-constraints #37: shields can persist after the app is deleted
            // with no UI anywhere to remove them. This button is the remedy, and
            // it is deliberately reachable without waiting out the Lock.
            Text("Removing everything is not gated by the Lock. Trapping you behind "
                 + "shields you can no longer manage would be worse than letting you quit.")
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button {
                    path.append(.lock)
                } label: {
                    Label("The Lock", systemImage: "lock")
                }
                Button {
                    path.append(.stats)
                } label: {
                    Label("Screen time", systemImage: "chart.bar")
                }
                #if DEBUG
                Button {
                    path.append(.debug)
                } label: {
                    Label("Debug", systemImage: "ladybug")
                }
                #endif
            } label: {
                Image(systemName: "ellipsis.circle")
                    .accessibilityLabel("More")
            }
        }
    }

    @ViewBuilder
    private func destination(for route: HomeRoute) -> some View {
        switch route {
        case .newRule:
            RuleEditorScreen(ruleID: nil)
        case .rule(let id):
            RuleEditorScreen(ruleID: id)
        case .lock:
            LockSettingsScreen()
        case .stats:
            StatsScreen()
        case .debug:
            debugDestination
        }
    }

    /// Conditional compilation at *declaration* level, not inside the
    /// `@ViewBuilder` switch: `HomeRoute` then stays exhaustive in both
    /// configurations without the route itself needing an `#if`.
    #if DEBUG
    private var debugDestination: some View { DebugScreen() }
    #else
    private var debugDestination: some View { EmptyView() }
    #endif

    // MARK: Mutations

    // Each of these is a `Void`-returning method rather than a closure body, so
    // the discarded `Ratchet.Outcome` is unambiguously a statement. They are also
    // the only places this screen touches durable state, which makes the list of
    // things the home screen can change one screenful long.

    private func cancel(_ change: PendingChange) {
        model.apply(.cancelPendingChange(id: change.id))
    }

    private func setRuleEnabled(_ ruleID: UUID, _ enabled: Bool) {
        model.apply(.setRuleEnabled(ruleID: ruleID, enabled: enabled))
    }

    private func setInstallProtection(_ enabled: Bool) {
        model.apply(.setInstallProtection(enabled: enabled))
    }

    private func refresh() {
        now = Date()
        model.reconcile(trigger: .userAction)
    }
}

// MARK: - Routes

enum HomeRoute: Hashable {
    case newRule
    case rule(UUID)
    case lock
    case stats
    case debug
}

// MARK: - GrantRow

private struct GrantRow: View {

    let grant: Grant
    let now: Date
    let ruleName: String?
    let onRevoke: () -> Void
    let onExpired: () -> Void

    var body: some View {
        HStack(spacing: GateTheme.Spacing.m) {
            GateStatusDot(tone: .pending)

            VStack(alignment: .leading, spacing: GateTheme.Spacing.xxs) {
                Text(ruleName ?? "A deleted rule")
                    .font(GateTheme.Typography.body)
                    .foregroundStyle(GateTheme.textPrimary)

                CountdownView(
                    deadline: grant.expiresAt,
                    style: .inline,
                    granularity: .seconds,
                    prefix: "Unblocked for another",
                    elapsedText: "re-blocking now",
                    onElapsed: onExpired
                )
                .foregroundStyle(GateTheme.textSecondary)

                if let reason = grant.reason, !reason.isEmpty {
                    Text("\u{201C}\(reason)\u{201D}")
                        .font(GateTheme.Typography.footnote)
                        .foregroundStyle(GateTheme.textTertiary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: GateTheme.Spacing.s)

            Button("End now", action: onRevoke)
                .font(GateTheme.Typography.callout)
                .buttonStyle(.bordered)
                .tint(GateTheme.accent)
        }
        .padding(.vertical, GateTheme.Spacing.xs)
    }
}

// MARK: - PartnerPasswordSheet

struct PasswordPrompt: Identifiable, Hashable {
    let changeID: UUID
    var id: UUID { changeID }
}

/// Releases one queued change with the partner passphrase (V1-3).
///
/// A separate release path, never a second deadline: a failed attempt cannot
/// shorten the wait, and a successful one leaves no trace on the clock.
struct PartnerPasswordSheet: View {

    let prompt: PasswordPrompt

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var password = ""
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("Passphrase", text: $password)
                        .textContentType(.password)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("Partner passphrase")
                } footer: {
                    if let hint = model.state.lock.password?.hint, !hint.isEmpty {
                        Text("Hint: \(hint)")
                    } else {
                        Text("Whoever set this passphrase can release the change now. "
                             + "Otherwise it lands when the countdown runs out.")
                    }
                }

                if let failure {
                    Section {
                        Text(failure)
                            .font(GateTheme.Typography.footnote)
                            .foregroundStyle(GateTheme.danger)
                    }
                }
            }
            .navigationTitle("Release early")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Release") { attempt() }
                        .disabled(password.isEmpty)
                }
            }
        }
    }

    private func attempt() {
        guard let result = model.release(pendingChangeID: prompt.changeID, password: password) else {
            failure = "Gate could not save the release. Nothing has changed."
            return
        }
        switch result.status {
        case .released:
            dismiss()
        case .passwordRefused(let verification):
            password = ""
            switch verification {
            case .rejected:
                failure = "That is not the passphrase."
            case .notConfigured:
                failure = "This Lock has no passphrase. The change lands when the "
                    + "countdown runs out."
            case .unsupportedAlgorithm:
                failure = "This passphrase was stored by a newer version of Gate and "
                    + "cannot be checked here. Update Gate, or wait the change out."
            case .accepted:
                // Unreachable: `.accepted` returns `.released` above.
                failure = nil
            }
        case .notRipe(let remaining):
            failure = remaining.map { "Not yet — \(GateCountdown.text(for: $0))." }
                ?? "This change has no deadline; only the passphrase can release it."
        case .notFound, .alreadyResolved:
            dismiss()
        case .notApplicable:
            failure = "This change was written by a newer version of Gate. It can be "
                + "cancelled, but not applied here."
        }
    }
}

// MARK: - Shared cost copy

/// One sentence describing what a mutation will cost, derived from the same
/// `Ratchet.Assessment` that will run on commit.
///
/// Internal rather than private: `RuleEditorScreen` and `LockSettingsScreen`
/// render the identical sentence, and two copies of this wording is how a screen
/// starts promising something the kernel does not do.
struct LockCostNote: View {

    let assessment: Ratchet.Assessment

    var body: some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: assessment.goesThroughLock ? "lock.fill" : "bolt.fill")
        }
        .font(GateTheme.Typography.footnote)
        .foregroundStyle(assessment.goesThroughLock ? GateTheme.pending : GateTheme.enforcing)
    }

    private var text: String {
        if let refusal = assessment.refusal {
            return LockCostNote.refusalText(refusal)
        }
        guard assessment.goesThroughLock else {
            return "Applies immediately. Tightening is always free."
        }
        // **`hasCountdown`, not `cost > 0`.** `Assessment.cost` is the full
        // `lock.delay` for every queued mutation, including under a
        // passphrase-only Lock — where `earliestApplyDate` is `nil` and the
        // change never ripens on time at all. Reading the cost as "it will land
        // in 15 minutes" there would be the single most misleading sentence in
        // the app.
        let paths = assessment.releasePaths
        let waits = paths.hasCountdown && assessment.cost > 0

        switch (waits, paths.contains(.password)) {
        case (true, true):
            return "Waits \(GateCountdown.durationText(for: assessment.cost)), "
                + "or the partner passphrase releases it sooner."
        case (true, false):
            return "Waits \(GateCountdown.durationText(for: assessment.cost)) before it applies."
        case (false, true):
            return "Needs the partner passphrase. There is no countdown on a "
                + "passphrase-only Lock."
        case (false, false):
            // `LockKind.password` with no digest stored: nothing will ever
            // release it, and saying so beats showing a countdown that is a lie.
            return "This Lock has no way to release a change right now. Set a passphrase "
                + "or switch the Lock to a delay first."
        }
    }

    static func refusalText(_ refusal: Ratchet.Refusal) -> String {
        switch refusal {
        case .unknownRule:
            "That rule no longer exists."
        case .unknownPendingChange:
            "That queued change is already resolved."
        case .unknownGrant:
            "That unblock has already ended."
        case .duplicateRule:
            "A rule with that identifier already exists."
        case .ruleLimitReached(let limit):
            "Gate caps rules at \(limit). Delete one first — which goes through the Lock."
        case .tokenCapExceeded(let collection, let count, let limit):
            "Too many \(RuleRow.collectionNoun(collection, plural: true)): "
                + "\(count) of \(limit). iOS silently shields nothing past the cap."
        case .invalidSchedule:
            "iOS will not accept that window. It has to be at least 15 minutes long, "
                + "no longer than a week, and land on at least one weekday."
        case .lockPasswordChangeUnavailable:
            "A partner passphrase can only be set while the Lock has never been used. "
                + "Clearing the existing one goes through the Lock first."
        case .notRepresentable:
            "Gate cannot queue that change, so it will not apply it either."
        }
    }
}
