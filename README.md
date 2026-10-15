# Kindle Auto Brightness Bridge for KOReader

A lightweight KOReader plugin for Kindles with ambient light sensors (Oasis, Voyage, Paperwhite SE, Scribe) that keeps KOReader's brightness controls and frontlight on/off state in sync with the Kindle's native auto-brightness.

## The Problem

When you run KOReader on a Kindle, the Kindle OS still adjusts the screen's frontlight in the background based on ambient light. However, KOReader caches its own brightness level in memory and doesn't know when the hardware changes underneath it.

This leads to annoying jumps: the Kindle might dim the screen in a dark room, but the next time you swipe to adjust brightness in KOReader, KOReader starts from its old cached value and suddenly snaps the light back to that level.

## What this plugin does

This plugin makes KOReader's brightness and frontlight on/off queries read the live hardware intensity from Kindle's native power daemon (`powerd:frontlightIntensityHW()`). Frontlight toggles use that current state too, so a light re-enabled by native auto-brightness can be turned off with the next toggle.

- **Zero background polling**: It only queries the hardware when KOReader asks for the current brightness or on/off state (e.g. when you swipe, toggle the light, open the frontlight menu, or receive an OSD update). No background timers are added.
- **Optional live warmth synchronization**: On devices with a hardware warmth reader, a separate setting makes KOReader read the Kindle's actual current warmth whenever KOReader asks for it. It is disabled by default and does not choose or run a warmth schedule.
- **Lets Kindle OS do the heavy lifting**: The Kindle's native firmware handles the light sensor and ambient curves; this plugin just makes sure KOReader stays in sync.
- **Clean and reversible**: No KOReader core patches needed. You can toggle it on or off on the fly from KOReader's menu.

## Requirements

- A Kindle with a frontlight and ambient light sensor (e.g., Kindle Oasis 2/3, Kindle Voyage, Kindle Paperwhite Signature Edition, Kindle Scribe).
- Stock Kindle **Auto Brightness** enabled in the native Kindle settings before opening KOReader.
- A modern KOReader version.

*(If your Kindle doesn't have an ambient light sensor or frontlight, the plugin automatically disables itself and hides from the menu).*

## Installation

1. Copy the `kindleautobrightness.koplugin` folder into your Kindle's KOReader plugins directory:
   ```text
   koreader/plugins/kindleautobrightness.koplugin/
   ```
2. Restart KOReader.
3. Make sure **Auto Brightness** is turned on in the native Kindle swipe-down menu.
4. In KOReader, open the top menu and go to **More tools** (wrench icon) → check **Synchronize with Kindle Auto Brightness**.
5. On devices with hardware warmth support, optionally check **Synchronize with Kindle scheduled warmth**. This setting is independent of brightness synchronization and is disabled by default.

The plugin is disabled by default. Once brightness synchronization is checked, KOReader's brightness gestures and dialogs work as normal, but always start from the actual current light level.

## How it works

KOReader's generic power management (`PowerD`) keeps an internal `fl_intensity` cache and returns it whenever a widget or gesture calls `frontlightIntensity()`.

When enabled, this plugin hooks brightness and on/off queries on the active Kindle `PowerD` instance:
1. It queries the live hardware level via KOReader's Kindle LIPC interface (`frontlightIntensityHW()`).
2. If the light is on, it updates KOReader's cached `fl_intensity` and frontlight state to match the hardware.
3. If the light is off (`0` / minimum), it reports `0` while preserving the last remembered non-zero level so KOReader can restore it properly when turned back on.

If you adjust brightness manually inside KOReader, your manual change takes effect as usual, and the Kindle's auto-brightness algorithm adapts from the new baseline.

Native auto-brightness can still turn the frontlight back on after you turn it off. The bridge keeps subsequent KOReader state queries and toggles in sync with that change.

### Optional warmth synchronization

When **Synchronize with Kindle scheduled warmth** is enabled, the plugin wraps KOReader's public warmth read method and asks the Kindle for the current applied hardware warmth whenever KOReader needs it. It uses KOReader's existing hardware reader and conversion, updates only KOReader's cached warmth value, and does not write warmth merely to synchronize it.

This setting follows the warmth currently applied by the Kindle, including changes made by the Kindle's own schedule. It does not choose or run a schedule. If KOReader's AutoWarmth plugin is also enabled, the Kindle and KOReader schedulers remain independent; do not expect them to cooperate as one algorithm.

## Troubleshooting

- **Menu item doesn't appear under "More tools"**:
  Make sure the directory is placed at `koreader/plugins/kindleautobrightness.koplugin` and contains both `_meta.lua` and `main.lua`. If the files are in place, the plugin detected that the device is either not a Kindle or lacks an ambient light sensor / live frontlight read capability.
- **Brightness doesn't adjust automatically**:
  Check that native Auto Brightness was turned on in the stock Kindle OS before launching KOReader. If you enabled it while KOReader was already running, restart KOReader.
- **Debugging**:
  Enable debug logging in KOReader (**Settings** → **Device** → **Developer options** → **Enable debug log**) and look for messages starting with `KindleAutoBrightness:`.

## License

[MIT](LICENSE)
