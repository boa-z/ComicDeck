# Localization

ComicDeck uses Xcode String Catalogs and Crowdin for app-owned UI localization.

## Overview

Current direction:

- localization assets live in `ComicDeck/Resources/Localization`
- runtime code resolves semantic keys through `AppLocalization`
- Crowdin sync is configured in `crowdin.yml`

Current migrated surfaces:

- `Home` (complete)
- `Library` (complete)
- `Settings` (complete)
- `Downloads` (keys added, code migration in progress)
- `Reader` (keys added, code migration in progress)
- `Source Management` (keys added, code migration in progress)
- `Search` (keys added, code migration in progress)
- `Discover` (keys added, code migration in progress)
- `Detail` (keys added, code migration pending)

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
6. Use the `common.*` namespace for shared action strings (e.g., `common.ok`, `common.cancel`, `common.copy`).

## Key Naming Conventions

Keys follow a hierarchical pattern:

```
<feature>.<section>.<element>.<property>
```

Examples:
- `downloads.navigation.title` - Downloads screen navigation title
- `reader.settings.mode` - Reader settings mode label
- `source.management.metric.updates` - Source management updates metric
- `search.action.apply_filters` - Search action for applying filters

Common namespaces:
- `home.*` - Home screen
- `library.*` - Library screens
- `downloads.*` - Downloads management
- `reader.*` - Comic reader
- `source.*` - Source management and details
- `search.*` - Search functionality
- `discover.*` - Discover/Explore screens
- `detail.*` - Comic detail view
- `settings.*` - Settings screens
- `common.*` - Shared/common strings

## Workflow

1. Add or update keys in `Localizable.xcstrings` with both English and Chinese translations.
2. Set `extractionState` to `"manual"` for manually added keys.
3. Set `state` to `"translated"` when both locales are complete.
4. Upload source strings to Crowdin (if using Crowdin for additional languages).

```bash
crowdin upload sources
```

5. Download translated strings.

```bash
crowdin download
```

6. Verify the target locale in Xcode.
7. Update code to use `AppLocalization.text()` for all UI strings.

## Code Usage

```swift
// Simple string
Text(AppLocalization.text("downloads.navigation.title", "Downloads"))

// With arguments (use String format)
Text(String(format: AppLocalization.text("downloads.metric.comics", "%d comics"), count))

// Button labels
Button(AppLocalization.text("common.cancel", "Cancel")) {
    // action
}

// Alert titles
.alert(AppLocalization.text("downloads.alert.clear_queue.title", "Clear download queue?"), isPresented: $showAlert) {
    Button(AppLocalization.text("common.ok", "OK"), role: .destructive) { }
}
```

## Scope Boundaries

Localization currently targets only ComicDeck-owned UI.

Not included:

- source-provided comic metadata
- source-provided comments
- source script errors
- offline file names

## Migration Status

### Completed
- Home screen navigation and cards
- Library workspaces and snapshots
- Settings sections and options
- Common actions (`common.*` namespace)

### In Progress
- Downloads management screen
- Reader interface and settings
- Source management and authentication
- Search interface
- Discover/Explore screens

### Pending
- Comic detail view (residual strings)
- Tracking integration UI
- Login flows

## Adding New Localization Keys

1. Open `ComicDeck/Resources/Localization/Localizable.xcstrings`
2. Add new key entry following the naming convention:

```json
"feature.section.key_name" : {
  "extractionState" : "manual",
  "localizations" : {
    "en" : {
      "stringUnit" : {
        "state" : "translated",
        "value" : "English text"
      }
    },
    "zh-Hans" : {
      "stringUnit" : {
        "state" : "translated",
        "value" : "中文文本"
      }
    }
  }
}
```

3. Add keys in alphabetical order within the file
4. Update code to reference the new key via `AppLocalization.text()`
