# Indirect Input

A little protocol DI box: Traktor MX2 in, clean OSC out. A native macOS app that
bridges the controller’s HID controls to Syndicate and sends RGB feedback back to
the deck. No MIDI mapping, virtual MIDI device, or third-party Swift packages.

## Plug in

1. Connect the MX2 over USB and open **Indirect Input.app**. Use native mode, not MIDI mode.
2. In Syndicate, enable **OSC INPUT** on port **9090**.
3. Choose decks **1 + 2** or **3 + 4** in Indirect Input. The pad-bank menu sets both sides;
   the hardware bank buttons still work independently.

### The one easily missed thing: subscribe to feedback

**In Syndicate → Settings → OSC FEEDBACK, tick the SUBSCRIPTIONS and set the
destination to `127.0.0.1:9096`. Without subscriptions, nothing lights from feedback.**

Start with Playing, PlayPending, Item Info, Cues, Loop, Meter and PlayerType; add the
sampler values if you use them. Click **RESEND STATE** in Syndicate or **Resend feedback**
in the bridge. An empty deck has little to report: load a track before judging the lights.

## What works / what doesn’t

- **Implemented:** browser navigation/loading, transport, mixer levels/EQ/filter knobs,
  hotcues, slip loops, sampler lane selection/mute, and feedback-driven RGB/meters.
- **Deliberately unmapped:** crossfader, preview, microphone, centre filter button,
  stem pads and Quick Effect preset selection. Syndicate’s OSC API has no matching routes.
- **Not promised:** complete hardware verification of every control, sample triggering
  from the sampler pads, or RGB delivery merely because a write was accepted.
- **MIDI Browse is retired from the UI.** Its legacy code and CLI test remain for later cleanup.

The window shows HID, feedback and RGB status plus OSC/render counts. Use **Reveal
diagnostic log** for `~/.local/state/indirect-input/native-events.log`.

## Build & run

Requires macOS 13+ and Xcode’s Swift 6 toolchain.

```sh
swift test
./scripts/build-app.sh --install
open "$HOME/Applications/Indirect Input.app"
```

Without `--install`, the script only builds `dist/Indirect Input.app`. Bundles are
ad-hoc signed, not notarized. OSC defaults to `127.0.0.1:9090`; expand **OSC destination**
to change it. Feedback always listens locally on **9096**; do not run a second listener there.

The patch-cable icon lives in `Resources/AppIcon.svg`; `bash Resources/build-icon.sh`
regenerates its PNG/iconset/ICNS with librsvg (or Nix), `sips` and `iconutil`.

Co-authored workflow notes: load the **`midi-osc-controller-bridge`** skill for protocol
evidence, feedback gotchas and packaging details.
