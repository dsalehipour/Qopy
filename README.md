<div align="center">

<img src="assets/icon-rounded.png" alt="" width="112">

# Qopy

**Move text between your Mac and Android phone with a QR code — no accounts, no cloud, no cables.**

<a href="https://github.com/dsalehipour/qopy/releases/latest/download/Qopy.zip"><img src="assets/download-button.png" alt="Download Qopy for macOS" width="234"></a>

<sub>Apple Silicon · macOS 26 or later ·
<a href="https://github.com/dsalehipour/qopy/releases/latest">release notes</a> ·
<a href="#build-from-source">build from source</a></sub>

</div>

<br>

Qopy lives in your menu bar. Select text on the Mac, send it as a QR, scan with your phone’s camera,
and copy. Or paste on your phone, show a QR, and let the Mac camera pull it onto the clipboard.

Native Swift. Liquid Glass panels. A tiny static webpage for Android — nothing to install on the
phone beyond a browser.

## Install

Apple Silicon, macOS 26 or later.

1. [**Download `Qopy.zip`**](https://github.com/dsalehipour/qopy/releases/latest/download/Qopy.zip),
   unzip it, and drag `Qopy.app` to Applications.
2. Open it. The first launch may be refused — the app is signed, but not notarized by Apple.
3. Go to **System Settings › Privacy & Security**, scroll to Security, and click **Open Anyway**.
4. When prompted, allow **Accessibility** (reading the current selection) and **Camera** (receive).

There is no Dock icon: look for the QR glyph in the menu bar.

### Build from source

Needs Xcode 26+ and a Swift 6 toolchain.

```bash
scripts/create-signing-identity.sh   # once per machine
scripts/build-mac.sh                 # Debug build → Mac/build/.../Qopy.app
open Mac/build/Build/Products/Debug/Qopy.app
```

For a Release zip (what GitHub Releases ships):

```bash
scripts/build-release.sh             # → dist/Qopy.app + dist/Qopy.zip
```

macOS pins Accessibility and Camera grants to the app’s signature. Ad-hoc signing changes every
build and silently drops those grants — hence the one-off local `qopy-dev` certificate. Grant
permissions once after the first stably-signed build.

## How it works

| Direction | What you do | What happens |
| --- | --- | --- |
| **Mac → Phone** | Select text, then **Send Selection to Phone** (or **⌃⌥⌘C**) | A Liquid Glass panel shows a QR. Scan with Android Camera / Lens → Copy |
| **Mac → Phone** | Copy text, then **Send Clipboard to Phone** | Same QR flow from the clipboard |
| **Phone → Mac** | On the phone page, paste text → QR appears | **Receive from Phone…** (**⌃⌥⌘V**) and point the Mac camera at it |

Esc or a click outside the panel dismisses it. Closing receive stops the camera immediately.

Text over **1200 UTF-8 bytes** is refused with a warning for now (chunking can come later).

### Services menu

After installing, **Services → Send to Phone with Qopy** is available on selected text in apps that
support Services. If it doesn’t appear yet, log out/in or run `/System/Library/CoreServices/pbs -flush`.

## Phone companion

The `Web/` folder is a static page: paste text and a QR renders automatically. No backend.

On the same Wi‑Fi as your Mac:

```bash
cd Web
python3 -m http.server 8765
```

Open `http://<your-mac-lan-ip>:8765` on the phone.

## Shortcuts

| Shortcut | Action |
| --- | --- |
| **⌃⌥⌘C** | Send current selection to phone |
| **⌃⌥⌘V** | Receive from phone (camera) |

## Development

```
Mac/Qopy/     Swift menubar app (Liquid Glass, Vision QR, Accessibility selection)
Web/          Mobile companion page
scripts/      build, release, signing identity, icon tooling
assets/       README artwork
```

Release to GitHub (after committing and pushing `main`):

```bash
scripts/release.sh
```

The release asset is always named `Qopy.zip`, so this link stays valid forever:

`https://github.com/dsalehipour/qopy/releases/latest/download/Qopy.zip`

## Privacy

Everything stays on your devices. QR payloads are the text itself (or a small `qopy:` encoding).
Nothing is uploaded. The phone page is static files you host or serve locally.

## License

MIT
