# Photographer's Pocket Knife 🔪📷

> A native macOS photography workflow app: cull like Photo Mechanic, develop RAW files non-destructively, and deliver over FTP/SFTP/WebDAV/S3 — all in one window, one catalog, no round trips.

[![Report Bug](https://img.shields.io/badge/Report-Bug-red)](https://github.com/VidiPT89/PhotographersPocketKnife/issues)
[![Request Feature](https://img.shields.io/badge/Request-Feature-blue)](https://github.com/VidiPT89/PhotographersPocketKnife/issues)

## ✨ Features

### 🗂️ Cull — pick the keepers, fast
- ✅ Ingest from a card or folder with a configurable folder structure (`{year}/{date}_{event}/{type}`), SHA-256 checksum verification and a simultaneous backup to a second destination
- ✅ Or simply open a folder from Finder or drop it onto the Dock icon
- ✅ Thumbnail grid in 5 sizes (`-` / `+`), backed by a memory-bounded + disk cache that reads the camera's embedded preview first; metadata is read in parallel on import
- ✅ Predictive prefetching of the next and previous frames, weighted by the direction you are moving in
- ✅ Loupe with 100 % zoom and a magnifier that follow the cursor, plus a filmstrip
- ✅ Focus peaking (`K`): sharp edges are painted orange in the loupe, so missed focus shows at a glance
- ✅ Watched folder: photos your camera sends over FTP or Wi-Fi, or that tethering saves, join the catalog on their own as soon as each file has finished writing
- ✅ Side-by-side compare of 2 or 4 frames with synced zoom and pan
- ✅ Star ratings (0–5), pick/reject and colour labels, all on the keyboard with Photo Mechanic–style defaults — every shortcut can be remapped
- ✅ Filter and sort by rating, flag, colour label, camera, lens, ISO, focal length, file name and capture time
- ✅ Batch rename with templates and conflict detection
- ✅ Batch IPTC with caption templates (`{date}`, `{event}`, `{camera}`, `{city}`, `{seq}`…), written without recompressing, with XMP sidecars for RAW
- ✅ Code replacements compatible with Photo Mechanic files: load a tab-delimited roster and type `=7=` to get the player's name (`=7#2=` for the next column), expanded live as you type
- ✅ Automatic player captions: the `{players}` token reads the shirt numbers in each photo on-device and writes the names from the roster
- ✅ Capture time adjustment to sync several cameras: set the correct time of one frame and the same offset is applied to the whole selection
- ✅ `.ppk` sidecars keep ratings and edits next to the originals; XMP ratings and labels are exported for Lightroom and Bridge, and picked up again on import
- ✅ Duplicate detection two ways: similar photos by perceptual hashing, or identical files (same size and SHA-256, even under another name or folder) with one click to remove the extra copies from the catalog
- ✅ Photo map: photos with GPS appear on a map, and clicking one opens it in the loupe
- ✅ Contact sheet PDF (A4) of the selection, with file name, stars, date and camera under each frame
- ✅ Automatic scene keywords written to IPTC/XMP and searchable in the catalog
- ✅ Smart selection, assisted or automatic: every photo is checked for focus, closed eyes, face quality and exposure, shots are grouped into moments, and the best of each moment is highlighted, tuned for the type of work (general, sports, weddings and events, portrait, landscape) — or picked, starred and the flawed ones rejected for you, with one-click undo. Taste profiles learn what you personally keep, from your ratings, picks and rejects or from a folder of photos you delivered, so the selection follows your eye. All on-device
- ✅ Client presentation mode in full screen
- ✅ Live histogram and EXIF panel

### 🎛️ Develop — non-destructive editing
- ✅ Every photo keeps an edit recipe — the original file is never touched
- ✅ GPU pipeline on Core Image and Metal, with RAW decoding through `CIRAWFilter` (tested with Canon CR3, Nikon NEF, Sony ARW and Fujifilm RAF)
- ✅ Exposure, contrast, highlights, shadows, whites, blacks, texture, clarity, temperature, tint, vibrance and saturation
- ✅ Tone curve (RGB + per channel), HSL across eight colour bands and colour grading wheels for shadows, midtones and highlights
- ✅ Sharpening with radius and edge masking, luminance and colour noise reduction, chromatic aberration correction, vignette and grain
- ✅ Background noise reduction for high-ISO shoots: wavelet denoising on the GPU (no AI, no internet) smooths grain while keeping edges, and saves a 16-bit TIFF copy (`-DN`) next to each original, added to the catalog
- ✅ Local adjustments with linear and radial gradient masks, a brush mask (hold ⌥ to erase) and an automatic subject mask, edited directly on the image
- ✅ One-click Auto edit: exposure metered on what draws attention in the frame, white balance, contrast and horizon straightening, all as regular sliders you can tweak
- ✅ Object removal: click a person or object to select it automatically, or paint over any distraction, and the area is filled with the surrounding texture — on-device, no internet needed
- ✅ Crop with aspect presets and rule-of-thirds or golden-spiral overlays, straighten, rotate, flip, perspective and automatic lens correction for RAW
- ✅ Clipping warnings on the histogram and on the image
- ✅ Visual history with undo/redo, named snapshots, presets with live hover preview that can be shared as `.ppkpreset` files, Lightroom `.xmp` preset import, and copy/paste settings across a selection
- ✅ Personal style: learns your look from photos edited here, from Lightroom develop settings in `.xmp` sidecars and from folders of photos you already delivered (it works out the adjustments between each original and its final version), then edits new shoots in that style — or straight from the Auto button
- ✅ Portrait retouch: skin smoothing and background blur, with people detected automatically
- ✅ Before/after toggle (`\`) and a draggable split view

### 📤 Deliver — export and upload
- ✅ Export to JPEG, HEIC, TIFF (8/16-bit), PNG and linear DNG
- ✅ Resize by long edge or percentage, DPI, sRGB / Display P3 / Adobe RGB, output sharpening for screen, matte or glossy paper
- ✅ Text watermark with position, size and opacity, and metadata rules (keep all, remove GPS, copyright only, remove all)
- ✅ Saved export presets and one-step export & upload (`⌘⇧E`)
- ✅ FTP, FTPS, SFTP (system OpenSSH, with keys or password), WebDAV and S3-compatible destinations
- ✅ Passwords stored in the macOS Keychain, never on disk, with a built-in connection test
- ✅ Organised destinations: search, a default destination, duplicate, test one or all at once with a status dot for each, paste a full address (`sftp://user@server:22/photos`) to fill in the fields, live checks for missing or wrong settings, and per-destination statistics
- ✅ Remote folders built from templates (`{date}`, `{year}`, `{month}`, `{day}`, `{event}`) with one-click tokens and a preview of the full upload address
- ✅ Transfer queue grouped by destination, with per-file and overall progress, speed, time remaining, pause/resume, automatic retries with back-off and native notifications
- ✅ Hot folder mode — anything given the chosen colour label is exported and uploaded automatically
- ✅ Client galleries: a self-contained web page with lightbox, keyword search, favourites the client can send back by email, and optional downloads — saved locally or uploaded to any destination, no server or subscription needed
- ✅ Upload history filtered by file, destination and status, with CSV report export of what you see, and drag photos onto a destination in the sidebar to send them straight away

### 🎨 Everywhere
- ✅ Runtime language switch — Português (PT-PT) and English, no restart needed (Settings, `⌘,`)
- ✅ Dark mode, Light mode and System mode
- ✅ Colour identity from [ividi.dev](https://ividi.dev/) — burnt orange, amber and near-black, with a neutral grey canvas behind photos so nothing skews colour judgement
- ✅ Animated splash screen with developer credits, then straight into the app
- ✅ Spring animations, sliding switchers, hover effects and toasts throughout, with full Reduce Motion support
- ✅ Diagnostics panel (`⌥⌘D`) with render, decode and export timings
- ✅ Automatic updates

## 🛠️ Tech Stack

| Category | Technology |
|----------|------------|
| Language | Swift 6 |
| UI | SwiftUI + AppKit |
| Rendering | Core Image + Metal |
| RAW decoding | `CIRAWFilter`, ImageIO |
| Catalog | SwiftData |
| Transfers | curl (FTP/FTPS/WebDAV/S3), OpenSSH `sftp` (SFTP) |
| Credentials | Keychain Services |
| Instrumentation | `OSSignposter` |
| Updates | Sparkle |
| Architecture | MVVM with `@Observable` |
| Project | XcodeGen |
| Tests | XCTest, XCUITest |
| Min. macOS | 14.0 |

## 🚀 Quick Start

### Prerequisites

- macOS 14+ with Xcode 16+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

### Installation

```bash
git clone https://github.com/VidiPT89/PhotographersPocketKnife.git
cd PhotographersPocketKnife
xcodegen generate
open PhotographersPocketKnife.xcodeproj
```

Pick the `PhotographersPocketKnife` scheme and run (`⌘R`).

> The Xcode project is generated with XcodeGen from `project.yml`. If you add or move Swift files, regenerate it with `xcodegen generate`.

Prefer a ready-made build? Download the latest version from [Releases](https://github.com/VidiPT89/PhotographersPocketKnife/releases/latest). The first time, right-click the app and choose **Open**.

## 📖 Usage

1. Watch the splash screen, then press `⌘I` to ingest a card or folder — choose the folder structure, checksum verification and a backup destination
2. In **Cull**, fly through the take with the arrow keys, rate with `0`–`5`, label with `6`–`9` or `V`, and mark keepers with `P` (or `X` to reject, `U` to clear)
3. Press `Space` for the loupe, `Z` for 100 %, `L` for the magnifier, `C` to compare the selection and `F` for presentation mode
4. Press `T` to jump to **Develop** — adjust, grade, add masks (`M`), crop (`R`) and check the result against the original with `\`
5. Copy a look with `⌘⇧C` and paste it across the selection with `⌘⇧V`, or save it as a preset or snapshot
6. Press `⌘E` to export, or `⌘⇧E` to export and upload in one go
7. Watch the queue in **Deliver** (`⌘3`) — speed, time remaining, pause, resume or retry failed files at any time
8. Turn on the hot folder in Settings to send every photo you label green straight to the client
9. Change language and appearance at any time in Settings (`⌘,`)

## 🧪 Testing

```bash
xcodebuild -project PhotographersPocketKnife.xcodeproj \
           -scheme PhotographersPocketKnife \
           -destination 'platform=macOS' test
```

Unit tests cover the edit pipeline (curves, HSL, colour grading, masks, clipping, DNG export), recipe and settings migrations, history and snapshots, ingest with checksums, sidecars, batch renaming, IPTC and XMP writing, export options, WebDAV commands, transfer speed, hot folder rules, duplicate detection, filters, shortcuts, localisation and a 10 000-photo catalog. A golden-image test compares a reference render with a ΔE tolerance, so colour regressions fail loudly.

UI tests (splash, modules, language and theme) run in their own scheme, using a separate preferences domain and an in-memory catalog:

```bash
# One-time: allow Xcode to drive the UI without an authorisation prompt
sudo automationmodetool enable-automationmode-without-authentication

xcodebuild -project PhotographersPocketKnife.xcodeproj -scheme PhotographersPocketKnifeUITests -destination 'platform=macOS' test
```

Integration tests run real uploads against local servers and decode real RAW files:

```bash
docker run -d --name ppk-sftp -p 2222:22 atmoz/sftp ppk:ppkpass:::upload
docker run -d --name ppk-ftp -p 2121:21 -p 21000-21010:21000-21010 -e USERS="ppk|ppkpass" -e ADDRESS=localhost delfer/alpine-ftp-server
docker run -d --name ppk-webdav -p 8088:80 -e AUTH_TYPE=Basic -e USERNAME=ppk -e PASSWORD=ppkpass bytemark/webdav
docker run -d --name ppk-s3 -p 9100:9000 -e MINIO_ROOT_USER=ppkadmin -e MINIO_ROOT_PASSWORD=ppkpass123 quay.io/minio/minio server /data
curl -X PUT --user ppkadmin:ppkpass123 --aws-sigv4 "aws:amz:us-east-1:s3" http://localhost:9100/ppk-bucket

TEST_RUNNER_PPK_INTEGRATION=1 TEST_RUNNER_PPK_RAW_DIR=/path/to/raw/files \
  xcodebuild -project PhotographersPocketKnife.xcodeproj -scheme PhotographersPocketKnife -destination 'platform=macOS' test
```

## 📄 License

Distributed under the MIT License. See [LICENSE](LICENSE) for details.

## 👨‍💻 Author

**David Arsénio Martins**

- 🌐 Website: [ividi.dev](https://ividi.dev/)
- 🐙 GitHub: [@VidiPT89](https://github.com/VidiPT89/)

## 🤝 Contributing

Contributions, issues and feature requests are welcome. Feel free to check the [issues page](https://github.com/VidiPT89/PhotographersPocketKnife/issues).

---

<p align="center">Developed by <a href="https://ividi.dev">David Arsénio Martins</a></p>
<p align="center">⭐ If you like this project, give it a star!</p>
