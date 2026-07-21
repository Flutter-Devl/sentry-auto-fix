import 'dart:convert';

import 'package:codeguardian_core/codeguardian_core.dart';
import 'package:http/http.dart' as http;

import 'ai_provider.dart';
import 'ai_suggestion.dart';
import 'redact_secrets.dart';

/// Default model used when none is configured. Kept in sync with the
/// default `codeguardian ai configure` writes.
const defaultAnthropicModel = 'claude-opus-4-8';

const _anthropicVersion = '2023-06-01';
const _messagesEndpoint = 'https://api.anthropic.com/v1/messages';

/// An [AiProvider] backed by the Anthropic Messages API.
///
/// Dart has no official Anthropic SDK, so this calls the API directly over
/// HTTP (`POST /v1/messages`) rather than wrapping a client library.
///
/// **What gets sent externally:** [finding]'s rule id, category, severity,
/// message, and line/column, plus [surroundingCode] -- but only *after*
/// `redactSecrets()` has scrubbed it. Nothing else about the project (file
/// paths beyond the single finding's, other files, git history, etc.) is
/// sent. See the package README for the full data-flow writeup.
class AnthropicAiProvider implements AiProvider {
  /// Creates a provider that authenticates with [apiKey] (read by the
  /// caller from an environment variable -- never hardcode a key when
  /// constructing this).
  AnthropicAiProvider({
    required this.apiKey,
    this.model = defaultAnthropicModel,
    http.Client? httpClient,
  }) : _httpClient = httpClient ?? http.Client();

  /// API key sent as the `x-api-key` header on every request.
  final String apiKey;

  /// Model id to request, e.g. `claude-opus-4-8`.
  final String model;

  final http.Client _httpClient;

  @override
  Future<AiSuggestion> suggestFix(Finding finding, String surroundingCode) async {
    // Redact before building the request body: nothing derived from
    // `surroundingCode` reaches `jsonEncode` (and therefore the request)
    // except through `redacted`.
    final redacted = redactSecrets(surroundingCode);

    return _post(_buildPrompt(finding, redacted));
  }

  @override
  Future<AiSuggestion> suggestRefactor(
    List<Finding> findings,
    String fileContent,
  ) async {
    if (findings.isEmpty) return AiSuggestion.empty;

    // Redact before building the request body, for the same reason
    // [suggestFix] does: nothing derived from the file's content reaches the
    // request except through `redacted`.
    final redacted = redactSecrets(fileContent);

    return _post(_buildRefactorPrompt(findings, redacted));
  }

  /// POSTs [prompt] to the Messages API and parses the response, mapping every
  /// ordinary failure mode to a zero-confidence [AiSuggestion].
  Future<AiSuggestion> _post(String prompt) async {
    http.Response response;
    try {
      response = await _httpClient.post(
        Uri.parse(_messagesEndpoint),
        headers: {
          'content-type': 'application/json',
          'x-api-key': apiKey,
          'anthropic-version': _anthropicVersion,
        },
        body: jsonEncode(_buildRequestBody(prompt)),
      );
    } on Exception catch (error) {
      return AiSuggestion(
        explanation: 'AI provider request failed: $error',
        confidence: 0.0,
      );
    }

    if (response.statusCode != 200) {
      return AiSuggestion(
        explanation: 'AI provider request failed '
            '(HTTP ${response.statusCode}): ${response.body}',
        confidence: 0.0,
      );
    }

    return _parseResponse(response.body);
  }

  Map<String, dynamic> _buildRequestBody(String prompt) {
    return {
      'model': model,
      // Whole-file refactors return the COMPLETE file in `suggestedCode`, so
      // the response can be large. 2048 truncated the JSON mid-string (a
      // FormatException on parse); 16000 is the safe ceiling for a
      // non-streaming request and comfortably fits a 300-600 line source file.
      'max_tokens': 16000,
      'output_config': {
        'effort': 'medium',
        'format': {
          'type': 'json_schema',
          'schema': {
            'type': 'object',
            'properties': {
              'explanation': {'type': 'string'},
              'confidence': {'type': 'number'},
              'suggestedCode': {'type': 'string'},
            },
            'required': ['explanation', 'confidence'],
            'additionalProperties': false,
          },
        },
      },
      'messages': [
        {'role': 'user', 'content': prompt},
      ],
    };
  }

  String _buildPrompt(Finding finding, String redactedCode) {
    return '''
You are a static-analysis fix assistant for a Dart/Flutter codebase. A rule
flagged the following finding:

Rule: ${finding.ruleId}
Category: ${finding.category.label}
Severity: ${finding.severity.label}
Location: ${finding.file}:${finding.line}:${finding.column}
Message: ${finding.message}

Surrounding code (secrets already redacted as `$redactionPlaceholder`):
```dart
$redactedCode
```

Suggest a fix. Respond with your explanation, a confidence score between
0.0 and 1.0, and the suggested replacement code if you have one.
''';
  }

  String _buildRefactorPrompt(List<Finding> findings, String redactedCode) {
    final file = findings.first.file;
    final findingList = findings
        .map((f) => '- ${f.file}:${f.line}:${f.column} [${f.ruleId}] '
            '${f.message}')
        .join('\n');

    return '''
You are a refactoring assistant for a Dart/Flutter codebase. Static-analysis
rules flagged the following refactoring opportunities in a single file
($file):

$findingList

Here is the entire file (secrets already redacted as `$redactionPlaceholder`):
```dart
$redactedCode
```

Refactor the file to address the findings above -- for example, move business
logic out of widgets into a service/repository, hoist duplicated blocks into a
shared helper, and extract deeply-nested or overly-complex widget subtrees
into their own widgets. Apply only these improvements: preserve the file's
public API and runtime behavior, and do NOT make unrelated changes. Keep the
redaction placeholders exactly as they appear -- do not invent values for
them.

Respond with your explanation, a confidence score between 0.0 and 1.0, and,
in `suggestedCode`, the COMPLETE refactored file (not a snippet or a diff). If
you cannot improve the file without risking behavior, omit `suggestedCode` and
return a low confidence.
''';
  }

  AiSuggestion _parseResponse(String body) {
    try {
      final decoded = jsonDecode(body) as Map<String, dynamic>;
      final content = decoded['content'] as List<dynamic>? ?? const [];
      final textBlock = content
          .cast<Map<String, dynamic>>()
          .firstWhere((block) => block['type'] == 'text', orElse: () => const {});
      final text = textBlock['text'] as String?;
      if (text == null || text.isEmpty) {
        return AiSuggestion(
          explanation: 'AI provider returned no text content.',
          confidence: 0.0,
        );
      }

      final parsed = jsonDecode(text) as Map<String, dynamic>;
      final confidence = (parsed['confidence'] as num?)?.toDouble() ?? 0.0;
      return AiSuggestion(
        explanation: parsed['explanation'] as String? ?? '',
        confidence: confidence.clamp(0.0, 1.0),
        suggestedCode: parsed['suggestedCode'] as String?,
      );
    } on Exception catch (error) {
      return AiSuggestion(
        explanation: 'Failed to parse AI provider response: $error',
        confidence: 0.0,
      );
    }
  }
}
