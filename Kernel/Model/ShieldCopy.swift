//
//  ShieldCopy.swift
//  GateKernel
//
//  The pre-rendered shield (docs/04-product-spec.md V1-6).
//
//  `GateShieldConfiguration` is network-blocked and latency-bounded: *"The system
//  provides a default appearance for any methods that your subclass doesn't
//  override, **or if it takes too long**"* — with no published timeout, so treat
//  it as sub-second and synchronous (docs/02-api-reference.md §9;
//  docs/03-hard-constraints.md #33). It therefore computes nothing. The app
//  pre-writes ``ShieldCopyTable`` to `shield.plist` in the App Group, the
//  extension decodes it and returns; that is the entire algorithm.
//
//  Build plan: docs/06-build-plan.md step 3.1 (this file), 4.2 (the extension).
//
//  Foundation only — see the header of Kernel/Model/Rule.swift. In particular
//  **no UIKit**: `UIColor`, `UIImage` and `UIBlurEffect.Style` are named only in
//  `GateKernelUI`, which converts these values at the point they are handed to
//  `ManagedSettingsUI`. Putting a `UIColor` in the model would (a) drag UIKit
//  into the 6 MB monitor's dependency graph and (b) make the shield's appearance
//  unserializable, which is the one thing it must be.
//

import Foundation

// MARK: - RGBAColor

/// A colour, as four channels in `0...1`.
///
/// Serializable and UIKit-free. `GateKernelUI` turns this into
/// `UIColor(red:green:blue:alpha:)` for `ShieldConfiguration.backgroundColor`,
/// `ShieldConfiguration.Label.color` and
/// `ShieldConfiguration.primaryButtonBackgroundColor` — the four colour-bearing
/// slots the shield template actually has. Note there is **no**
/// `secondaryButtonBackgroundColor` in the API (docs/02-api-reference.md §9);
/// the model does not offer one either, because a field that cannot be applied is
/// a field someone will spend an afternoon debugging.
public struct RGBAColor: Codable, Sendable, Equatable, Hashable {

    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = RGBAColor.clamp(red)
        self.green = RGBAColor.clamp(green)
        self.blue = RGBAColor.clamp(blue)
        self.alpha = RGBAColor.clamp(alpha)
    }

    /// From `#RRGGBB` or `#RRGGBBAA` (the leading `#` optional).
    ///
    /// Returns `nil` for anything else. Shield colours come from a plist the app
    /// wrote, so a malformed one is a bug — but it is a bug that would otherwise
    /// surface as a black shield on a user's device, so it fails to `nil` and the
    /// caller falls back to a known-good default.
    public init?(hex: String) {
        var text = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count == 6 || text.count == 8,
              text.allSatisfy(\.isHexDigit),
              let value = UInt32(text, radix: 16)
        else { return nil }

        if text.count == 6 {
            self.init(
                red: Double((value >> 16) & 0xFF) / 255,
                green: Double((value >> 8) & 0xFF) / 255,
                blue: Double(value & 0xFF) / 255,
                alpha: 1
            )
        } else {
            self.init(
                red: Double((value >> 24) & 0xFF) / 255,
                green: Double((value >> 16) & 0xFF) / 255,
                blue: Double((value >> 8) & 0xFF) / 255,
                alpha: Double(value & 0xFF) / 255
            )
        }
    }

    public static let white = RGBAColor(red: 1, green: 1, blue: 1)
    public static let black = RGBAColor(red: 0, green: 0, blue: 0)
    /// 70 % white — the muted tone the shield subtitle uses against a dark blur.
    public static let mutedOnDark = RGBAColor(red: 1, green: 1, blue: 1, alpha: 0.7)

    private static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }

    private enum CodingKeys: String, CodingKey {
        case red = "r"
        case green = "g"
        case blue = "b"
        case alpha = "a"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            red: container.gateValue(Double.self, forKey: .red, default: 1),
            green: container.gateValue(Double.self, forKey: .green, default: 1),
            blue: container.gateValue(Double.self, forKey: .blue, default: 1),
            alpha: container.gateValue(Double.self, forKey: .alpha, default: 1)
        )
    }
}

// MARK: - ShieldLabel

/// One `ShieldConfiguration.Label` — text plus colour, which is the whole of what
/// that type is (docs/02-api-reference.md §9).
public struct ShieldLabel: Codable, Sendable, Equatable, Hashable {

    public var text: String
    public var color: RGBAColor

    public init(text: String, color: RGBAColor) {
        self.text = text
        self.color = color
    }

    public var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private enum CodingKeys: String, CodingKey {
        case text = "t"
        case color = "c"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            text: container.gateValue(String.self, forKey: .text, default: ""),
            color: container.gateValue(RGBAColor.self, forKey: .color, default: .white)
        )
    }
}

// MARK: - ShieldBlurStyle

/// The `UIBlurEffect.Style` the shield sits on.
///
/// A closed set of names rather than an `Int` raw value: `UIBlurEffect.Style` is
/// a UIKit enum whose numeric values are an implementation detail Apple has never
/// promised to keep, and this value is written to disk by one process and read by
/// another. `GateKernelUI` maps these names to the real cases in a `switch`, so a
/// renamed or removed style is a compile error there rather than a wrong blur on
/// a user's device.
public enum ShieldBlurStyle: String, Codable, Sendable, Hashable, CaseIterable {
    /// The V1-6 default.
    case systemUltraThinMaterialDark
    case systemThinMaterialDark
    case systemMaterialDark
    case systemThickMaterialDark
    case systemChromeMaterialDark
    case dark
    case regular
}

// MARK: - ShieldCopy

/// Everything `GateShieldConfiguration` needs to build one rule's
/// `ShieldConfiguration`, with no computation and no I/O beyond one plist read.
///
/// **There is deliberately no `Date`, no duration and no counter anywhere in this
/// type, and there never may be.** iOS reuses a stale, recycled
/// `ShieldConfiguration` when a shield is applied while the target app is already
/// frontmost, and there is no API to force a re-request — FB14237883, open about
/// two years (docs/02-api-reference.md §9). Any state-dependent text would render
/// wrong, at the worst moment, with no way to correct it. A live countdown is the
/// specific thing V1-6 forbids. Making the *type* incapable of holding a
/// timestamp is a cheaper guarantee than a code review.
///
/// The shield template's total customization surface is: blur style, background
/// colour, one icon, two coloured labels, two coloured button labels, one button
/// background colour, and — on iOS 26.4+ — up to three submenu strings. No custom
/// views, no SwiftUI, no animation, no text input (docs/03-hard-constraints.md
/// #28). Nothing here offers more than that.
public struct ShieldCopy: Codable, Sendable, Equatable, Hashable, Identifiable {

    // Length caps. Apple publishes none; these are ours, chosen so the fixed
    // template does not truncate at the smallest supported width. Exceeding one
    // is a warning from ``validate()``, never a hard failure — a truncated
    // shield still blocks.
    public static let maxTitleLength = 48
    public static let maxSubtitleLength = 140
    public static let maxButtonLabelLength = 28
    public static let maxSubmenuItemLength = 28

    /// The rule this copy belongs to. Matches ``Rule/id``.
    public var id: UUID

    /// `ShieldConfiguration.title`. The rule's name (docs/04-product-spec.md V1-6).
    public var title: ShieldLabel

    /// `ShieldConfiguration.subtitle`. A **static** line of the user's own copy —
    /// "You said you'd read instead."
    public var subtitle: ShieldLabel?

    /// `ShieldConfiguration.primaryButtonLabel`. "Let me in".
    ///
    /// Pressing it produces `.openParentalControlsApp` on iOS 26.5+, or a
    /// notification carrying `GateID.interventionURL(ruleID:requestID:)` plus
    /// `.close` below that (docs/04-product-spec.md V1-7). Whether
    /// `.openParentalControlsApp` works at all under `.individual` authorization
    /// is **(unverified)** — Apple's wording is parental-centric and there are no
    /// field reports (docs/02-api-reference.md §10; device-test gate
    /// docs/06-build-plan.md 2.5a). The copy must therefore read as an invitation
    /// to continue, not as a promise that the app will open, because on the
    /// fallback path the user has to tap a notification. `GateKernelUI` owns the
    /// wording; this field just carries it.
    public var primaryButton: ShieldLabel

    /// `ShieldConfiguration.secondaryButtonLabel`. "Not now" -> `.close`.
    public var secondaryButton: ShieldLabel

    /// `ShieldConfiguration.primaryButtonBackgroundColor`.
    public var primaryButtonBackground: RGBAColor?

    /// `ShieldConfiguration.backgroundColor`.
    public var background: RGBAColor?

    /// `ShieldConfiguration.backgroundBlurStyle`.
    public var blurStyle: ShieldBlurStyle?

    /// Name of an image in the **extension's own** asset catalog for
    /// `ShieldConfiguration.icon`.
    ///
    /// A name, never bytes. The extension is memory- and latency-bounded, and a
    /// `UIImage` decoded from a plist blob would be both slower and larger than
    /// `UIImage(named:)` against a compiled asset catalog. `nil` uses the system
    /// default icon.
    public var iconAssetName: String?

    /// `ShieldConfiguration.secondaryButtonSubmenuItems` — iOS 26.4+, hard cap
    /// three, excess silently ignored (docs/02-api-reference.md §14).
    ///
    /// v2 (docs/04-product-spec.md V2-1). Carried unconditionally in the model so
    /// a plist written on 26.4 is readable on iOS 17; the extension only reads it
    /// inside `if #available(iOS 26.4, *)`. Truncated to
    /// ``GateLimits/maxShieldSubmenuItems`` on the way in, because "silently
    /// ignored" is exactly the kind of cap that turns into a support ticket.
    public var submenuItems: [String]

    public init(
        id: UUID,
        title: ShieldLabel,
        subtitle: ShieldLabel? = nil,
        primaryButton: ShieldLabel,
        secondaryButton: ShieldLabel,
        primaryButtonBackground: RGBAColor? = nil,
        background: RGBAColor? = nil,
        blurStyle: ShieldBlurStyle? = .systemUltraThinMaterialDark,
        iconAssetName: String? = nil,
        submenuItems: [String] = []
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.primaryButton = primaryButton
        self.secondaryButton = secondaryButton
        self.primaryButtonBackground = primaryButtonBackground
        self.background = background
        self.blurStyle = blurStyle
        self.iconAssetName = iconAssetName
        self.submenuItems = Array(submenuItems.prefix(GateLimits.maxShieldSubmenuItems))
    }

    /// Problems that would make this copy render badly. Never fatal — a shield
    /// with bad copy still blocks, and blocking is the job.
    public enum Issue: Sendable, Equatable, Hashable {
        case emptyTitle
        case emptyPrimaryButton
        case emptySecondaryButton
        case titleTooLong(count: Int, limit: Int)
        case subtitleTooLong(count: Int, limit: Int)
        case buttonLabelTooLong(count: Int, limit: Int)
        case submenuItemTooLong(index: Int, count: Int, limit: Int)
        case tooManySubmenuItems(count: Int, limit: Int)
        case emptySubmenuItem(index: Int)
    }

    public func validate() -> [Issue] {
        var issues: [Issue] = []
        if title.isEmpty { issues.append(.emptyTitle) }
        if primaryButton.isEmpty { issues.append(.emptyPrimaryButton) }
        if secondaryButton.isEmpty { issues.append(.emptySecondaryButton) }

        if title.text.count > ShieldCopy.maxTitleLength {
            issues.append(.titleTooLong(count: title.text.count, limit: ShieldCopy.maxTitleLength))
        }
        if let subtitle, subtitle.text.count > ShieldCopy.maxSubtitleLength {
            issues.append(.subtitleTooLong(count: subtitle.text.count, limit: ShieldCopy.maxSubtitleLength))
        }
        for label in [primaryButton, secondaryButton] where label.text.count > ShieldCopy.maxButtonLabelLength {
            issues.append(.buttonLabelTooLong(count: label.text.count, limit: ShieldCopy.maxButtonLabelLength))
        }

        if submenuItems.count > GateLimits.maxShieldSubmenuItems {
            issues.append(.tooManySubmenuItems(
                count: submenuItems.count, limit: GateLimits.maxShieldSubmenuItems
            ))
        }
        for (index, item) in submenuItems.enumerated() {
            if item.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append(.emptySubmenuItem(index: index))
            } else if item.count > ShieldCopy.maxSubmenuItemLength {
                issues.append(.submenuItemTooLong(
                    index: index, count: item.count, limit: ShieldCopy.maxSubmenuItemLength
                ))
            }
        }
        return issues
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title = "t"
        case subtitle = "st"
        case primaryButton = "p1"
        case secondaryButton = "p2"
        case primaryButtonBackground = "p1bg"
        case background = "bg"
        case blurStyle = "blur"
        case iconAssetName = "icon"
        case submenuItems = "menu"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(UUID.self, forKey: .id)
        self.init(
            id: id,
            title: container.gateValue(
                ShieldLabel.self, forKey: .title, default: ShieldLabel(text: "", color: .white)
            ),
            subtitle: container.gateOptional(ShieldLabel.self, forKey: .subtitle),
            primaryButton: container.gateValue(
                ShieldLabel.self, forKey: .primaryButton, default: ShieldLabel(text: "", color: .white)
            ),
            secondaryButton: container.gateValue(
                ShieldLabel.self, forKey: .secondaryButton, default: ShieldLabel(text: "", color: .white)
            ),
            primaryButtonBackground: container.gateOptional(RGBAColor.self, forKey: .primaryButtonBackground),
            background: container.gateOptional(RGBAColor.self, forKey: .background),
            // An unknown blur style from a newer build decodes to `nil`, which
            // means "system default" — a legal, good-looking shield. Coercing it
            // to a named style we do happen to know would look deliberate and be
            // wrong.
            blurStyle: container.gateOptional(String.self, forKey: .blurStyle).flatMap(ShieldBlurStyle.init(rawValue:)),
            iconAssetName: container.gateOptional(String.self, forKey: .iconAssetName),
            submenuItems: container.gateLossyArray(String.self, forKey: .submenuItems)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encodeIfPresent(subtitle, forKey: .subtitle)
        try container.encode(primaryButton, forKey: .primaryButton)
        try container.encode(secondaryButton, forKey: .secondaryButton)
        try container.encodeIfPresent(primaryButtonBackground, forKey: .primaryButtonBackground)
        try container.encodeIfPresent(background, forKey: .background)
        try container.encodeIfPresent(blurStyle?.rawValue, forKey: .blurStyle)
        try container.encodeIfPresent(iconAssetName, forKey: .iconAssetName)
        if !submenuItems.isEmpty {
            try container.encode(submenuItems, forKey: .submenuItems)
        }
    }
}

// MARK: - ShieldCopyTable

/// `shield.plist` — the whole of what `GateShieldConfiguration` reads.
///
/// **Written only by the app. Read-only in every extension**
/// (docs/05-architecture.md, single-writer discipline; whether the shield
/// configuration extension can write at all is *(unverified)* and the design
/// assumes it cannot — device-test gate docs/06-build-plan.md 2.5d).
///
/// ### The lookup problem this type exists to solve
///
/// `ShieldConfigurationDataSource` is handed an `Application` / `WebDomain` /
/// `ActivityCategory` — never a rule. There is no API that answers "which of my
/// rules is shielding this?", and the extension cannot afford to decode every
/// rule's `FamilyActivitySelection` to find out (it is latency-bounded and the
/// system substitutes its own shield if it is slow,
/// docs/03-hard-constraints.md #33). So the app pre-computes the inverse map and
/// writes it here. Resolution order in ``ruleID(forToken:)``:
///
/// 1. **Exact token fingerprint** — covers every blocklist rule.
/// 2. **``catchAllRuleIDs``** — covers allowlist rules, which shield by
///    `.all(except:)` and so shield tokens that appear in no selection anywhere.
///    A token shielded by `.all(except:)` genuinely belongs to *every* allowlist
///    rule in force at once, so when more than one is active the copy shown is
///    necessarily approximate; the app writes them most-recently-activated first
///    and the extension takes the head. This is a limit of the API, not a bug to
///    be fixed later.
/// 3. **``fallback``** — generic Gate copy. Always present, so the extension has
///    no failure path and no reason to return `ShieldConfiguration()` and inherit
///    Apple's default shield.
///
/// Step 3 is not a formality. Tokens go stale: a token handed to the extension
/// can fail `==` against the one the app stored, and the iOS 26.5 remedy
/// (`TokenExpiryMessage` + `refresh(_:)`) is itself reported broken for ~30 % of
/// new users (docs/03-hard-constraints.md #36, FB23391495). Index misses are
/// expected, routine, and must look like a plain shield rather than a broken one.
public struct ShieldCopyTable: Codable, Sendable, Equatable {

    /// Filename inside the App Group container. `AppGroupContainer.shieldURL` is
    /// built from this constant.
    public static let fileName = "shield.plist"

    public static let currentSchemaVersion = 1

    public var schemaVersion: Int

    /// Mirrors ``GateState/generation`` at the time of the write, so a reader can
    /// tell whether `shield.plist` and `state.plist` came from the same app write.
    public var generation: Int

    public var updatedAt: Date

    /// Shown when nothing else resolves. Never optional — see the class note.
    public var fallback: ShieldCopy

    /// One entry per rule. At most ``GateLimits/maxRules``, so linear lookup is
    /// cheaper than building a dictionary in a latency-bounded extension.
    public var entries: [ShieldCopy]

    /// ``EncodedToken/fingerprint`` -> ``Rule/id``, for blocklist rules.
    ///
    /// Bounded by construction at `maxRules × 3 × maxTokensPerShieldCollection`
    /// = 8 × 3 × 50 = 1200 entries, i.e. roughly 60 KB of plist. `shield.plist`
    /// has no 8 KB budget — that constraint is `state.plist`'s alone, because
    /// that is the file the 6 MB monitor decodes on every callback
    /// (docs/05-architecture.md). The shield extension is a different process
    /// with a different budget and reads this one exactly once per shield.
    ///
    /// A `String`-keyed dictionary because that is the only dictionary shape
    /// property lists encode natively; a `[UUID: …]` map would serialize as a
    /// flat alternating array and lose O(1) lookup on the read side.
    public var ruleIDsByTokenFingerprint: [String: UUID]

    /// Rules in force that shield by `.all(except:)`, most recently activated
    /// first. See the resolution order above.
    public var catchAllRuleIDs: [UUID]

    public init(
        schemaVersion: Int = ShieldCopyTable.currentSchemaVersion,
        generation: Int = 0,
        updatedAt: Date = .distantPast,
        fallback: ShieldCopy,
        entries: [ShieldCopy] = [],
        ruleIDsByTokenFingerprint: [String: UUID] = [:],
        catchAllRuleIDs: [UUID] = []
    ) {
        self.schemaVersion = schemaVersion
        self.generation = generation
        self.updatedAt = updatedAt
        self.fallback = fallback
        self.entries = entries
        self.ruleIDsByTokenFingerprint = ruleIDsByTokenFingerprint
        self.catchAllRuleIDs = catchAllRuleIDs
    }

    public func copy(forRuleID ruleID: UUID) -> ShieldCopy? {
        entries.first { $0.id == ruleID }
    }

    /// Resolves a shielded token to the rule that is shielding it, or `nil`.
    public func ruleID(forToken token: EncodedToken) -> UUID? {
        ruleIDsByTokenFingerprint[token.fingerprint] ?? catchAllRuleIDs.first
    }

    /// The copy to render for a shielded token. Never fails.
    public func copy(forToken token: EncodedToken) -> ShieldCopy {
        guard let ruleID = ruleID(forToken: token), let copy = copy(forRuleID: ruleID) else {
            return fallback
        }
        return copy
    }

    /// Rebuilds ``ruleIDsByTokenFingerprint`` from scratch.
    ///
    /// - Parameter tokensByRuleID: for each blocklist rule, every token it
    ///   shields. The app builds this while it has the decoded
    ///   `FamilyActivitySelection`s in hand; no other process ever can.
    ///
    /// Last writer wins on a token shielded by two rules. That is a real
    /// ambiguity — the token *is* shielded by both, and iOS tells the extension
    /// only that it is shielded — so the copy shown is one of the two, not a
    /// merge. Documented rather than hidden.
    public mutating func rebuildIndex(tokensByRuleID: [UUID: [EncodedToken]]) {
        var index: [String: UUID] = [:]
        index.reserveCapacity(tokensByRuleID.values.reduce(0) { $0 + $1.count })
        for (ruleID, tokens) in tokensByRuleID {
            for token in tokens where !token.isEmpty {
                index[token.fingerprint] = ruleID
            }
        }
        ruleIDsByTokenFingerprint = index
    }

    /// Every problem across every entry, for the debug screen.
    public func validate() -> [(ruleID: UUID, issues: [ShieldCopy.Issue])] {
        ([fallback] + entries).compactMap { copy in
            let issues = copy.validate()
            return issues.isEmpty ? nil : (ruleID: copy.id, issues: issues)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "v"
        case generation = "g"
        case updatedAt = "u"
        case fallback = "fb"
        case entries = "e"
        case ruleIDsByTokenFingerprint = "idx"
        case catchAllRuleIDs = "all"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // `fallback` is genuinely required: without it the extension has no
        // last-resort copy and would have to return Apple's default shield,
        // which is the one visible regression this whole file exists to prevent.
        let fallback = try container.decode(ShieldCopy.self, forKey: .fallback)
        self.init(
            schemaVersion: container.gateValue(Int.self, forKey: .schemaVersion, default: 0),
            generation: container.gateValue(Int.self, forKey: .generation, default: 0),
            updatedAt: container.gateValue(Date.self, forKey: .updatedAt, default: .distantPast),
            fallback: fallback,
            entries: container.gateLossyArray(ShieldCopy.self, forKey: .entries),
            ruleIDsByTokenFingerprint: container.gateValue(
                [String: UUID].self, forKey: .ruleIDsByTokenFingerprint, default: [:]
            ),
            catchAllRuleIDs: container.gateLossyArray(UUID.self, forKey: .catchAllRuleIDs)
        )
    }
}
