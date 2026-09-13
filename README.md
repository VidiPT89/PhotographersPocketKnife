# Photographer's Pocket Knife 🔪📷

> A native macOS photography workflow app: cull like Photo Mechanic, develop RAW files non-destructively, and deliver over FTP/SFTP/S3 — all in one window, one catalog, no round trips.

[![Report Bug](https://img.shields.io/badge/Report-Bug-red)](https://github.com/VidiPT89/PhotographersPocketKnife/issues)
[![Request Feature](https://img.shields.io/badge/Request-Feature-blue)](https://github.com/VidiPT89/PhotographersPocketKnife/issues)

## ✨ Features

### 🗂️ Cull — pick the keepers, fast
- ✅ Import from a folder or memory card, optionally copying into date-based subfolders — or just open a folder from Finder
- ✅ Thumbnail grid with adjustable size, backed by a memory + disk cache that reads the camera's embedded preview first
- ✅ Loupe view with filmstrip, and side-by-side compare of 2 or 4 frames
- ✅ Star ratings (0–5), pick/reject flags and colour labels, all on the keyboard with Photo Mechanic–style defaults
- ✅ Every culling shortcut can be remapped in Settings
- ✅ Filter and sort by rating, flag, colour label, camera, lens, file name and capture time
- ✅ Batch rename with templates (`{date}`, `{time}`, `{seq}`, `{event}`, `{name}`, `{camera}`) and conflict detection
- ✅ Batch IPTC — title, caption, creator, copyright, keywords, city and country — written without recompressing, with XMP sidecars for RAW
- ✅ Duplicate and near-duplicate detection using perceptual hashing
- ✅ Live histogram and EXIF panel

### 🎛️ Develop — non-destructive editing
- ✅ Every photo keeps an edit recipe — the original file is never touched
- ✅ GPU pipeline on Core Image and Metal, with RAW decoding through `CIRAWFilter` (tested with Canon CR3, Nikon NEF, Sony ARW and Fujifilm RAF)
- ✅ Exposure, contrast, highlights, shadows, whites, blacks, temperature, tint, vibrance, saturation, sharpening, noise reduction and vignette
- ✅ Tone curve (RGB + per channel) and HSL across eight colour bands
- ✅ Crop with aspect presets and rule-of-thirds or golden-spiral overlays, straighten, rotate, flip, perspective and automatic lens correction for RAW
- ✅ Visual history timeline with undo/redo
- ✅ Presets, plus copy and paste settings across a whole selection
- ✅ Before/after toggle and draggable split view

### 📤 Deliver — export and upload
- ✅ Export to JPEG, HEIC, TIFF (8/16-bit), PNG and linear DNG, with resize, file suffix and metadata options
- ✅ Saved export presets and one-step export & upload
- ✅ FTP, FTPS, SFTP (system OpenSSH, with keys or password) and S3-compatible destinations
- ✅ Passwords stored in the macOS Keychain, never on disk, with a built-in connection test
- ✅ Remote folders built from templates (`{date}`, `{year}`, `{month}`, `{day}`, `{event}`)
- ✅ Transfer queue with per-file and overall progress, pause/resume, automatic retries with back-off and native notifications
- ✅ Upload history, and drag photos onto a destination in the sidebar to send them straight away

### 🎨 Everywhere
- ✅ Runtime language switch — Português (PT-PT) and English, no restart needed
- ✅ Dark mode, Light mode and System mode
- ✅ Colour identity from [ividi.dev](https://ividi.dev/) — orange, burnt yellow and black
- ✅ Animated splash screen with developer credits, then straight into the app
- ✅ Spring animations, hover effects and toasts throughout, with full Reduce Motion support
- ✅ Automatic updates

## 🛠️ Tech Stack

| Category | Technology |
|----------|------------|
| Language | Swift 6 |
| UI | SwiftUI + AppKit |
| Rendering | Core Image + Metal |
| RAW decoding | `CIRAWFilter`, ImageIO |
| Catalog | SwiftData |
| Transfers | curl (FTP/FTPS/S3), OpenSSH `sftp` (SFTP) |
| Credentials | Keychain Services |
| Updates | Sparkle |
| Architecture | MVVM with `@Observable` |
| Project | XcodeGen |
| Tests | XCTest |
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

1. Watch the splash screen, then press `⌘I` to import a folder or card — or drop a folder onto the window
2. In **Cull**, move through the take with the arrow keys, rate with `0`–`5`, mark keepers with `P` (or `X` to reject, `U` to clear) and label with `6`–`9` or `V`
3. Press `Space` for the loupe and `C` to compare the selection side by side
4. Switch to **Develop** (`⌘2`) — adjust, crop, check the result against the original in split view, and undo with `⌘Z`
5. Copy the settings and paste them across the rest of the selection, or save them as a preset
6. Press `⌘E` to export, and tick **Upload after exporting** to send the files to a saved destination
7. Watch the queue in **Deliver** (`⌘3`) — pause, resume or retry failed files at any time
8. Change language and appearance at any time from the top bar

## 🧪 Testing

```bash
xcodebuild -project PhotographersPocketKnife.xcodeproj \
           -scheme PhotographersPocketKnife \
           -destination 'platform=macOS' test
```

Unit tests cover the edit pipeline (curves, HSL, LUTs, rendering, DNG export), history, batch renaming, IPTC writing, duplicate detection, filters, shortcuts, localisation and a 10 000-photo catalog.

Integration tests run real uploads against local servers and decode real RAW files:

```bash
docker run -d --name ppk-sftp -p 2222:22 atmoz/sftp ppk:ppkpass:::upload
docker run -d --name ppk-ftp -p 2121:21 -p 21000-21010:21000-21010 -e USERS="ppk|ppkpass" -e ADDRESS=localhost delfer/alpine-ftp-server
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
