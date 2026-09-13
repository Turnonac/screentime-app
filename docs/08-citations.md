## Key sources

### Apple — framework documentation
- https://developer.apple.com/documentation/familycontrols
- https://developer.apple.com/documentation/familycontrols/authorizationcenter
- https://developer.apple.com/documentation/familycontrols/authorizationcenter/requestauthorization(for:)
- https://developer.apple.com/documentation/familycontrols/familycontrolsmember
- https://developer.apple.com/documentation/familycontrols/familyactivityselection
- https://developer.apple.com/documentation/familycontrols/familyactivitypicker
- https://developer.apple.com/documentation/familycontrols/familycontrolserror
- https://developer.apple.com/documentation/familycontrols/authorizationstatus/approvedwithdataaccess
- https://developer.apple.com/documentation/familycontrols/familyactivitydata
- https://developer.apple.com/documentation/managedsettings/managedsettingsstore
- https://developer.apple.com/documentation/managedsettings/shieldsettings
- https://developer.apple.com/documentation/managedsettings/shieldsettings/activitycategorypolicy
- https://developer.apple.com/documentation/managedsettings/applicationsettings
- https://developer.apple.com/documentation/managedsettings/webcontentsettings
- https://developer.apple.com/documentation/managedsettings/token
- https://developer.apple.com/documentation/managedsettings/shieldactiondelegate
- https://developer.apple.com/documentation/managedsettings/shieldaction
- https://developer.apple.com/documentation/managedsettings/shieldactionresponse/openparentalcontrolsapp
- https://developer.apple.com/documentation/managedsettings/managedsettingsstore/tokenexpirymessage
- https://developer.apple.com/documentation/managedsettings/managedsettingsstore/isactive
- https://developer.apple.com/documentation/managedsettingsui/shieldconfiguration
- https://developer.apple.com/documentation/managedsettingsui/shieldconfiguration/secondarybuttonsubmenuitems
- https://developer.apple.com/documentation/managedsettingsui/shieldconfigurationdatasource
- https://developer.apple.com/documentation/deviceactivity
- https://developer.apple.com/documentation/deviceactivity/deviceactivitycenter
- https://developer.apple.com/documentation/deviceactivity/deviceactivitycenter/startmonitoring(_:during:events:)
- https://developer.apple.com/documentation/deviceactivity/deviceactivitycenter/monitoringerror
- https://developer.apple.com/documentation/deviceactivity/deviceactivityschedule
- https://developer.apple.com/documentation/deviceactivity/deviceactivityevent
- https://developer.apple.com/documentation/deviceactivity/deviceactivityevent/includespastactivity
- https://developer.apple.com/documentation/deviceactivity/deviceactivitymonitor
- https://developer.apple.com/documentation/deviceactivity/deviceactivityreport
- https://developer.apple.com/documentation/deviceactivity/deviceactivityreportextension
- https://developer.apple.com/documentation/deviceactivity/deviceactivitydata
- https://developer.apple.com/documentation/deviceactivity/deviceactivitydata/applicationactivity
- https://developer.apple.com/documentation/deviceactivity/deviceactivityfilter
- https://developer.apple.com/documentation/deviceactivity/deviceactivitydata/activitydata(filteredby:using:)

### Apple — entitlements, capabilities, distribution
- https://developer.apple.com/documentation/xcode/configuring-family-controls
- https://developer.apple.com/documentation/familycontrols/requesting-the-family-controls-entitlement
- https://developer.apple.com/contact/request/family-controls-distribution
- https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.family-controls
- https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.family-controls.app-and-website-usage
- https://developer.apple.com/help/account/reference/supported-capabilities-ios
- https://developer.apple.com/help/account/capabilities/capability-requests/
- https://developer.apple.com/help/account/reference/provisioning-with-managed-capabilities

### Apple — App Store policy, privacy, review
- https://developer.apple.com/app-store/review/guidelines/ (2.1, 2.5.1, 4.10, 5.1.1, 5.4, 5.5)
- https://developer.apple.com/distribute/app-review/
- https://developer.apple.com/app-store/app-privacy-details/
- https://developer.apple.com/app-store/user-privacy-and-data-use/
- https://developer.apple.com/documentation/bundleresources/privacy-manifest-files
- https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api
- https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitypereasons
- https://developer.apple.com/documentation/technotes/tn3181-debugging-invalid-privacy-manifest
- https://developer.apple.com/support/third-party-SDK-requirements/
- https://developer.apple.com/news/?id=0d2gpmml — "Introducing Time Allowances" (June 8, 2026)
- https://developer.apple.com/news/?id=tlur8uvi — age-rating questionnaire social-media questions (July 9, 2026)
- https://developer.apple.com/documentation/ios-ipados-release-notes/ios-ipados-27-release-notes

### Apple — WWDC sessions
- https://developer.apple.com/videos/play/wwdc2021/10123/ — Meet the Screen Time API
- https://developer.apple.com/videos/play/wwdc2022/110336/ — What's new in Screen Time API
- https://developer.apple.com/videos/play/wwdc2025/299/ — Deliver age-appropriate experiences
- https://developer.apple.com/videos/play/wwdc2025/293/ — Enhance child safety with PermissionKit
- https://developer.apple.com/videos/wwdc2026/ — (verified: zero Screen Time / parental-controls sessions)

### Apple Developer Forums — the load-bearing evidence
- https://developer.apple.com/forums/thread/838231 — **DTS: no API to detect app-open or self-foreground**
- https://developer.apple.com/forums/thread/766644 — Frameworks Engineer: no supported way to open your app pre-26.5; private API "should be rejected in App Review"
- https://developer.apple.com/forums/thread/766923 — **DTS: TestFlight requires the distribution entitlement ("No")**
- https://developer.apple.com/forums/thread/803362 — DTS: free Personal Teams cannot use Family Controls
- https://developer.apple.com/forums/thread/717569 — Frameworks Engineer: "The Screen Time APIs are currently for iOS only"
- https://developer.apple.com/forums/thread/814446 — Mac Catalyst runtime failure (FamilyControlsAgent, error 159)
- https://developer.apple.com/forums/thread/818174 + /817516 + /818297 — **DTS: report-extension sandbox is intentional ("Yes")**; channel-by-channel export failures
- https://developer.apple.com/forums/thread/735454 + /745035 + /773228 + /823431 — 6 MB monitor limit; killed for memory or idleness
- https://developer.apple.com/forums/thread/814945 — **DTS: shield-action identifier has no "UI"**; ASC rejection text
- https://developer.apple.com/forums/thread/681963 — Systems Engineer: monitor extension point identifier
- https://developer.apple.com/forums/thread/683110 — shield-configuration identifier
- https://developer.apple.com/forums/thread/809227 + /812380 — report-extension ExtensionKit packaging catch-22 (Error 3002)
- https://developer.apple.com/forums/thread/710915 — 20-activity cap
- https://developer.apple.com/forums/thread/733361 — 50-token / 50-store caps, silent failure
- https://developer.apple.com/forums/thread/726331 + /729841 — DateComponents granularity (the contradiction)
- https://developer.apple.com/forums/thread/819997 — one sec's umbrella bug report (thresholds, token reissue, shield recycling)
- https://developer.apple.com/forums/thread/809410 + /811305 + /811743 + /812472 + /838510 — iOS 26.x threshold regressions
- https://developer.apple.com/forums/thread/758325 + /788764 + /814571 + /844148 — token instability and the broken 26.5 refresh
- https://developer.apple.com/forums/thread/819224 + /820956 — monitor never launched on iOS 26.3.1
- https://developer.apple.com/forums/thread/716340 + /717269 — stale/recycled ShieldConfiguration (FB14237883)
- https://developer.apple.com/forums/thread/729637 + /729717 — denyAppRemoval not honored under `.individual`
- https://developer.apple.com/forums/thread/820796 — `$authorizationStatus` does not emit on revoke while backgrounded
- https://developer.apple.com/forums/thread/821959 — Screen Time passcode vs Face ID on revoke *(unverified fix in iOS 27)*
- https://developer.apple.com/forums/thread/776058 + /822078 — **Guideline 2.5.1 rejections, verbatim**
- https://developer.apple.com/forums/thread/819573 — bundle-ID case mismatch / "Prefix Mismatch"
- https://developer.apple.com/forums/thread/818553 + /820971 + /821964 + /809190 — entitlement approval delays
- https://developer.apple.com/forums/thread/820283 — iOS 26.4 all-or-nothing consent prompt
- https://developer.apple.com/forums/thread/844661 — approvedWithDataAccess evicts Apple's own Screen Time
- https://developer.apple.com/forums/thread/727017 — Frameworks Engineer: notifications OK from the monitor; NotificationCenter is in-process only
- https://developer.apple.com/forums/thread/802242 — shields persisting after app deletion

### Open-source reference implementations
- https://github.com/awaseem/foqos — **best reference**; shipped App Store app, all four targets, soft-unblock grant system, named stores, unit tests
- https://github.com/kingstinct/react-native-device-activity — most exhaustive written catalogue of limits and gotchas
- https://github.com/christianp-622/ScreenBreak — report extension with correct `EXAppExtensionAttributes` plist
- https://github.com/Provenance-Emu/Provenance — `Extensions/ActivityReportExtension/Info.plist`
- https://github.com/slavayosome/papatime-oss — XcodeGen `project.yml` with Screen Time extensions
- https://github.com/nuynait/screen-time-enhancement — XcodeGen targetTemplate with `APPLICATION_EXTENSION_API_ONLY`
- https://github.com/EvanBacon/expo-apple-targets — authoritative extension-point-identifier table
- https://yonaskolb.github.io/XcodeGen/Docs/ProjectSpec.html

### Andoff (Android) and competitors
- https://play.google.com/store/apps/details?id=app.plucky.dpc
- https://docs.andoff.one — manual (how-to-block-apps, how-to-install-andoff-via-adb, how-to-block-app-installations, updates-in-solid-mode, how-to-uninstall, how-to-block-web-view, just-installed)
- https://developer.android.com/reference/android/app/admin/DevicePolicyManager — `setPackagesSuspended`, `setUninstallBlocked`, `addUserRestriction`
- https://support.google.com/googleplay/android-developer/answer/10964491 — Play AccessibilityService policy (stricter review from 28 Jan 2026)
- https://www.pnas.org/doi/10.1073/pnas.2213114120 — one sec intervention study (n=280, 57% reduction in app openings)

### Environment caveat carried from the dossier
All App Store pricing, ratings and download figures for ScreenZen, one sec, Opal, Jomo, Brick, Clearspace, Roots, Freedom, Unpluq and LivingRoom come from third-party search syntheses — `apps.apple.com`, `itunes.apple.com`, every vendor domain, `apple.com`, `support.apple.com` and the app-intelligence providers were all blocked by the research environment's egress proxy. **Re-verify any competitive or pricing claim against live listings before it informs a business decision.**
