import 'package:codeguardian_core/codeguardian_core.dart';

import 'ai_suggestion.dart';

/// A backend capable of suggesting a fix for a [Finding].
///
/// Implementations must not send [surroundingCode] to any external service
/// without first passing it through `redactSecrets()` -- see
/// [AiProvider.suggestFix]'s implementations ([NoOpAiProvider],
/// `AnthropicAiProvider`) for what "external" means for each.
abstract class AiProvider {
  /// Asks the provider to suggest a fix for [finding], given [surroundingCode]
  /// (the source text around the finding's location, for context).
  ///
  /// Never throws for ordinary failure modes (network error, malformed
  /// provider response, missing credentials) -- those resolve to
  /// [AiSuggestion.empty] so callers can treat every provider uniformly.
  Future<AiSuggestion> suggestFix(Finding finding, String surroundingCode);

  /// Asks the provider to rewrite an entire file to resolve [findings], given
  /// the file's full [fileContent].
  ///
  /// Unlike [suggestFix], whose result is only ever *shown* to a human, this
  /// is meant to be *applied*: the returned [AiSuggestion.suggestedCode], when
  /// present, is the complete rewritten file. Whole-file (rather than a
  /// snippet) is deliberate -- structural refactors such as extracting a
  /// subtree into a new widget, or hoisting a duplicated block into a shared
  /// helper, *add* declarations that a snippet replacement can't express, and
  /// one file in/one file out keeps the resulting diff conflict-free.
  ///
  /// [findings] are all in the same file and share [fileContent]'s path. Like
  /// [suggestFix], this never throws for ordinary failure modes -- they
  /// resolve to [AiSuggestion.empty].
  Future<AiSuggestion> suggestRefactor(
    List<Finding> findings,
    String fileContent,
  );
}
