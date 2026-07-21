# codeguardian_core

Core models, the rule interface, and the static-analysis **engine foundation**
used by every other package.

Dependency-light by design: it depends only on the Dart
[`analyzer`](https://pub.dev/packages/analyzer) (to resolve source with full
type information), plus `meta` and `path`. No Flutter, no AI, no network calls.

## What's here

- **`Finding`** — an immutable issue: `ruleId`, `category`, `severity`, `file`,
  `line`, `column`, `message`, `snippet`, and optional `cweId` / `masvsId`.
- **`Category`** / **`Severity`** — enums classifying findings.
- **`CodeGuardianRule`** — the abstract rule interface. A rule inspects a fully
  resolved unit and returns findings: `List<Finding> check(ResolvedUnitResult unit)`.
- **`RuleRegistry`** — holds rules and runs them against a project path. It uses
  the analyzer's `AnalysisContextCollection` to resolve every Dart file with
  full type information, then aggregates findings into an `AnalysisResult`.

## Usage

```dart
final registry = RuleRegistry([/* your rules */]);
final result = await registry.analyze('path/to/project');
for (final finding in result.findings) {
  print(finding);
}
```

With zero registered rules the engine still resolves the project and returns an
empty finding list, which makes it a convenient pure resolution check.
