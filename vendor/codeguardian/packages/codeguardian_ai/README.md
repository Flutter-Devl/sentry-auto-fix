# codeguardian_ai

AI/LLM-backed fix suggestions for CodeGuardian findings.

## What this package does

`AiProvider` is the interface every backend implements:

```dart
abstract class AiProvider {
  Future<AiSuggestion> suggestFix(Finding finding, String surroundingCode);
}
```

Two implementations are provided:

- **`AnthropicAiProvider`** — calls the Anthropic Messages API directly over HTTP (Dart has no official Anthropic SDK, so this is a plain `POST` to `https://api.anthropic.com/v1/messages`, not a wrapped client library).
- **`NoOpAiProvider`** — offline mode. Always resolves to `AiSuggestion.empty` (confidence `0.0`, no suggested code) and never makes a network call.

`AiSuggestion` carries `explanation` (String), `confidence` (0.0–1.0), and an optional `suggestedCode`.

## What gets sent externally when AI is enabled

This is the important part — read it before enabling `AnthropicAiProvider` on a real project.

When `AnthropicAiProvider.suggestFix(finding, surroundingCode)` is called, the following is sent to Anthropic's API (`api.anthropic.com`), and nothing else:

| Field | Contents |
|---|---|
| `finding.ruleId`, `.category`, `.severity`, `.message`, `.file`, `.line`, `.column` | The single finding's metadata — no other findings, no project-wide data. |
| `surroundingCode` | The code snippet passed in by the caller — **after** it has been run through `redactSecrets()`. |
| API key | Sent as the `x-api-key` HTTP header. Read from an environment variable at call time (see below) — never embedded in the request body, never logged, never written to disk by this package. |

Nothing else leaves the machine: no other files, no git history, no project structure, no other findings, no telemetry. Each call is a single, independent HTTP request for one finding.

### Secret redaction happens before every request

`redactSecrets(String code)` scrubs anything matching `HardcodedSecretRule`'s own detection pattern (a variable/field/const whose name looks like `secret`, `password`, `apiKey`, `authToken`, etc., assigned a string literal that itself looks like a secret value — not a path, not an i18n key, not a plain label) and replaces the value with the literal text `[REDACTED]`. It reuses the rule's exact `secretNamePattern` and `looksLikeSecretValue` from `codeguardian_rules`, so "looks like a secret" means the same thing here as it does when the rule itself flags a finding.

`AnthropicAiProvider.suggestFix` always calls `redactSecrets()` on `surroundingCode` *before* building the HTTP request body — there is no code path that constructs a request from the raw, unredacted string. This is enforced by a test (`test/anthropic_ai_provider_test.dart`) that intercepts the outgoing request via a mock HTTP client and asserts the raw secret literal is absent from the request body while the `[REDACTED]` placeholder is present.

Redaction is a regex-based approximation of the rule's AST-based check (callers pass in an arbitrary code snippet, not necessarily a full parseable file, so an AST-based check isn't available at this point). It only catches the same shape the rule itself catches — a bare declaration (`name = 'value'`), not e.g. secrets embedded in map literals or string interpolation. Treat it as a safety net for the common case, not a substitute for keeping real secrets out of source in the first place.

### Offline mode sends nothing

`NoOpAiProvider` never constructs an HTTP request. If no provider is configured (see below) or the configured API key's environment variable isn't set, `createAiProvider` falls back to `NoOpAiProvider` — so "AI disabled" and "AI provider unavailable" both fail safe to zero external calls, rather than erroring.

## Configuring a provider

```
codeguardian ai configure --provider=anthropic --api-key-env=ANTHROPIC_API_KEY --model=claude-opus-4-8
codeguardian ai configure --provider=none
```

- The API key is **never** accepted as a CLI argument and **never** written to disk. `configure` only validates that the named environment variable is currently set (failing with a non-zero exit and no file written if it isn't) and persists the *variable name* to `codeguardian-ai-config.json` in the project directory.
- At analysis time, `createAiProvider(config)` reads the actual key fresh from that environment variable (`Platform.environment`). If it's unset by then, you get `NoOpAiProvider`, not an error.
- `codeguardian-ai-config.json` therefore only ever contains `{"provider": ..., "apiKeyEnvVar": ..., "model": ...}` — no secret ever touches this file. It's safe to commit.

## Package layout

| File | Contents |
|---|---|
| `lib/src/ai_provider.dart` | `AiProvider` interface |
| `lib/src/ai_suggestion.dart` | `AiSuggestion` model |
| `lib/src/anthropic_ai_provider.dart` | `AnthropicAiProvider` (raw HTTP against the Messages API, with structured JSON output) |
| `lib/src/noop_ai_provider.dart` | `NoOpAiProvider` |
| `lib/src/redact_secrets.dart` | `redactSecrets()` |
| `lib/src/ai_config.dart` | `AiConfig`, `readAiConfig`/`writeAiConfig`, `createAiProvider` |
