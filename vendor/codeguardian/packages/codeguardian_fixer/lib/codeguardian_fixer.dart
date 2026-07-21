/// CodeGuardian AI - Automated code-fix generation built on top of the rule
/// engine.
///
/// Core infrastructure: [Fix] (a proposed change as a unified diff),
/// [applyFixes] (dry-run-by-default, git-checkpointed application), and
/// [checkIdempotency] (a harness proving a fix-generation strategy resolves
/// an issue completely rather than leaving something to re-fix).
///
/// Also exports ten concrete, deterministic fix generators covering
/// `codeguardian_rules`/`codeguardian_native`'s quality, security,
/// performance, and native rules that have a clear, safe mechanical fix:
/// [buildMissingConstConstructorFix], [buildUnusedImportFix],
/// [buildMissingMountedCheckFix], [buildInsecureHttpUrlFix],
/// [buildMissingRepaintBoundaryFix], [buildUnusedPluginDependencyFix],
/// [buildMissingListViewBuilderFix], [buildAndroidManifestSecurityFix],
/// [buildIosPlistSecurityFix], and [buildSyncIoOnUiIsolateFix].
library codeguardian_fixer;

export 'src/apply_fixes.dart';
export 'src/fix.dart';
export 'src/fix_dispatch.dart';
export 'src/fix_utils.dart';
export 'src/fixes/android_manifest_security_fix.dart';
export 'src/fixes/insecure_http_url_fix.dart';
export 'src/fixes/ios_plist_security_fix.dart';
export 'src/fixes/missing_const_constructor_fix.dart';
export 'src/fixes/missing_listview_builder_fix.dart';
export 'src/fixes/missing_mounted_check_fix.dart';
export 'src/fixes/missing_repaint_boundary_fix.dart';
export 'src/fixes/sync_io_on_ui_isolate_fix.dart';
export 'src/fixes/unused_import_fix.dart';
export 'src/fixes/unused_plugin_dependency_fix.dart';
export 'src/git_checkpoint.dart';
export 'src/refactor_fix.dart';
export 'src/idempotency.dart';
export 'src/unified_diff.dart';
