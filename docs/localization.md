# Localization

MyClip ships in 简体中文 (source), English, 日本語, 한국어, Español, Français and Deutsch. It follows the system
language, falls back to English for a language it does not ship, and can be changed in onboarding.

`AppLanguage` (in `MyClipCore`) owns all of this:

- `AppLanguage.current` — the language in use: the first system preference MyClip ships, else English.
- `AppLanguage.applyAtLaunch()` — called from `main()` **before AppKit exists**, because the bundle resolves its
  language on the first localized string and never re-reads it. When no preferred language is one MyClip ships, it
  writes `AppleLanguages` so the interface is English rather than the development region, which is Chinese.
- `AppLanguage.select(_:)` — stores the onboarding choice the same way System Settings' per-app language does, and the
  picker then calls `MyClipAppDelegate.relaunch()`, since a running bundle keeps the language it resolved.

The picker lives in onboarding only (`CaptureOnboardingView.languagePicker`); afterwards macOS's own per-app language
setting applies. `MemoryPrompt.outputLanguage` follows `AppLanguage.current`, so Memory is written in the same
language as the interface.

## How strings are localized

- **Source language is Simplified Chinese.** The Chinese text in code is the String Catalog key. Write new UI strings in
  Chinese as before.
- **SwiftUI literals** (`Text("…")`, `Button("…")`, `Label("…")`, `.help("…")`, …) are `LocalizedStringKey` and are
  extracted by the compiler (`SWIFT_EMIT_LOC_STRINGS`). Nothing to do.
- **Plain `String` values** that reach the UI (model state, error messages, strings passed to custom views) must be
  wrapped in `String(localized: "…")`, in the app target and in `MyClipCore` alike.
  Interpolation is fine: `String(localized: "已更新 \(count) 个文件")` produces the key `已更新 %lld 个文件`.
- **Agent-facing text** (prompts in `MemoryPrompt`, `TaskPrompt`, `HandoffPrompt`, MCP tool
  descriptions) stays Chinese on purpose. The agent is told which language to write Memory bodies in through
  `MemoryPrompt.outputLanguage`, which follows the system language.
- Never branch on the text of a localized string. Use an enum case or a flag (see `LibraryError.agentStopped`).

## Two traps that silently keep the UI Chinese

- **A forced locale.** The window used to be hosted with `.environment(\.locale, Locale(identifier: "zh_Hans_CN"))`,
  which pins every SwiftUI string and date to Chinese no matter the system language, while `String(localized:)` keeps
  following it. Do not set `\.locale` on the root view.
- **`Button("…", systemImage:)` and `Label("…", systemImage:)`.** Their title parameter is a plain `String`, so the
  literal is neither collected nor translated. Write `Button(String(localized: "…"), systemImage: …)`. A literal that
  sits inside another string's interpolation (`"\(flag ? "是" : "否")"`) has the same problem and needs the same wrapping.

After any UI change, run `Scripts/localization/update_keys.sh` and check that the new keys appear; a string that never
shows up is almost always one of these two cases.

## Catalog

`MyClip/Supporting/Localizable.xcstrings` holds every key, from the app target and from `MyClipCore` alike. Core does
not carry its own catalog: Xcode compiles a package's String Catalog but does not copy the per-language files into the
SwiftPM resource bundle, so `Bundle.module` would find nothing. Core therefore uses plain `String(localized:)`, which
looks up the main bundle — the app's. Outside the app (the `myclip-mcp` executable, unit tests) there is no catalog and
the Chinese key is used, which is what those contexts want.

## Updating after code changes

```bash
Scripts/localization/update_keys.sh
```

This builds the app and Core once with the compiler's string extraction on and reads the emitted `.stringsdata`
files, adds new keys to both catalogs, drops stale ones and prints how many keys each language still lacks. It does not
use `xcodebuild -exportLocalizations`: that export rewrites multi-argument keys into positional form (`%1$lld … %2$lld`)
while the runtime looks up `%lld … %lld`, so its keys would never match. To merge
translations, put `<lang>.json` files (`{"<Chinese key>": "<translation>"}`) in a directory and run:

```bash
Scripts/localization/update_keys.sh --translations path/to/translations
```

Translation keys may be written in positional form (as an XLIFF export gives them); they are matched to the catalog's
`%lld` keys. Translated values may use positional placeholders to reorder arguments. Translations whose placeholders
differ from the key are rejected and listed.
