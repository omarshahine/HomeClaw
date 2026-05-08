fastlane documentation
----

# Installation

Make sure you have the latest version of the Xcode command line tools installed:

```sh
xcode-select --install
```

For _fastlane_ installation instructions, see [Installing _fastlane_](https://docs.fastlane.tools/#installing-fastlane)

# Available Actions

## iOS

### ios auth_check

```sh
[bundle exec] fastlane ios auth_check
```

Validate App Store Connect API key auth

### ios archive

```sh
[bundle exec] fastlane ios archive
```

Build a release .xcarchive (no upload)

### ios upload

```sh
[bundle exec] fastlane ios upload
```

Build + upload to App Store Connect (no external submission)

### ios beta

```sh
[bundle exec] fastlane ios beta
```

Build + upload + submit to external TestFlight (full release loop)

### ios submit_only

```sh
[bundle exec] fastlane ios submit_only
```

Re-submit an already-uploaded build to external TestFlight (recovery)

### ios status

```sh
[bundle exec] fastlane ios status
```

Show TestFlight status for the latest (or specified) build

----

This README.md is auto-generated and will be re-generated every time [_fastlane_](https://fastlane.tools) is run.

More information about _fastlane_ can be found on [fastlane.tools](https://fastlane.tools).

The documentation of _fastlane_ can be found on [docs.fastlane.tools](https://docs.fastlane.tools).
