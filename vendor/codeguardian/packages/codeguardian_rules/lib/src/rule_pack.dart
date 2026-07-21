import 'package:codeguardian_core/codeguardian_core.dart';

import 'rules/business_logic_in_widget_rule.dart';
import 'rules/deep_widget_nesting_rule.dart';
import 'rules/duplicate_code_block_rule.dart';
import 'rules/expensive_build_method_rule.dart';
import 'rules/hardcoded_secret_rule.dart';
import 'rules/insecure_http_url_rule.dart';
import 'rules/long_method_rule.dart';
import 'rules/missing_const_constructor_rule.dart';
import 'rules/missing_listview_builder_rule.dart';
import 'rules/missing_mounted_check_rule.dart';
import 'rules/missing_repaint_boundary_rule.dart';
import 'rules/sync_io_on_ui_isolate_rule.dart';
import 'rules/unused_import_rule.dart';
import 'rules/unused_plugin_dependency_rule.dart';

/// The bundle of general-purpose code-quality rules.
///
/// Register these on a `RuleRegistry` to check for missing `const`
/// constructors, unused imports, overly complex methods, deep widget
/// nesting, duplicated code blocks, business logic embedded in widgets, and
/// unguarded BuildContext/setState use after an await.
List<CodeGuardianRule> qualityRulePack() => const [
      MissingConstConstructorRule(),
      UnusedImportRule(),
      LongMethodRule(),
      DeepWidgetNestingRule(),
      DuplicateCodeBlockRule(),
      BusinessLogicInWidgetRule(),
      MissingMountedCheckRule(),
    ];

/// The bundle of rules that flag opportunities the `codeguardian refactor`
/// command can address with an AI-assisted rewrite.
///
/// Unlike the other packs, these aren't about a single mechanical edit --
/// they mark code that benefits from a structural change: business logic that
/// should move out of a widget, duplicated blocks that should be hoisted into
/// a shared helper, and deep/complex widget trees and methods that should be
/// decomposed. `codeguardian refactor` feeds their findings to the configured
/// AI provider to generate the actual rewrite.
List<CodeGuardianRule> refactorRulePack() => const [
      BusinessLogicInWidgetRule(),
      DuplicateCodeBlockRule(),
      DeepWidgetNestingRule(),
      LongMethodRule(),
    ];

/// The bundle of security rules.
///
/// Register these on a `RuleRegistry` to check for hardcoded secrets and
/// plaintext (`http://`) network endpoints.
List<CodeGuardianRule> securityRulePack() => const [
      HardcodedSecretRule(),
      InsecureHttpUrlRule(),
    ];

/// The bundle of per-file performance rules.
///
/// Register these on a `RuleRegistry` to check for eager `ListView`s over
/// generated lists, expensive work inside `build()`, missing
/// `RepaintBoundary`s on animated subtrees, and synchronous file IO on the
/// UI isolate. See also [performanceProjectRulePack] for the
/// project-level performance rule.
List<CodeGuardianRule> performanceRulePack() => const [
      MissingListViewBuilderRule(),
      ExpensiveBuildMethodRule(),
      MissingRepaintBoundaryRule(),
      SyncIoOnUiIsolateRule(),
    ];

/// The bundle of project-level performance rules.
///
/// Register these on a `RuleRegistry` (via `registerAllProjectRules`) to
/// check for dependencies declared in `pubspec.yaml` that are never
/// imported anywhere in the project.
List<ProjectRule> performanceProjectRulePack() => const [
      UnusedPluginDependencyRule(),
    ];
