/// CodeGuardian AI - AI/LLM-backed fix suggestions for analysis findings.
///
/// [AiProvider] is the backend interface ([AiProvider.suggestFix] for
/// single-finding suggestions, [AiProvider.suggestRefactor] for whole-file
/// refactors); two implementations are provided:
///
///  * [AnthropicAiProvider] -- calls the Anthropic Messages API directly
///    over HTTP (Dart has no official Anthropic SDK).
///  * [NoOpAiProvider] -- offline mode; always returns [AiSuggestion.empty]
///    and never makes a network call.
///
/// [redactSecrets] scrubs anything matching `HardcodedSecretRule`'s
/// detection pattern out of code before it's sent to a provider --
/// [AnthropicAiProvider] always applies it internally, so callers never
/// need to remember to call it themselves.
///
/// [AiConfig] (with [readAiConfig]/[writeAiConfig]/[createAiProvider]) is
/// the persisted provider selection `codeguardian ai configure` writes and
/// that later commands read to build the configured [AiProvider] -- see the
/// package README for exactly what data crosses the network when AI is
/// enabled.
library codeguardian_ai;

export 'src/ai_config.dart';
export 'src/ai_provider.dart';
export 'src/ai_suggestion.dart';
export 'src/anthropic_ai_provider.dart';
export 'src/noop_ai_provider.dart';
export 'src/redact_secrets.dart';
