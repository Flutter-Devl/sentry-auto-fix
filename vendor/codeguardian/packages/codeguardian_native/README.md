# codeguardian_native

Analyzers for native/platform-configuration files that a Dart-only rule
engine can't see: `AndroidManifest.xml`, `Info.plist`, and the boundary
between Dart platform channels and their native (Kotlin/Swift) handlers.

All three are `ProjectRule`s (from `codeguardian_core`): they run once per
`analyze()` call against the project root, rather than once per resolved
Dart file, since they need to read project-relative files that aren't Dart
source.

## Analyzers

- **`AndroidManifestAnalyzer`** — parses
  `android/app/src/main/AndroidManifest.xml` and flags exported components
  without a permission guard, `usesCleartextTraffic`, `debuggable`, missing
  `allowBackup="false"`, and broad/sensitive permissions.
- **`IOSPlistAnalyzer`** — parses `ios/Runner/Info.plist` and flags
  `NSAppTransportSecurity` arbitrary-loads exceptions, empty or
  background-mode-implied usage-description strings, and generic/collidable
  custom URL schemes.
- **`PlatformChannelCrossReferencer`** — see below.

Every finding from these analyzers carries a MASVS control ID
(`Finding.masvsId`), and most also carry a CWE ID.

## PlatformChannelCrossReferencer: pattern-based, not a real cross-language analysis

This rule scans Dart files for `MethodChannel`/`EventChannel` usage and
tries to match each channel name against native (`.kt`/`.swift`) source
under `android/`/`ios/`. It also scans native handlers for a channel
argument flowing into a file path or query with no obvious validation in
between.

**There is no Kotlin/Swift parser available here.** The native side is
matched with regular expressions over raw source text, not an AST. Read
every finding as a prompt to go look at the code, not as a proven bug. In
particular:

- **Channel names must be plain string literals** on both sides. A name
  built from string interpolation, a shared constant, concatenation, or any
  other non-literal expression is invisible to this rule — on the Dart side
  it won't be recognized as a channel usage at all, and on the native side
  it won't be found even if a channel with that literal name is genuinely
  invoked from Dart.
- **"No native handler found" is a substring search**, not proof the
  channel is unhandled. It means the exact channel-name string wasn't found
  in any `.kt`/`.swift` file under `android/`/`ios/`. A handler registered
  under a different platform-folder layout, in a package outside
  `android/`/`ios/` (e.g. a separate native plugin package), or built from a
  non-literal name, will be a **false positive**.
- **"Argument used without validation" is a fixed-size line-window
  heuristic**, not data-flow/taint analysis. It looks for an
  argument-extraction line (`call.argument<...>` in Kotlin,
  `call.arguments` in Swift) followed within a short window by a
  file-path/query-construction line, with no validation keyword
  (`validate`, `sanitize`, `.replace(`, a `..` check, a `?` placeholder,
  ...) appearing in between. Validation performed via a helper function
  defined elsewhere, or guarding the argument use further away than the
  lookahead window, will be a **false negative**. Conversely, unrelated code
  that happens to match both patterns nearby could be a **false positive**.
- The Dart-side scan itself, while AST-based, only recognizes channel
  variables assigned in a `MethodChannel(...)`/`EventChannel(...)`
  initializer and `invokeMethod` calls made against a simple identifier
  referencing that variable **in the same file**; channels passed around,
  stored on `this`, or invoked through indirection are not tracked.

In short: treat every finding as "worth a human look," and treat the
absence of a finding as "not yet caught," not as "verified clean."
