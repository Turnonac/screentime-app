//
//  GateShieldAction.swift
//  GateShieldAction
//
//  What happens when someone presses a button on the shield.
//  Build plan: docs/06-build-plan.md step 4.3.
//  Product spec: docs/04-product-spec.md V1-7 (the intervention), V1-11 (stats).
//
//  WHAT THIS PROCESS IS
//  --------------------
//  `ShieldActionDelegate` is the only Gate extension that *writes*, and it writes
//  exactly one kind of thing: an append-only record into `inbox/`. It never
//  touches `state.plist`, never touches `shield.plist`, never writes a
//  `ManagedSettingsStore`. The app compacts `inbox/` into `GateState` on its next
//  foreground reconcile (docs/05-architecture.md, single-writer discipline).
//
//  Like the configuration extension it is network-blocked and latency-bounded
//  (docs/03-hard-constraints.md #33), so everything here is synchronous. There is
//  no `Task`, no `await`, no dispatch to another queue: the completion handler
//  must be called before this method returns or the shield hangs, and a `Task`
//  that outlives the call is a `Task` the system may never run.
//
//  THE ONE RULE THIS FILE ENFORCES
//  ------------------------------
//  **Never record an unblock you cannot guarantee you can end.**
//
//  That is what "on scheduling failure, roll the grant back before responding"
//  (docs/06-build-plan.md step 4.3) actually means. The record in `inbox/` is a
//  promise that the app will lift part of a shield; the one-shot
//  `gate.grant:<ruleUUID>|<recordUUID>` activity is the only thing that
//  guarantees a monitor callback arrives to put it back if the user never opens
//  Gate again. If the activity cannot be armed — the 20-activity budget is full,
//  the deadline is past the one-week ceiling — the record is deleted and the
//  shield stays up. Failing closed costs the user one refused tap. Failing open
//  costs them the block.
//
//  WHAT IT DOES NOT DO
//  -------------------
//  It does not issue a ``Grant``. V1-7 is wait → typed reason → grant, and the
//  wait and the reason both live in the app. The kernel is explicit about this:
//  `Reconciler.fold` never issues a grant for a `.grantRequest` event, because
//  that event means *"the user tapped Let me in"*, not *"the user earned an
//  unblock"*. This file records the tap and hands off.
//
//  It also does not decrement the daily budget. docs/04-product-spec.md V1-7 says
//  the budget is "decremented in `ShieldActionDelegate`", but an extension cannot
//  write `state.plist` without breaking the single-writer rule that keeps the
//  file consistent for the 6 MB monitor. So the decrement happens exactly once,
//  in the app, when the grant is actually issued — and the *check* that happens
//  here (submenu path only) counts in-flight inbox records so a stale ledger
//  cannot be spent twice (``GrantEngine/inFlightCount(in:now:maxAge:)``).
//

import Foundation
import DeviceActivity
import ManagedSettings
import UserNotifications
import os

import GateKernel

// Computed, not a stored global: `Logger` has no audited `Sendable` conformance
// and a stored global of such a type is a Swift 6 strict-concurrency error.
// `print()` is invisible from an extension (docs/06-build-plan.md step 4.1).
private var log: Logger {
    Logger(subsystem: GateID.Subsystem.shieldAction, category: "handler")
}

// MARK: - GateShieldAction

/// The principal class named by `NSExtensionPrincipalClass` in
/// `Config/ShieldAction-Info.plist` as `$(PRODUCT_MODULE_NAME).GateShieldAction`.
///
/// **Three overrides, not four.** `ShieldConfigurationDataSource` has four
/// (application, application-in-category, web domain, web-domain-in-category);
/// `ShieldActionDelegate` has three — application, category, web domain — because
/// an action is delivered against the token that was shielded, and a category
/// shield reports the category (docs/02-api-reference.md §10). There is no
/// `handle(action:for:in:)` to override; adding one would not compile.
///
/// **The asymmetry that bites:** the configuration extension is handed an
/// `Application` carrying a display name and a bundle identifier; this one is
/// handed a bare `ApplicationToken`. Apple: *"The system doesn't provide the name
/// of a shielded Application, ActivityCategory, or WebDomain to preserve the
/// Family Sharing group's privacy."* Everything this file knows about *which*
/// rule was hit comes from looking the token's fingerprint up in `shield.plist`,
/// and that lookup is allowed to miss.
///
/// **No `super` calls.** `DeviceActivityMonitor`'s overrides must always call
/// `super` (docs/02-api-reference.md §8); these must not. The superclass
/// implementation invokes the completion handler with its own default, so calling
/// it here would answer the same action twice — and a duplicated
/// `ShieldActionResponse` is a crash in a process whose crash the user sees only
/// as a shield that vanished.
final class GateShieldAction: ShieldActionDelegate {

    // MARK: Overrides

    override func handle(
        action: ShieldAction,
        for application: ApplicationToken,
        completionHandler: @escaping (ShieldActionResponse) -> Void
    ) {
        respond(
            to: action,
            token: encoding(.application) { try TokenGuard.encode(application) },
            tokenKind: .application,
            completionHandler: completionHandler
        )
    }

    override func handle(
        action: ShieldAction,
        for category: ActivityCategoryToken,
        completionHandler: @escaping (ShieldActionResponse) -> Void
    ) {
        respond(
            to: action,
            token: encoding(.category) { try TokenGuard.encode(category) },
            tokenKind: .category,
            completionHandler: completionHandler
        )
    }

    override func handle(
        action: ShieldAction,
        for webDomain: WebDomainToken,
        completionHandler: @escaping (ShieldActionResponse) -> Void
    ) {
        respond(
            to: action,
            token: encoding(.webDomain) { try TokenGuard.encode(webDomain) },
            tokenKind: .webDomain,
            completionHandler: completionHandler
        )
    }

    // MARK: - The one handler

    /// Every path through this method calls `completionHandler` exactly once, and
    /// none of them can throw. Failing to respond leaves the shield's button spun
    /// forever; responding twice is a duplicate-callback crash in a process whose
    /// crash is invisible to the user.
    private func respond(
        to action: ShieldAction,
        token: EncodedToken?,
        tokenKind: TokenKind,
        completionHandler: @escaping (ShieldActionResponse) -> Void
    ) {
        let now = Date()
        let kind = Self.actionKind(of: action)

        // Everything below is best effort. Not one of these failures may stop a
        // response — a shield extension that dies takes the shield with it
        // (docs/03-hard-constraints.md #33).
        let inbox = try? InboxStore()
        let table = try? ShieldCopyFile.read()
        let ruleID = token.flatMap { table?.ruleID(forToken: $0) }

        // A token the app shielded but cannot now recognise is the documented
        // stale-token signature: tokens are reissued across OS updates and
        // re-authorization and stop matching stored copies
        // (docs/03-hard-constraints.md #36, thread 814571 — Apple asked for a
        // Feedback and gave no workaround). The app turns this record into the
        // reselection flow, which is a first-class screen, not an error path
        // (docs/04-product-spec.md V1-9).
        //
        // Two conditions keep this honest. A table must actually have been read —
        // with no `shield.plist` at all, *nothing* resolves, and that is a
        // publishing failure rather than an expired token. And the token must have
        // encoded — a codec failure is this file's problem, not iOS's, and
        // reporting it as an expiry would send the user to reselect apps that are
        // fine. An allowlist rule cannot trip this either: it resolves through
        // `catchAllRuleIDs`, so `ruleID` is non-`nil`.
        if table != nil, token != nil, ruleID == nil, let inbox {
            inbox.appendBestEffort(
                InboxEvent.tokenExpiry(ruleID: nil, source: Self.breadcrumbSource, now: now)
            )
        }

        switch kind {
        case .secondaryButton:
            dismiss(
                token: token, tokenKind: tokenKind, ruleID: ruleID,
                inbox: inbox, now: now, completionHandler: completionHandler
            )

        case .primaryButton:
            handOff(
                token: token, tokenKind: tokenKind, ruleID: ruleID,
                inbox: inbox, now: now, completionHandler: completionHandler
            )

        case .firstSubmenuItem, .secondSubmenuItem, .thirdSubmenuItem:
            grantFromSubmenu(
                kind: kind, token: token, tokenKind: tokenKind, ruleID: ruleID,
                inbox: inbox, now: now, completionHandler: completionHandler
            )
        }
    }

    // MARK: "Not now"

    /// The outcome the product is trying to produce.
    ///
    /// Recorded, not ignored: an ``InterventionRequest`` that resolves without a
    /// grant **is** the bypass-attempt record — there is no second record type —
    /// and it is the only usage data Gate is allowed to have about itself
    /// (docs/03-hard-constraints.md #25, #30; V1-11's counter, V2-5's stats).
    private func dismiss(
        token: EncodedToken?,
        tokenKind: TokenKind,
        ruleID: UUID?,
        inbox: InboxStore?,
        now: Date,
        completionHandler: @escaping (ShieldActionResponse) -> Void
    ) {
        // `grantRequestEvent` maps `.secondaryButton` to `.bypassAttempt`, so the
        // kind and the recorded action can never disagree.
        if let inbox {
            inbox.appendBestEffort(
                GrantEngine.grantRequestEvent(
                    ruleID: ruleID, token: token, tokenKind: tokenKind,
                    action: .secondaryButton, now: now
                )
            )
        }
        completionHandler(.close)
    }

    // MARK: "Let me in" — V1-7

    private func handOff(
        token: EncodedToken?,
        tokenKind: TokenKind,
        ruleID: UUID?,
        inbox: InboxStore?,
        now: Date,
        completionHandler: @escaping (ShieldActionResponse) -> Void
    ) {
        guard let inbox else {
            // No App Group, no record, and therefore nothing for the app to show
            // if it were opened. Keep the shield up rather than handing off to a
            // blank screen.
            log.fault("inbox unavailable — refusing the hand-off and keeping the shield up")
            completionHandler(Self.keepShieldUp)
            return
        }

        let event = GrantEngine.grantRequestEvent(
            ruleID: ruleID, token: token, tokenKind: tokenKind,
            action: .primaryButton, now: now
        )

        guard inbox.appendBestEffort(event) else {
            log.fault("could not record the intervention request — keeping the shield up")
            completionHandler(Self.keepShieldUp)
            return
        }

        // Arm the backstop that ends the unblock, if there is an unblock to end.
        //
        // With no resolved rule there is nothing a grant could be scoped to: the
        // app will deny this request as `.ruleUnresolved` and route to recovery,
        // so no timer is owed and there is nothing to roll back.
        if let ruleID {
            let state = Self.loadState(now: now)
            let policy = state?.grantPolicy ?? .default

            // The latest instant a grant born from *this* request can expire: the
            // user has ``InterventionRequest/maxAge`` to complete the intervention,
            // and the grant runs for its duration from whenever it is issued.
            // Arming past the true expiry is harmless — the reconciler recomputes
            // `Grant.isActive(at:)` from absolute timestamps and the activity is
            // only an accelerator. Arming *before* it would burn the one-shot on a
            // grant that is still live and leave nothing to end it.
            let horizon = now
                .addingTimeInterval(InterventionRequest.maxAge)
                .addingTimeInterval(GrantPolicy.clampDuration(policy.defaultDuration))

            // The grant id is the request id. `GrantEngine.issue(for:…)` takes an
            // explicit `grantID:`, so the app adopts this one rather than minting
            // a second — which is what makes the timer armed here name the grant
            // that eventually exists. If the app ever stops doing that, this timer
            // becomes an orphan and the reconciler's sweep stops it on the next
            // pass; it does not leak.
            guard arm(.grant(ruleID: ruleID, grantID: event.id), deadline: horizon, now: now) else {
                rollBack(event, in: inbox)
                // Interpolate `uuidString`, never the `UUID` itself: `OSLogMessage`
                // only has overloads for strings, numbers, booleans and `NSObject`.
                log.error("""
                    could not arm the expiry timer for rule \
                    \(ruleID.uuidString, privacy: .public) — \
                    rolled the request back and kept the shield up
                    """)
                completionHandler(Self.keepShieldUp)
                return
            }
        }

        completionHandler(handOffResponse(ruleID: ruleID, requestID: event.id))
    }

    /// How the user gets from here to `App/Screens/InterventionScreen.swift`.
    ///
    /// **Both halves of this are marked (unverified) by the spec and must be
    /// device-tested on day 1** (docs/02-api-reference.md §10; gate at
    /// docs/06-build-plan.md 2.5a):
    ///
    /// 1. *(unverified)* whether `.openParentalControlsApp` works at all under
    ///    `FamilyControlsMember.individual` — Apple's wording is parental-centric
    ///    and there are no field reports.
    /// 2. *(unverified)* whether it passes any context. Assume it cold-launches
    ///    with no payload, which is why the request is already in `inbox/` before
    ///    this method is called: the App Group is the hand-off, the response is
    ///    only the trigger.
    ///
    /// The defensive answer to (1) is the same notification the sub-26.5 path uses,
    /// posted a few seconds out instead of immediately. If the hand-off works, the
    /// app foregrounds and cancels the pending request before it fires. If it
    /// silently does nothing, the user still gets a tappable way back rather than
    /// a shield that ate their tap.
    private func handOffResponse(ruleID: UUID?, requestID: UUID) -> ShieldActionResponse {
        if #available(iOS 26.5, *) {
            postInterventionNotification(
                ruleID: ruleID,
                requestID: requestID,
                delay: Self.handOffBackstopDelay,
                withSound: false
            )
            return .openParentalControlsApp
        }

        // Below 26.5 there is no supported way for an app to bring itself to the
        // foreground, and Family Controls grants no exception
        // (docs/03-hard-constraints.md #19). The notification *is* the path
        // (docs/04-product-spec.md V1-7, fallback paragraph) — and the in-app copy
        // has to say plainly that this is an OS limitation.
        postInterventionNotification(
            ruleID: ruleID, requestID: requestID, delay: nil, withSound: true
        )
        return .close
    }

    // MARK: Submenu grants — V2-1, iOS 26.4+

    /// The three submenu items: "1 more minute" / "15 more minutes" / "1 hour".
    ///
    /// Unreachable in v1: ``ShieldCopy/submenuItems`` is empty, so the shield
    /// renders no submenu and iOS never sends these actions. Implemented anyway —
    /// the alternative is shipping an extension that silently `.close`s on an
    /// action a future build's shield will offer, and discovering it on a device.
    private func grantFromSubmenu(
        kind: ShieldActionKind,
        token: EncodedToken?,
        tokenKind: TokenKind,
        ruleID: UUID?,
        inbox: InboxStore?,
        now: Date,
        completionHandler: @escaping (ShieldActionResponse) -> Void
    ) {
        guard let inbox, let ruleID else {
            log.error("submenu grant with no inbox or no resolved rule — keeping the shield up")
            completionHandler(Self.keepShieldUp)
            return
        }

        let state = Self.loadState(now: now)
        let policy = state?.grantPolicy ?? .default
        let duration = Self.submenuDuration(for: kind)

        // Budget. `state.plist` is stale between a shield tap and the next app
        // foreground — the extension cannot write it — so the ledger alone would
        // let a day's grants be spent several times over. Counting the unresolved
        // records already sitting in `inbox/` closes that
        // (``GrantEngine/inFlightCount(in:now:maxAge:)``; the double-spend note on
        // ``GrantEngine/Budget``).
        let inFlight = GrantEngine.inFlightCount(in: (try? inbox.peek()) ?? [], now: now)
        let budget = GrantEngine.budget(
            ledger: state?.grantLedger ?? GrantLedger(),
            policy: policy,
            now: now,
            inFlight: inFlight
        )

        guard budget.hasBudget else {
            // Running out is a *tightening*: immediate, no Lock, no
            // `PendingChange` (docs/04-product-spec.md V1-7). Record the tap as
            // the bypass attempt it now is and leave the shield up.
            inbox.appendBestEffort(
                InboxEvent(
                    kind: .bypassAttempt,
                    createdAt: now,
                    ruleID: ruleID,
                    payload: GrantEngine.inboxPayload(
                        action: kind, token: token, kind: tokenKind, duration: duration
                    )
                )
            )
            log.notice("submenu grant refused: daily budget exhausted")
            completionHandler(Self.keepShieldUp)
            return
        }

        // `.grantIssued` rather than `.grantRequest`: the button named the
        // duration, so there is nothing left to negotiate and the app should apply
        // it rather than re-running the intervention screen. The ledger is still
        // decremented in exactly one place — the app re-issues this through
        // `GrantEngine.issue` like everything else.
        let event = InboxEvent(
            kind: .grantIssued,
            createdAt: now,
            ruleID: ruleID,
            payload: GrantEngine.inboxPayload(
                action: kind, token: token, kind: tokenKind, duration: duration
            )
        )

        guard inbox.appendBestEffort(event) else {
            log.fault("could not record the submenu grant — keeping the shield up")
            completionHandler(Self.keepShieldUp)
            return
        }

        guard arm(
            .grant(ruleID: ruleID, grantID: event.id),
            deadline: policy.expiry(from: now, duration: duration),
            now: now
        ) else {
            rollBack(event, in: inbox)
            log.error("could not arm the submenu grant's expiry timer — rolled it back")
            completionHandler(Self.keepShieldUp)
            return
        }

        // `.close` rather than `.openParentalControlsApp`: the point of the
        // submenu is that it does not require the app. Note the honest limitation
        // — the shield set is not rewritten here (that needs the rule's decoded
        // `FamilyActivitySelection`, which is the app's job), so the lift lands on
        // the next reconcile. The one-shot armed above starts at the beginning of
        // today, i.e. it is already ongoing, so iOS delivers `intervalDidStart`
        // almost immediately (docs/02-api-reference.md §7) and the monitor wakes.
        completionHandler(.close)
    }

    // MARK: - Arming and rollback

    /// Arms a one-shot `gate.grant:` activity whose `intervalDidEnd` is the
    /// monitor's cue to put the shield back.
    ///
    /// Returns `false` — never throws — for every reason the arm can fail, which
    /// the caller turns into a rollback:
    ///
    /// * `.excessiveActivities`: the 20-activity cap is shared by the app *and*
    ///   all of its extensions (docs/02-api-reference.md §14). Repeated taps that
    ///   never become grants do not accumulate forever: `MonitorPlan.diff` sweeps
    ///   activities that no record in `GateState` explains.
    /// * `.intervalTooLong` / `.intervalTooShort` / `.invalidDateComponents`:
    ///   ``ScheduleBuilder/oneShotSpec(deadline:now:calendar:)`` already corrects
    ///   the late-night floor, the one-week ceiling and fall-back DST ambiguity,
    ///   so reaching one of these means the deadline itself was unreasonable.
    /// * `.unauthorized`: authorization was revoked between the shield going up
    ///   and this tap. Four taps in Settings is all it takes and there is no API
    ///   to detect it (docs/03-hard-constraints.md #14).
    private func arm(_ activity: GateActivity, deadline: Date, now: Date) -> Bool {
        switch ScheduleBuilder.oneShotSpec(deadline: deadline, now: now) {
        case .unschedulable(let reason):
            log.error("""
                cannot schedule \(activity.rawName, privacy: .public): \
                \(reason.rawValue, privacy: .public)
                """)
            return false

        case .scheduled(let spec, _):
            do {
                // No `stopMonitoring` first: the name carries a freshly minted
                // UUID, so there is nothing of ours to overwrite
                // (docs/02-api-reference.md §7 is about re-arming an existing
                // name). `events:` defaults to empty — v1 arms no threshold
                // events, and `eventDidReachThreshold` is the least reliable part
                // of the API (docs/03-hard-constraints.md #35).
                try DeviceActivityCenter().startMonitoring(
                    activity.activityName,
                    during: spec.deviceActivitySchedule
                )
                return true
            } catch {
                log.error("""
                    startMonitoring failed for \(activity.rawName, privacy: .public): \
                    \(String(describing: error), privacy: .public)
                    """)
                return false
            }
        }
    }

    /// Deletes a record this handler appended moments ago.
    ///
    /// ``InboxStore`` has no `remove` — the app owns deletion, through `drain()` —
    /// so this reaches for the file directly. That is safe precisely because it is
    /// the file *this* call just wrote: the name carries a fresh UUID, so no other
    /// writer can own it, and a concurrent drain either took it already (in which
    /// case the removal is a no-op and the app has a request it will expire by
    /// ``InterventionRequest/maxAge``) or has not seen it.
    @discardableResult
    private func rollBack(_ event: InboxEvent, in inbox: InboxStore) -> Bool {
        let url = inbox.directoryURL.appendingPathComponent(event.fileName, isDirectory: false)
        do {
            try FileManager.default.removeItem(at: url)
            return true
        } catch {
            // Absence is success: the app drained it between the append and here.
            guard FileManager.default.fileExists(atPath: url.path) else { return true }
            log.fault("""
                could not roll back \(event.fileName, privacy: .public): \
                \(String(describing: error), privacy: .public) — \
                the app will expire this request by maxAge
                """)
            return false
        }
    }

    // MARK: - Notifications

    /// Identifier prefix for the intervention hand-off notification:
    /// `"gate.intervention."` + the request's UUID.
    ///
    /// **Derived from ``GateID/Notifications/interventionCategory``, not written
    /// out.** This extension is an `.appex` — the app cannot import it and cannot
    /// see this constant — so the only way the app can reconstruct the same prefix
    /// is to build it from something both modules already share. That is what
    /// makes this a contract rather than a duplicated literal.
    ///
    /// **The app must cancel these.** On iOS 26.5 the notification is posted as a
    /// delayed backstop *behind* `.openParentalControlsApp`; when the hand-off
    /// works, the app foregrounds first and should call
    /// `removePendingNotificationRequests(withIdentifiers:)` for every pending
    /// request whose identifier starts with this prefix. It must **not** call
    /// `removeAllPendingNotificationRequests()` — that would also wipe the
    /// `UNCalendarNotificationTrigger` backstops V1-10 re-arms at every schedule
    /// boundary (`ReconcileReport.backstopDates`).
    ///
    /// The request id is recoverable from the delivered notification without this
    /// prefix at all: `userInfo[GateID.Notifications.urlKey]` is the deep link and
    /// `GateID.intervention(from:)` parses both UUIDs back out of it. There is
    /// deliberately no second `userInfo` key carrying the id on its own — one
    /// representation, one parser.
    static let notificationIdentifierPrefix = GateID.Notifications.interventionCategory + "."

    /// How long after `.openParentalControlsApp` the backstop fires.
    ///
    /// Long enough for a cold launch plus the first reconcile, short enough that a
    /// silently-failed hand-off does not feel like the button did nothing. A
    /// spurious banner when the hand-off *worked* is the cost of treating
    /// `.openParentalControlsApp` as unverified, and it is the cheap direction to
    /// be wrong in.
    private static let handOffBackstopDelay: TimeInterval = 12

    /// Posts the deep-link notification described in docs/04-product-spec.md V1-7.
    ///
    /// The URL is a **pointer, not a payload**: two UUIDs, nothing else. Any other
    /// installed app can claim `gate://`, so the app re-reads the real record out
    /// of the App Group and never trusts anything in the link
    /// (see `GateID.interventionURL(ruleID:requestID:)`).
    ///
    /// Authorization is the app's to request, during onboarding — an extension has
    /// no UI and cannot prompt. If it was never granted, `add` fails and is logged;
    /// on the sub-26.5 path that is a dead end for this tap, which is one more
    /// reason onboarding must ask.
    ///
    /// Deliberately **not** `.timeSensitive`: that interruption level needs
    /// `com.apple.developer.usernotifications.time-sensitive`, and
    /// `Config/Gate-Extension.entitlements` carries exactly two keys on purpose —
    /// every entitlement an `.appex` holds is one more thing that has to match its
    /// provisioning profile (project.yml, docs/02-api-reference.md §2).
    private func postInterventionNotification(
        ruleID: UUID?,
        requestID: UUID,
        delay: TimeInterval?,
        withSound: Bool
    ) {
        // A tap with no resolved rule still deserves a way back. The all-zero
        // sentinel already means "not scoped to a rule" elsewhere in the product
        // (``GateActivity/unscopedID``) and cannot collide with a real `Rule.id`,
        // because `UUID()` cannot generate it. The request id is the key that
        // matters; the rule id is a hint the app is free to ignore.
        let url = GateID.interventionURL(
            ruleID: ruleID ?? GateActivity.unscopedID,
            requestID: requestID
        )

        let content = UNMutableNotificationContent()
        // Static copy, and careful not to promise something the platform cannot
        // do: Gate cannot open the blocked app for the user afterwards — it holds
        // only an opaque token, and `OpenAppFromApplicationTokenIntent`
        // (FB15500695) got no Apple response (docs/03-hard-constraints.md #20).
        // The notification leads to Gate, and Gate then says "press Home and tap
        // the app" (docs/04-product-spec.md V1-7 step 4).
        content.title = "Ready when you are"
        content.body = "Tap to continue in Gate."
        content.categoryIdentifier = GateID.Notifications.interventionCategory
        content.userInfo = [GateID.Notifications.urlKey: url.absoluteString]
        if withSound { content.sound = .default }

        // `repeats: false` has no 60-second floor, so a short backstop is legal.
        // Typed as the base class: `UNNotificationRequest` takes
        // `UNNotificationTrigger?`, and `nil` here means "deliver now".
        let trigger: UNNotificationTrigger? = delay.map {
            UNTimeIntervalNotificationTrigger(timeInterval: max($0, 1), repeats: false)
        }

        let request = UNNotificationRequest(
            identifier: Self.notificationIdentifierPrefix + requestID.uuidString,
            content: content,
            trigger: trigger
        )

        // Fire and forget. `add` hands the request across to `usernotificationd`
        // during the call and only the acknowledgement is asynchronous, so
        // answering the shield immediately afterwards — which this extension must
        // do — does not drop the notification. The closure captures only
        // `requestID`, a `Sendable` value, so it holds nothing that could outlive
        // the process it is logging from.
        //
        // Worth confirming on device alongside the two `.openParentalControlsApp`
        // unknowns: if a fast teardown *does* eat the request, the sub-26.5 path
        // has no other way home.
        UNUserNotificationCenter.current().add(request) { error in
            guard let error else { return }
            log.error("""
                could not post the intervention notification for \
                \(requestID.uuidString, privacy: .public): \
                \(String(describing: error), privacy: .public)
                """)
        }
    }

    // MARK: - Mapping and environment

    /// Source string for the breadcrumb / token-expiry records this file writes.
    private static let breadcrumbSource = "shield-action"

    /// `ShieldAction` → ``ShieldActionKind``.
    ///
    /// The three submenu cases are iOS 26.4 symbols (docs/02-api-reference.md §13),
    /// so they can only be *named* inside `if #available`. An action this build
    /// does not recognise maps to `.secondaryButton`, i.e. it is recorded as a
    /// dismissal and the app is closed: for an unknown button on a future OS, the
    /// conservative answer is the one that keeps the block.
    private static func actionKind(of action: ShieldAction) -> ShieldActionKind {
        if #available(iOS 26.4, *) {
            switch action {
            case .firstSecondarySubmenuItemPressed: return .firstSubmenuItem
            case .secondSecondarySubmenuItemPressed: return .secondSubmenuItem
            case .thirdSecondarySubmenuItemPressed: return .thirdSubmenuItem
            default: break
            }
        }

        switch action {
        case .primaryButtonPressed:
            return .primaryButton
        case .secondaryButtonPressed:
            return .secondaryButton
        default:
            log.error("""
                unrecognised shield action \(String(describing: action), privacy: .public) — \
                treating it as a dismissal
                """)
            return .secondaryButton
        }
    }

    /// Durations behind the three submenu items, matching the labels the app
    /// publishes in ``ShieldCopy/submenuItems`` (docs/04-product-spec.md V2-1).
    ///
    /// Total: the two non-submenu kinds cannot reach here, and answering them with
    /// the shortest grant is strictly safer than trapping in a system callback.
    private static func submenuDuration(for kind: ShieldActionKind) -> TimeInterval {
        switch kind {
        case .firstSubmenuItem: 60
        case .secondSubmenuItem: 15 * 60
        case .thirdSubmenuItem: 60 * 60
        case .primaryButton, .secondaryButton: 60
        }
    }

    /// `ShieldActionResponse.defer` — *"keep the shield up and re-draw it"*.
    ///
    /// The case name is a Swift keyword and needs backticks at every use site
    /// (docs/02-api-reference.md §10). Computed rather than a stored `static let`:
    /// the SDK enum has no audited `Sendable` conformance.
    ///
    /// Re-drawing means the configuration extension is asked again, which is the
    /// path FB14237883 can answer with a recycled configuration. That is harmless
    /// *here specifically*, and only because ``ShieldCopy`` is static by
    /// construction — a stale configuration renders the identical shield. It is
    /// the reason the no-countdown rule is a type-level guarantee rather than a
    /// review note.
    private static var keepShieldUp: ShieldActionResponse { ShieldActionResponse.`defer` }

    /// Reads `GateState` for the two things this extension needs from it: the
    /// grant policy and the ledger. Never writes it.
    ///
    /// Uncoordinated on purpose. `NSFileCoordinator`'s failure mode is *blocking*,
    /// and this is a latency-bounded system callback; the atomic write already
    /// rules out a torn read, so the only thing coordination would buy is "not one
    /// write old" (`PlistFile`, Kernel/Store/GateStateStore.swift).
    ///
    /// `nil` means "use the defaults", which are the enforcing values —
    /// ``GrantPolicy/default`` is 3 grants a day of 5 minutes each, not unlimited.
    private static func loadState(now: Date) -> GateState? {
        do {
            let decoded = try FileStateStore(coordinated: false).load()
            // Decode → migrate → use, in that order: only after `migrate` do the
            // invariants hold (clamped lock delay, clamped grant policy, no
            // orphaned grants). `isFromFuture` is not checked because it only
            // forbids *writing*, and this process never writes state.
            return GateState.migrate(decoded, now: now).state
        } catch StateStoreError.stateMissing {
            // Genuine first run, or a rule armed before the app ever saved. Not an
            // error worth a log line on a path the user is waiting on.
            return nil
        } catch {
            log.error("""
                could not read \(GateState.fileName, privacy: .public): \
                \(String(describing: error), privacy: .public) — using default policy
                """)
            return nil
        }
    }

    /// Encodes a live token, swallowing the failure.
    ///
    /// ``TokenGuard`` is the only token codec in the product; its sorted-keys JSON
    /// is what makes a fingerprint computed here equal to one the app wrote. A
    /// failure costs the token's identity, not the record: the request is still
    /// written, the app can still offer to unblock the whole rule, and that is a
    /// broader unblock than the user asked for — which is why it is logged rather
    /// than ignored.
    private func encoding(_ kind: TokenKind, _ body: () throws -> EncodedToken) -> EncodedToken? {
        do {
            return try body()
        } catch {
            log.error("""
                could not encode a \(kind.rawValue, privacy: .public) token: \
                \(String(describing: error), privacy: .public)
                """)
            return nil
        }
    }
}
