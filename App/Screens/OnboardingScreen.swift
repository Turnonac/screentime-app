//
//  OnboardingScreen.swift
//  Gate
//
//  V1-1 (docs/04-product-spec.md), build plan step 5.1. One screen, about sixty
//  seconds, four jobs:
//
//  1. **Explain the deal honestly, including the limit.** Verbatim from the
//     spec: *"You can always turn Gate off in Settings. Gate makes that cost you
//     time, not impossible."* Shipping a blocker that overclaims is the #1 trust
//     failure in this category, and the claim would be false anyway: under
//     `FamilyControlsMember.individual` Apple deliberately removes the
//     anti-bypass protections, and the user can revoke everything in about four
//     taps with no API to block, delay or reliably detect it
//     (docs/03-hard-constraints.md #13, #14).
//  2. `try await AuthorizationCenter.shared.requestAuthorization(for: .individual)`.
//  3. **Every `FamilyControlsError` case with real copy** — the mapping lives in
//     `AuthorizationCopy` (App/AppModel.swift) so the same sentences are
//     available to any other screen that ever needs them.
//  4. **Nudge, not require, a Screen Time passcode.**
//

import FamilyControls
import SwiftUI
import UIKit

import GateKernel
import GateKernelUI

struct OnboardingScreen: View {

    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL

    /// Two beats, not a carousel. The passcode nudge only makes sense once
    /// authorization exists, and putting it first would read as a requirement.
    private enum Step {
        case deal
        case passcode
    }

    @State private var step: Step = .deal

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: GateTheme.Spacing.xl) {
                header

                switch step {
                case .deal:
                    dealSection
                case .passcode:
                    passcodeSection
                }
            }
            .padding(GateTheme.Spacing.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(GateTheme.background)
        .scrollDismissesKeyboard(.interactively)
        .onChange(of: model.authorizationStatus) { _, status in
            // Approval can also arrive from a repeat call that did not re-prompt
            // biometrics, so the step advances on the *status*, not on the
            // button's completion.
            if AppModel.isApproved(status) {
                step = .passcode
            }
        }
        // `alert(_:isPresented:presenting:actions:message:)` — the iOS 15+ form.
        // The older `alert(item:content:)` returns an `Alert` value and cannot
        // vary its button set per case, which is exactly what ten distinct
        // `FamilyControlsError` recoveries need.
        .alert(
            model.authorizationFailure?.title ?? "",
            isPresented: authorizationFailureIsPresented,
            presenting: model.authorizationFailure
        ) { copy in
            if copy.offersRetry {
                Button("Try again") {
                    Task { await model.requestAuthorization() }
                }
            }
            if copy.offersSettings {
                Button("Open Settings") { openSettings() }
            }
            Button("Not now", role: .cancel) {
                model.authorizationFailure = nil
            }
        } message: { copy in
            Text(copy.message)
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: GateTheme.Spacing.s) {
            Text("Gate")
                .font(GateTheme.Typography.display)
                .foregroundStyle(GateTheme.textPrimary)

            Text("A commitment device for your phone.")
                .font(GateTheme.Typography.headline)
                .foregroundStyle(GateTheme.textSecondary)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Step 1 — the deal

    private var dealSection: some View {
        VStack(alignment: .leading, spacing: GateTheme.Spacing.l) {
            promise

            honestLimit

            VStack(alignment: .leading, spacing: GateTheme.Spacing.s) {
                Text("What happens next")
                    .font(GateTheme.Typography.headline)
                    .foregroundStyle(GateTheme.textPrimary)

                Text("iOS will ask whether Gate may use Screen Time, and you will confirm "
                     + "with Face ID, Touch ID or your passcode. Gate then gets an opaque "
                     + "handle for each app you choose — never its name, never its icon, "
                     + "never how long you used it.")
                    .font(GateTheme.Typography.body)
                    .foregroundStyle(GateTheme.textSecondary)
            }
            .gateCard()

            continueButton

            Text("Gate has no account, no server and no analytics. Everything it knows "
                 + "stays on this device.")
                .font(GateTheme.Typography.footnote)
                .foregroundStyle(GateTheme.textTertiary)
        }
    }

    private var promise: some View {
        VStack(alignment: .leading, spacing: GateTheme.Spacing.s) {
            Text("Changing your mind costs time.")
                .font(GateTheme.Typography.title)
                .foregroundStyle(GateTheme.textPrimary)

            Text("Blocking something is instant and free. Un-blocking it waits out a delay "
                 + "you choose now, while you still want what you want.")
                .font(GateTheme.Typography.body)
                .foregroundStyle(GateTheme.textSecondary)
        }
        .gateCard()
    }

    /// The spec's sentence, unsoftened. It is first-class copy, not a footnote.
    private var honestLimit: some View {
        VStack(alignment: .leading, spacing: GateTheme.Spacing.s) {
            Label {
                Text("The honest limit")
                    .font(GateTheme.Typography.headline)
            } icon: {
                Image(systemName: "exclamationmark.circle")
            }
            .foregroundStyle(GateTheme.pending)

            Text("You can always turn Gate off in Settings. Gate makes that cost you time, "
                 + "not impossible.")
                .font(GateTheme.Typography.body)
                .foregroundStyle(GateTheme.textPrimary)

            Text("Settings › Screen Time › Apps with Screen Time Access is about four taps "
                 + "away, and iOS gives Gate no way to block, delay or even reliably notice "
                 + "it. Any app that tells you otherwise is wrong.")
                .font(GateTheme.Typography.footnote)
                .foregroundStyle(GateTheme.textSecondary)
        }
        .gateCard(
            fill: GateTheme.Tone.pending.pair.opacity(0.12).color,
            stroke: GateTheme.Tone.pending.pair.opacity(0.4).color
        )
    }

    private var continueButton: some View {
        Button {
            Task { await model.requestAuthorization() }
        } label: {
            HStack(spacing: GateTheme.Spacing.s) {
                if model.isRequestingAuthorization {
                    ProgressView()
                        .tint(GateTheme.onAccent)
                }
                Text(model.isRequestingAuthorization ? "Asking iOS…" : "Continue")
                    .font(GateTheme.Typography.headline)
            }
            .frame(maxWidth: .infinity, minHeight: GateTheme.Spacing.minimumTapTarget)
        }
        .buttonStyle(.borderedProminent)
        .tint(GateTheme.accent)
        .disabled(model.isRequestingAuthorization || !model.isOperational)
        .accessibilityHint("Asks iOS for permission to use Screen Time")
    }

    // MARK: Step 2 — the Screen Time passcode nudge

    /// **A nudge, never a requirement, and never framed as making Gate
    /// unremovable.**
    ///
    /// iOS 26.4 reportedly added Screen Time passcode gating on revoking a third
    /// party app's access, with a Face ID bypass bug fixed only in the iOS 27
    /// public beta — but that is a single developer report with no Apple
    /// documentation behind it, and the spec marks it *(unverified)*
    /// (docs/03-hard-constraints.md #17). So the copy below promises exactly one
    /// thing: **more steps**. It does not promise that anything becomes
    /// impossible, and it does not say the passcode blocks revocation, because
    /// nobody has confirmed that it does.
    private var passcodeSection: some View {
        VStack(alignment: .leading, spacing: GateTheme.Spacing.l) {
            VStack(alignment: .leading, spacing: GateTheme.Spacing.s) {
                Label {
                    Text("Screen Time is on")
                        .font(GateTheme.Typography.headline)
                } icon: {
                    Image(systemName: "checkmark.seal.fill")
                }
                .foregroundStyle(GateTheme.enforcing)

                Text("Gate can now shield the apps and sites you pick. Nothing is blocked "
                     + "yet — you make the first rule on the next screen.")
                    .font(GateTheme.Typography.body)
                    .foregroundStyle(GateTheme.textSecondary)
            }
            .gateCard()

            VStack(alignment: .leading, spacing: GateTheme.Spacing.s) {
                Text("Optional: make the escape hatch cost more")
                    .font(GateTheme.Typography.headline)
                    .foregroundStyle(GateTheme.textPrimary)

                Text("If you set a Screen Time passcode, turning Gate off in Settings takes "
                     + "extra steps. It does not make Gate unremovable, and Gate cannot tell "
                     + "whether you have one.")
                    .font(GateTheme.Typography.body)
                    .foregroundStyle(GateTheme.textSecondary)

                Text("The version of this that actually works: have someone else type the "
                     + "passcode and not tell you. That turns four taps into a conversation, "
                     + "which is the whole idea.")
                    .font(GateTheme.Typography.body)
                    .foregroundStyle(GateTheme.textSecondary)

                Text("Settings › Screen Time › Lock Screen Time Settings")
                    .font(GateTheme.Typography.footnote)
                    .foregroundStyle(GateTheme.textTertiary)

                Button {
                    openSettings()
                } label: {
                    Label("Open Settings", systemImage: "arrow.up.forward.app")
                        .frame(minHeight: GateTheme.Spacing.minimumTapTarget)
                }
                .buttonStyle(.bordered)
                .tint(GateTheme.accent)
            }
            .gateCard()

            Button {
                model.completeOnboarding()
            } label: {
                Text("Make my first rule")
                    .font(GateTheme.Typography.headline)
                    .frame(maxWidth: .infinity, minHeight: GateTheme.Spacing.minimumTapTarget)
            }
            .buttonStyle(.borderedProminent)
            .tint(GateTheme.accent)
            .disabled(!model.isOperational)

            Button("Skip the passcode for now") {
                model.completeOnboarding()
            }
            .font(GateTheme.Typography.callout)
            .tint(GateTheme.textSecondary)
            .frame(maxWidth: .infinity, minHeight: GateTheme.Spacing.minimumTapTarget)
        }
    }

    // MARK: Errors

    /// `AppModel.authorizationFailure` is the one `var` on the model a screen may
    /// write, and it is presentation state rather than anything durable: clearing
    /// it dismisses the alert. Nothing enforceable is reachable from here.
    private var authorizationFailureIsPresented: Binding<Bool> {
        Binding(
            get: { model.authorizationFailure != nil },
            set: { isPresented in
                if !isPresented { model.authorizationFailure = nil }
            }
        )
    }

    /// `UIApplication.openSettingsURLString` is the only *documented* way into
    /// Settings.
    ///
    /// Deliberately not an `App-prefs:` sub-path such as `App-prefs:SCREEN_TIME`:
    /// those are undocumented, have been rejected under Guideline 2.5.1, and
    /// break silently between releases. The exact path is spelled out in the copy
    /// above instead, which costs the user two taps and costs Gate nothing.
    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(url)
    }
}

#if DEBUG
// The model is built inside the preview body, which the `#Preview` macro makes
// `@MainActor`. A `@State private var model = AppModel()` on a `View` would call
// a main-actor initializer from the struct's non-isolated memberwise init, which
// Swift 6 rejects — `App` gets away with it because `App.init()` is itself
// `@MainActor`.
#Preview("Onboarding") {
    OnboardingScreen()
        .environment(AppModel())
}
#endif
