# AI Model Selection Stability Design

## Problem

VitaPet currently rewrites the model field when the AI backend changes. Both the settings view and `AppDelegate` treat the previous backend's default model as disposable and replace it with the new backend's default. A user-selected value can therefore become `gpt-4o-mini` or `llama3.2` without an explicit model edit, which looks like an automatic downgrade.

The running configuration confirms that explicit custom model names are otherwise sent unchanged. Provider-side routing remains outside VitaPet's control, so the application must not add another silent model-selection layer.

## Decision

Use one explicit model value across backends and preserve every non-empty value. Only an empty or whitespace-only value resolves to the selected backend's default model.

The resolution rule lives in AIEngine as a small pure API. Settings, startup/configuration, and request construction all call the same API. Backend switching may normalize whitespace but never substitutes one non-empty model for another.

## Alternatives Considered

1. Preserve the explicit value across backend changes. This is the selected approach because it removes silent behavior without changing the configuration schema.
2. Store a separate preferred model for every backend. This is convenient for frequent switching but requires a migration and more UI state than the reported problem needs.
3. Discover a model from `/v1/models` and choose automatically. This can still select a cheaper or incompatible model and recreates the same loss of user control.

## Data Flow

1. The settings model field contains either a user value or an empty value.
2. `AIModelSelection.resolvedModel(_:for:)` trims the value and returns it when non-empty.
3. Only an empty value resolves to `AIBackend.defaultModel`.
4. The resolved value is persisted and passed to `OllamaService`.
5. Every request uses that resolved value. HTTP/provider failures are surfaced rather than retried with another model.

## Error Handling

An unavailable or invalid explicit model produces the provider's existing HTTP error. VitaPet does not retry with a default model. This makes failures visible and prevents a successful response from concealing a model downgrade.

## Testing

- A regression test proves that `llama3.2` remains `llama3.2` when resolving for an OpenAI-compatible backend.
- Tests cover preservation and trimming of custom model names.
- Tests cover the sole fallback case: blank input.
- Existing request tests and an independent harness verify that request bodies retain the configured model.

## Scope

This change controls VitaPet's model selection only. It cannot control model routing performed by an upstream gateway or by the Codex/ChatGPT platform hosting this development session.
