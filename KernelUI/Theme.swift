//
//  Theme.swift
//  GateKernelUI
//
//  The whole design system: colours (light + dark), a type scale, a spacing
//  scale, and the shield palette (docs/04-product-spec.md V1-6).
//
//  GateKernelUI is linked by the app, by GateShieldConfiguration and by
//  GateReport — never by GateActivityMonitor, which has a 6 MB ceiling
//  (docs/05-architecture.md, module layer split; docs/03-hard-constraints.md
//  #31). It is built with APPLICATION_EXTENSION_API_ONLY = YES, so nothing here
//  may touch `UIApplication`, `openURL`, or any other non-extension-safe API:
//  the link fails if it does.
//
//  Two deliberate properties of this file:
//
//  1. **No asset catalog.** Every colour is defined in code as two `RGBAColor`
//     values. A framework-bundled asset catalog has to be found at runtime via
//     `Bundle(for:)`, which is one more thing that can silently resolve to the
//     wrong bundle inside an .appex, and the shield palette has to be
//     serializable anyway — `ShieldCopy` stores `RGBAColor`, not `Color`
//     (Kernel/Model/ShieldCopy.swift). Defining the palette once, in the
//     kernel's own colour type, means the in-app preview of a shield and the
//     real shield cannot drift.
//
//  2. **Every SwiftUI-typed constant is computed, never a stored `static let`.**
//     A stored static of an SDK type whose `Sendable` conformance is not audited
//     is a Swift 6 strict-concurrency error, and `Color`/`Font` are cheap value
//     types — the same rule Kernel/Identifiers.swift applies to
//     `ManagedSettingsStore.Name`. Call sites are unchanged.
//

import SwiftUI

import GateKernel

#if canImport(UIKit)
// UIKit appears for exactly two reasons, both of which SwiftUI genuinely cannot
// do on iOS 17:
//   * `UIColor(dynamicProvider:)` — the only way to build one `Color` that
//     resolves differently in light and dark without an asset catalog.
//     (`Color(light:dark:)` does not exist; `@Environment(\.colorScheme)` would
//     force every consumer to thread the scheme through by hand.)
//   * `UIBlurEffect.Style` and `UIColor` are the literal types
//     `ShieldConfiguration` takes (docs/02-api-reference.md §9).
// Neither is extension-unsafe.
import UIKit
#endif

// MARK: - GateTheme

/// Design tokens. Uninhabited namespace — there is nothing to instantiate.
public enum GateTheme {

    /// A colour expressed in 0…255 channels, which is how palettes are written
    /// down everywhere else.
    public static func rgb(_ red: Int, _ green: Int, _ blue: Int, alpha: Double = 1) -> RGBAColor {
        RGBAColor(
            red: Double(red) / 255,
            green: Double(green) / 255,
            blue: Double(blue) / 255,
            alpha: alpha
        )
    }

    // MARK: ColorPair

    /// One semantic colour, in both appearances.
    ///
    /// Stored as ``RGBAColor`` — the kernel's serializable colour — so the same
    /// value can be written into `shield.plist` for `GateShieldConfiguration` to
    /// read back, and so this type stays `Sendable` without qualification.
    public struct ColorPair: Sendable, Equatable, Hashable {

        public var light: RGBAColor
        public var dark: RGBAColor

        public init(light: RGBAColor, dark: RGBAColor) {
            self.light = light
            self.dark = dark
        }

        /// The same colour in both appearances.
        public init(_ both: RGBAColor) {
            self.light = both
            self.dark = both
        }

        public func resolved(for scheme: ColorScheme) -> RGBAColor {
            scheme == .dark ? dark : light
        }

        /// A `Color` that follows the viewer's appearance.
        ///
        /// Allocates a `UIColor` per access. That is what SwiftUI does for its
        /// own semantic colours too, and it is measured in nanoseconds; caching
        /// it would mean either mutable global state (a strict-concurrency
        /// problem) or a stored static of a non-audited SDK type (the same
        /// problem). Where a body reads the same pair many times, hoist it into
        /// a `let` first.
        public var color: Color {
            #if canImport(UIKit)
            return Color(uiColor: UIColor { traits in
                traits.userInterfaceStyle == .dark ? self.dark.uiColor : self.light.uiColor
            })
            #else
            // No UIKit (previews on another platform, or a future target):
            // the light value is the honest default rather than a crash.
            return light.color
            #endif
        }

        /// The same colour at a reduced alpha, in both appearances.
        public func opacity(_ factor: Double) -> ColorPair {
            ColorPair(
                light: RGBAColor(red: light.red, green: light.green, blue: light.blue,
                                 alpha: light.alpha * factor),
                dark: RGBAColor(red: dark.red, green: dark.green, blue: dark.blue,
                                alpha: dark.alpha * factor)
            )
        }
    }

    // MARK: Palette (raw, serializable)

    /// The raw palette. Prefer the semantic `Color` accessors below in view
    /// code; reach in here only when you need an ``RGBAColor`` to persist.
    public enum Palette {

        /// Screen background.
        public static let background = ColorPair(
            light: GateTheme.rgb(246, 246, 249),
            dark: GateTheme.rgb(14, 15, 19)
        )

        /// Card / row background.
        public static let surface = ColorPair(
            light: GateTheme.rgb(255, 255, 255),
            dark: GateTheme.rgb(26, 28, 34)
        )

        /// Hairline rules and card borders.
        public static let separator = ColorPair(
            light: GateTheme.rgb(17, 17, 23, alpha: 0.10),
            dark: GateTheme.rgb(255, 255, 255, alpha: 0.12)
        )

        public static let textPrimary = ColorPair(
            light: GateTheme.rgb(20, 21, 26),
            dark: GateTheme.rgb(244, 245, 249)
        )

        public static let textSecondary = ColorPair(
            light: GateTheme.rgb(92, 96, 112),
            dark: GateTheme.rgb(170, 176, 192)
        )

        public static let textTertiary = ColorPair(
            light: GateTheme.rgb(138, 143, 158),
            dark: GateTheme.rgb(126, 132, 148)
        )

        /// Gate's own colour. Used for primary actions and the shield's primary
        /// button.
        public static let accent = ColorPair(
            light: GateTheme.rgb(58, 70, 200),
            dark: GateTheme.rgb(126, 138, 255)
        )

        /// Text and glyphs drawn *on* ``accent``.
        public static let onAccent = ColorPair(GateTheme.rgb(255, 255, 255))

        /// A rule is blocking right now.
        public static let enforcing = ColorPair(
            light: GateTheme.rgb(22, 128, 92),
            dark: GateTheme.rgb(72, 199, 142)
        )

        /// A rule is on, but outside its window.
        public static let scheduled = ColorPair(
            light: GateTheme.rgb(38, 104, 186),
            dark: GateTheme.rgb(106, 166, 246)
        )

        /// Something is waiting on the Lock (docs/04-product-spec.md V1-3).
        public static let pending = ColorPair(
            light: GateTheme.rgb(160, 100, 8),
            dark: GateTheme.rgb(240, 182, 72)
        )

        /// Destructive, refused, or over a platform cap.
        public static let danger = ColorPair(
            light: GateTheme.rgb(178, 42, 40),
            dark: GateTheme.rgb(255, 118, 112)
        )
    }

    // MARK: Semantic colours

    public static var background: Color { Palette.background.color }
    public static var surface: Color { Palette.surface.color }
    public static var separator: Color { Palette.separator.color }
    public static var textPrimary: Color { Palette.textPrimary.color }
    public static var textSecondary: Color { Palette.textSecondary.color }
    public static var textTertiary: Color { Palette.textTertiary.color }
    public static var accent: Color { Palette.accent.color }
    public static var onAccent: Color { Palette.onAccent.color }
    public static var enforcing: Color { Palette.enforcing.color }
    public static var scheduled: Color { Palette.scheduled.color }
    public static var pending: Color { Palette.pending.color }
    public static var danger: Color { Palette.danger.color }

    // MARK: Tone

    /// The five states anything in Gate can be in, so a dot, a chip and a label
    /// never disagree about what "on" looks like.
    public enum Tone: String, Sendable, Hashable, CaseIterable {
        /// Blocking right now.
        case enforcing
        /// On, but waiting for its window.
        case scheduled
        /// Off.
        case off
        /// Queued behind the Lock.
        case pending
        /// Destructive, or a platform cap exceeded.
        case danger
        /// No opinion.
        case neutral

        public var pair: ColorPair {
            switch self {
            case .enforcing: Palette.enforcing
            case .scheduled: Palette.scheduled
            case .off: Palette.textTertiary
            case .pending: Palette.pending
            case .danger: Palette.danger
            case .neutral: Palette.textSecondary
            }
        }

        public var color: Color { pair.color }
    }

    // MARK: Spacing

    /// A 4-point scale. Every gap and inset in Gate is one of these.
    public enum Spacing {
        public static let xxs: CGFloat = 2
        public static let xs: CGFloat = 4
        public static let s: CGFloat = 8
        public static let m: CGFloat = 12
        public static let l: CGFloat = 16
        public static let xl: CGFloat = 24
        public static let xxl: CGFloat = 32

        /// The HIG minimum tap target. Rows are never shorter than this.
        public static let minimumTapTarget: CGFloat = 44
    }

    // MARK: Radius

    public enum Radius {
        public static let control: CGFloat = 10
        public static let card: CGFloat = 16
        /// Large enough that any realistic height becomes a capsule.
        public static let pill: CGFloat = 999
    }

    // MARK: Stroke

    public enum Stroke {
        /// One point. `strokeBorder` insets inward, so this never clips.
        public static let hairline: CGFloat = 1
        public static let emphasis: CGFloat = 2
    }

    // MARK: Typography

    /// The type scale.
    ///
    /// Every entry is built from a `Font.TextStyle`, so all of it responds to
    /// Dynamic Type. Nothing here is a fixed point size.
    public enum Typography {

        /// Screen titles.
        public static var display: Font { .system(.largeTitle, design: .rounded, weight: .semibold) }

        /// Section and sheet titles.
        public static var title: Font { .system(.title2, design: .rounded, weight: .semibold) }

        /// Row titles — a rule's name, a banner's headline.
        public static var headline: Font { .system(.headline, design: .rounded, weight: .semibold) }

        public static var body: Font { .system(.body) }

        public static var callout: Font { .system(.callout) }

        /// Secondary row copy.
        public static var footnote: Font { .system(.footnote) }

        /// Tertiary copy and honest-limitation notes.
        public static var caption: Font { .system(.caption) }

        /// Chips and badges.
        public static var chip: Font { .system(.caption2, design: .rounded, weight: .semibold) }

        /// Inline countdowns. Monospaced digits so "12m 04s" does not reflow the
        /// line every second — the single most visible reason a countdown looks
        /// cheap.
        public static var numeric: Font {
            .system(.footnote, design: .rounded, weight: .semibold).monospacedDigit()
        }

        /// The hero countdown on the intervention screen.
        public static var numericLarge: Font {
            .system(.title, design: .rounded, weight: .semibold).monospacedDigit()
        }
    }

    // MARK: Shield palette

    /// The colours `GateShieldConfiguration` renders (docs/04-product-spec.md
    /// V1-6).
    ///
    /// Flat `RGBAColor`, not ``ColorPair``: the shield is drawn over
    /// `.systemUltraThinMaterialDark`, so it is dark in both appearances and a
    /// light variant would be a colour that never renders. It is also written to
    /// `shield.plist` by the app and read back by a different process, where
    /// there is no trait collection to resolve against.
    ///
    /// **Nothing here may become time-dependent.** iOS recycles a stale
    /// `ShieldConfiguration` when a shield is applied while the target app is
    /// already frontmost — FB14237883, open about two years
    /// (docs/02-api-reference.md §9) — which is why ``ShieldCopy`` structurally
    /// cannot hold a `Date`.
    public enum Shield {

        /// Behind the blur.
        public static let background = GateTheme.rgb(12, 13, 18, alpha: 0.86)

        public static let title = RGBAColor.white

        public static let subtitle = RGBAColor.mutedOnDark

        public static let primaryLabel = RGBAColor.white

        /// The one button background the template offers. There is no
        /// `secondaryButtonBackgroundColor` (docs/02-api-reference.md §9).
        public static let primaryBackground = GateTheme.rgb(78, 92, 226)

        public static let secondaryLabel = RGBAColor.mutedOnDark

        /// V1-6's default.
        public static let blurStyle: ShieldBlurStyle = .systemUltraThinMaterialDark

        /// The asset name the shield extension looks up for
        /// `ShieldConfiguration.icon`, or `nil` for the system default icon.
        ///
        /// `nil` today: no asset catalog ships in
        /// `Extensions/ShieldConfiguration`, and
        /// `UIImage(named:in:compatibleWith:)` against a bundle with no catalog
        /// returns `nil` anyway — naming a missing asset only makes the plist
        /// claim something the extension cannot honour. To give the shield its
        /// own icon, add `Extensions/ShieldConfiguration/ShieldAssets.xcassets`
        /// containing a `ShieldIcon` imageset (XcodeGen picks it up from the
        /// target's existing `sources` glob — project.yml needs no change) and
        /// set this back to `"ShieldIcon"`. The image bytes never travel through
        /// the App Group; ``ShieldCopy`` stores the name only.
        public static let iconAssetName: String? = nil

        /// V1-6's button copy. "Let me in" routes to `.openParentalControlsApp`
        /// on iOS 26.5+ and to a notification deep link below it;
        /// "Not now" is `.close`.
        public static let primaryButtonText = "Let me in"
        public static let secondaryButtonText = "Not now"

        /// The identity of ``ShieldCopyTable/fallback``.
        ///
        /// `ShieldCopy.id` is normally a `Rule.id`; the fallback belongs to no
        /// rule, so it gets a fixed sentinel that cannot collide with a `UUID()`
        /// in practice. Deliberately *not* the all-zero UUID, which
        /// `ActivityNameCodec` has already reserved as its unscoped-revert wire
        /// sentinel.
        public static let fallbackID =
            UUID(uuidString: "00000000-0000-0000-0000-0000000000FB") ?? UUID()

        /// Truncate to a ``ShieldCopy`` limit so `validate()` comes back clean.
        ///
        /// `ShieldCopy.init` truncates only `submenuItems`; over-long text is
        /// reported by `validate()` rather than silently cut, because the model
        /// must not decide how a sentence gets shortened. This is where that
        /// decision lives.
        public static func clamp(_ text: String, to limit: Int) -> String {
            guard limit > 0 else { return "" }
            guard text.count > limit else { return text }
            guard limit > 1 else { return String(text.prefix(limit)) }
            return String(text.prefix(limit - 1)) + "\u{2026}"
        }

        /// Build one rule's shield copy in Gate's palette.
        ///
        /// `subtitle` must be a *static* line the user wrote ("You said you'd
        /// read instead."), never a countdown or a count — see the type comment
        /// above and V1-6.
        ///
        /// `submenuItems` is **iOS 26.4+ only**
        /// (`ShieldConfiguration.secondaryButtonSubmenuItems`, with its 9-argument
        /// init; docs/02-api-reference.md §10). Staging them here is safe at any
        /// OS version — they are just strings in a plist — but the extension must
        /// gate the *assignment* behind `if #available(iOS 26.4, *)` and fall back
        /// to the 8-argument init, where the secondary button simply fires
        /// `.secondaryButtonPressed`. v1 ships none of them; they are V2-1.
        /// `ShieldCopy.init` already truncates the array to the platform's silent
        /// 3-item cap (docs/03-hard-constraints.md #34).
        public static func copy(
            ruleID: UUID,
            title: String,
            subtitle: String? = nil,
            primaryButtonText: String = Shield.primaryButtonText,
            secondaryButtonText: String = Shield.secondaryButtonText,
            submenuItems: [String] = []
        ) -> ShieldCopy {
            ShieldCopy(
                id: ruleID,
                title: ShieldLabel(
                    text: clamp(title, to: ShieldCopy.maxTitleLength),
                    color: Shield.title
                ),
                subtitle: subtitle.map {
                    ShieldLabel(
                        text: clamp($0, to: ShieldCopy.maxSubtitleLength),
                        color: Shield.subtitle
                    )
                },
                primaryButton: ShieldLabel(
                    text: clamp(primaryButtonText, to: ShieldCopy.maxButtonLabelLength),
                    color: Shield.primaryLabel
                ),
                secondaryButton: ShieldLabel(
                    text: clamp(secondaryButtonText, to: ShieldCopy.maxButtonLabelLength),
                    color: Shield.secondaryLabel
                ),
                primaryButtonBackground: Shield.primaryBackground,
                background: Shield.background,
                blurStyle: Shield.blurStyle,
                iconAssetName: Shield.iconAssetName,
                submenuItems: submenuItems.map { clamp($0, to: ShieldCopy.maxSubmenuItemLength) }
            )
        }

        /// What the shield says when the token it was handed maps to no rule —
        /// a stale token (docs/03-hard-constraints.md #36), or a rule deleted
        /// between the shield being written and the app being opened.
        ///
        /// `ShieldCopyTable.fallback` is the one field with no decode default,
        /// precisely so that this can never be missing.
        public static var fallbackCopy: ShieldCopy {
            copy(
                ruleID: fallbackID,
                title: "Blocked by Gate",
                subtitle: "You set this up when you had more perspective than you do right now."
            )
        }
    }
}

// MARK: - RGBAColor bridging

public extension RGBAColor {

    /// SwiftUI's colour. Appearance-independent: ``RGBAColor`` is one literal
    /// colour, and the light/dark decision belongs to ``GateTheme/ColorPair``.
    var color: Color {
        Color(red: red, green: green, blue: blue, opacity: alpha)
    }
}

#if canImport(UIKit)
public extension RGBAColor {

    /// The type `ShieldConfiguration.backgroundColor`,
    /// `ShieldConfiguration.Label.color` and
    /// `ShieldConfiguration.primaryButtonBackgroundColor` all take
    /// (docs/02-api-reference.md §9).
    ///
    /// sRGB, matching ``RGBAColor/color`` above: SwiftUI's
    /// `Color(red:green:blue:opacity:)` and UIKit's
    /// `UIColor(red:green:blue:alpha:)` both interpret their channels as sRGB on
    /// iOS. Using `displayP3Red:` here instead would make the in-app preview of a
    /// shield and the real shield render visibly different colours from the same
    /// four numbers, which is the one thing this bridge exists to prevent.
    var uiColor: UIColor {
        UIColor(
            red: CGFloat(red),
            green: CGFloat(green),
            blue: CGFloat(blue),
            alpha: CGFloat(alpha)
        )
    }
}

public extension ShieldBlurStyle {

    /// The SDK case this serialized name stands for.
    ///
    /// An exhaustive `switch` on purpose: ``ShieldBlurStyle`` exists so the blur
    /// can be written to `shield.plist` as a stable string, and this is the one
    /// place a renamed or removed case has to become a compile error rather than
    /// a wrong blur on someone's device (see the type's comment in
    /// Kernel/Model/ShieldCopy.swift). All seven cases are iOS 13+; no
    /// availability gate is needed at our 17.0 floor.
    var uiBlurEffectStyle: UIBlurEffect.Style {
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
#endif

// MARK: - Card

/// Gate's one container shape.
public struct GateCard: ViewModifier {

    public var padding: CGFloat
    public var cornerRadius: CGFloat
    public var fill: Color
    public var stroke: Color

    public init(
        padding: CGFloat = GateTheme.Spacing.l,
        cornerRadius: CGFloat = GateTheme.Radius.card,
        fill: Color = GateTheme.surface,
        stroke: Color = GateTheme.separator
    ) {
        self.padding = padding
        self.cornerRadius = cornerRadius
        self.fill = fill
        self.stroke = stroke
    }

    public func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(fill))
            .overlay(shape.strokeBorder(stroke, lineWidth: GateTheme.Stroke.hairline))
            .contentShape(shape)
    }
}

public extension View {

    /// Wrap in Gate's card: padded, filled, hairline-bordered, continuous corners.
    func gateCard(
        padding: CGFloat = GateTheme.Spacing.l,
        cornerRadius: CGFloat = GateTheme.Radius.card,
        fill: Color = GateTheme.surface,
        stroke: Color = GateTheme.separator
    ) -> some View {
        modifier(GateCard(padding: padding, cornerRadius: cornerRadius, fill: fill, stroke: stroke))
    }
}

// MARK: - Chip

/// A small pill: "Pending", "Allow-list", "Over the limit".
public struct GateChip: View {

    public var text: String
    public var tone: GateTheme.Tone
    public var systemImage: String?

    public init(_ text: String, tone: GateTheme.Tone = .neutral, systemImage: String? = nil) {
        self.text = text
        self.tone = tone
        self.systemImage = systemImage
    }

    public var body: some View {
        let color = tone.color
        return HStack(spacing: GateTheme.Spacing.xxs) {
            if let systemImage {
                Image(systemName: systemImage)
                    .imageScale(.small)
            }
            Text(text)
        }
        .font(GateTheme.Typography.chip)
        .foregroundStyle(color)
        .padding(.horizontal, GateTheme.Spacing.s)
        .padding(.vertical, GateTheme.Spacing.xxs)
        .background(Capsule(style: .continuous).fill(tone.pair.opacity(0.14).color))
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(tone.pair.opacity(0.30).color, lineWidth: GateTheme.Stroke.hairline)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(text))
    }
}

// MARK: - Status dot

/// The leading state indicator on a rule row. Filled means "in force".
public struct GateStatusDot: View {

    public var tone: GateTheme.Tone
    public var isFilled: Bool
    public var diameter: CGFloat

    public init(tone: GateTheme.Tone, isFilled: Bool = true, diameter: CGFloat = 10) {
        self.tone = tone
        self.isFilled = isFilled
        self.diameter = diameter
    }

    public var body: some View {
        let color = tone.color
        return Circle()
            .strokeBorder(color, lineWidth: GateTheme.Stroke.emphasis)
            .background(Circle().fill(isFilled ? color : Color.clear))
            .frame(width: diameter, height: diameter)
            // The state is always stated in words next to the dot; announcing the
            // dot as well would read the row's status twice.
            .accessibilityHidden(true)
    }
}
