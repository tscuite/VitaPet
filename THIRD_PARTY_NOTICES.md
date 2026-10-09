# Third-party notices

## CodeNotch

UsageMonitor request headers, credential field names and response schemas were adapted from CodeNotch **1.20.0**, revision `6e8b0f8`, including CodexLocalProvider/CodexCredentials/CodexUsage, ClaudeOAuthProvider/ClaudeCredentials, CursorLocalProvider/CursorCredentials/CursorUsage, GitHubCopilotProvider, and OllamaProvider/OllamaUsage. Only the minimal read-only usage behavior was reused; no provider scripts were executed. Keychain credential access, presence probes and save/delete APIs have since been removed by user request; only existing file-based sign-ins remain. Compatible official credentials already stored by Pi can be borrowed read-only using its documented file formats; other Keychain-dependent sources remain unavailable. No migration, substitute credential storage or Pi runtime code is included.

The quota strip in `UsageNotchStyle.swift`, `UsageBarView.swift` and `UsageBarController.swift` also ports the original design measurements, steady top/bottom `SideNotchShape` outline, `ProviderRing` quota layers, `FlareArc` settings handle, oversized-rectangle Liquid Glass clipping, the three `NotchSurfaceStyle` materials and native appearance precedence, typography, settings-hover transitions, reading transitions, single-provider click refresh with the original 380ms feedback and finite 0.95s ring turn, and nonactivating screen-edge panel setup with transparent-region pointer routing from that revision. Session/activity widgets, drag/fold animations and hardware-notch joining are not part of this port.

The six vector PDFs in `Modules/ChatUI/UsageGlyphs` are adapted from the same revision: Codex/OpenAI, Claude, Cursor, Copilot and Ollama use the corresponding normalized loops from `Sources/Providers/GlyphOutline.swift`; DeepSeek uses `Sources/Assets.xcassets/glyph-deepseek.imageset/deepseek.svg`. They were converted once to native vector PDF with librsvg; no renderer or third-party runtime is bundled or needed to build VitaPet. Provider names/logos remain the property of their respective owners; no affiliation is implied.

The Codex detail ports `TooltipCard`, `NotchLayout`, `CodexTokenUsage`, `UsageResetCredits`, `UsagePace`, `Percent`, `ResetCopy`, token formatting and the original design-system typography/palette. VitaPet adapts the card to a 320pt width with native 12pt body/15pt title text and no auto-shrinking quota/reset lines for readability. The same revision's `UsageStore` scheduling decisions/defaults, `CodexActivityMonitor`/`CodexRolloutActivity`/`CodexOpenRollouts`, `CodexStore`/`CodexThread`/`CodexStoreCache`, `AgentSession`, and `SQLiteStore` are adapted for opt-in quota scheduling. Activity UI/logging, conversation titles/previews, sign-in flows, and archive restoration are omitted; bounded/nonblocking read guards, Swift 6 isolation and VitaPet localization are added. Source excerpts under `Modules/UsageMonitor/Tests/CodeNotchReference` provide an independent, fixture-only comparison and are not linked into the application.

Source: https://github.com/vinzdg/codenotch (reference checkout supplied for this implementation).

```text
MIT License

Copyright (c) 2026 Vinz

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## CC Switch

DeepSeek local accounting in `PiLocalSpend.swift` is informed by CC Switch's Pi session importer (`session_usage_pi.rs`) and usage cost calculator at revision **`5ae6ad3`**: actual-model attribution, recorded costs before price estimates, normalized fresh-input/cache token semantics, and deduplication of copied Pi history. `DeepSeekReferencePricing.swift` adapts the named DeepSeek V3/V4 subset of that revision's `model_pricing` seed table and model-name normalization; V4 aliases were checked against https://api-docs.deepseek.com/quick_start/pricing on 2026-10-08. Like the upstream snapshot, V4 uses peak reference rates, not actual gateway or historical bills. VitaPet implements its own bounded, read-only, in-memory Swift scan; no CC Switch proxy, database or application/runtime dependency is bundled. Source: https://github.com/farion1231/cc-switch.

```text
MIT License

Copyright (c) 2025 Jason Young

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
