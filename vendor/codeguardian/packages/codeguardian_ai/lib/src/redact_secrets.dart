import 'package:codeguardian_rules/codeguardian_rules.dart' as rules;

/// The literal text substituted for a redacted secret value.
const redactionPlaceholder = '[REDACTED]';

/// Matches a Dart variable/field/const declaration assigning a (possibly
/// raw-prefixed) single- or double-quoted string literal: `name = 'value'`,
/// `name = "value"`, or `name = r'value'`.
///
/// Deliberately mirrors exactly the shape `HardcodedSecretRule` looks for
/// (a bare identifier immediately followed by `=` and a
/// `SimpleStringLiteral`) rather than something broader like map-literal
/// keys (`'apiKey': '...'`) -- those aren't in the rule's detection scope
/// either, so redacting them here would create a mismatch between what this
/// function scrubs and what the rule actually flags.
final RegExp _assignmentPattern = RegExp(
  r'''([A-Za-z_$][A-Za-z0-9_$]*)(\s*=\s*)(r?)(['"])((?:\\.|(?!\4).)*?)\4''',
);

/// Scrubs source code of anything matching `HardcodedSecretRule`'s
/// detection pattern (a secret-shaped name assigned a secret-shaped string
/// literal) before the code is sent to any AI provider.
///
/// This is a regex-based approximation of the rule's AST-based check --
/// intentionally so, since callers pass in an arbitrary snippet of
/// surrounding code (not necessarily a full, parseable compilation unit)
/// that a resolved-AST rule can't run against. It reuses the exact same
/// [rules.secretNamePattern] and [rules.looksLikeSecretValue] the rule
/// itself uses, so "looks like a secret" means the same thing in both
/// places.
///
/// Only the string literal's contents are replaced with
/// [redactionPlaceholder] -- the variable name, quote style, and everything
/// else around it is left intact, so the redacted code is still valid Dart
/// and still useful context for a fix suggestion.
String redactSecrets(String code) {
  return code.replaceAllMapped(_assignmentPattern, (match) {
    final name = match.group(1)!;
    final value = match.group(5)!;
    if (!rules.secretNamePattern.hasMatch(name)) return match.group(0)!;
    if (!rules.looksLikeSecretValue(value)) return match.group(0)!;

    final prefix = match.group(2)!;
    final rawMarker = match.group(3)!;
    final quote = match.group(4)!;
    return '$name$prefix$rawMarker$quote$redactionPlaceholder$quote';
  });
}
