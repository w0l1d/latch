# iOS Build Notes

## Status
Android: ✅ Building (`build/app/outputs/flutter-apk/app-debug.apk`)  
iOS: ⏳ Not yet attempted — requires macOS with Xcode

## Prerequisites
- Xcode 16+ installed (for iOS 18 SDK)
- CocoaPods: `sudo gem install cocoapods` or `brew install cocoapods`
- A valid Apple Developer account (for device builds; simulator works without one)
- iOS deployment target ≥ 12.0 (set in `ios/Podfile`)

## Known Issues to Resolve Before Building

### 1. file_picker iOS entitlements (iCloud / NSDocumentPickerViewController)
`file_picker 10.3.x` uses `UIDocumentPickerViewController` on iOS.  
Add the following key to `ios/Runner/Info.plist` if missing:
```xml
<key>NSDocumentPickerSupported</key>
<true/>
```
For iCloud Drive access (optional):
```xml
<key>UIFileSharingEnabled</key>
<true/>
<key>LSSupportsOpeningDocumentsInPlace</key>
<true/>
```

### 2. Minimum iOS deployment target
`file_picker 10.x` requires iOS 12.0+. Confirm `ios/Podfile` has:
```ruby
platform :ios, '12.0'
```

### 3. CocoaPods install
After first `flutter pub get`, run:
```bash
cd ios && pod install && cd ..
```
If pod install fails due to spec repo: `pod repo update` first.

### 4. Xcode workspace
Always open `ios/Runner.xcworkspace` (not `.xcodeproj`) after pod install.

## Build Commands
```bash
# Simulator (no signing needed)
flutter build ios --debug --simulator

# Device (requires signing)
flutter build ios --debug

# Run on connected simulator
flutter run -d "iPhone 16"
```

## Signing (Device Builds)
1. Open `ios/Runner.xcworkspace` in Xcode
2. Select Runner target → Signing & Capabilities
3. Set Team to your Apple Developer account
4. Bundle ID: `com.latch.latch` (already set)

## Architecture Notes
- `file_picker` on iOS delegates to the OS `UIDocumentPickerViewController` — 
  the same as Android; no custom UI needed.
- All crypto work will run in Dart isolates, which are fine on iOS.
- The hardware wrap (M4 of the roadmap) will use the Secure Enclave via a 
  `MethodChannel` in `ios/Runner/AppDelegate.swift`.

## Expected Warnings (Non-blocking)
- Kotlin-related warnings don't appear on iOS builds.
- `file_picker` may show a deprecation about `UIAlertController` — harmless.
