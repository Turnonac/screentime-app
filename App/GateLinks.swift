//
//  GateLinks.swift
//  Gate
//
//  The one URL the app ships.
//
//  App Review guideline 5.1.1(i) requires a privacy policy link that is
//  reachable **inside the app, without an account**. Gate has no accounts, so
//  "without an account" is free; "inside the app" is not, and it is the thing
//  that gets missed. `Docs/REVIEW-NOTES.md` §5 names the two places it has to
//  appear and points at this file for the value; `docs/03-hard-constraints.md`
//  #43 and `docs/06-build-plan.md` step 7.4 are the same requirement stated in
//  the dossier.
//
//  **Why App/ and not Kernel/.** `Kernel/Identifiers.swift` is the home of
//  cross-process constants and says in as many words that nothing which is not a
//  cross-process identifier belongs there — it is linked into the monitor
//  extension, which runs under a 6 MB jetsam ceiling and has no business
//  carrying a marketing URL. This is app-layer presentation, so it lives in the
//  app target.
//
//  Gate has no networking of any kind. This URL is handed to `SwiftUI.Link`,
//  which opens Safari; nothing in this process ever fetches it.
//

import Foundation

enum GateLinks {

    /// The public privacy policy.
    ///
    /// **Set this to the real host before submitting.** It must be live at the
    /// moment of review, and it must be the same URL entered in the App Store
    /// Connect metadata field — a mismatch between the two is itself a rejection
    /// (Review Notes §5).
    ///
    /// Force-unwrapped deliberately: the literal is a compile-time constant, so
    /// a `nil` here is a typo that should be caught on the first launch of the
    /// first build rather than degraded into a link that silently does nothing.
    static let privacyPolicy = URL(string: "https://<REPLACE-WITH-REAL-HOST>/privacy")!
}
