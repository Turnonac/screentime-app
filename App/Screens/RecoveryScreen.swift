//
//  RecoveryScreen.swift
//  Gate
//
//  V1-9 (docs/04-product-spec.md), build plan step 5.6.
//
//  **A first-class screen, not an error path.** `ApplicationToken`s go stale:
//  they change after OS updates and re-authorization, and tokens handed to
//  `ShieldConfigurationDataSource` / `ShieldActionDelegate` can fail `==` against
//  tokens Gate stored (thread 814571; Apple DTS asked for a Feedback report and
//  gave no workaround). The iOS 26.5 remedy — `TokenExpiryMessage` plus
//  `refresh(_:)` — is itself reported broken, with roughly 30% of new users
//  receiving `.tokensDidExpire` immediately after granting approval (FB23391495,
//  Apple status "Potential fix identified — For a future OS update").
//  docs/03-hard-constraints.md #36.
//
//  ─────────────────────────────────────────────────────────────────────────────
//  RESELECTING IS A TIGHTENING AND IS NEVER GATED BEHIND THE LOCK
//  ─────────────────────────────────────────────────────────────────────────────
//  V1-9, verbatim: *"Reselecting is a tightening — never gate recovery behind the
//  lock, or you will trap users out of their own blocks."* `Ratchet` enforces
//  that at the kernel: `Mutation.reselectSelection` classifies as
//  `.tighten` / `.recoveryReselect` unconditionally. This screen is the only
//  place that mutation is issued, which is also the bound on what it can be
//  abused for — a user who wants a cheap loosening has to first arrive at a
//  screen that exists because something is broken.
//

import FamilyControls
import SwiftUI

import GateKernel
import GateKernelUI

struct RecoveryScreen: View {

    let trigger: AppModel.RecoveryTrigger

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var selection = FamilyActivitySelection()
    @State private var activeRuleID: UUID?
    @State private var isPickerPresented = false
    @State private var refreshNotes: [String] = []
    @State private var repaired: Set<UUID> = []

    var body: some View {
        NavigationStack {
            List {
                explanationSection
                if !model.isAuthorized { authorizationSection }
                rulesSection
                if !refreshNotes.isEmpty { notesSection }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(GateTheme.background)
            .navigationTitle("Re-pick your apps")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        model.completeRecovery()
                        dismiss()
                    }
                }
            }
            .modifier(
                RecoveryPickerModifier(
                    isPresented: $isPickerPresented,
                    selection: $selection,
                    title: "Re-pick what this rule covers",
                    headerText: "Everything Gate could recover is already ticked.",
                    footerText: "Re-picking is free and takes effect immediately. It never "
                        + "waits out the Lock."
                )
            )
            .onChange(of: selection) { _, newValue in
                commit(newValue)
            }
        }
    }

    // MARK: Explanation

    private var explanationSection: some View {
        Section {
            VStack(alignment: .leading, spacing: GateTheme.Spacing.s) {
                // The one sentence V1-9 asks for.
                Text("iOS occasionally re-issues the anonymous handles it gives Gate for "
                     + "your apps, and the old ones stop matching.")
                    .font(GateTheme.Typography.body)
                    .foregroundStyle(GateTheme.textPrimary)

                Text(Self.triggerDetail(trigger))
                    .font(GateTheme.Typography.footnote)
                    .foregroundStyle(GateTheme.textSecondary)

                Text("Nothing you configured is lost — names, windows and the Lock are all "
                     + "still here. Only the app handles need re-picking.")
                    .font(GateTheme.Typography.footnote)
                    .foregroundStyle(GateTheme.textSecondary)
            }
            .padding(.vertical, GateTheme.Spacing.xs)
            .listRowBackground(GateTheme.surface)
        } header: {
            Text("What happened")
        }
    }

    // MARK: Authorization

    private var authorizationSection: some View {
        Section {
            Button {
                Task { await model.requestAuthorization() }
            } label: {
                Label("Turn Screen Time access back on", systemImage: "shield")
                    .frame(minHeight: GateTheme.Spacing.minimumTapTarget)
            }
            .tint(GateTheme.accent)
            .disabled(model.isRequestingAuthorization)
            .listRowBackground(GateTheme.surface)
        } header: {
            Text("First")
        } footer: {
            // Apple: any token a `FamilyActivitySelection` provided while the app
            // was authorized is voided on revoke (docs/02-api-reference.md §5).
            // Re-picking before access is back would produce tokens that are
            // voided again the moment they are stored.
            Text("Screen Time access is off, so nothing is being blocked and every app "
                 + "handle Gate held has been voided. Turn access on before re-picking, "
                 + "or the new handles will be voided too.")
        }
    }

    // MARK: Rules

    private var rulesSection: some View {
        Section {
            if model.state.rules.isEmpty {
                Text("There are no rules to repair.")
                    .foregroundStyle(GateTheme.textSecondary)
                    .listRowBackground(GateTheme.surface)
            }

            ForEach(model.state.rules) { rule in
                Button {
                    begin(rule)
                } label: {
                    HStack(spacing: GateTheme.Spacing.m) {
                        GateStatusDot(
                            tone: repaired.contains(rule.id) ? .enforcing : .pending,
                            isFilled: repaired.contains(rule.id)
                        )
                        VStack(alignment: .leading, spacing: GateTheme.Spacing.xxs) {
                            Text(rule.name.isEmpty ? RuleRow.untitledName : rule.name)
                                .foregroundStyle(GateTheme.textPrimary)
                            Text(RuleRow.selectionSummary(for: rule))
                                .font(GateTheme.Typography.footnote)
                                .foregroundStyle(GateTheme.textSecondary)
                        }
                        Spacer()
                        Text(repaired.contains(rule.id) ? "Re-picked" : "Re-pick")
                            .font(GateTheme.Typography.callout)
                            .foregroundStyle(GateTheme.accent)
                    }
                    .frame(minHeight: GateTheme.Spacing.minimumTapTarget)
                }
                .disabled(!model.isAuthorized || !model.isOperational)
                .listRowBackground(GateTheme.surface)
            }
        } header: {
            Text("Rules")
        } footer: {
            Text("Re-picking a rule applies immediately and is free — it is a tightening, "
                 + "and Gate never makes fixing a broken block cost you time.")
        }
    }

    // MARK: Refresh notes

    private var notesSection: some View {
        Section {
            ForEach(refreshNotes, id: \.self) { note in
                Text(note)
                    .font(GateTheme.Typography.footnote)
                    .foregroundStyle(GateTheme.textSecondary)
                    .listRowBackground(GateTheme.surface)
            }
        } header: {
            Text("What iOS said")
        } footer: {
            // Never claim a clean refresh that did not happen: the 26.5 remedy is
            // itself reported broken (docs/03-hard-constraints.md #36), so the
            // honest move is to show what came back and let the user re-pick.
            Text("Gate asked iOS to re-issue what it could before opening the picker. "
                 + "Anything it could not recover is simply unticked.")
        }
    }

    // MARK: Actions

    /// Seeds the picker with **what survived**, after asking iOS to re-issue
    /// whatever it can.
    private func begin(_ rule: Rule) {
        activeRuleID = rule.id

        var seed = model.currentSelection(forRuleID: rule.id) ?? FamilyActivitySelection()
        // `ManagedSettingsStore.refresh(_:)` ×3, iOS 26.5+, inside `AppModel`.
        // Below 26.5 it returns a single note saying so; either way the picker
        // opens with whatever is left, because re-picking is the remedy that
        // works on every version.
        refreshNotes = model.refreshTokens(in: &seed)
        selection = seed
        isPickerPresented = true
    }

    /// The picker closed. Anything the user ticked becomes the rule's selection
    /// immediately.
    private func commit(_ newValue: FamilyActivitySelection) {
        guard let ruleID = activeRuleID else { return }
        guard model.reselect(ruleID: ruleID, selection: newValue) != nil else { return }
        repaired.insert(ruleID)
        activeRuleID = nil
    }

    private static func triggerDetail(_ trigger: AppModel.RecoveryTrigger) -> String {
        switch trigger {
        case .tokenExpiryMessage:
            "iOS told Gate directly that the handles expired."
        case .authorizationLost:
            "Screen Time access was turned off, which voids every handle Gate was given."
        case .unmatchedToken:
            "A shield fired against an app Gate could no longer place, which is what a "
                + "stale handle looks like from the outside."
        case .userReported:
            "You said a rule stopped working. A stale handle is by far the most common "
                + "cause — the rule looks armed and shields nothing."
        }
    }
}

// MARK: - RecoveryPickerModifier

/// Same version gate as the rule editor: the five-argument
/// `.familyActivityPicker` is iOS 26.2, the two-argument form is iOS 15
/// (docs/02-api-reference.md §5, §13).
///
/// Duplicated rather than shared with `RuleEditorScreen`'s copy on purpose: they
/// carry different copy, and a single modifier taking six strings would be
/// harder to read than two that each say what they are for.
private struct RecoveryPickerModifier: ViewModifier {

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
            content.familyActivityPicker(
                isPresented: $isPresented,
                selection: $selection
            )
        }
    }
}
