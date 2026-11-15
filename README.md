# indirect-input

A little protocol DI box for DJ hardware: it takes the MX2’s awkward MIDI signals and turns them into clean OSC controls that Syndicate understands.

This native macOS app currently turns the Traktor MX2’s relative browse encoder into Syndicate’s fixed OSC browser controls. It does not create a virtual MIDI device and does not alter your Syndicate MIDI mappings.

Native MX2 control is implemented: HID input for every advertised control plus an
RGB feedback renderer. Two caveats, both host-side rather than bridge-side: Syndicate
sends **no** feedback until you tick subscriptions in Settings → OSC FEEDBACK (see
Use), and Syndicate 0.3.10's OSC API has no crossfader route, so the MX2 crossfader is
intentionally unmapped rather than emulated.

## Use

1. Put the MX2 in MIDI mode by pressing both SHIFT buttons together.
2. Open **MX2 Syndicate Bridge.app**. The app connects to the physical Traktor MX2 and reconnects after unplug/replug.
3. In Syndicate, open **Settings → OSC**, enable **OSC INPUT**, set the listen port to **9090**, and save.
4. Turn the MX2’s browse encoder while watching Syndicate’s browser.

### Turning the lights on

The RGB feedback renderer is driven entirely by what Syndicate sends back, and
Syndicate sends **nothing** until you subscribe. In **Settings → OSC FEEDBACK**:

- set DEST IP `127.0.0.1` and PORT `9096`
- under SUBSCRIPTIONS, tick `Playing`, `PlayPending`, `Item Info`, `Cues`, `Loop`,
  `Meter`, `PlayerType` and the sampler values
- press **RESEND STATE** so the bridge gets a full snapshot immediately

`ColorPalette` needs no subscription; Syndicate sends it on connect and on resend, so
your cue colours are matched to the nearest MX2 colour automatically.

Verify the link without the UI: any UDP listener on `9096` receives nothing while
subscriptions are empty, and a burst of packets right after
`/Syndicate/Feedback/Resend`. Lights that stay dark are almost always this, not the
renderer.

With no feedback the controller is deliberately dark apart from the selected pad bank
— an LED only lights for state the bridge actually knows. Two controls are unmapped
by choice: the crossfader (Syndicate 0.3.10 has no OSC route, and faking it by writing
channel volumes fights the app's crossfader lock) and the centre filter button (audio
only; the channel filter *knobs* do work, via `/Mixer/CH{n}/Filter1`).

The default encoder is **CC 16 on either MIDI channel**, matching both MX2 browse encoders. The bridge accepts CC 16 and CC 19 so the other browse control can be selected under **Connection settings**. Click **Apply** after changing the CC or optional channel filter; settings persist across launches.

## Translation

- CC value 63 → `/Syndicate/Browser/Navigation/Up`, integer `1`
- CC value 65 → `/Syndicate/Browser/Navigation/Down`, integer `1`
- Optional Shift + turn → `Navigation/Left` and `Navigation/Right`
- Optional encoder press → `/Syndicate/Browser/L1` through `/L4`, depending on the chosen deck

The optional Shift modifier is Note 12, and encoder press is Note 30, both selected from the same MIDI channel. Only nonzero velocities count as presses. These MIDI assignments come from the MX2 Companion project’s machine-readable control profile; the physical CC 19 behavior was observed directly in Syndicate’s MIDI monitor.

The app sends one int32 argument over UDP to `127.0.0.1:9090` by default. Syndicate’s browser triggers re-arm themselves, so no release packet is needed.

## Build and test

```bash
swift test
swift run MX2CLITest
./scripts/build-app.sh
```

`MX2CLITest` uses two CoreMIDI clients to send CC 19 values 63 and 65 across a virtual source, and a real UDP listener on port 19090 to assert the corresponding OSC messages. It does not contact Syndicate.

For the MIDI/OSC workflow, protocol evidence and packaging pitfalls, load the
`midi-osc-controller-bridge` skill when working on this repository.

`scripts/build-app.sh` creates an ad-hoc-signed `dist/MX2 Syndicate Bridge.app`. It requires Xcode’s Swift toolchain on macOS; no third-party packages are used.

## Why this exists

Syndicate 0.3.10’s mapping editor supports absolute CC, notes and pitch wheel, but not NI’s Relative (Offset) 63/65 encoding. Its OSC API has dedicated browser Up/Down trigger addresses, which avoids trying to reinterpret those relative values as absolute MIDI positions.
