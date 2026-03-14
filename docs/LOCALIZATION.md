# Localization

ComicDeck uses Xcode String Catalogs and Crowdin for app-owned UI localization.

## Overview

Current direction:

- localization assets live in `ComicDeck/Resources/Localization`
- runtime code resolves semantic keys through `AppLocalization`
- Crowdin sync is configured in `crowdin.yml`

Current migrated surfaces:

- `Home`
- `Library`
- `Settings`

Current shipped locales:

- `en`
- `zh-Hans`

## Key Files

- `ComicDeck/Core/Localization/AppLocalization.swift`
- `ComicDeck/Resources/Localization/Localizable.xcstrings`
- `crowdin.yml`

## Rules

1. Do not add new user-visible UI strings as raw English literals in product screens.
2. Use semantic keys such as `home.navigation.title`, not English source text as keys.
3. Prefer complete phrase or sentence keys over string concatenation.
4. Add translator context when a string could be ambiguous.
5. Keep source-provided content out of app UI localization.

## Workflow

1. Add or update keys in `Localizable.xcstrings`.
2. Upload source strings.

```bash
crowdin upload sources
```

3. Download translated strings.

```bash
crowdin download
```

4. Verify the target locale in Xcode.

## Scope Boundaries

Localization currently targets only ComicDeck-owned UI.

Not included:

- source-provided comic metadata
- source-provided comments
- source script errors
- offline file names

## Migration Priorities

Remaining product areas should migrate in this order:

1. `Downloads`
2. `Reader`
3. `Source management`
4. `Detail`
5. `Search / Discover` residual hard-coded UI strings
