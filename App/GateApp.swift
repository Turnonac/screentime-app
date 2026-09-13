//
//  GateApp.swift
//  Gate
//
//  Build plan: docs/06-build-plan.md step 5.7 — "Reconcile-on-foreground".
//
//  This file owns four things and nothing else:
//
//  1. **The scene-phase hook.** Every `scenePhase == .active` polls
//     `authorizationStatus`, resolves the Lock clock against the Keychain, runs
//     `Reconciler.reconcile`, drains `inbox/`, and re-arms the
//     `UNCalendarNotificationTrigger` backstops (docs/04-product-spec.md V1-10).
//     The ordered work itself lives in `AppModel.activate(trigger:)`; this file
//     decides *when*.
//
//  2. **Notification authorization.** Requested here, from the app, because
//     **extensions cannot present the permission prompt**. If the app never
//     asks, every notification `GateShieldAction` posts — which on iOS < 26.5 is
//     the *entire* intervention hand-off (docs/04-product-spec.md V1-7) — is
//     silently dropped with no error anywhere.
//
//  3. **The `UNUserNotificationCenterDelegate`.** A notification tap is how the
//     sub-26.5 shield fallback reaches `InterventionScreen`, and it has to work
//     on a cold launch, which is why the delegate is installed in `init()` and
//     buffers whatever arrives before the model is attached.
//
//  4. **The deep link.** `gate://intervention?rule=…&request=…`, parsed by
//     `GateID.intervention(from:)`. The URL is a pointer, never a payload: any
//     app on the device can open `gate://`, so the two UUIDs only ever name a
//     record Gate wrote itself.
//

import SwiftUI
import UserNotifications
import os

import GateKernel
import GateKernelUI

private var launchLog: Logger {
    Logger(subsystem: GateID.Subsystem.app, category: "Launch")
}

// MARK: - GateApp

@main
struct GateApp: App {

    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Installed before the first frame so a cold launch from a notification
        // tap is delivered to us rather than dropped. The router buffers until
        // `RootView` hands it the model.
        let center = UNUserNotificationCenter.current()
        center.delegate = GateNotificationRouter.shared
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: GateID.Notifications.interventionCategory,
                actions: [],
                intentIdentifiers: [],
                options: []
            ),
            UNNotificationCategory(
                identifier: GateID.Notifications.backstopCategory,
                actions: [],
                intentIdentifiers: [],
                options: []
            )
        ])
        launchLog.log("notification delegate and categories registered")
    }

    var body: some Scene {
        // Hoisted out of the closures below on purpose. `task(_:)` takes a
        // `@Sendable` closure, which does **not** inherit this scene's main-actor
        // isolation; capturing the `AppModel` *value* (a `@MainActor` class, and
        // therefore `Sendable`) sidesteps the question entirely, where reaching
        // through `self` into a property wrapper would depend on how the SDK
        // annotates it.
        let model = self.model

        return WindowGroup {
            RootView()
                .environment(model)
                .task {
                    // Attaching the model flushes anything the router buffered
                    // during the cold launch. `MainActor.run` because the router
                    // is main-actor isolated and this closure is not.
                    await MainActor.run {
                        GateNotificationRouter.shared.attach(model)
                    }
                    await model.activate(trigger: .launch)
                }
                .onChange(of: scenePhase) { _, phase in
                    // docs/06-build-plan.md step 5.7. `.active` is the only phase
                    // that does work: `.inactive` fires for a control-centre pull
                    // and a notification banner, and reconciling on those would
                    // write every `ManagedSettingsStore` several times a minute.
                    guard phase == .active else { return }
                    Task { await model.activate(trigger: .foreground) }
                }
                .onOpenURL { url in
                    model.handle(url: url)
                }
        }
    }
}

// MARK: - RootView

/// Chooses the screen, and hosts the two modals that can be raised from
/// anywhere: the intervention (V1-7) and recovery (V1-9).
struct RootView: View {

    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        Group {
            switch model.startup {
            case .containerUnavailable(let detail):
                StartupFailureView(
                    title: "Gate cannot reach its own storage",
                    detail: "The App Group container did not resolve, so nothing is being "
                        + "enforced right now. This is a configuration problem, not something "
                        + "you did.",
                    technical: detail
                )

            case .stateUnreadable(let detail):
                StartupFailureView(
                    title: "Gate's settings file could not be read",
                    detail: "Your rules are still on the device and every block that was "
                        + "already applied is still applied — Gate has deliberately left them "
                        + "alone rather than guessing. Reinstalling would clear the file, but "
                        + "note that the Lock's deadline lives in the Keychain and survives a "
                        + "reinstall by design.",
                    technical: detail
                )

            case .pending, .ready:
                if model.needsOnboarding {
                    OnboardingScreen()
                } else {
                    HomeScreen()
                }
            }
        }
        .sheet(item: $model.activeIntervention) { request in
            InterventionScreen(request: request)
                .environment(model)
        }
        .sheet(item: $model.recovery) { trigger in
            RecoveryScreen(trigger: trigger)
                .environment(model)
        }
    }
}

// MARK: - StartupFailureView

/// Shown when the app genuinely cannot do its job.
///
/// It says what is and is not still enforced, because the difference matters
/// enormously and the user has no other way to find out.
private struct StartupFailureView: View {

    let title: String
    let detail: String
    let technical: String

    @State private var showsTechnical = false

    var body: some View {
        VStack(alignment: .leading, spacing: GateTheme.Spacing.l) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle)
                .foregroundStyle(GateTheme.danger)

            Text(title)
                .font(GateTheme.Typography.title)
                .foregroundStyle(GateTheme.textPrimary)

            Text(detail)
                .font(GateTheme.Typography.body)
                .foregroundStyle(GateTheme.textSecondary)

            DisclosureGroup("Technical details", isExpanded: $showsTechnical) {
                Text(technical)
                    .font(GateTheme.Typography.footnote)
                    .foregroundStyle(GateTheme.textTertiary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .tint(GateTheme.accent)

            Spacer()
        }
        .padding(GateTheme.Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(GateTheme.background)
    }
}

// MARK: - GateNotificationRouter

/// Routes notification taps into the model.
///
/// Two shapes arrive here, both posted by `GateShieldAction`:
///
/// * `gate.intervention.<requestID>` — the sub-26.5 "Let me in" hand-off, and
///   the 12-second silent backstop posted *behind* `.openParentalControlsApp` on
///   26.5+, because whether that response works under `.individual`
///   authorization is *(unverified)* (docs/02-api-reference.md §10). Carries the
///   deep link in `userInfo[GateID.Notifications.urlKey]`.
/// * `gate.backstop.<…>` — a `UNCalendarNotificationTrigger` armed by the app at
///   a schedule boundary. It carries no payload; the tap *is* the payload,
///   because opening the app is a reconcile (docs/04-product-spec.md V1-10).
///
/// `@MainActor` on the class, `nonisolated` on the two delegate methods.
/// `UNUserNotificationCenterDelegate` makes no main-thread promise, and a
/// `nonisolated` witness satisfies the requirement whichever way the SDK
/// annotates it. Only `Sendable` values are lifted out before the hop; the
/// completion handlers themselves are **never** captured by the `Task`, because
/// an ObjC-imported block is not guaranteed `@Sendable`.
@MainActor
final class GateNotificationRouter: NSObject, UNUserNotificationCenterDelegate {

    static let shared = GateNotificationRouter()

    private weak var model: AppModel?

    /// A link that arrived before the model existed — i.e. a cold launch from a
    /// notification tap, which is the *normal* way this app is opened on
    /// iOS < 26.5. Dropping it would swallow the user's tap entirely.
    private var bufferedURL: URL?

    func attach(_ model: AppModel) {
        self.model = model
        if let url = bufferedURL {
            bufferedURL = nil
            model.handle(url: url)
        }
    }

    private func route(url: URL?) {
        guard let url else {
            // A backstop tap. No payload by design; the activation already
            // reconciles, so there is nothing more to do.
            launchLog.debug("backstop notification tapped")
            return
        }
        guard let model else {
            bufferedURL = url
            return
        }
        model.handle(url: url)
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        // Lift out only `Sendable` values, then hop. `UNNotificationResponse` is
        // a reference type with no audited conformance and must not cross.
        let urlString = response.notification.request.content
            .userInfo[GateID.Notifications.urlKey] as? String
        let url = urlString.flatMap(URL.init(string:))

        Task { @MainActor in
            GateNotificationRouter.shared.route(url: url)
        }

        // Called synchronously rather than from inside the `Task`: the contract
        // is "call it when you are finished handling", the handling above is a
        // single enqueue, and capturing the block would require a `@Sendable`
        // guarantee the ObjC import does not make.
        completionHandler()
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let category = notification.request.content.categoryIdentifier
        let urlString = notification.request.content
            .userInfo[GateID.Notifications.urlKey] as? String
        let url = urlString.flatMap(URL.init(string:))

        if category == GateID.Notifications.interventionCategory {
            // The user is already looking at Gate, so a banner telling them to
            // open Gate is noise. Route straight to the intervention instead.
            Task { @MainActor in
                GateNotificationRouter.shared.route(url: url)
            }
            completionHandler([])
            return
        }

        if category == GateID.Notifications.backstopCategory {
            // Likewise: being foreground already got us the reconcile the
            // backstop existed to trigger.
            completionHandler([])
            return
        }

        completionHandler([.banner, .list, .sound])
    }
}
