import 'package:meta/meta.dart';

/// An AI provider's response to a [Finding]-plus-surrounding-code fix
/// request.
///
/// [confidence] is always in `[0.0, 1.0]`; [AiSuggestion.empty] (confidence
/// `0.0`, no [suggestedCode]) is what offline/no-op providers return, and
/// what real providers return when they can't produce a usable fix.
@immutable
class AiSuggestion {
  /// Creates a suggestion. [confidence] must be in `[0.0, 1.0]`.
  const AiSuggestion({
    required this.explanation,
    required this.confidence,
    this.suggestedCode,
  }) : assert(confidence >= 0.0 && confidence <= 1.0);

  /// Human-readable explanation of the suggested fix, or of why no fix
  /// could be produced.
  final String explanation;

  /// How confident the provider is in [suggestedCode], from `0.0` (no
  /// confidence / no suggestion) to `1.0` (fully confident).
  final double confidence;

  /// The suggested replacement code, if the provider produced one.
  final String? suggestedCode;

  /// The result offline/no-op providers return, and the fallback for a real
  /// provider that couldn't produce a usable suggestion.
  static const empty = AiSuggestion(
    explanation: 'No AI suggestion available.',
    confidence: 0.0,
  );

  @override
  String toString() =>
      'AiSuggestion(confidence: $confidence, explanation: "$explanation", '
      'suggestedCode: ${suggestedCode == null ? 'null' : '"$suggestedCode"'})';
}
