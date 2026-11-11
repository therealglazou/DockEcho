# DockEcho 1.2.2

Your Dock, echoed on every screen. DockEcho mirrors the macOS Dock on every display except
the one currently showing the real Dock (an option in the menu bar menu adds that one too),
and shows window previews above the icons of the real Dock and of every copy.

*Imagined by Daniel Glazman, created by Anthropic Claude.*

## Build
Requirements: macOS 12.3+, Xcode 15+ or the matching Command Line Tools (`xcode-select --install`).

    ./build.sh --install

This builds DockEcho.app, copies it to `/Applications` (quitting and replacing any copy that
is running) and launches it from there. Plain `./build.sh` only builds the app in the project
folder.

**Run DockEcho from `/Applications`.** macOS ties the privacy permissions (Accessibility,
Screen Recording) to the app and to where it is launched from. Launched from the project
folder, the app is replaced at every build; a downloaded copy may even be run by macOS from a
hidden temporary location (Gatekeeper's "app translocation"). In both cases the permissions
can look granted in System Settings and still not work, and the window previews stay empty.
From `/Applications`, they hold.

A menu bar icon gives access to: About, Dock Settings… (opens System Settings > Desktop & Dock), Refresh Dock, Also Show on the Display with the Real Dock, Open Apps on DockEcho's Display, Show Window Previews, Permissions, Copy Diagnostics, Quit.

Bundle identifier: `com.glazou.DockEcho` · Version: 1.2.2

## Multiple displays (fixed in 1.2)
- One copy per display, identified by its display ID: plugging, unplugging or rearranging
  displays keeps the existing copies, adds or removes only what changed, and is applied once
  macOS has finished reconfiguring (a first pass after 0.3 s, a second after 1.5 s).
- The display without a copy is the one that currently shows the real Dock. macOS moves the
  real Dock to another display when you push the pointer against its bottom edge; DockEcho
  follows it (through the Accessibility API, checked every second). Without Accessibility
  access, the primary display is assumed.
- If a display still gets no copy, use **Copy Diagnostics** in the menu and paste the result
  into a bug report: it lists the displays, the copies and their frames.

## Clicking an icon in a copy
- Running apps are activated through LaunchServices, like the real Dock (which also sends the
  app a "reopen"): since macOS 14, `NSRunningApplication.activate()` is ignored when called from
  an app that is not active, and DockEcho never is.
- **Open Apps on DockEcho's Display** (menu, off by default): when the app has no window on the
  display whose copy was clicked, its main window is moved and centered there (shrunk if
  needed); if it already has one there, that window is raised. For an app being launched,
  DockEcho waits up to 15 s for its first window. Needs Accessibility access; the menu shows
  a "Grant … Access" item when the permission is missing.

## Window previews (new in 1.2)
Hover an app's icon, in the real Dock or in any copy: after 0.3 s its windows appear above
the icon as thumbnails (beside it when the Dock is on the left or right).
- Click a thumbnail to bring that window to the front **on the display of the Dock you used**:
  DockEcho un-minimizes it, moves it there if it is on another display (keeping its size
  and relative position), activates its app and raises it.
- Hover a thumbnail to show its close button. If the app asks to save first, the window is
  brought forward on that same display so the dialog can be seen.
- Moving to another icon switches the previews at once; clicking elsewhere or leaving the
  icon and the previews for a quarter of a second hides them.
- Toggle with **Show Window Previews** in the menu.

Permissions:
- **Accessibility** (called **Device Control and Data Access** since macOS 27) (required): lists, raises, moves and closes windows, and watches the
  real Dock's icons.
- **Screen Recording** (for the thumbnails): without it, each window shows its app icon and
  title instead. On recent macOS versions the system may ask again from time to time to
  confirm this access.
- Both are under Menu > Permissions; the menu uses the name of your macOS version.

### Permissions assistant
When a permission is missing at launch, DockEcho opens a window, centered on the screen,
instead of firing system prompts. It starts with a welcome page (the DockEcho icon, name,
credits and version), followed by one page per missing permission, each with what it is used for, a miniature
of the System Settings list showing DockEcho's switch, the steps, a live status (granted /
waiting) and an Open System Settings button. **Next** goes to the following page.
Screen Recording, which macOS only applies after the app is quit and reopened, comes last:
its page ends with **Quit & Reopen**. "Don't show at launch" turns the window off; it can
always be opened again from Menu > Permissions > Permissions Assistant…, or from the
"Grant … Access" item shown in the menu when a needed permission is missing.

### If a permission is granted but DockEcho does not see it
The checkmarks in Menu > Permissions reflect what actually works: DockEcho reads the Dock's
accessibility tree, and counts Screen Recording as granted once a capture has succeeded,
instead of trusting only what macOS reports (on macOS 27 and with rebuilt apps, the two can
disagree). Menu > Copy Diagnostics shows both values.

First, make sure DockEcho runs from `/Applications` (`./build.sh --install`). The other
usual cause is the signature. macOS ties these permissions to the app's signature; an
ad-hoc signature changes at every build, so System Settings still shows the old build as
allowed while the new one is refused. Either:
- sign with a stable identity: `build.sh` now picks the first code-signing identity in your
  keychain (a free "Apple Development" certificate from Xcode > Settings > Accounts > Manage
  Certificates is enough), or use `SIGN_IDENTITY="..." ./build.sh`; or
- after each rebuild, remove DockEcho from both lists with the − button (or run
  `tccutil reset Accessibility com.glazou.DockEcho` and `tccutil reset ScreenCapture com.glazou.DockEcho`),
  relaunch it and grant the permissions again.

Limits:
- Only windows of the current Space are listed (the Accessibility API does not expose others).
- Full-screen windows are raised but not moved.
- Thumbnails use ScreenCaptureKit on macOS 14+, and the older CGWindowListCreateImage
  (looked up at run time) on macOS 12.3–13.
- The window ID of an Accessibility window comes from `_AXUIElementGetWindow`, a private
  function used by most window managers.

## Staying in sync with the main Dock
The `com.apple.dock` preferences are watched continuously (notification + a check every second):
any change made in System Settings > Desktop & Dock, or to the pinned apps of the real Dock,
is applied to every copy within about a second.

Supported settings:
- Icon size (`tilesize`), magnification (`magnification`, `largesize`)
- Position on screen: bottom, left, right (`orientation`)
- Automatically hide and show (`autohide`, `autohide-delay`, `autohide-time-modifier`),
  with a fade in/out
- Launch animation (`launchanim`, bouncing icon)
- Indicators for running apps (`show-process-indicators`)
- Recent apps (`show-recents`) and "show only open applications" (`static-only`)
- Pinned apps, spacers (`spacer-tile`), folders/files (`persistent-others`), Trash

Not supported (no public API or too complex): minimized windows in the Dock, minimize effect,
stacks (fan/grid), notification badges, drag and drop.

## Notes
- Animations: each icon is a Core Animation layer driven by the display's refresh
  (CADisplayLink on macOS 14+, a 120 Hz timer on older systems), so the magnification
  stays smooth. Magnification follows the cursor with no lag and eases in and out only
  when the cursor enters or leaves.
- Trash: the real macOS Trash icons are used. To switch between the empty and full icons,
  DockEcho needs to read `~/.Trash`, which requires Full Disk Access
  (System Settings > Privacy & Security > Full Disk Access). Without it the empty icon is shown.
- Window Layouts (versions 1.1 to 1.2.1) has been removed. Layouts it saved can be deleted:
  `~/Library/Application Support/DockEcho/layouts.json`.
- To start at login: System Settings > General > Login Items > add /Applications/DockEcho.app.
