# TestFlight Distribution

HTMLGraph includes an Xcode project for macOS TestFlight distribution while keeping the SwiftPM development workflow intact.

## Prerequisites

- Apple Developer Program membership.
- A macOS app record in App Store Connect.
- A Bundle ID matching `PRODUCT_BUNDLE_IDENTIFIER` in `Config/Signing.xcconfig`.
- A valid development team ID in `Config/Signing.xcconfig`.
- Xcode 13 or newer. This project is currently verified with Xcode 26.5.

## Local Build Check

This verifies the Xcode project without requiring signing:

```bash
xcodebuild \
  -project HTMLGraph.xcodeproj \
  -scheme HTMLGraph \
  -configuration Release \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

The regular SwiftPM checks should still pass:

```bash
swift test
swift build
```

## Configure Signing

Edit `Config/Signing.xcconfig`:

```xcconfig
PRODUCT_BUNDLE_IDENTIFIER = com.yourcompany.htmlgraph
DEVELOPMENT_TEAM = ABCDE12345
CODE_SIGN_STYLE = Automatic
```

The Bundle ID must match the app record in App Store Connect.

## Archive

```bash
xcodebuild \
  -project HTMLGraph.xcodeproj \
  -scheme HTMLGraph \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath build/HTMLGraph.xcarchive \
  archive
```

## Upload to TestFlight

```bash
xcodebuild \
  -exportArchive \
  -archivePath build/HTMLGraph.xcarchive \
  -exportOptionsPlist Config/ExportOptions.testflight.plist \
  -exportPath build/TestFlight
```

After upload, manage internal or external testing in App Store Connect.
