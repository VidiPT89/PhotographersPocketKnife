# iPhone and iPad

Native SwiftUI app for iOS/iPadOS 17 or later. The mobile target shares the catalogue, image pipeline, metadata, selection algorithms and delivery queue with the Mac app. It has its own touch interface, file import and network transports.

## Build

Requirements: Xcode with an iOS SDK supporting Swift 6, XcodeGen, and internet access for the initial dependency download.

```sh
sh scripts/ios-static-framework.sh
xcodegen generate
open PhotographersPocketKnife.xcodeproj
```

Select **PhotographersPocketKnife-iOS** and an iPhone or iPad simulator. For a physical device, select your signing team. No signing account is needed for a simulator.

The bootstrap downloads the pinned curl 8.18.0 XCFramework and verifies its SHA-256. `Vendor/` is ignored by Git. The static framework is linked, never embedded in the app bundle. Citadel and ZIPFoundation are resolved through Swift Package Manager. Third-party notices are bundled and accessible in Settings.

## Mobile workflows

- **Import:** Photos picker, Files, folders and connected cards. Imports are copied into the app's Documents/Originals directory and verified with SHA-256. Settings offer folder templates, an event name and a simultaneous backup folder.
- **Cull:** adjustable grid, search, stars, picks/rejects, colour labels, RAW+JPEG stacks, advanced filters, sorting and delivery badges. Tools include comparison with synchronized zoom/pan, GPS map, smart selection and taste profiles, metadata, batch rename, capture-time offsets, duplicate detection, noise reduction and automatic keywords. Removing a photo from the catalogue preserves its files.
- **Edit:** shared non-destructive pipeline with RAW development, basic adjustments, curves, HSL, colour grading, masks, removal, crop/geometry, history, snapshots, presets and learned styles. iPad uses side-by-side canvas and controls; iPhone stacks them. Use the editing-tool menu to change panels. Pinch to zoom up to 6× in the editor or presentation, drag to inspect details, and double-tap to zoom in or fit. The zoom indicator also restores the full photograph. In crop, mask, removal and split comparison tools, use two fingers to navigate and one finger to edit. Comparison panes share zoom and position; changing photographs resets the editor viewport. Optional selection/removal models download in Settings.
- **Metadata:** single or batch IPTC editing, stationery pad, copy/paste, caption variables, code replacements and XMP templates. Untouched batch fields keep individual values. Save-and-next supports sequential captioning. The assistant at the top of File info takes typed or dictated notes; dictation runs on the device in English or Portuguese. With Apple Intelligence (iOS 26), Fill with AI proposes headline, caption, event, place, people and keywords from the notes and the photo details, and nothing changes until you apply the proposal. Without it, the notes can be used as the caption.
- **Export:** JPEG, HEIC, TIFF, PNG and linear DNG; resizing, colour profiles, sharpening, watermark and metadata rules. Save to Files, share, add compatible images to Photos or queue delivery. Failed photographs can be retried without exporting successful photographs again. Cancel finishes the current photograph and preserves completed files.
- **Deliver:** FTP, explicit FTPS, SFTP, WebDAV and S3, destination connection tests, default destination, duplication, queue persistence, pause/retry and CSV history. Long-press a destination for management actions; swipe a queued file to remove it. The queue includes overall progress, retry-failed and clear-completed actions. Credentials and imported Ed25519/RSA private keys are stored in Keychain. SFTP pins the server key after an explicitly enabled first connection and rejects changed keys. Modern Ed25519/ECDSA server keys are supported by the default SSH algorithms; legacy RSA-only hosts may require server configuration changes.
- **Client output:** contact-sheet PDF and a shareable ZIP containing a static client gallery, with an optional upload destination.
- **Settings:** English or Portuguese, appearance, sidecars, models, roster, labelled-photo delivery and watched folder.

Exports are available in **Files → On My iPhone/iPad → Photographer's Pocket Knife → Exports**. Imported originals and sidecars can also be copied out using Files. The catalogue is local to each installation; there is no automatic Mac/iOS catalogue sync.

## Platform behaviour

Transfers and watched-folder monitoring require the app to remain active. Going into the background pauses the queue; return to Upload and tap Resume. Retrying a mobile upload safely restarts that file from byte zero. This is not byte-offset resume or a background-transfer service.

Files and Photos supply access through system pickers. External providers can revoke access or become unavailable; reselect an external folder if necessary. The iOS importer keeps its own originals so editing does not depend on a card remaining connected. RAW support follows the device's Core Image camera support. Preview resolution and memory caches are smaller than on Mac.

Mac-specific desktop interactions (Dock/Finder integration, remappable keyboard shortcuts, pointer-following loupe and hover previews) are not mobile controls. The mobile editing, selection and export engines are shared, but device performance and third-party server compatibility still require testing with real shoots and equipment before release.

## Tests

```sh
xcodebuild -project PhotographersPocketKnife.xcodeproj \
  -scheme PhotographersPocketKnife-iOS \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -parallel-testing-enabled NO test
```

The unit suite covers imported copies/sidecars, recipe persistence, all export formats, metadata and cancellation. UI tests launch an isolated in-memory fixture catalogue, navigate editing and destinations, switch language, check custom ports and capture both normal and accessibility-sized text in dark/light appearances. Integration tests skip unless local fixtures are explicitly enabled:

```sh
python3 -m venv /tmp/ppk-ios-transfer-tests
/tmp/ppk-ios-transfer-tests/bin/pip install pyftpdlib paramiko pyopenssl 'moto[s3,server]'
/tmp/ppk-ios-transfer-tests/bin/python scripts/test-ios-transfers.py
```

In another terminal, prepend `TEST_RUNNER_PPK_MOBILE_INTEGRATION=1` to the test command. Fixtures bind only to localhost and exercise byte-for-byte uploads through all five protocols, invalid credentials, untrusted TLS certificates and changed SSH host keys. Moto emulates S3 storage and does not validate AWS credentials against a real account. Stop the fixture script with Ctrl-C when finished.

No App Store upload or signing/distribution archive is performed by these commands.
