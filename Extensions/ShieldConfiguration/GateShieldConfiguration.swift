//
//  GateShieldConfiguration.swift
//  GateShieldConfiguration
//
//  The shield's face. Build plan: docs/06-build-plan.md step 4.2.
//  Product spec: docs/04-product-spec.md V1-6.
//
//  WHAT THIS PROCESS IS
//  --------------------
//  `ShieldConfigurationDataSource` is called by the system, on the system's
//  clock, every time a shielded app or web page is opened. Apple, verbatim:
//  *"your extension runs in a sandbox. This sandbox prevents your extension from
//  making network requests or moving sensitive content outside the extension's
//  address space. The system provides a default appearance for any methods that
//  your subclass doesn't override, or if it takes too long."*
//  (docs/02-api-reference.md §9; docs/03-hard-constraints.md #33.)
//
//  There is no published timeout. Treat it as sub-second and synchronous. That
//  single sentence dictates every decision in this file:
//
//  1. **No async, no `Task`, no `await`, no completion handlers.** Every override
//     returns a value on the thread it was called on. A `Task` would outlive the
//     return and the return would be Apple's default shield.
//  2. **No `NSFileCoordinator`.** Coordination exists to order a reader against a
//     writer, and its failure mode is *blocking* — the app can hold the file long
//     enough for the coordinator to time out. `shield.plist` is written
//     `.atomic`, i.e. written to a sibling and `rename(2)`d, so an uncoordinated
//     reader sees the whole previous file or the whole new one, never a torn
//     prefix. The worst case is copy that is one write old, which on a file of
//     static strings is invisible (`ShieldCopyFile`, Kernel/Enforcement/ShieldWriter.swift).
//  3. **No computation.** Everything on screen was rendered by the app into
//     `shield.plist`: colours as RGBA, the blur as an enum case, the icon as an
//     asset *name*. This file maps values to UIKit types and returns.
//  4. **No crash, ever.** A crashed shield extension means Apple's default shield
//     — or no shield at all. Every path here ends in a `ShieldConfiguration`,
//     including "the App Group is unreadable", which is what
//     ``GateShieldConfiguration/emergencyFallback`` is for.
//
//  WHY THERE IS NO COUNTDOWN
//  -------------------------
//  FB14237883, open about two years: apply a shield while the target app is
//  already frontmost and iOS reuses a stale, recycled `ShieldConfiguration`.
//  There is no API to force a re-request. Any state-dependent text — a countdown,
//  a grant balance, "3 minutes left" — therefore renders wrong at the worst
//  possible moment with no way to correct it (docs/02-api-reference.md §9;
//  docs/04-product-spec.md V1-6: *"Never a countdown"*).
//
//  This is enforced by the type system rather than by review: ``ShieldCopy``
//  structurally cannot hold a `Date`, a duration or a counter
//  (Kernel/Model/ShieldCopy.swift). Nothing in this file may introduce one — not
//  `Date()`, not an elapsed interval, not a number read from `state.plist`. This
//  file does not open `state.plist` at all.
//
//  LINKAGE
//  -------
//  `GateKernel` only, in practice. project.yml also lists `GateKernelUI` for this
//  target, but nothing here imports it: every visual value arrives pre-rendered
//  in `shield.plist`, so the theme is the app's problem, not the shield's. The
//  one thing the extension owns locally is ``GateShieldConfiguration/emergencyFallback``,
//  and that has to be hard-coded precisely because it is the path taken when
//  nothing shared can be read.
//

import Foundation
import ManagedSettings
import ManagedSettingsUI
import UIKit
import os

import GateKernel

// Computed rather than a stored `let`: `Logger` is an SDK type whose `Sendable`
// conformance is not audited, and a stored global of such a type is a Swift 6
// strict-concurrency error. Constructing one wraps an existing `os_log_t` handle
// and costs nothing. Same reasoning as Kernel/Enforcement/ShieldWriter.swift.
//
// `print()` is not an option — it is invisible from an extension
// (docs/06-build-plan.md step 4.1).
private var log: Logger {
    Logger(subsystem: GateID.Subsystem.shieldConfiguration, category: "configuration")
}

// MARK: - ShieldCopyCache

/// One process-lifetime cache of the decoded `shield.plist`.
///
/// The extension process is spawned by the system and reused for as long as it
/// stays warm, and it is perfectly normal for it to be asked for several
/// configurations in a row — an app plus its category, a web domain plus its
/// category, or a user bouncing between two shielded apps. Decoding the table
/// once per *call* would mean decoding a file that can reach tens of kilobytes
/// (the token→rule fingerprint index is bounded at 8 rules × 3 collections × 50
/// tokens) on a latency-bounded path, repeatedly, for bytes that did not change.
///
/// So the first call decodes and every call after it pays one `stat`. Staleness
/// is bounded by comparing the file's modification date *and* its size: whole-
/// second `mtime` granularity can hide a same-second republish, and a size change
/// catches most of what a timestamp misses. A miss costs one shield rendered with
/// copy that is one write old — which, because ``ShieldCopy`` is static by
/// construction, is a different *string*, never a wrong *number*.
///
/// `@unchecked Sendable` is honest here rather than a shortcut: every stored
/// property is mutable, every access goes through ``lock``, and the three values
/// stored are themselves `Sendable` (`ShieldCopyTable` is, `Date` and `Int` are).
/// `NSLock` rather than an actor because an actor would make every read `async`,
/// and `async` is the one thing this file cannot afford.
private final class ShieldCopyCache: @unchecked Sendable {

    static let shared = ShieldCopyCache()

    private let lock = NSLock()

    // Named `cached` rather than `table` so the stored property and the `table()`
    // accessor below cannot shadow each other inside an `if let`.
    private var cached: ShieldCopyTable?
    private var modificationDate: Date?
    private var byteCount: Int?

    private init() {}

    /// The current table, or `nil` if `shield.plist` cannot be read or decoded.
    ///
    /// `nil` is a real state with a real cause, not just an error: on a fresh
    /// install the app has not published a table yet, and a shield can be
    /// presented in that window only if a rule was armed in the same session.
    /// The caller renders ``GateShieldConfiguration/emergencyFallback``.
    func table() -> ShieldCopyTable? {
        let url: URL
        do {
            url = try AppGroupContainer.shieldURL
        } catch {
            // The App Group itself is gone. Nothing shared can be read; there is
            // no point re-checking on the next call in this process, but there is
            // also no cheap way to remember that, and this is already the
            // pathological path.
            log.fault("""
                app group unavailable: \(String(describing: error), privacy: .public) \
                — rendering the built-in fallback shield
                """)
            return nil
        }

        let stamp = Self.stamp(of: url)

        lock.lock()
        if let cached, stamp.matches(date: modificationDate, size: byteCount) {
            lock.unlock()
            return cached
        }
        lock.unlock()

        // Decode outside the lock. Two processes never race here — there is only
        // one of this extension — and two *threads* racing costs a duplicated
        // decode, not a corrupted cache, because the store below is atomic under
        // the lock and both threads decode the same bytes.
        let decoded: ShieldCopyTable?
        do {
            decoded = try ShieldCopyFile.read()
        } catch {
            log.error("""
                could not read \(ShieldCopyTable.fileName, privacy: .public): \
                \(String(describing: error), privacy: .public)
                """)
            decoded = nil
        }

        guard let decoded else { return nil }

        lock.lock()
        cached = decoded
        modificationDate = stamp.date
        byteCount = stamp.size
        lock.unlock()

        return decoded
    }

    // MARK: File stamp

    private struct Stamp {
        var date: Date?
        var size: Int?

        /// Conservative: an unreadable stamp (either field `nil`) never matches,
        /// so a `stat` failure re-reads rather than serving a cached table
        /// forever.
        func matches(date other: Date?, size otherSize: Int?) -> Bool {
            guard let mine = self.date, let mySize = self.size,
                  let other, let otherSize
            else { return false }
            return mine == other && mySize == otherSize
        }
    }

    private static func stamp(of url: URL) -> Stamp {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        return Stamp(date: values?.contentModificationDate, size: values?.fileSize)
    }
}

// MARK: - GateShieldConfiguration

/// The principal class named by `NSExtensionPrincipalClass` in
/// `Config/ShieldConfiguration-Info.plist` as
/// `$(PRODUCT_MODULE_NAME).GateShieldConfiguration`. Renaming the class or the
/// module breaks the binding silently — the system falls back to its own shield
/// and logs nothing useful.
///
/// All four overrides are implemented. Apple substitutes the default appearance
/// for *"any methods that your subclass doesn't override"*, so an unimplemented
/// overload is not "the same shield without our copy", it is Apple's grey shield
/// in the middle of our product (docs/02-api-reference.md §9).
final class GateShieldConfiguration: ShieldConfigurationDataSource {

    // MARK: Application

    override func configuration(shielding application: Application) -> ShieldConfiguration {
        render(preferring: [encoded(application.token)])
    }

    override func configuration(
        shielding application: Application,
        in category: ActivityCategory
    ) -> ShieldConfiguration {
        // Application first: a rule that names this specific app is a more
        // precise answer than the category it happens to belong to, and when both
        // are shielded the user thinks of the app.
        render(preferring: [encoded(application.token), encoded(category.token)])
    }

    // MARK: Web domain

    override func configuration(shielding webDomain: WebDomain) -> ShieldConfiguration {
        render(preferring: [encoded(webDomain.token)])
    }

    override func configuration(
        shielding webDomain: WebDomain,
        in category: ActivityCategory
    ) -> ShieldConfiguration {
        render(preferring: [encoded(webDomain.token), encoded(category.token)])
    }

    // MARK: Resolution

    /// Resolves a token to its rule's copy and renders it.
    ///
    /// - Parameter candidates: tokens to try, most specific first. `nil` entries
    ///   are expected — `Application.token` is `Optional` and the system is free
    ///   to hand over an `Application` built from a bundle identifier instead.
    ///
    /// Note what this method deliberately does **not** use. Apple, verbatim:
    /// *"The system provides your extension with the display names, bundle
    /// identifiers, and domains for each application, website, or category it
    /// shields"* — so `application.localizedDisplayName` is populated here and
    /// only here, and is genuinely tempting. V1-6 pins `title` to the *rule's*
    /// name, and a shield whose title sometimes comes from the rule and sometimes
    /// from the app is two sources of truth for one string. The names stay unused
    /// (they must not leave this process either — docs/03-hard-constraints.md #25).
    private func render(preferring candidates: [EncodedToken?]) -> ShieldConfiguration {
        let tokens = candidates.compactMap { $0 }.filter { !$0.isEmpty }

        guard let table = ShieldCopyCache.shared.table() else {
            return Self.emergencyFallback
        }

        // Exact fingerprint hits, in the caller's priority order. `ShieldCopyTable`
        // offers `copy(forToken:)`, which never fails — but that is precisely why
        // it cannot be used to *chain*: it would answer the first token with the
        // catch-all rule and never look at the second.
        for token in tokens {
            if let ruleID = table.ruleIDsByTokenFingerprint[token.fingerprint],
               let copy = table.copy(forRuleID: ruleID) {
                return Self.configuration(for: copy)
            }
        }

        // No rule names this token. Two ordinary reasons, neither an error:
        //
        //  • an allowlist rule is in force, which shields by `.all(except:)` and
        //    so cannot enumerate what it blocks — `catchAllRuleIDs` is exactly
        //    that case; or
        //  • the token was reissued by iOS and no longer matches the bytes the app
        //    stored (docs/03-hard-constraints.md #36, thread 814571, no workaround
        //    from Apple). Recovery is a first-class screen, not an error path
        //    (docs/04-product-spec.md V1-9) — and until the user runs it, showing
        //    generic copy over a block that is still correctly enforcing is the
        //    right failure.
        //
        // This extension deliberately does **not** write an
        // `InboxEvent.tokenExpiry` record here, even though the second case is
        // exactly what that record is for. Writing a file is the one thing the
        // latency budget cannot absorb, and this method runs on every presentation
        // of every shield. `GateShieldAction` reports it instead: it runs only on a
        // button press, and a user looking at unfamiliar copy presses a button.
        //
        // `copy(forToken:)` applies the catch-all and then the guaranteed
        // `fallback`, so this always produces something. When the system handed
        // over no token at all, an empty one takes the same route: it matches
        // nothing in the index (which skips empty tokens) and lands on the
        // catch-all, which is still the best available guess.
        let primary = tokens.first ?? EncodedToken(bytes: Data())
        return Self.configuration(for: table.copy(forToken: primary))
    }

    /// Encodes a live token for lookup, swallowing the encode failure.
    ///
    /// ``TokenGuard`` is the only token codec in the product — its sorted-keys
    /// JSON is what makes a fingerprint computed here equal to one the app wrote
    /// (Kernel/Enforcement/TokenGuard.swift). A throw means the token would not
    /// have matched anything anyway, so the caller degrades to the catch-all.
    ///
    /// Three overloads rather than one generic over `Token<Resource>`: the three
    /// token types are distinct generic instantiations, and narrowing a generic
    /// one back down would mean a conditional cast — a runtime check standing in
    /// for something the compiler already knows at every call site.
    private func encoded(_ token: ApplicationToken?) -> EncodedToken? {
        guard let token else { return nil }
        return encoding(.application) { try TokenGuard.encode(token) }
    }

    private func encoded(_ token: ActivityCategoryToken?) -> EncodedToken? {
        guard let token else { return nil }
        return encoding(.category) { try TokenGuard.encode(token) }
    }

    private func encoded(_ token: WebDomainToken?) -> EncodedToken? {
        guard let token else { return nil }
        return encoding(.webDomain) { try TokenGuard.encode(token) }
    }

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

    // MARK: Rendering

    /// Maps one ``ShieldCopy`` onto the fixed template.
    ///
    /// The template's entire customization surface is blur style, background
    /// colour, one icon, two coloured labels, two coloured button labels, one
    /// button background colour, and — on iOS 26.4+ — up to three submenu strings.
    /// There is no `secondaryButtonBackgroundColor`, no custom view, no SwiftUI,
    /// no animation, no text field (docs/02-api-reference.md §9;
    /// docs/03-hard-constraints.md #28). Every property is `let`, so the choice of
    /// initializer is the only place the 26.4 branch can live.
    private static func configuration(for copy: ShieldCopy) -> ShieldConfiguration {
        let icon = copy.iconAssetName.flatMap { name in
            // `Bundle(for:)` is this `.appex`, which is where an asset catalog
            // would live if one shipped. **None does today** —
            // `GateTheme.Shield.iconAssetName` is `nil` for exactly that reason,
            // so this closure does not run at all and the shield uses the system
            // icon. A name that is not in the catalog yields `nil` anyway, which
            // the template reads as "use the system icon" — so a copy written by
            // a newer build naming an asset this build does not ship degrades to
            // a plain shield instead of a blank one.
            UIImage(named: name, in: Bundle(for: GateShieldConfiguration.self), compatibleWith: nil)
        }

        let title = ShieldConfiguration.Label(
            text: copy.title.text,
            color: copy.title.color.uiColor
        )
        let subtitle = copy.subtitle.map {
            ShieldConfiguration.Label(text: $0.text, color: $0.color.uiColor)
        }
        let primary = ShieldConfiguration.Label(
            text: copy.primaryButton.text,
            color: copy.primaryButton.color.uiColor
        )
        let secondary = ShieldConfiguration.Label(
            text: copy.secondaryButton.text,
            color: copy.secondaryButton.color.uiColor
        )

        // `secondaryButtonSubmenuItems` and the nine-argument initializer are
        // iOS 26.4 (docs/02-api-reference.md §13). Below that the symbol does not
        // exist, so the branch is on the *initializer*, not on the value.
        //
        // v1 publishes no submenu items at all — V2-1 is v2 — so `submenuItems`
        // is empty here in practice and the 26.4 branch produces exactly the same
        // shield as the 17.0 one. It is wired now because the alternative is
        // discovering on the 26.4 device that the shield and the action extension
        // disagree about whether a submenu exists.
        if #available(iOS 26.4, *) {
            // Already truncated to three by `ShieldCopy.init` — excess items are
            // *silently ignored* by the system (docs/02-api-reference.md §14), and
            // a silently-dropped button is a support ticket. Passing `nil` rather
            // than `[]` keeps the system default (no submenu) rather than asking
            // for an empty one.
            let items = copy.submenuItems.isEmpty
                ? nil
                : Array(copy.submenuItems.prefix(GateLimits.maxShieldSubmenuItems))

            return ShieldConfiguration(
                backgroundBlurStyle: copy.blurStyle?.uiBlurStyle,
                backgroundColor: copy.background?.uiColor,
                icon: icon,
                title: title,
                subtitle: subtitle,
                primaryButtonLabel: primary,
                primaryButtonBackgroundColor: copy.primaryButtonBackground?.uiColor,
                secondaryButtonLabel: secondary,
                secondaryButtonSubmenuItems: items
            )
        }

        return ShieldConfiguration(
            backgroundBlurStyle: copy.blurStyle?.uiBlurStyle,
            backgroundColor: copy.background?.uiColor,
            icon: icon,
            title: title,
            subtitle: subtitle,
            primaryButtonLabel: primary,
            primaryButtonBackgroundColor: copy.primaryButtonBackground?.uiColor,
            secondaryButtonLabel: secondary
        )
    }

    // MARK: Emergency fallback

    /// The shield shown when `shield.plist` cannot be read at all.
    ///
    /// Hard-coded on purpose, and the only strings in the product that are.
    /// `ShieldCopyTable.fallback` is the *normal* last resort and lives in the
    /// file; this one is reached when the file itself is unreachable — a missing
    /// App Group container, a first launch that armed a rule before publishing
    /// copy, or data protection denying the read. Sourcing it from anywhere
    /// shared would make it fail in exactly the situation it exists for.
    ///
    /// Static text only, same rule as everywhere else in this file: no state, no
    /// numbers, nothing that can be stale. It must also not promise anything the
    /// action extension cannot deliver — on this path `GateShieldAction` will very
    /// likely fail to record the tap too, and answers `.defer`, leaving the shield
    /// up. "Let me in" therefore reads as a request, not a guarantee.
    ///
    /// Computed rather than a stored `static let`: `ShieldConfiguration` is an SDK
    /// type with no audited `Sendable` conformance, and a stored static of one is
    /// a Swift 6 strict-concurrency error.
    private static var emergencyFallback: ShieldConfiguration {
        ShieldConfiguration(
            backgroundBlurStyle: .systemUltraThinMaterialDark,
            backgroundColor: nil,
            icon: nil,
            title: ShieldConfiguration.Label(text: "Blocked by Gate", color: .white),
            subtitle: ShieldConfiguration.Label(
                text: "Open Gate to see or change this block.",
                color: UIColor.white.withAlphaComponent(0.7)
            ),
            primaryButtonLabel: ShieldConfiguration.Label(text: "Let me in", color: .black),
            primaryButtonBackgroundColor: .white,
            secondaryButtonLabel: ShieldConfiguration.Label(
                text: "Not now",
                color: UIColor.white.withAlphaComponent(0.7)
            )
        )
    }
}

// MARK: - Value mapping

private extension RGBAColor {

    /// The kernel stores colours as four `Double`s so `shield.plist` is readable
    /// by a Foundation-only module and by the SwiftPM tests. Components are
    /// already clamped to `0...1` by `RGBAColor.init`, so no defensive clamp here.
    ///
    /// Deliberately **not** `UIColor(dynamicProvider:)`: the shield is a dark,
    /// blurred template and the app resolves the appearance when it writes the
    /// file. A dynamic colour resolved inside a recycled configuration would be
    /// one more thing that can render stale (FB14237883).
    ///
    /// The `CGFloat` conversions are explicit. `Double` and `CGFloat` are
    /// interchangeable since Swift 5.5, but leaning on that in a four-argument
    /// call where every parameter is the same type is how an implicit conversion
    /// becomes an overload-resolution puzzle later.
    var uiColor: UIColor {
        UIColor(
            red: CGFloat(red),
            green: CGFloat(green),
            blue: CGFloat(blue),
            alpha: CGFloat(alpha)
        )
    }
}

private extension ShieldBlurStyle {

    /// Exhaustive by design — no `default`. Adding a case to ``ShieldBlurStyle``
    /// should fail this build rather than silently resolve to `.regular`, which
    /// on a dark shield reads as a visual bug.
    var uiBlurStyle: UIBlurEffect.Style {
        switch self {
        case .systemUltraThinMaterialDark: .systemUltraThinMaterialDark
        case .systemThinMaterialDark: .systemThinMaterialDark
        case .systemMaterialDark: .systemMaterialDark
        case .systemThickMaterialDark: .systemThickMaterialDark
        case .systemChromeMaterialDark: .systemChromeMaterialDark
        case .dark: .dark
        case .regular: .regular
        }
    }
}
