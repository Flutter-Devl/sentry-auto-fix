import 'package:codeguardian_core/codeguardian_core.dart';

import 'ai_provider.dart';
import 'ai_suggestion.dart';

/// An [AiProvider] for offline mode: never makes a network call, and always
/// resolves to [AiSuggestion.empty].
///
/// Use this when no AI provider is configured (e.g. `codeguardian ai
/// configure --provider=none`, or no API key is available) so callers don't
/// need to special-case "AI is disabled" -- they just get an empty
/// suggestion back, the same shape a real provider returns when it can't
/// help.
class NoOpAiProvider implements AiProvider {
  /// Creates a no-op provider.
  const NoOpAiProvider();

  @override
  Future<AiSuggestion> suggestFix(Finding finding, String surroundingCode) async {
    return AiSuggestion.empty;
  }

  @override
  Future<AiSuggestion> suggestRefactor(
    List<Finding> findings,
    String fileContent,
  ) async {
    return AiSuggestion.empty;
  }
}
