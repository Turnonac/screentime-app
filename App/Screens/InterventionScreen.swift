//
//  InterventionScreen.swift
//  Gate
//
//  V1-7 (docs/04-product-spec.md), build plan step 5.5. The landing screen for
//  `ShieldActionResponse.openParentalControlsApp` on iOS 26.5+, and for the
//  `gate://intervention?…` notification tap below it.
//
//  Four beats, in order:
//
//  1. **A forced wait** — `GrantPolicy.interventionWait(under:)`, which is the
//     impulse delay (30 s by default) unless the user chose to spend the full
//     Lock delay here too.
//  2. **A typed reason**, kept with the grant so the next one is read in the
//     light of the last one.
//  3. **A grant** — a token-scoped, time-boxed subtraction from the shield set,
//     never `clearAllSettings()`.
//  4. **"You can open it now — press Home and tap the app."**
//
//  ─────────────────────────────────────────────────────────────────────────────
//  THE SENTENCE IN STEP 4 IS NOT A UX COMPROMISE, IT IS THE API
//  ─────────────────────────────────────────────────────────────────────────────
//  Gate holds an opaque `ApplicationToken` and nothing else: no bundle id, no
//  URL, no launch handle. `OpenAppFromApplicationTokenIntent` was filed as
//  FB15500695 and got no Apple response, and no supported API lets one app launch
//  another from a token (docs/03-hard-constraints.md #20). Every competitor in
//  this category has the same limitation. Saying so plainly costs one sentence;
//  implying otherwise costs the user a confused tap and Gate its credibility.
//

import SwiftUI

import GateKernel
import GateKernelUI

struct InterventionScreen: View {

    let request: InterventionRequest

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private enum Phase: Equatable {
        case waiting
        case reason
        case granted(Grant)
        case denied(InterventionRequest.DenialReason)
    }

    @State private var phase: Phase = .waiting
    @State private var reason = ""
    @State private var deadline: Date?

    /// The shortest reason Gate will accept.
    ///
    /// Not an arbitrary gate: the value of the step is that you have to say the
    /// thing out loud, and "x" is not saying it. Low enough that a real sentence
    /// always clears it.
    private static let minimumReasonLength = 12

    private var isResolved: Bool {
        switch phase {
        case .waiting, .reason: false
        case .granted, .denied: true
        }
    }

    private var title: String {
        switch phase {
        case .waiting, .reason: "Wait a moment"
        case .granted: "Unblocked"
        case .denied: "Not this time"
        }
    }

    private var ruleName: String? {
        request.ruleID.flatMap { model.ruleNames[$0] }
    }

    private var wait: TimeInterval {
        model.state.grantPolicy.interventionWait(under: model.state.lock)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: GateTheme.Spacing.xl) {
                    header

                    switch phase {
                    case .waiting: waitingSection
                    case .reason: reasonSection
                    case .granted(let grant): grantedSection(grant)
                    case .denied(let denial): deniedSection(denial)
                    }
                }
                .padding(GateTheme.Spacing.xl)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(GateTheme.background)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // "Not now" is a *decision* and is recorded as one, so it is
                    // only offered while there is still a decision to make. After
                    // a grant or a denial the same button would be closing a
                    // receipt, and labelling that "Not now" would quietly imply
                    // the unblock could still be taken back.
                    if isResolved {
                        Button("Close") { dismiss() }
                    } else {
                        Button("Not now") { backOut() }
                    }
                }
            }
        }
        .interactiveDismissDisabled(phase == .waiting)
        .onAppear(perform: start)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: GateTheme.Spacing.s) {
            Text(ruleName.map { "\u{201C}\($0)\u{201D} is blocking this." }
                 ?? "Something you blocked.")
                .font(GateTheme.Typography.title)
                .foregroundStyle(GateTheme.textPrimary)

            // Deliberately not the app's name: iOS hands `ShieldActionDelegate` a
            // bare token with no name attached, to preserve privacy
            // (docs/02-api-reference.md §10). Gate does not know which app this
            // is, and inventing a name would be a lie the user could catch.
            Text("iOS does not tell Gate which app you tapped, only that it was one this "
                 + "rule covers.")
                .font(GateTheme.Typography.footnote)
                .foregroundStyle(GateTheme.textTertiary)
        }
    }

    // MARK: 1 — the wait

    @ViewBuilder
    private var waitingSection: some View {
        VStack(alignment: .leading, spacing: GateTheme.Spacing.l) {
            if let deadline {
                VStack(alignment: .leading, spacing: GateTheme.Spacing.s) {
                    Text("Give it")
                        .font(GateTheme.Typography.callout)
                        .foregroundStyle(GateTheme.textSecondary)

                    CountdownView(
                        deadline: deadline,
                        style: .prominent,
                        granularity: .seconds,
                        elapsedText: "ready",
                        onElapsed: { phase = .reason }
                    )
                    .foregroundStyle(GateTheme.textPrimary)
                }
                .gateCard()
            }

            Text("Most of the time the urge is gone before the timer is. If it is, close "
                 + "this — that is a win, not a failure.")
                .font(GateTheme.Typography.body)
                .foregroundStyle(GateTheme.textSecondary)

            budgetLine
        }
    }

    // MARK: 2 — the reason

    private var reasonSection: some View {
        VStack(alignment: .leading, spacing: GateTheme.Spacing.l) {
            VStack(alignment: .leading, spacing: GateTheme.Spacing.s) {
                Text("What do you actually want to do in there?")
                    .font(GateTheme.Typography.headline)
                    .foregroundStyle(GateTheme.textPrimary)

                TextField("Reply to one message and get out", text: $reason, axis: .vertical)
                    .lineLimit(2...5)
                    .textFieldStyle(.plain)
                    .textInputAutocapitalization(.sentences)
                    .padding(GateTheme.Spacing.m)
                    .background(
                        RoundedRectangle(cornerRadius: GateTheme.Radius.control, style: .continuous)
                            .fill(GateTheme.surface)
                    )
                    .onChange(of: reason) { _, value in
                        if value.count > Grant.maxReasonLength {
                            reason = String(value.prefix(Grant.maxReasonLength))
                        }
                    }

                // The journal is `Grant.reason`, kept in `state.plist` and
                // compacted after seven days. There is no second store and
                // nothing leaves the device.
                Text("Kept on this device with the unblock, so you can read the last few "
                     + "back later.")
                    .font(GateTheme.Typography.footnote)
                    .foregroundStyle(GateTheme.textTertiary)
            }
            .gateCard()

            budgetLine

            Button {
                issue()
            } label: {
                Text(unlockButtonTitle)
                    .font(GateTheme.Typography.headline)
                    .frame(maxWidth: .infinity, minHeight: GateTheme.Spacing.minimumTapTarget)
            }
            .buttonStyle(.borderedProminent)
            .tint(GateTheme.accent)
            .disabled(!canIssue)

            if reason.trimmingCharacters(in: .whitespacesAndNewlines).count
                < Self.minimumReasonLength {
                Text("Write a sentence, not a word.")
                    .font(GateTheme.Typography.footnote)
                    .foregroundStyle(GateTheme.textTertiary)
            }
        }
    }

    // MARK: 3 — granted

    private func grantedSection(_ grant: Grant) -> some View {
        VStack(alignment: .leading, spacing: GateTheme.Spacing.l) {
            VStack(alignment: .leading, spacing: GateTheme.Spacing.s) {
                Label {
                    Text("Unblocked")
                        .font(GateTheme.Typography.headline)
                } icon: {
                    Image(systemName: "lock.open.fill")
                }
                .foregroundStyle(GateTheme.enforcing)

                // V1-7 step 4, verbatim in spirit and explicit about the reason.
                Text("You can open it now — press Home and tap the app.")
                    .font(GateTheme.Typography.title)
                    .foregroundStyle(GateTheme.textPrimary)

                Text("Gate cannot open it for you. iOS gives Gate an anonymous handle for "
                     + "the app and no way to launch it.")
                    .font(GateTheme.Typography.body)
                    .foregroundStyle(GateTheme.textSecondary)

                CountdownView(
                    deadline: grant.expiresAt,
                    style: .inline,
                    granularity: .seconds,
                    prefix: "It re-blocks in",
                    elapsedText: "re-blocked"
                )
                .foregroundStyle(GateTheme.textSecondary)
            }
            .gateCard()

            Text("The shield comes back on its own. You do not have to do anything, and "
                 + "the time you spend looking at Gate's shield still counts as time in "
                 + "that app as far as iOS is concerned.")
                .font(GateTheme.Typography.footnote)
                .foregroundStyle(GateTheme.textTertiary)

            Button("Done") { dismiss() }
                .buttonStyle(.bordered)
                .tint(GateTheme.accent)
                .frame(maxWidth: .infinity, minHeight: GateTheme.Spacing.minimumTapTarget)
        }
    }

    // MARK: 4 — denied

    private func deniedSection(_ denial: InterventionRequest.DenialReason) -> some View {
        VStack(alignment: .leading, spacing: GateTheme.Spacing.l) {
            VStack(alignment: .leading, spacing: GateTheme.Spacing.s) {
                Text(Self.denialTitle(denial))
                    .font(GateTheme.Typography.headline)
                    .foregroundStyle(GateTheme.textPrimary)

                Text(Self.denialDetail(denial))
                    .font(GateTheme.Typography.body)
                    .foregroundStyle(GateTheme.textSecondary)
            }
            .gateCard()

            if denial == .ruleUnresolved {
                Button("Re-pick my apps") {
                    model.recovery = .unmatchedToken
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(GateTheme.accent)
                .frame(maxWidth: .infinity, minHeight: GateTheme.Spacing.minimumTapTarget)
            }

            Button("Close") { dismiss() }
                .buttonStyle(.bordered)
                .tint(GateTheme.accent)
                .frame(maxWidth: .infinity, minHeight: GateTheme.Spacing.minimumTapTarget)
        }
    }

    // MARK: Budget

    private var budgetLine: some View {
        let budget = model.grantBudget()
        return HStack(spacing: GateTheme.Spacing.xs) {
            GateStatusDot(tone: budget.isExhausted ? .danger : .pending)
            Text(budget.isExhausted
                 ? "No unblocks left today."
                 : "\(budget.remaining) of \(budget.limit) unblocks left today.")
                .font(GateTheme.Typography.footnote)
                .foregroundStyle(GateTheme.textSecondary)
        }
    }

    private var canIssue: Bool {
        model.isOperational
            && reason.trimmingCharacters(in: .whitespacesAndNewlines).count
                >= Self.minimumReasonLength
    }

    private var unlockButtonTitle: String {
        let duration = GrantPolicy.clampDuration(model.state.grantPolicy.defaultDuration)
        return "Unblock for \(GateCountdown.durationText(for: duration))"
    }

    // MARK: Actions

    private func start() {
        guard deadline == nil else { return }

        // Anchored to *this screen appearing*, not to when the shield was tapped.
        //
        // The friction has to happen in front of the person. Anchoring to
        // `request.createdAt` would let a notification that sat for five minutes
        // arrive with the wait already served, which is the one direction this
        // timer must not fail in. It also means re-opening the screen restarts
        // the wait — stricter, and the stricter reading is the correct default.
        let seconds = wait
        guard seconds > 0 else {
            phase = .reason
            return
        }
        deadline = Date().addingTimeInterval(seconds)
        phase = .waiting
    }

    private func issue() {
        let text = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let issuance = model.grant(for: request, reason: text) else {
            phase = .denied(.notAuthorized)
            return
        }
        if let grant = issuance.grant {
            phase = .granted(grant)
        } else {
            phase = .denied(issuance.denial ?? .ruleUnresolved)
        }
    }

    /// Backing out is the outcome the product exists to produce, so it is a
    /// completion rather than a cancellation — and it is recorded as one.
    private func backOut() {
        model.dismissIntervention(request)
        dismiss()
    }

    // MARK: Denial copy

    private static func denialTitle(_ denial: InterventionRequest.DenialReason) -> String {
        switch denial {
        case .budgetExhausted: "You are out of unblocks for today"
        case .ruleUnresolved: "Gate could not place that app"
        case .notAuthorized: "Gate's Screen Time access is off"
        case .stale: "That request is too old"
        }
    }

    private static func denialDetail(_ denial: InterventionRequest.DenialReason) -> String {
        switch denial {
        case .budgetExhausted:
            // Running out is a *tightening*: immediate, no Lock, no appeal, and
            // no way to buy more. Saying that plainly is the point of the budget.
            "They come back at midnight. There is no way to buy more, and no wait that "
                + "makes more appear — that is what makes the budget mean anything."
        case .ruleUnresolved:
            // The V1-9 signature: iOS reissued the app's identifier, so the token
            // the shield handed over matches nothing Gate stored
            // (docs/03-hard-constraints.md #36).
            "iOS sometimes re-issues app identifiers, which leaves Gate holding a handle "
                + "that no longer matches anything. Re-picking your apps fixes it, and "
                + "re-picking is free — it never waits out the Lock."
        case .notAuthorized:
            "Screen Time access was turned off, so every app handle Gate held was voided. "
                + "Nothing is being blocked right now. Turn access back on and re-pick "
                + "your apps."
        case .stale:
            "Gate only honours a shield tap for "
                + "\(GateCountdown.durationText(for: InterventionRequest.maxAge)). "
                + "If you still want in, tap the shield again."
        }
    }
}
