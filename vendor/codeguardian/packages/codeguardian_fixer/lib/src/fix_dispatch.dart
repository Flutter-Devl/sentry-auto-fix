import 'package:codeguardian_core/codeguardian_core.dart';

import 'fix.dart';
import 'fixes/insecure_http_url_fix.dart';
import 'fixes/missing_const_constructor_fix.dart';
import 'fixes/missing_listview_builder_fix.dart';
import 'fixes/missing_mounted_check_fix.dart';
import 'fixes/missing_repaint_boundary_fix.dart';
import 'fixes/sync_io_on_ui_isolate_fix.dart';
import 'fixes/unused_import_fix.dart';
import 'fixes/unused_plugin_dependency_fix.dart';

/// Builds a deterministic [Fix] for a single [finding], with paths in the
/// diff relative to [projectPath].
///
/// Returns `null` (or throws `ArgumentError`) for a finding the builder
/// decides it can't safely fix; [buildDeterministicFixes] treats both as
/// "skip this one".
typedef FixBuilder = Fix? Function(Finding finding, String projectPath);

/// Maps a rule id to the deterministic fix generator for it.
///
/// These are the rules with a clear, safe, mechanical fix (confidence `1.0`).
/// Rules absent from this map (e.g. `hardcoded-secret`, `long-method`,
/// `deep-widget-nesting`) have no deterministic fix -- they need human
/// judgement or the AI-assisted `refactor` path.
const Map<String, FixBuilder> deterministicFixBuilders = {
  'missing-const-constructor': buildMissingConstConstructorFix,
  'unused-import': buildUnusedImportFix,
  'missing-mounted-check': buildMissingMountedCheckFix,
  'insecure-http-url': buildInsecureHttpUrlFix,
  'missing-repaint-boundary': buildMissingRepaintBoundaryFix,
  'unused-plugin-dependency': buildUnusedPluginDependencyFix,
  'missing-listview-builder': buildMissingListViewBuilderFix,
  'sync-io-on-ui-isolate': buildSyncIoOnUiIsolateFix,
};

/// Builds every deterministic [Fix] available for [findings], with diff paths
/// relative to [projectRoot].
///
/// Findings whose rule has no entry in [deterministicFixBuilders] are skipped,
/// as are ones a builder declines (by returning `null` or throwing
/// `ArgumentError`). Fixes with an identical diff are de-duplicated, so two
/// findings that resolve to the same edit don't produce a conflicting pair.
///
/// This does not touch disk -- pass the result to `applyFixes` to apply it.
/// Because a fix's diff is generated against the current file, callers applying
/// fixes should re-run this after each apply pass (line numbers shift); see the
/// `improve` command for that convergence loop.
List<Fix> buildDeterministicFixes(
  Iterable<Finding> findings,
  String projectRoot,
) {
  final fixes = <Fix>[];
  final seenDiffs = <String>{};
  for (final finding in findings) {
    final builder = deterministicFixBuilders[finding.ruleId];
    if (builder == null) continue;
    try {
      final fix = builder(finding, projectRoot);
      if (fix != null && seenDiffs.add(fix.diff)) fixes.add(fix);
    } on ArgumentError {
      // The builder rejected a finding it can't safely fix; skip it.
    }
  }
  return fixes;
}
