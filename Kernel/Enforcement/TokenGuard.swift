//
//  TokenGuard.swift
//  GateKernel
//
//  The four caps that fail *silently*, enforced in our own code before a value
//  ever reaches the framework — and the single supported conversion between
//  `ManagedSettings.Token<_>` and ``EncodedToken``.
//
//  Build plan: docs/06-build-plan.md step 3.8.
//  Caps: docs/02-api-reference.md §14; docs/03-hard-constraints.md #34.
//
//  ─────────────────────────────────────────────────────────────────────────────
//  WHY THIS FILE EXISTS
//
//  Apple's words, on a store with 51 tokens in one collection: nothing happens.
//  No throw, no log, no `Result`. The store shields *nothing at all* and the
//  property reads back `nil` (docs/02-api-reference.md §14). A rule the user
//  believes is blocking Instagram is simply not blocking it, and the only
//  symptom is that Instagram opens.
//
//  docs/03-hard-constraints.md #34 states the remedy in as many words:
//  **"Guard `tokens.count <= 50` in your own code."** That guard is this file,
//  and it is the last one in the chain — the rule editor checks the same number
//  while the user is picking (docs/04-product-spec.md V1-2) and ``Rule/validate()``
//  checks it again on save, but both of those run in the app, and neither runs
//  when a `state.plist` written by a newer build is decoded inside the monitor.
//  This one runs immediately before the write, in whatever process is writing.
//
//  A guard that truncates would be worse than no guard: silently dropping the
//  51st app is a *loosening* the user never asked for and cannot see. So every
//  check here refuses, loudly, with a typed error the UI renders
//  (`Kernel/Enforcement/ShieldWriter.swift` turns a refusal into "leave the last
//  known-good shield set in place"), and nothing in this file ever returns a
//  shortened set.
//  ─────────────────────────────────────────────────────────────────────────────
//
//  RULES FOR THIS FILE
//  1. **Pure.** No I/O, no `Date()`, no logging. Every function is a total
//     function of its arguments so the whole cap layer is testable on Linux
//     (docs/06-build-plan.md step 3.11) where none of these frameworks exist.
//  2. **No truncation, ever.** See above.
//  3. The `ManagedSettings` half lives in the island at the bottom, fenced with
//     `#if canImport(ManagedSettings)`, exactly as `Kernel/Enforcement/MonitorPlan.swift`
//     fences `DeviceActivity`.
//  4. **This file is the only token codec in the product.** ``EncodedToken``
//     bytes are compared by ``GateFingerprint`` across process boundaries — the
//     app builds `shield.plist`'s fingerprint index and the shield extensions
//     look tokens up in it (``ShieldCopyTable/ruleID(forToken:)``) — so two
//     encoders that disagree by one byte produce two fingerprints for one app
//     and every lookup misses. Any new code that needs bytes from a token calls
//     ``TokenGuard/encode(_:)-(ApplicationToken)``; it does not reach for a
//     `JSONEncoder` of its own.
//

import Foundation

#if canImport(ManagedSettings)
import ManagedSettings
#endif

// MARK: - TokenGuardError

/// A platform cap that a write would have exceeded, or a token that could not be
/// carried across the kernel boundary.
///
/// `Error` so a call site can `throw`, `Equatable` so tests can assert on the
/// exact case, and deliberately **not** `Codable`: like ``RuleIssue`` these are
/// computed on demand for the editor and the debug screen and must never outlive
/// the state that produced them. User-facing copy lives in `GateKernelUI`; the
/// kernel has no localization.
public enum TokenGuardError: Error, Sendable, Equatable, Hashable, CustomStringConvertible {

    /// A shield collection would have held more than
    /// ``GateLimits/maxTokensPerShieldCollection`` tokens.
    ///
    /// The one that costs the product if it is missed: past the cap the store
    /// shields nothing (docs/03-hard-constraints.md #34).
    case collectionOverflow(collection: TokenCollection, count: Int, limit: Int)

    /// The `except:` set of a `ShieldSettings.ActivityCategoryPolicy` would have
    /// held more than the cap.
    ///
    /// Same 50 as ``collectionOverflow(collection:count:limit:)`` — the
    /// exceptions ride in the same collection — but reported separately because
    /// the user-facing cause is different: the exceptions come from live grants
    /// and from allowlist selections, not from the blocklist the user edited.
    case exceptionOverflow(collection: TokenCollection, count: Int, limit: Int)

    /// The shielded set and its exceptions each fit, but their **sum** does not.
    ///
    /// **(unverified)** Apple documents the cap per collection and says nothing
    /// about whether a `.specific(categories, except: exceptions)` policy counts
    /// `categories.count`, `exceptions.count` or their sum against it
    /// (docs/02-api-reference.md §14 lists one number per collection). Gate
    /// therefore treats this as a *warning*, not a refusal: ``isBlocking`` is
    /// `false`, `ShieldWriter` still performs the write, and the case exists so
    /// the debug screen (docs/04-product-spec.md V1-11) can show it next to the
    /// rule if a device test ever proves the sum is what counts. Refusing on an
    /// unverified rule would strand a legitimate 50-category rule with three
    /// exceptions permanently unenforced, which is the more expensive mistake.
    case combinedOverflow(collection: TokenCollection, shielded: Int, exceptions: Int, limit: Int)

    /// More rules than ``GateLimits/maxRules``.
    ///
    /// Advisory. See ``TokenGuard/checkRuleCount(_:)`` for why exceeding it never
    /// stops a shield from being written.
    case ruleLimitExceeded(count: Int, limit: Int)

    /// More named `ManagedSettingsStore`s than ``GateLimits/maxNamedStores``.
    /// Silent failure, like the token cap.
    case namedStoreLimitExceeded(count: Int, limit: Int)

    /// More domains than ``GateLimits/maxWebFilterDomains`` in a
    /// `webContent.blockedByFilter` policy. Silent failure.
    ///
    /// v1 never writes `blockedByFilter` — any policy other than `.none` disables
    /// Safari private browsing device-wide (docs/02-api-reference.md §14), which
    /// is not a side effect an app blocker gets to impose. The check is here so
    /// that the day someone adds a web filter, the cap is already guarded.
    case webFilterDomainLimitExceeded(count: Int, limit: Int)

    /// A `Token<_>` could not be encoded to bytes.
    ///
    /// Effectively unreachable — `Token` is `Codable` (docs/02-api-reference.md
    /// §5) and holds opaque bytes — but a `try!` here would trade a missed
    /// fingerprint for a crash in the monitor.
    case tokenEncodingFailed(kind: TokenKind, detail: String)

    /// Stored bytes could not be decoded back into a `Token<_>`.
    ///
    /// Reachable: `state.plist` is decoded leniently and a torn write can leave
    /// an ``EncodedToken`` holding a truncated blob. The caller drops that one
    /// token and carries on; it never fails the whole write.
    case tokenDecodingFailed(kind: TokenKind, fingerprint: String, detail: String)

    /// Whether the platform's failure mode for this cap is silence.
    ///
    /// Every `true` here is a case where iOS neither throws nor logs, which is
    /// the entire justification for this file.
    public var isSilent: Bool {
        switch self {
        case .collectionOverflow, .exceptionOverflow, .combinedOverflow,
             .namedStoreLimitExceeded, .webFilterDomainLimitExceeded:
            true
        case .ruleLimitExceeded, .tokenEncodingFailed, .tokenDecodingFailed:
            false
        }
    }

    /// Whether a write must be refused rather than merely reported.
    ///
    /// `false` for the advisory cases: a rule count over the product cap is a
    /// planning problem (`MonitorPlan` evicts activities; the shield set is still
    /// correct), an unverified combined overflow is a warning by design, and a
    /// single undecodable token costs one token, not a rule.
    public var isBlocking: Bool {
        switch self {
        case .collectionOverflow, .exceptionOverflow, .namedStoreLimitExceeded,
             .webFilterDomainLimitExceeded:
            true
        case .combinedOverflow, .ruleLimitExceeded, .tokenEncodingFailed,
             .tokenDecodingFailed:
            false
        }
    }

    /// The collection this error is about, when it is about one.
    public var collection: TokenCollection? {
        switch self {
        case .collectionOverflow(let collection, _, _),
             .exceptionOverflow(let collection, _, _),
             .combinedOverflow(let collection, _, _, _):
            collection
        case .ruleLimitExceeded, .namedStoreLimitExceeded,
             .webFilterDomainLimitExceeded, .tokenEncodingFailed, .tokenDecodingFailed:
            nil
        }
    }

    /// The equivalent ``RuleIssue``, so the rule editor renders one string for
    /// this condition whether it was caught on save or at write time.
    ///
    /// `nil` for the errors that are not about a user-editable rule.
    public var ruleIssue: RuleIssue? {
        switch self {
        case .collectionOverflow(let collection, let count, let limit),
             .exceptionOverflow(let collection, let count, let limit):
            .tokenCapExceeded(collection: collection, count: count, limit: limit)
        case .combinedOverflow, .ruleLimitExceeded, .namedStoreLimitExceeded,
             .webFilterDomainLimitExceeded, .tokenEncodingFailed, .tokenDecodingFailed:
            nil
        }
    }

    /// Diagnostic text for the debug screen and `os.Logger`. Not user-facing and
    /// not localized — see the type's note.
    public var description: String {
        switch self {
        case .collectionOverflow(let collection, let count, let limit):
            "shield collection \(collection.rawValue) holds \(count) tokens, cap is \(limit) (fails silently)"
        case .exceptionOverflow(let collection, let count, let limit):
            "shield collection \(collection.rawValue) has \(count) exceptions, cap is \(limit) (fails silently)"
        case .combinedOverflow(let collection, let shielded, let exceptions, let limit):
            "shield collection \(collection.rawValue) holds \(shielded) + \(exceptions) exceptions, "
                + "over \(limit) combined (unverified whether iOS counts the sum)"
        case .ruleLimitExceeded(let count, let limit):
            "\(count) rules, product cap is \(limit)"
        case .namedStoreLimitExceeded(let count, let limit):
            "\(count) named ManagedSettingsStores, cap is \(limit) (fails silently)"
        case .webFilterDomainLimitExceeded(let count, let limit):
            "\(count) web filter domains, cap is \(limit) (fails silently)"
        case .tokenEncodingFailed(let kind, let detail):
            "could not encode \(kind.rawValue) token: \(detail)"
        case .tokenDecodingFailed(let kind, let fingerprint, let detail):
            "could not decode \(kind.rawValue) token \(fingerprint): \(detail)"
        }
    }
}

// MARK: - TokenGuard

/// The caps, and the token codec.
///
/// An uninhabited namespace: nothing here has state, and a `TokenGuard()` in the
/// monitor would be one more allocation under a 6 MB ceiling
/// (docs/03-hard-constraints.md #31).
public enum TokenGuard {

    // MARK: The numbers

    /// 50 tokens per shield collection (docs/02-api-reference.md §14).
    public static var collectionLimit: Int { GateLimits.maxTokensPerShieldCollection }

    /// 50 named `ManagedSettingsStore`s per process.
    public static var storeLimit: Int { GateLimits.maxNamedStores }

    /// 8 rules per install (docs/04-product-spec.md V1-2).
    public static var ruleLimit: Int { GateLimits.maxRules }

    /// 50 domains per `webContent.blockedByFilter` policy.
    public static var webFilterDomainLimit: Int { GateLimits.maxWebFilterDomains }

    // MARK: Shield collections

    /// Whether `count` tokens fit in one shield collection.
    public static func isWithinCap(_ count: Int) -> Bool {
        count <= collectionLimit
    }

    /// How many more tokens a collection holding `count` can take. Never negative.
    ///
    /// This is the number the rule editor puts next to the picker — "6 more apps"
    /// — so that the user meets the cap as a budget rather than as an error
    /// (docs/06-build-plan.md step 5.2).
    public static func headroom(after count: Int) -> Int {
        max(0, collectionLimit - count)
    }

    /// Throws ``TokenGuardError/collectionOverflow(collection:count:limit:)`` when
    /// a shield collection would be over the cap.
    public static func check(_ count: Int, in collection: TokenCollection) throws {
        guard count > collectionLimit else { return }
        throw TokenGuardError.collectionOverflow(
            collection: collection, count: count, limit: collectionLimit
        )
    }

    /// The `except:` half of the same cap.
    public static func checkExceptions(_ count: Int, in collection: TokenCollection) throws {
        guard count > collectionLimit else { return }
        throw TokenGuardError.exceptionOverflow(
            collection: collection, count: count, limit: collectionLimit
        )
    }

    /// The unverified sum rule, as a warning value rather than a throw.
    ///
    /// See ``TokenGuardError/combinedOverflow(collection:shielded:exceptions:limit:)``
    /// for why this never refuses a write.
    public static func combinedIssue(
        shielded: Int,
        exceptions: Int,
        in collection: TokenCollection
    ) -> TokenGuardError? {
        guard shielded + exceptions > collectionLimit else { return nil }
        return .combinedOverflow(
            collection: collection,
            shielded: shielded,
            exceptions: exceptions,
            limit: collectionLimit
        )
    }

    /// Every cap a set of counts breaks, in ``TokenCollection/allCases`` order.
    ///
    /// Ordered rather than set-shaped so that two processes produce byte-identical
    /// diagnostics for the same state — the same determinism rule
    /// `Kernel/Enforcement/MonitorPlan.swift` follows.
    public static func issues(forCounts counts: [TokenCollection: Int]) -> [TokenGuardError] {
        TokenCollection.allCases.compactMap { collection in
            let count = counts[collection] ?? 0
            guard count > collectionLimit else { return nil }
            return TokenGuardError.collectionOverflow(
                collection: collection, count: count, limit: collectionLimit
            )
        }
    }

    /// Every cap a stored selection breaks, without decoding the selection blob.
    ///
    /// ``SelectionDigest`` carries the three counts precisely so that this check
    /// is affordable in the monitor, where decoding a `FamilyActivitySelection`
    /// costs real memory against the 6 MB ceiling
    /// (docs/05-architecture.md, persistence).
    public static func issues(in digest: SelectionDigest) -> [TokenGuardError] {
        digest.overflowingCollections.map { overflow in
            TokenGuardError.collectionOverflow(
                collection: overflow.collection,
                count: overflow.count,
                limit: collectionLimit
            )
        }
    }

    /// Throwing form of ``issues(in:)``, reporting the first overflow.
    public static func check(_ digest: SelectionDigest) throws {
        if let first = issues(in: digest).first { throw first }
    }

    // MARK: Rules and stores

    /// Throws when an install holds more than ``GateLimits/maxRules`` rules.
    ///
    /// **Advisory, and deliberately so.** `Ratchet` already refuses
    /// ``Mutation/createRule(_:)`` past the cap, so the only way to see a ninth
    /// rule is a `state.plist` written by a future build. Refusing to *write* its
    /// shield set at that point would silently unenforce a rule the user
    /// configured — a loosening, caused by our own version check, with no UI
    /// anywhere to explain it. `ShieldWriter` therefore writes every rule it is
    /// given and this error is surfaced as a banner; the real consequence of the
    /// cap is `MonitorPlan` evicting the ninth rule's *activity*, which costs
    /// latency and nothing else.
    public static func checkRuleCount(_ count: Int) throws {
        guard count > ruleLimit else { return }
        throw TokenGuardError.ruleLimitExceeded(count: count, limit: ruleLimit)
    }

    /// Throws when a process would hold more than ``GateLimits/maxNamedStores``
    /// named stores.
    ///
    /// Gate's own names are ``ManagedSettingsStore/Name/rule(_:)`` per rule plus
    /// ``ManagedSettingsStore/Name/solid`` and
    /// ``ManagedSettingsStore/Name/backstop`` — ten in total at the rule cap, so
    /// this can only be reached through stores orphaned by deleted rules. That is
    /// what the iOS 26.5 sweep in `Kernel/Engine/Reconciler.swift`
    /// (`ManagedSettingsStore.deleteStores(_:)`) exists to prevent, and below
    /// 26.5 there is no way to enumerate or delete them at all — see
    /// ``storeAudit()``.
    public static func checkStoreCount(_ count: Int) throws {
        guard count > storeLimit else { return }
        throw TokenGuardError.namedStoreLimitExceeded(count: count, limit: storeLimit)
    }

    /// The number of named stores Gate will hold for `ruleCount` rules.
    ///
    /// Rules, plus `solid`, plus `backstop`.
    public static func expectedStoreCount(ruleCount: Int) -> Int {
        max(0, ruleCount) + 2
    }

    /// Throws when a `webContent.blockedByFilter` policy would be over the cap.
    public static func checkWebFilterDomainCount(_ count: Int) throws {
        guard count > webFilterDomainLimit else { return }
        throw TokenGuardError.webFilterDomainLimitExceeded(
            count: count, limit: webFilterDomainLimit
        )
    }
}

// MARK: - ManagedSettings island

// The SDK half: the `Token<_>` <-> ``EncodedToken`` codec and the cap checks that
// take real token sets. Fenced so everything above compiles in the
// platform-agnostic SwiftPM test package (docs/05-architecture.md, module layer
// split) — `ManagedSettings` does not exist on Linux, and neither does `os`,
// which is why nothing in this file logs.
//
// Nothing here stores a token: `Token<_>` has no audited `Sendable` conformance,
// so a stored property or a stored static of one inside a `Sendable` type is a
// Swift 6 strict-concurrency error. Tokens are parameters and return values only.

#if canImport(ManagedSettings)

public extension TokenGuard {

    // MARK: Codec

    /// The encoder every token in the product goes through.
    ///
    /// `.sortedKeys` is load-bearing, not tidiness. If `Token`'s `Codable`
    /// synthesis writes a keyed container, an unsorted encoder is free to emit
    /// the keys in a different order in a different process — and two orderings
    /// of the same token are two different ``EncodedToken/fingerprint``s, which
    /// breaks `ShieldCopyTable`'s fingerprint index between the app that wrote it
    /// and the extension that reads it. Sorted keys make the bytes a function of
    /// the token alone.
    ///
    /// Computed rather than a stored static: `JSONEncoder` is a non-`Sendable`
    /// class, so a `static let` would be a strict-concurrency error, and
    /// allocating one is cheap next to the daemon round trip that follows it.
    private static var tokenEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    /// Bytes for one token.
    ///
    /// The token is wrapped in a one-element array before encoding. `Token`'s
    /// encoded form is opaque to us and may well be a JSON fragment (a bare
    /// string), and top-level fragment support has moved around between Swift
    /// versions; an array is a container on every version, on every platform.
    /// ``decode(_:as:kind:)`` unwraps it again, and since this file is the only
    /// codec in the product (see the file header) the wrapper never leaks.
    private static func encodeToken<Resource>(
        _ token: Token<Resource>,
        kind: TokenKind
    ) throws -> EncodedToken {
        do {
            return EncodedToken(bytes: try tokenEncoder.encode([token]))
        } catch {
            throw TokenGuardError.tokenEncodingFailed(
                kind: kind, detail: String(describing: error)
            )
        }
    }

    /// Inverse of ``encodeToken(_:kind:)``.
    ///
    /// `Resource` is inferred from the call site's return type rather than passed
    /// as a metatype, so this file never has to name `Application`,
    /// `ActivityCategory` or `WebDomain` — only the `…Token` typealiases, which
    /// docs/02-api-reference.md §5 pins to `ManagedSettings`.
    private static func decodeToken<Resource>(
        _ encoded: EncodedToken,
        kind: TokenKind
    ) throws -> Token<Resource> {
        guard !encoded.isEmpty else {
            throw TokenGuardError.tokenDecodingFailed(
                kind: kind, fingerprint: encoded.fingerprint, detail: "empty"
            )
        }
        do {
            let unwrapped = try JSONDecoder().decode([Token<Resource>].self, from: encoded.bytes)
            guard let token = unwrapped.first else {
                throw TokenGuardError.tokenDecodingFailed(
                    kind: kind, fingerprint: encoded.fingerprint, detail: "empty array"
                )
            }
            return token
        } catch let error as TokenGuardError {
            throw error
        } catch {
            throw TokenGuardError.tokenDecodingFailed(
                kind: kind, fingerprint: encoded.fingerprint, detail: String(describing: error)
            )
        }
    }

    /// Encodes an `ApplicationToken` for storage in ``GateState`` or
    /// `shield.plist`.
    static func encode(_ token: ApplicationToken) throws -> EncodedToken {
        try encodeToken(token, kind: .application)
    }

    /// Encodes an `ActivityCategoryToken`.
    static func encode(_ token: ActivityCategoryToken) throws -> EncodedToken {
        try encodeToken(token, kind: .category)
    }

    /// Encodes a `WebDomainToken`.
    static func encode(_ token: WebDomainToken) throws -> EncodedToken {
        try encodeToken(token, kind: .webDomain)
    }

    /// Decodes stored bytes back into an `ApplicationToken`.
    ///
    /// A successful decode does **not** mean the token still refers to the app it
    /// referred to when it was stored. Tokens are reissued across OS updates and
    /// re-authorization and can fail `==` against a stored copy
    /// (docs/03-hard-constraints.md #36, thread 814571, no workaround from
    /// Apple). Prefer a live token the system just handed you — see
    /// ``fingerprintIndex(_:kind:)`` — and treat a decoded one as a best effort
    /// that the recovery flow (docs/04-product-spec.md V1-9) exists to repair.
    static func decodeApplication(_ encoded: EncodedToken) throws -> ApplicationToken {
        try decodeToken(encoded, kind: .application)
    }

    /// Decodes stored bytes back into an `ActivityCategoryToken`.
    static func decodeCategory(_ encoded: EncodedToken) throws -> ActivityCategoryToken {
        try decodeToken(encoded, kind: .category)
    }

    /// Decodes stored bytes back into a `WebDomainToken`.
    static func decodeWebDomain(_ encoded: EncodedToken) throws -> WebDomainToken {
        try decodeToken(encoded, kind: .webDomain)
    }

    // MARK: Bulk conversion

    /// Decodes a list of stored tokens, keeping the ones that survive.
    ///
    /// Lenient on purpose and in one direction only: a torn ``EncodedToken`` costs
    /// exactly one token — for a grant, one app that stays shielded; for a
    /// selection, one app that stays blocked — and never fails the write that
    /// would otherwise have enforced the other forty-nine. The failures are
    /// returned rather than swallowed so the caller can report them.
    static func decodeApplications(
        _ encoded: [EncodedToken]
    ) -> (tokens: Set<ApplicationToken>, failures: [TokenGuardError]) {
        var tokens: Set<ApplicationToken> = []
        var failures: [TokenGuardError] = []
        for item in encoded {
            do { tokens.insert(try decodeApplication(item)) }
            catch let error as TokenGuardError { failures.append(error) }
            catch {
                failures.append(.tokenDecodingFailed(
                    kind: .application,
                    fingerprint: item.fingerprint,
                    detail: String(describing: error)
                ))
            }
        }
        return (tokens, failures)
    }

    /// ``decodeApplications(_:)`` for category tokens.
    static func decodeCategories(
        _ encoded: [EncodedToken]
    ) -> (tokens: Set<ActivityCategoryToken>, failures: [TokenGuardError]) {
        var tokens: Set<ActivityCategoryToken> = []
        var failures: [TokenGuardError] = []
        for item in encoded {
            do { tokens.insert(try decodeCategory(item)) }
            catch let error as TokenGuardError { failures.append(error) }
            catch {
                failures.append(.tokenDecodingFailed(
                    kind: .category,
                    fingerprint: item.fingerprint,
                    detail: String(describing: error)
                ))
            }
        }
        return (tokens, failures)
    }

    /// ``decodeApplications(_:)`` for web-domain tokens.
    static func decodeWebDomains(
        _ encoded: [EncodedToken]
    ) -> (tokens: Set<WebDomainToken>, failures: [TokenGuardError]) {
        var tokens: Set<WebDomainToken> = []
        var failures: [TokenGuardError] = []
        for item in encoded {
            do { tokens.insert(try decodeWebDomain(item)) }
            catch let error as TokenGuardError { failures.append(error) }
            catch {
                failures.append(.tokenDecodingFailed(
                    kind: .webDomain,
                    fingerprint: item.fingerprint,
                    detail: String(describing: error)
                ))
            }
        }
        return (tokens, failures)
    }

    // MARK: Fingerprints

    /// The stable digest of a token, or `nil` if it could not be encoded.
    ///
    /// Stable across processes and launches, which `hashValue` is not — Swift
    /// seeds its hasher per process (see ``GateFingerprint``). This is the key
    /// `ShieldCopyTable/ruleIDsByTokenFingerprint` is built on.
    static func fingerprint(of token: ApplicationToken) -> String? {
        try? encode(token).fingerprint
    }

    /// ``fingerprint(of:)-(ApplicationToken)`` for a category token.
    static func fingerprint(of token: ActivityCategoryToken) -> String? {
        try? encode(token).fingerprint
    }

    /// ``fingerprint(of:)-(ApplicationToken)`` for a web-domain token.
    static func fingerprint(of token: WebDomainToken) -> String? {
        try? encode(token).fingerprint
    }

    /// Indexes live tokens by fingerprint.
    ///
    /// This is how `Kernel/Enforcement/ShieldWriter.swift` subtracts a grant
    /// without ever comparing a stored token to a live one with `==`: it looks up
    /// the grant's fingerprint and, on a hit, removes *the system's own token
    /// object* from the shielded set. A token that cannot be encoded is skipped —
    /// it simply never matches a lift, which leaves the app shielded, which is
    /// the safe direction.
    ///
    /// - Parameter kind: only used to shape the (unused) error path; the index
    ///   itself is keyed by fingerprint alone.
    static func fingerprintIndex<Resource>(
        _ tokens: Set<Token<Resource>>,
        kind: TokenKind
    ) -> [String: Token<Resource>] {
        var index: [String: Token<Resource>] = [:]
        index.reserveCapacity(tokens.count)
        for token in tokens {
            guard let encoded = try? encodeToken(token, kind: kind) else { continue }
            index[encoded.fingerprint] = token
        }
        return index
    }

    // MARK: Guarded sets

    /// Returns `tokens` unchanged, or throws if the set is over the cap.
    ///
    /// Never truncates — a 51st app dropped quietly is a loosening the user did
    /// not ask for (see the file header). The set is returned rather than
    /// discarded so a call site reads
    /// `store.shield.applications = try TokenGuard.guarded(apps, in: .applications)`
    /// and cannot forget to check.
    static func guarded<Resource>(
        _ tokens: Set<Token<Resource>>,
        in collection: TokenCollection
    ) throws -> Set<Token<Resource>> {
        try check(tokens.count, in: collection)
        return tokens
    }

    /// ``guarded(_:in:)`` for the `except:` half of a category policy.
    static func guardedExceptions<Resource>(
        _ tokens: Set<Token<Resource>>,
        in collection: TokenCollection
    ) throws -> Set<Token<Resource>> {
        try checkExceptions(tokens.count, in: collection)
        return tokens
    }

    // MARK: Store audit

    /// What the process currently holds against the 50-named-store cap.
    ///
    /// `nil` below iOS 26.5: `ManagedSettingsStore.stores` is a 26.5 symbol
    /// (docs/02-api-reference.md §13) and there is no other way to enumerate
    /// stores, so on iOS 17–26.4 the cap is unobservable and Gate relies on its
    /// own naming discipline instead — ``expectedStoreCount(ruleCount:)`` is ten
    /// at the rule cap, forty short of the limit. A `nil` here means "cannot
    /// tell", never "clean".
    static func storeAudit() -> StoreAudit? {
        if #available(iOS 26.5, *) {
            let names = ManagedSettingsStore.stores
            let gateNames = names
                .filter(\.isGateStore)
                .map(\.rawValue)
                .sorted()
            return StoreAudit(
                total: names.count,
                gateNames: gateNames,
                limit: storeLimit
            )
        }
        return nil
    }

    /// The result of ``storeAudit()``.
    ///
    /// Carries raw strings, not `ManagedSettingsStore.Name` values: `Name` has no
    /// audited `Sendable` conformance, and this type is handed to the debug
    /// screen across an isolation boundary.
    struct StoreAudit: Sendable, Equatable, Hashable {

        /// Every named store in the process, Gate's and anyone else's.
        public let total: Int

        /// Gate's own store names, sorted for a stable debug rendering.
        public let gateNames: [String]

        /// ``GateLimits/maxNamedStores``.
        public let limit: Int

        public init(total: Int, gateNames: [String], limit: Int) {
            self.total = total
            self.gateNames = gateNames
            self.limit = limit
        }

        /// Stores that are not Gate's. Never deleted by Gate — the 26.5 sweep
        /// filters on ``ManagedSettingsStore/Name/isGateStore`` first.
        public var foreign: Int { max(0, total - gateNames.count) }

        /// Whether the process is over the silent cap.
        public var isOverCap: Bool { total > limit }

        /// The error to surface, if any.
        public var error: TokenGuardError? {
            isOverCap
                ? .namedStoreLimitExceeded(count: total, limit: limit)
                : nil
        }
    }
}

#endif
