import 'package:meta/meta.dart';

/// A single proposed change to one file, expressed as a unified diff.
///
/// A [Fix] is an immutable value object. It doesn't touch disk by itself --
/// [applyFixes] is what turns a list of these into actual file changes.
@immutable
class Fix {
  /// Creates a fix.
  ///
  /// [confidence] defaults to `1.0`, meaning fully deterministic: the fix
  /// was derived mechanically from the rule that produced it (e.g. "delete
  /// this unused import line"), not suggested by a model. Lower values are
  /// reserved for future AI-assisted fixes whose correctness isn't
  /// guaranteed by construction.
  const Fix({
    required this.ruleId,
    required this.file,
    required this.diff,
    this.confidence = 1.0,
  }) : assert(
          confidence >= 0.0 && confidence <= 1.0,
          'confidence must be between 0.0 and 1.0',
        );

  /// Identifier of the rule this fix addresses (e.g. `unused-import`),
  /// matching the `ruleId` of the [Finding] it was derived from.
  final String ruleId;

  /// Absolute path of the file this fix modifies.
  final String file;

  /// The change, as unified diff text (the format produced by `diff -u` /
  /// `git diff`, and consumed by `git apply` / `patch`).
  ///
  /// Paths in the `---`/`+++` headers are relative to the project root the
  /// fix will be applied against, using the standard `a/`/`b/` prefixes.
  final String diff;

  /// How confident the fix producer is that this fix is correct, from `0.0`
  /// to `1.0`. Deterministic, rule-derived fixes use the default `1.0`.
  final double confidence;

  /// A JSON-serializable representation of this fix.
  Map<String, dynamic> toJson() => {
        'ruleId': ruleId,
        'file': file,
        'diff': diff,
        'confidence': confidence,
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Fix &&
          runtimeType == other.runtimeType &&
          ruleId == other.ruleId &&
          file == other.file &&
          diff == other.diff &&
          confidence == other.confidence;

  @override
  int get hashCode => Object.hash(ruleId, file, diff, confidence);

  @override
  String toString() => 'Fix($ruleId, $file, confidence: $confidence)';
}
