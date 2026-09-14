//
//  InboxStore.swift
//  GateKernel
//
//  The one direction data flows *out* of an extension.
//
//  Build plan: docs/06-build-plan.md step 3.3.
//
//  THE SHAPE, AND WHY IT IS THIS SHAPE
//  docs/05-architecture.md, single-writer discipline: the app is the only writer
//  of `state.plist`; extensions never mutate it. `GateShieldAction` *appends* one
//  tiny plist per event into `inbox/` (`grant-<uuid>.plist`,
//  `bypass-<uuid>.plist`); `GateActivityMonitor` appends a breadcrumb. The app
//  compacts `inbox/` into `state.plist` on every foreground reconcile and deletes
//  the consumed files.
//
//  Append-only with UUID filenames is what makes three processes writing at once
//  correct **without any lock, any coordination, and any blocking call**:
//    * two writers can never target the same path, so there is no last-writer-wins;
//    * each file is written with `Data.WritingOptions.atomic`, which is a write to
//      a sibling temporary plus `rename(2)`, so a reader enumerating the directory
//      sees each file as either absent or complete — never a torn prefix;
//    * `rename(2)` within one directory is atomic on APFS, so "appears in the
//      listing" and "is fully written" are the same instant.
//  That matters because `NSFileCoordinator` is a synchronous, blocking hop and
//  `GateShieldAction` runs inside a latency-bounded system callback
//  (docs/03-hard-constraints.md #33). This store never coordinates.
//
//  DELIVERY IS AT-LEAST-ONCE. ``InboxStore/drain()`` reads a file and then
//  deletes it; if the process dies in between, the event is delivered twice. The
//  app must therefore be idempotent per ``InboxEvent/id`` — which it must be
//  anyway, since "the same event can fire twice" is true of the whole
//  DeviceActivity surface (docs/03-hard-constraints.md #35;
//  docs/05-architecture.md, enforcement layering).
//
//  RULES FOR THIS FILE
//  1. Foundation + os only. Linked into GateActivityMonitor (6 MB ceiling,
//     docs/03-hard-constraints.md #31).
//  2. Appending must stay O(1) in syscalls: one idempotent `mkdir`, one atomic
//     write. It must never enumerate the directory, stat anything, or decode
//     anything. Bounding the inbox is the *drainer's* job.
//

import Foundation
import os

/// Computed rather than a stored global: see the note in
/// `Kernel/Store/GateStateStore.swift`.
private var inboxLog: Logger {
    Logger(subsystem: GateID.Subsystem.kernel, category: "inbox")
}

// MARK: - InboxEvent

/// One thing that happened in an extension, on its way to the app.
///
/// Deliberately schema-light: a kind, a timestamp, an optional rule, and a small
/// string-to-string payload. Two reasons, both real.
///
/// 1. **Version skew.** An app update replaces the app and its four `.appex`
///    bundles together, but files written by the *previous* version can still be
///    sitting in `inbox/` when the new version drains it. A record whose decoding
///    tolerates missing and unknown fields survives that; a record with a tight
///    synthesized `Codable` conformance throws, and the event is lost or the
///    drain stalls.
/// 2. **Budget.** The whole point of the inbox is that a process under a 6 MB
///    ceiling can write to it without linking a model layer.
///
/// ``id`` is also the *request identifier* the sub-iOS-26.5 intervention deep
/// link carries: `GateShieldAction` appends a `.grantRequest`, then builds
/// `GateID.interventionURL(ruleID:requestID:)` with this `id` and attaches it to
/// its notification (docs/04-product-spec.md V1-7). The URL is a pointer to this
/// record, never a payload — any app on the device can open `gate://`.
public struct InboxEvent: Codable, Hashable, Sendable, Identifiable {

    // MARK: Kind

    /// What happened.
    ///
    /// Raw values are also the filename prefix, so `ls inbox/` is legible over a
    /// sysdiagnose and matches the names in docs/05-architecture.md.
    public enum Kind: String, Codable, Hashable, Sendable, CaseIterable {

        /// The user tapped the shield's primary button ("Let me in") and wants
        /// the intervention (docs/04-product-spec.md V1-7). Carries the rule; the
        /// event's ``InboxEvent/id`` is the request ID in the deep link.
        case grantRequest = "grant"

        /// A grant was issued *by an extension* rather than by the app — the
        /// iOS 26.4+ shield submenu path ("1 more minute" / "15 more minutes" /
        /// "1 hour", docs/04-product-spec.md V2-1). The app applies it to
        /// `GateState` on the next reconcile; the extension has already armed the
        /// one-shot expiry activity, which is why the grant must adopt this
        /// event's `id`.
        ///
        /// Written whenever the device actually has the submenu:
        /// `GateShieldAction` handles the three submenu cases, and
        /// `GateShieldConfiguration` offers them behind `if #available(iOS 26.4)`.
        /// Below 26.4 nothing writes one, so the v1 install base mostly never
        /// sees this kind — "mostly", not "never".
        case grantIssued = "granted"

        /// The user hit a shield. Counted honestly and shown back to them as
        /// "Gate's own data", which is the only usage data Gate is allowed to
        /// have (docs/03-hard-constraints.md #25, #30;
        /// docs/04-product-spec.md V2-5).
        case bypassAttempt = "bypass"

        /// A monitor callback ran. The only evidence the monitor is alive: it is
        /// killed for memory or idleness and has been reported as never launched
        /// at all on iOS 26.3.1 with correct configuration
        /// (docs/03-hard-constraints.md #32), and a jetsam kill delivers no
        /// callback and leaves no crash the user will ever see. A run of missing
        /// breadcrumbs on the debug screen is the symptom
        /// (docs/04-product-spec.md V1-11).
        case breadcrumb = "breadcrumb"

        /// An extension was handed an `ApplicationToken` it could not match
        /// against anything in `GateState`. Tokens go stale after OS updates and
        /// re-authorization and can fail `==` against stored copies
        /// (docs/03-hard-constraints.md #36). The app turns this into the
        /// reselection flow, which is a first-class screen and not an error path
        /// (docs/04-product-spec.md V1-9).
        case tokenExpiry = "token-expiry"

        /// A record written by a version of Gate this one does not know about.
        /// Preserved rather than dropped so the drain never stalls and the debug
        /// screen can show that something arrived.
        case unknown = "unknown"
    }

    // MARK: Payload keys

    /// Well-known ``InboxEvent/payload`` keys.
    ///
    /// A caseless namespace rather than an enum with cases: the payload is
    /// deliberately open, and a writer in a future version must be able to add a
    /// key without this type rejecting it.
    public enum Key {
        /// Which callback or button produced the event, e.g. `intervalDidStart`,
        /// `primaryButtonPressed`.
        public static let source = "source"
        /// Free-form detail for the debug screen. Never Screen Time data.
        public static let detail = "detail"
        /// The `DeviceActivityName` raw value, for monitor breadcrumbs.
        public static let activityName = "activity"
        /// Seconds, as a base-10 integer string. Grant durations.
        public static let durationSeconds = "duration"
        /// Which submenu item was pressed, `0`-based (iOS 26.4+, V2-1).
        public static let submenuIndex = "submenu"
        /// The `ShieldAction` case name, for bypass records.
        public static let action = "action"
    }

    // MARK: Stored

    /// Unique per event, and the request ID in the intervention deep link.
    public let id: UUID

    /// What happened.
    public let kind: Kind

    /// When the writer created it. **The only ordering key** — the drain sorts
    /// on this rather than on file modification dates, which keeps this whole
    /// file clear of `NSPrivacyAccessedAPICategoryFileTimestamp`
    /// (docs/06-build-plan.md step 7.1) and clear of a stat per file.
    public let createdAt: Date

    /// The rule this concerns, when there is one.
    public let ruleID: UUID?

    /// Small, flat, plist-safe extras. Strings only, by design: the value must
    /// survive a round trip through a property list written by one version of
    /// Gate and read by another without a schema.
    public let payload: [String: String]

    // MARK: Init

    public init(
        id: UUID = UUID(),
        kind: Kind,
        createdAt: Date = Date(),
        ruleID: UUID? = nil,
        payload: [String: String] = [:]
    ) {
        self.id = id
        self.kind = kind
        self.createdAt = createdAt
        self.ruleID = ruleID
        self.payload = payload
    }

    // MARK: Lenient decoding

    private enum CodingKeys: String, CodingKey {
        case id, kind, createdAt, ruleID, payload
    }

    /// Decodes defensively. See the type's note on version skew.
    ///
    /// An unrecognized ``Kind`` becomes ``Kind/unknown`` instead of throwing; a
    /// missing `payload` becomes empty; a missing `createdAt` becomes the epoch,
    /// which sorts such an event first and gets it consumed rather than stuck.
    /// Only `id` is required — without it the app cannot deduplicate, and an
    /// event it cannot deduplicate is worse than an event it drops.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        let rawKind = try container.decodeIfPresent(String.self, forKey: .kind)
        self.kind = rawKind.flatMap { Kind(rawValue: $0) } ?? .unknown
        self.createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date(timeIntervalSince1970: 0)
        self.ruleID = try container.decodeIfPresent(UUID.self, forKey: .ruleID)
        self.payload = try container.decodeIfPresent([String: String].self, forKey: .payload) ?? [:]
    }

    // MARK: Payload access

    public subscript(_ key: String) -> String? { payload[key] }

    public func integer(_ key: String) -> Int? { payload[key].flatMap { Int($0) } }

    public func uuid(_ key: String) -> UUID? { payload[key].flatMap { UUID(uuidString: $0) } }

    // MARK: Factories

    /// The user tapped "Let me in" on a rule's shield.
    ///
    /// The returned event's ``id`` is what goes into
    /// `GateID.interventionURL(ruleID:requestID:)`.
    public static func grantRequest(
        ruleID: UUID,
        action: String,
        now: Date = Date()
    ) -> InboxEvent {
        InboxEvent(
            kind: .grantRequest,
            createdAt: now,
            ruleID: ruleID,
            payload: [Key.action: action]
        )
    }

    /// The user hit a shield.
    public static func bypassAttempt(
        ruleID: UUID,
        action: String,
        now: Date = Date()
    ) -> InboxEvent {
        InboxEvent(
            kind: .bypassAttempt,
            createdAt: now,
            ruleID: ruleID,
            payload: [Key.action: action]
        )
    }

    /// A monitor callback ran.
    ///
    /// Keep `detail` short and free of anything derived from Screen Time: the
    /// breadcrumb is shown on the debug screen and pasted into bug reports.
    public static func breadcrumb(
        source: String,
        activityName: String? = nil,
        ruleID: UUID? = nil,
        detail: String? = nil,
        now: Date = Date()
    ) -> InboxEvent {
        var payload = [Key.source: source]
        payload[Key.activityName] = activityName
        payload[Key.detail] = detail
        return InboxEvent(kind: .breadcrumb, createdAt: now, ruleID: ruleID, payload: payload)
    }

    /// An extension saw a token it could not match.
    public static func tokenExpiry(
        ruleID: UUID?,
        source: String,
        now: Date = Date()
    ) -> InboxEvent {
        InboxEvent(
            kind: .tokenExpiry,
            createdAt: now,
            ruleID: ruleID,
            payload: [Key.source: source]
        )
    }

    // MARK: Filenames

    /// `grant-<uuid>.plist`, `bypass-<uuid>.plist`, … — exactly the names in
    /// docs/05-architecture.md.
    public var fileName: String {
        "\(kind.rawValue)-\(id.uuidString).plist"
    }

    /// The extension every inbox file carries.
    public static let fileExtension = "plist"
}

// MARK: - InboxDrain

/// What one ``InboxStore/drain()`` actually did.
///
/// The counts exist because the interesting cases are the ones that produce no
/// events: an inbox full of files that will not decode, or a drain that stopped
/// at the per-pass cap and needs another pass.
public struct InboxDrain: Sendable, Equatable {

    /// The events, oldest first by ``InboxEvent/createdAt``.
    public let events: [InboxEvent]

    /// Files that decoded and were deleted.
    public let consumed: Int

    /// Files that did not decode and were deleted. Logged as faults.
    public let corrupt: Int

    /// Files left in place for another pass: unreadable right now, or beyond the
    /// per-pass cap.
    public let deferred: Int

    /// Events that were read but whose file could not be deleted. These **will**
    /// be delivered again; the app deduplicates by ``InboxEvent/id``.
    public let redelivered: Int

    /// Whether another ``InboxStore/drain()`` would find more work.
    public var hasMore: Bool { deferred > 0 }

    public init(events: [InboxEvent], consumed: Int, corrupt: Int, deferred: Int, redelivered: Int) {
        self.events = events
        self.consumed = consumed
        self.corrupt = corrupt
        self.deferred = deferred
        self.redelivered = redelivered
    }

    public static let empty = InboxDrain(events: [], consumed: 0, corrupt: 0, deferred: 0, redelivered: 0)
}

// MARK: - InboxStore

/// The append-only event directory in the App Group container.
///
/// Written by extensions, drained by the app. See the file header for the
/// concurrency argument.
public struct InboxStore: Sendable {

    /// The only stored property. All the mutable state is the filesystem, which
    /// provides its own cross-process synchronization — which is why this is a
    /// value type with nothing to synchronize and no lifetime to manage.
    private let directory: URL

    /// How many files one ``drain()`` will read.
    ///
    /// A bound, not a target. If the app has not been foregrounded for a long
    /// time — exactly the situation in which a commitment device is doing its
    /// job — the shield-action extension may have appended hundreds of bypass
    /// records, and the reconcile that finally consumes them runs during a
    /// scene activation, where a multi-megabyte spike is a launch stutter at
    /// best. The drain reports ``InboxDrain/hasMore`` and the caller decides
    /// whether to go again, so the work is bounded per pass rather than per
    /// backlog.
    ///
    /// The bound matters more than it looks: `GateShieldAction` runs in a
    /// system callback and has no idea when the app will next be opened, so
    /// nothing upstream of here limits how large the backlog gets.
    public static let maxEventsPerDrain = 256

    // MARK: Init

    /// Opens `inbox/` in the App Group container.
    ///
    /// Does not create the directory — creation happens on first ``append(_:)``,
    /// so that constructing the store in a read-only path costs no syscalls.
    ///
    /// - Throws: ``StateStoreError/container(_:)`` when the App Group is not
    ///   usable in this process.
    public init() throws {
        let directory: URL
        do {
            directory = try AppGroupContainer.inboxURL
        } catch let error as AppGroupContainer.ContainerError {
            throw StateStoreError.container(error)
        }
        self.init(directory: directory)
    }

    /// Memberwise initializer. Tests point this at a temporary directory.
    public init(directory: URL) {
        self.directory = directory
    }

    /// Where the events live. For the debug screen (docs/04-product-spec.md V1-11).
    public var directoryURL: URL { directory }

    // MARK: Append — the extension side

    /// Writes one event.
    ///
    /// Two syscall groups and no enumeration, no stat, no decode, no
    /// coordination: this runs inside `ShieldActionDelegate`, which is
    /// network-blocked and latency-bounded, and inside the monitor, which is
    /// under 6 MB (docs/03-hard-constraints.md #31, #33).
    ///
    /// Safe against concurrent appends from any number of processes: the
    /// filename contains a UUID, so two writers cannot collide, and the write is
    /// atomic, so a concurrent drain sees the file as absent or complete.
    public func append(_ event: InboxEvent) throws {
        try AppGroupContainer.ensureDirectory(at: directory)
        let file = PlistFile<InboxEvent>(
            url: directory.appendingPathComponent(event.fileName, isDirectory: false),
            coordinated: false
        )
        try file.write(event)
    }

    /// Appends without throwing, logging instead.
    ///
    /// For call sites inside a system callback that must respond no matter what:
    /// `ShieldActionDelegate` has to invoke its completion handler or the shield
    /// hangs, and a monitor breadcrumb is diagnostics, not enforcement. The
    /// return value says whether it landed.
    @discardableResult
    public func appendBestEffort(_ event: InboxEvent) -> Bool {
        do {
            try append(event)
            return true
        } catch {
            inboxLog.error("""
                could not append \(event.kind.rawValue, privacy: .public) event: \
                \(String(describing: error), privacy: .public)
                """)
            return false
        }
    }

    // MARK: Drain — the app side

    /// Reads and deletes every pending event, oldest first.
    ///
    /// **App only.** docs/05-architecture.md: *"the app compacts `inbox/` into
    /// `state.plist` on every foreground reconcile and deletes the consumed
    /// files."* An extension that drained would destroy records the app has not
    /// seen, and would do it under a memory ceiling.
    ///
    /// Delivery is at-least-once; deduplicate by ``InboxEvent/id``.
    public func drain() throws -> [InboxEvent] {
        try drainDetailed().events
    }

    /// ``drain()``, with the counts.
    public func drainDetailed(limit: Int = InboxStore.maxEventsPerDrain) throws -> InboxDrain {
        let log = inboxLog
        let files = try pendingFiles()
        guard !files.isEmpty else { return .empty }

        var events: [InboxEvent] = []
        var consumed = 0
        var corrupt = 0
        var deferred = 0
        var redelivered = 0

        events.reserveCapacity(min(files.count, limit))

        for url in files {
            guard events.count + corrupt < limit else {
                // Everything from here on waits for the next pass.
                deferred += 1
                continue
            }

            let file = PlistFile<InboxEvent>(url: url, coordinated: false)
            let event: InboxEvent
            do {
                event = try file.read()
            } catch StateStoreError.stateMissing {
                // Raced with something that removed it. Nothing to do.
                continue
            } catch StateStoreError.protectedWhileLocked(let path) {
                // Never delete what we could not read. Leave it for a pass that
                // happens after the device is unlocked. Should be unreachable:
                // everything is written with `completeUntilFirstUserAuthentication`
                // (`AppGroupContainer.fileProtection`).
                log.fault("inbox file unreadable while locked: \(path, privacy: .public)")
                deferred += 1
                continue
            } catch StateStoreError.decodeFailed(let detail) {
                // Unrecoverable, and keeping it would make every future drain pay
                // for it forever. Delete and account for it.
                log.fault("""
                    discarding undecodable inbox file \(url.lastPathComponent, privacy: .public): \
                    \(detail, privacy: .public)
                    """)
                corrupt += 1
                try? file.delete()
                continue
            } catch {
                log.error("""
                    could not read inbox file \(url.lastPathComponent, privacy: .public): \
                    \(String(describing: error), privacy: .public)
                    """)
                deferred += 1
                continue
            }

            events.append(event)

            do {
                try file.delete()
                consumed += 1
            } catch {
                // Read succeeded, delete failed: this event comes back next time.
                redelivered += 1
                log.error("""
                    consumed but could not delete \(url.lastPathComponent, privacy: .public) — \
                    the event will be delivered again; deduplicate by id
                    """)
            }
        }

        // `createdAt` is the only ordering key; see its documentation. UUID
        // string is the tiebreak so the order is total and tests are stable.
        events.sort {
            $0.createdAt == $1.createdAt
                ? $0.id.uuidString < $1.id.uuidString
                : $0.createdAt < $1.createdAt
        }

        if consumed + corrupt + redelivered > 0 {
            log.notice("""
                drained inbox: \(consumed, privacy: .public) consumed, \
                \(corrupt, privacy: .public) corrupt, \
                \(deferred, privacy: .public) deferred, \
                \(redelivered, privacy: .public) will redeliver
                """)
        }

        return InboxDrain(
            events: events,
            consumed: consumed,
            corrupt: corrupt,
            deferred: deferred,
            redelivered: redelivered
        )
    }

    /// Reads without deleting.
    ///
    /// Two callers, both of which must see records the app has not drained yet
    /// and neither of which may delete one:
    ///
    /// * `GateShieldAction`, to count in-flight grants against the day's budget
    ///   (``GrantEngine/inFlightCount(in:now:maxAge:)``) — `state.plist`'s ledger
    ///   is stale between a shield tap and the next foreground.
    /// * `Reconciler`, under ``ReconcileOptions/foldsPendingGrants``, so the
    ///   monitor can honour a submenu grant on the pass it wakes for.
    ///
    /// And the debug screen (docs/04-product-spec.md V1-11).
    ///
    /// - Parameter kind: when non-`nil`, only events of that kind are read at
    ///   all. **Pass it whenever you are looking for something specific.**
    ///   `limit` truncates in `contentsOfDirectory` order, which is undefined,
    ///   and the monitor fills this directory with breadcrumbs — so an unfiltered
    ///   `peek` can silently omit the one record the caller came for once the
    ///   backlog exceeds `limit`. ``InboxEvent/fileName`` carries the kind, so
    ///   filtering happens on the filename, before any file is opened.
    public func peek(
        kind: InboxEvent.Kind? = nil,
        limit: Int = InboxStore.maxEventsPerDrain
    ) throws -> [InboxEvent] {
        var files = try pendingFiles()
        if let kind {
            let prefix = "\(kind.rawValue)-"
            files = files.filter { $0.lastPathComponent.hasPrefix(prefix) }
        }
        return files
            .prefix(limit)
            .compactMap { try? PlistFile<InboxEvent>(url: $0, coordinated: false).read() }
            // The filename is a hint, not the authority: the decoded `kind` is.
            // A record written by a newer build degrades to `.unknown` on decode
            // and must not be handed back as something it is not.
            .filter { kind == nil || $0.kind == kind }
            .sorted {
                $0.createdAt == $1.createdAt
                    ? $0.id.uuidString < $1.id.uuidString
                    : $0.createdAt < $1.createdAt
            }
    }

    /// How many files are waiting. Absent directory counts as zero.
    public var pendingCount: Int {
        ((try? pendingFiles()) ?? []).count
    }

    /// Deletes every pending event without reading any of them. Teardown only
    /// (docs/03-hard-constraints.md #37).
    public func erase() throws {
        for url in (try? pendingFiles()) ?? [] {
            try? FileManager.default.removeItem(at: url)
        }
        inboxLog.notice("erased inbox")
    }

    // MARK: Enumeration

    /// Every `*.plist` directly inside `inbox/`.
    ///
    /// `includingPropertiesForKeys: nil` on purpose: prefetching resource values
    /// would stat every file, which is both a syscall per entry and a
    /// required-reason API (`NSPrivacyAccessedAPICategoryFileTimestamp` /
    /// `C617.1`, docs/06-build-plan.md step 7.1). Ordering comes from inside the
    /// files instead.
    ///
    /// A missing directory is not an error — nothing has ever been appended.
    private func pendingFiles() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        do {
            return try FileManager.default
                .contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
                )
                .filter { $0.pathExtension == InboxEvent.fileExtension }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return []
        } catch {
            throw StateStoreError.readFailed(String(describing: error))
        }
    }
}
