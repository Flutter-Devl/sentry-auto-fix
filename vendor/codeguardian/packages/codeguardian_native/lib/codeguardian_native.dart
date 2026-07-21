/// CodeGuardian AI - Native/platform-configuration analyzers.
///
/// Exposes [AndroidManifestAnalyzer] and [IOSPlistAnalyzer], both
/// `ProjectRule`s that inspect `AndroidManifest.xml` and `Info.plist`
/// respectively for common native app-hardening gaps, and
/// [PlatformChannelCrossReferencer], which cross-references Dart platform
/// channel usage against native (`.kt`/`.swift`) handler registration.
library codeguardian_native;

export 'src/android_manifest_analyzer.dart';
export 'src/ios_plist_analyzer.dart';
export 'src/platform_channel_cross_referencer.dart';
