//
//  LockSettingsScreen.swift
//  Gate
//
//  V1-3 (The Lock) and V1-4 (The Ratchet), build plan step 5.3.
//
//  Every control on this screen routes through `Ratchet.apply`, and every one of
//  them shows `Ratchet.assess` *first*. That is not decoration: the asymmetry is
//  the product, and a screen that let the user discover the cost only after
//  committing would be teaching them to avoid the screen.
//
//  The three asymmetries, exactly as V1-3 specifies them:
//
//  * **Increasing the delay applies immediately.** It is a tightening.
//  * **Decreasing the delay costs `oldDelay − newDelay`** — not the full delay.
//    Cutting 60 minutes to 45 costs 15 minutes, and doing it twice costs the same
//    as doing it once in one step.
//  * **Changing the lock *type* is a loosening** and goes through the Lock. Even
//    `delay -> both`, which looks purely additive: it adds a release path.
//

import SwiftUI

import GateKernel
import GateKernelUI

struct LockSettingsScreen: View {

    @Environment(AppModel.self) private var model

    @State private var draftDelay: TimeInterval = GateLimits.defaultLockDelay
    @State private var isSettingPassword = false
    @State private var confirmingRevoke = false
    @State private var didLoad = false
    @State private var failure: String?

    private var lock: LockPolicy { model.state.lock }

    var body: some View {
        Form {
            delaySection
            kindSection
            passwordSection
            ratchetSection
            survivalSection
            revokeSection
        }
        .scrollContentBackground(.hidden)
        .background(GateTheme.background)
        .navigationTitle("The Lock")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard !didLoad else { return }
            didLoad = true
            draftDelay = lock.delay
        }
        .sheet(isPresented: $isSettingPassword) {
            PartnerPassphraseSheet()
                .environment(model)
        }
        .alert(
            "Gate could not make that change",
            isPresented: Binding(
                get: { failure != nil },
                set: { if !$0 { failure = nil } }
            ),
            presenting: failure
        ) { _ in
            Button("OK", role: .cancel) { failure = nil }
        } message: { detail in
            Text(detail)
        }
        .confirmationDialog(
            "Turn Screen Time access off?",
            isPresented: $confirmingRevoke,
            titleVisibility: .visible
        ) {
            Button(revokeButtonTitle, role: .destructive) { revoke() }
            Button("Keep it on", role: .cancel) {}
        } message: {
            Text(revokeMessage)
        }
    }

    // MARK: The delay (V1-3)

    private var delaySection: some View {
        let mutation = Mutation.setLockDelay(seconds: draftDelay)
        let assessment = model.assess(mutation)
        let changed = LockPolicy.clampDelay(draftDelay) != lock.delay

        return Section {
            Picker("Wait", selection: $draftDelay) {
                ForEach(delayChoices, id: \.self) { seconds in
                    Text(GateCountdown.durationText(for: seconds)).tag(seconds)
                }
            }

            if changed {
                LockCostNote(assessment: assessment)
                Button("Apply this wait") {
                    perform(mutation)
                }
                .buttonStyle(.borderedProminent)
                .tint(GateTheme.accent)
                .frame(maxWidth: .infinity)
                .disabled(!model.isOperational)
            }
        } header: {
            Text("How long un-blocking waits")
        } footer: {
            VStack(alignment: .leading, spacing: GateTheme.Spacing.xs) {
                Text("Right now: \(GateCountdown.durationText(for: lock.delay)).")
                // The exact number for the pending change is on the row above,
                // from `Ratchet.assess`. This is the rule, stated once, without
                // interpolating a figure that reads as nonsense when the draft
                // happens to be an increase.
                Text("Making the wait longer takes effect immediately. Making it shorter "
                     + "costs the difference, not the whole delay — and cutting it in "
                     + "stages costs exactly the same as cutting it in one go.")
            }
        }
    }

    // MARK: The lock type

    private var kindSection: some View {
        Section {
            ForEach(LockKind.allCases, id: \.self) { kind in
                LockKindRow(
                    kind: kind,
                    isCurrent: kind == lock.kind,
                    assessment: kind == lock.kind ? nil : model.assess(.setLockKind(kind)),
                    isEnabled: model.isOperational
                ) {
                    perform(.setLockKind(kind))
                }
            }
        } header: {
            Text("What releases a queued change")
        } footer: {
            // V1-3, verbatim: "Changing the lock *type* is a loosening and goes
            // through the lock." No exceptions.
            Text("Changing this is always a loosening, whichever direction you go — "
                 + "even adding a passphrase to a delay, because that adds a second way out. "
                 + "So it goes through the Lock you have now.")
        }
    }

    // MARK: The partner passphrase

    @ViewBuilder
    private var passwordSection: some View {
        Section {
            if let digest = lock.password {
                LabeledContent("Passphrase") {
                    Text("Set \(digest.createdAt.formatted(date: .abbreviated, time: .shortened))")
                        .foregroundStyle(GateTheme.textSecondary)
                }
                if let hint = digest.hint, !hint.isEmpty {
                    LabeledContent("Hint") {
                        Text(hint).foregroundStyle(GateTheme.textSecondary)
                    }
                }
                let assessment = model.assess(.clearLockPassword)
                LockCostNote(assessment: assessment)
                Button("Remove the passphrase", role: .destructive) {
                    perform(.clearLockPassword)
                }
                .disabled(!model.isOperational)
            } else {
                let assessment = model.assess(
                    .setLockPassword(PasswordDigest(
                        algorithm: .saltedSHA256,
                        salt: Data(),
                        digest: Data(),
                        createdAt: Date(),
                        hint: nil
                    ))
                )
                if assessment.refusal == nil {
                    Button("Set a partner passphrase") {
                        isSettingPassword = true
                    }
                    .tint(GateTheme.accent)
                    .disabled(!model.isOperational)
                } else {
                    Text(LockCostNote.refusalText(assessment.refusal ?? .notRepresentable))
                        .font(GateTheme.Typography.footnote)
                        .foregroundStyle(GateTheme.textSecondary)
                }
            }
        } header: {
            Text("Partner passphrase")
        } footer: {
            // The exploit this closes is spelled out on
            // `Ratchet.Refusal.lockPasswordChangeUnavailable`: whoever can set a
            // passphrase can release every queued loosening instantly, forever.
            Text("Hand the phone to someone else and let them type it. A passphrase can "
                 + "only be set while the Lock has never been used — otherwise setting one "
                 + "would be a way to release the changes already waiting.")
        }
    }

    // MARK: The ratchet switch (V1-4)

    private var ratchetSection: some View {
        let next = !lock.isRatchetEnabled
        let assessment = model.assess(.setRatchet(enabled: next))

        return Section {
            Toggle(isOn: Binding(
                get: { lock.isRatchetEnabled },
                set: { setRatchet($0) }
            )) {
                VStack(alignment: .leading, spacing: GateTheme.Spacing.xxs) {
                    Text("Permit tightening changes directly")
                    Text("On: blocking more is instant. Off: everything waits, including "
                         + "blocking more.")
                        .font(GateTheme.Typography.footnote)
                        .foregroundStyle(GateTheme.textSecondary)
                }
            }
            .tint(GateTheme.accent)
            .disabled(!model.isOperational)

            LockCostNote(assessment: assessment)
        } header: {
            Text("The Ratchet")
        } footer: {
            Text("Turning this off makes Gate stricter, so it is free. Turning it back on "
                 + "makes Gate easier to change, so it goes through the Lock.")
        }
    }

    // MARK: Survival

    private var survivalSection: some View {
        Section {
            VStack(alignment: .leading, spacing: GateTheme.Spacing.s) {
                Text("Deleting Gate does not reset the wait.")
                    .font(GateTheme.Typography.headline)
                    .foregroundStyle(GateTheme.textPrimary)

                // Keychain items survive app deletion on iOS; the App Group
                // container does not. That single fact is the whole mechanism
                // (docs/04-product-spec.md V1-3).
                Text("The deadline is stored in the iOS Keychain, which survives deleting "
                     + "the app. Reinstalling gets you back to the same countdown.")
                    .font(GateTheme.Typography.body)
                    .foregroundStyle(GateTheme.textSecondary)

                Text("What it does not survive: erasing the device, and setting your clock "
                     + "forward. There is no trusted time source on an offline phone, and "
                     + "Gate does not pretend otherwise — but neither is the weakest link, "
                     + "because you can also just switch Gate off in Settings.")
                    .font(GateTheme.Typography.footnote)
                    .foregroundStyle(GateTheme.textTertiary)
            }
            .padding(.vertical, GateTheme.Spacing.xs)
        } header: {
            Text("What the Lock survives")
        }
    }

    // MARK: Revoking (V1-4, a loosening)

    private var revokeSection: some View {
        Section {
            Button(role: .destructive) {
                confirmingRevoke = true
            } label: {
                Label("Turn off Gate's Screen Time access", systemImage: "xmark.shield")
                    .frame(minHeight: GateTheme.Spacing.minimumTapTarget)
            }
            .disabled(!model.isOperational)
        } footer: {
            // Gate cannot stop the four-tap Settings route and must never claim
            // to (docs/03-hard-constraints.md #13, #14). It can decline to be the
            // *quick* route, which is all this does.
            Text("Doing it here goes through the Lock. Doing it in Settings › Screen Time "
                 + "does not, and Gate has no way to stop that or even to notice it "
                 + "reliably. This button exists so the honest path is not the slow one "
                 + "by accident.")
        }
    }

    private var revokeButtonTitle: String {
        model.assess(.revokeAuthorization).goesThroughLock ? "Queue it" : "Turn it off"
    }

    private var revokeMessage: String {
        let assessment = model.assess(.revokeAuthorization)
        guard assessment.goesThroughLock else {
            return "Every shield lifts and every app identifier Gate holds is voided. "
                + "Your rules stay, but you will have to re-pick your apps."
        }
        if assessment.releasePaths.hasCountdown, assessment.cost > 0 {
            return "This is a loosening, so it waits "
                + "\(GateCountdown.durationText(for: assessment.cost)). Cancelling is free. "
                + "You can still do it immediately from Settings — Gate cannot stop that."
        }
        return "This is a loosening, so it needs the partner passphrase. You can still do "
            + "it immediately from Settings — Gate cannot stop that."
    }

    // MARK: Actions

    // Void-returning methods rather than closure bodies, so the discarded
    // `Ratchet.Outcome` is unambiguously a statement.

    private func perform(_ mutation: Mutation) {
        guard let outcome = model.apply(mutation) else {
            failure = "Gate could not save that. Nothing has changed."
            return
        }
        if let refusal = outcome.refusal {
            failure = LockCostNote.refusalText(refusal)
        }
        draftDelay = model.state.lock.delay
    }

    private func setRatchet(_ enabled: Bool) {
        perform(.setRatchet(enabled: enabled))
    }

    private func revoke() {
        perform(.revokeAuthorization)
    }

    /// The standard list plus whatever the Lock is actually set to.
    ///
    /// A delay written by an older build — or clamped by `GateState.migrate` —
    /// need not be one of the round numbers below, and a `Picker` whose selection
    /// is absent from its options renders as blank. Including it keeps the
    /// control honest without silently proposing a change on appear.
    private var delayChoices: [TimeInterval] {
        var values = Set(Self.standardDelayChoices)
        values.insert(LockPolicy.clampDelay(lock.delay))
        return values.sorted()
    }

    /// 1 minute to 7 days — `GateLimits.minLockDelay` to `GateLimits.maxLockDelay`
    /// (V1-3). A fixed list rather than a slider: the values a person actually
    /// wants are logarithmic, and a slider invites fiddling with a number that is
    /// expensive to lower.
    private static let standardDelayChoices: [TimeInterval] = [
        60,
        5 * 60,
        15 * 60,
        30 * 60,
        60 * 60,
        2 * 60 * 60,
        4 * 60 * 60,
        8 * 60 * 60,
        24 * 60 * 60,
        3 * 24 * 60 * 60,
        7 * 24 * 60 * 60
    ]
}

// MARK: - LockKindRow

private struct LockKindRow: View {

    let kind: LockKind
    let isCurrent: Bool
    let assessment: Ratchet.Assessment?
    let isEnabled: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: GateTheme.Spacing.xxs) {
                HStack {
                    Text(Self.title(kind))
                        .foregroundStyle(GateTheme.textPrimary)
                    Spacer()
                    if isCurrent {
                        Image(systemName: "checkmark")
                            .foregroundStyle(GateTheme.accent)
                    }
                }
                Text(Self.detail(kind))
                    .font(GateTheme.Typography.footnote)
                    .foregroundStyle(GateTheme.textSecondary)
                if let assessment {
                    LockCostNote(assessment: assessment)
                }
            }
            .frame(minHeight: GateTheme.Spacing.minimumTapTarget)
        }
        .buttonStyle(.plain)
        .disabled(isCurrent || !isEnabled)
        .accessibilityAddTraits(isCurrent ? [.isSelected, .isButton] : .isButton)
    }

    private static func title(_ kind: LockKind) -> String {
        switch kind {
        case .delay: "Wait it out"
        case .password: "Partner passphrase only"
        case .both: "Either one"
        }
    }

    private static func detail(_ kind: LockKind) -> String {
        switch kind {
        case .delay:
            "Every un-blocking change waits out the delay. No passphrase involved."
        case .password:
            "Only the passphrase releases a change. There is no countdown at all — "
                + "without the passphrase, a queued change never lands."
        case .both:
            "The countdown runs, and the passphrase can release a change early."
        }
    }
}

// MARK: - PartnerPassphraseSheet

/// V1-3's "hand your phone to someone" flow.
///
/// The copy is written for the person holding the phone *and* for the person
/// typing, because the whole value of this feature is that they are different
/// people.
private struct PartnerPassphraseSheet: View {

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var passphrase = ""
    @State private var confirmation = ""
    @State private var hint = ""
    @State private var failure: String?

    private var isValid: Bool {
        passphrase.count >= 4 && passphrase == confirmation
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Hand the phone to someone you trust and let them type this. "
                         + "If you know it, it is not a partner passphrase — it is a "
                         + "speed bump.")
                        .font(GateTheme.Typography.body)
                        .foregroundStyle(GateTheme.textSecondary)
                }

                Section {
                    SecureField("Passphrase", text: $passphrase)
                        .textContentType(.newPassword)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    SecureField("Type it again", text: $confirmation)
                        .textContentType(.newPassword)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField("Hint (optional)", text: $hint)
                        .onChange(of: hint) { _, value in
                            if value.count > PasswordDigest.maxHintLength {
                                hint = String(value.prefix(PasswordDigest.maxHintLength))
                            }
                        }
                } footer: {
                    Text("Gate stores a salted SHA-256 digest, never the passphrase itself. "
                         + "If it is forgotten, queued changes still land on their own "
                         + "deadline — unless the Lock is passphrase-only, in which case "
                         + "nothing releases them.")
                }

                if let failure {
                    Section {
                        Text(failure)
                            .font(GateTheme.Typography.footnote)
                            .foregroundStyle(GateTheme.danger)
                    }
                }
            }
            .navigationTitle("Partner passphrase")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Set") { commit() }
                        .disabled(!isValid)
                }
            }
        }
    }

    private func commit() {
        let trimmedHint = hint.trimmingCharacters(in: .whitespacesAndNewlines)
        // `PasswordDigest.make(password:hint:now:)` is the CryptoKit convenience;
        // the kernel keeps a hasher-injected form for the platform-agnostic test
        // package, which has no CryptoKit.
        let digest = PasswordDigest.make(
            password: passphrase,
            hint: trimmedHint.isEmpty ? nil : trimmedHint,
            now: Date()
        )

        guard let outcome = model.apply(.setLockPassword(digest)) else {
            failure = "Gate could not save the passphrase. Nothing has changed."
            return
        }
        if let refusal = outcome.refusal {
            failure = LockCostNote.refusalText(refusal)
            return
        }
        dismiss()
    }
}
