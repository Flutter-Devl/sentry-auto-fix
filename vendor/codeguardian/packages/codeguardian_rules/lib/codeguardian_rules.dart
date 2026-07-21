/// CodeGuardian AI - Static analysis rule definitions and the rule engine.
///
/// Exposes concrete `CodeGuardianRule`/`ProjectRule` implementations built
/// on top of `codeguardian_core`, plus [qualityRulePack], [securityRulePack],
/// [performanceRulePack], and [performanceProjectRulePack], which bundle
/// rules for registration on a `RuleRegistry`.
library codeguardian_rules;

export 'src/rule_pack.dart';
export 'src/rules/business_logic_in_widget_rule.dart';
export 'src/rules/deep_widget_nesting_rule.dart';
export 'src/rules/duplicate_code_block_rule.dart';
export 'src/rules/expensive_build_method_rule.dart';
export 'src/rules/hardcoded_secret_rule.dart';
export 'src/rules/insecure_http_url_rule.dart';
export 'src/rules/long_method_rule.dart';
export 'src/rules/missing_const_constructor_rule.dart';
export 'src/rules/missing_listview_builder_rule.dart';
export 'src/rules/missing_mounted_check_rule.dart';
export 'src/rules/missing_repaint_boundary_rule.dart';
export 'src/rules/sync_io_on_ui_isolate_rule.dart';
export 'src/rules/unused_import_rule.dart';
export 'src/rules/unused_plugin_dependency_rule.dart';
