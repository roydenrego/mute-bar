# MuteBar

<p align="center">
  <img src="docs/logo.png" width="128" alt="MuteBar logo">
</p>

<a href="https://chromewebstore.google.com/detail/mutebar/jdnohcgdlpndiinaklmckmaonpjimkfg"><img src="docs/badge-chrome-web-store.png" alt="Available in the Chrome Web Store"></a>

<!-- Hero screenshot TODO: capture the menu bar dropdown during a Meet call, save as docs/screenshot.png, then uncomment:
<img src="docs/screenshot.png" width="360" alt="MuteBar menu bar showing live Meet mute state">
-->

A macOS menu bar app + browser extension that gives you one **global hotkey (F6)** to mute/unmute **Google Meet** — at the *app level*, so your microphone keeps working for everything else (speech-to-text, dictation, recording).

## Getting started

1. Download [MuteBar.dmg](https://github.com/sfdye/mute-bar/releases/latest/download/MuteBar.dmg) from [Releases](https://github.com/sfdye/mute-bar/releases), open it, and drag **MuteBar** into **Applications**. First launch: right-click → **Open**. A mic icon appears in the menu bar.
2. Install the [Chrome extension](https://chromewebstore.google.com/detail/mutebar/jdnohcgdlpndiinaklmckmaonpjimkfg).
3. Join a Google Meet call and press **F6**, or press your AirPods stem. MuteBar clicks Meet's own mic button (so participants see you muted) and the menu bar icon mirrors the state — "Mic on", "Muted", or "No active meeting".

While you're in a meeting, the menu bar icon doubles as a status readout:

- **Browser: connected / not connected** — whether the extension is talking to the app (if not, check the extension is installed and the app is running).
- **Mute shortcut: F6** — the current hotkey. Pick **Change Shortcut…** to record any combo (letters need ⌘/⌥/⌃).
- **Mute with AirPods stem press** — on by default; see [AirPods stem press](#airpods-stem-press).
- **Start at Login** — keep MuteBar running from the get-go.

If pressing F6 does nothing, it's usually the function-key setting: enable "Use F1, F2, etc. keys as standard function keys" or hold **Fn** (see Notes). If the menu bar says "Browser: not connected", reload the extension or restart the browser after first installing the app.

## How it works

```
global hotkey ─┐                      click Meet's own mute button
               │                            ▲
AirPods stem ──┤                            │
               ▼                            │
MuteBar.app ──unix socket── mutebar-host ──stdio── browser extension ── content script
   ▲                                                        │
   └──────────── state updates (muted / live / no meeting) ──┘
```

- **MuteBar.app** — menu bar agent (Swift). Owns the triggers and shows true Meet mute state.
- **mutebar-host** — native messaging host embedded in the app bundle; bridges the extension to the app.
- **Extension** — content script toggles Meet's own mic button (so the UI and participants see the real state); a MutationObserver pushes state changes back.

### AirPods stem press

On iPhone, pressing an AirPods stem mutes the call. On a Mac it does nothing in a
browser call, and macOS puts up "Cannot Control Mic with AirPods".

macOS delivers the gesture in-process, to whichever app is *capturing* from the
accessory, through
[`AVAudioApplication.setInputMuteStateChangeHandler`](https://developer.apple.com/documentation/avfaudio/avaudioapplication/setinputmutestatechangehandler(_:)).
For a browser call that app is the browser, and neither Chrome nor Safari
registers a handler — hence the banner. There is no API for a bystander process
to observe the gesture.

So MuteBar becomes a capturing app. During a meeting it opens an input tap and
discards every buffer; pulling audio is what makes macOS count it as recording,
which is the precondition for the handler being invoked at all. Returning `true`
from the handler is what suppresses the banner, and the resulting mute state is
mirrored back with `setInputMuted(_:)` so the accessory plays the right tone.

**No audio is kept.** The tap body is empty — nothing is copied, written or sent
— and it only runs while a meeting is live, so the mic indicator appears only
alongside the one the browser is already showing.

Where the handler is unavailable (microphone denied, or macOS 13, which predates
the API) MuteBar falls back to watching the unified log, where `bluetoothd`
records every press. Both paths share one 500 ms dedup so a press reported twice
toggles once.

#### Limitations

- **macOS still plays its "unsupported" tone.** The browser is capturing too and
  doesn't handle the gesture, so the press is unhandled as far as that client is
  concerned. MuteBar can claim the gesture on its own behalf but cannot do so for
  the browser. The banner is suppressed; the tone is not. The real fix is browsers
  adopting the API.
- **Mute is reported optimistically.** The handler returns `true` before the
  extension has clicked Meet's button, because the system expects an immediate
  answer. If the click failed you would get a confirming chime while staying live.
- **The log fallback needs an admin account** and matches an undocumented message.
  Apple can rename it in any release; the menu says when it is in use.
- **The gesture needs microphone permission.** Denied, you keep muting via the
  log fallback but the banner returns.
- **AirPods only.** Tested with AirPods Pro on macOS 27; other accessories
  reporting mute control may work but are unverified.

## Development

```bash
git clone <repo> && cd mute-bar
scripts/build-app.sh                  # swift build + assemble MuteBar.app
```

Then:
1. `chrome://extensions` (or `arc://extensions`) → Developer mode → **Load unpacked** → select `extension/`
2. Start `MuteBar.app` (registers the native messaging host itself on launch)
3. Join a Google Meet call, press **F6** (change it via the menu-bar "Change Shortcut…" item — press any combo to record it)

```bash
swift build                       # build app + host
scripts/build-app.sh              # assemble .build/app/MuteBar.app
scripts/smoke-test.sh             # app <-> host round trip, no browser needed
scripts/package-dmg.sh            # .build/MuteBar.dmg
swift scripts/gen-icons.swift      # regenerate extension icons into extension/icons/
scripts/package-extension.sh      # Chrome Web Store zip into dist/ (strips the dev key)
```

Signing and notarization are done locally (Developer ID + `notarytool`); releases are published manually. Store submission copy and checklist: [docs/store-listing.md](docs/store-listing.md).

## Roadmap

- [ ] More locales for Meet's mic-button labels
- [ ] Zoom / Teams web support (the extension already matches on meet.google.com only)
- [ ] More stores: Firefox Add-ons (AMO) / Edge Add-ons

## Notes

- F6 as a raw function key requires "Use F1, F2, etc. keys as standard function keys" (or holding Fn), otherwise macOS may route it to a media function.
- Meet's in-call mic toggle is a `<button role="button" aria-label="Turn on/off microphone">`; the prejoin uses `div[role=button]`. The content script matches both, prefers the "turn on/off" label, and falls back to a broad localized regex.
- Meet removes the toolbar buttons from the DOM when controls auto-hide. The content script keeps the last observed mute state (sticky) and, if the button is missing on toggle, wakes the toolbar with a synthetic mousemove before clicking.
- The "You left the meeting" screen keeps the meeting URL; it is detected via its Rejoin / "Return to home screen" buttons.
- Chrome 151+ requires `allowed_origins` (chrome-extension URL patterns) in the native host manifest — `allowed_extensions` alone is rejected. The app writes both when it registers (Firefox needs `allowed_extensions`).
- State is aggregated across tabs in the service worker: any tab in a meeting wins, so a stale Meet tab can't clobber the live call's state.
- Meet's keyboard-shortcut state ("⌘ + d") is displayed in the button label; MuteBar clicks the button rather than synthesizing key events.
- Known edge: pressing F6 twice within ~300ms may land on muted (Meet's toggle lags the DOM label); debounce if it bothers you.
