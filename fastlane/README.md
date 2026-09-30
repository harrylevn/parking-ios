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

### ios lint

```sh
[bundle exec] fastlane ios lint
```

SwiftLint at zero violations

### ios test

```sh
[bundle exec] fastlane ios test
```

Unit tests, then the coverage gate

### ios uitest

```sh
[bundle exec] fastlane ios uitest
```

UI tests on the simulator, against in-process fakes

### ios ci

```sh
[bundle exec] fastlane ios ci
```

Everything CI runs: lint, build, String Catalog check, unit tests, UI tests

### ios ipa

```sh
[bundle exec] fastlane ios ipa
```

A development-signed .ipa, built by gym and pointed at this Mac's backend

----

This README.md is auto-generated and will be re-generated every time [_fastlane_](https://fastlane.tools) is run.

More information about _fastlane_ can be found on [fastlane.tools](https://fastlane.tools).

The documentation of _fastlane_ can be found on [docs.fastlane.tools](https://docs.fastlane.tools).
