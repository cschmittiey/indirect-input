# MX2 native protocol evidence

Recovered from the arm64 slice of Traktor Pro 4 installed at `/Applications/Native Instruments/Traktor Pro 4`, using a separate copy; the installed application was not modified.

## Input reports

The HID descriptor declares report 1 as 88 one-bit buttons followed by six four-bit encoders, 15 bytes including the report ID. Traktor's `MX2::Device` constructor instantiates `ButtonHandler` with **83 buttons** and `EncoderHandler` with **six encoders**. `ButtonHandler::process` reads the bits sequentially and emits the control ID stored at `handler.baseID + bitIndex`.

The `MX2PortDescriptor` constructor names the controls and gives their actual IDs. Relevant transport and bank IDs:

- left Cue 28, Play 29; right Cue 58, Play 59
- left Hotcues 16, Stems 17, Pattern 18, Loops 19
- right Hotcues 46, Stems 47, Pattern 48, Loops 49
- left pads 20...27; right pads 50...57

**Mixer block, measured against hardware.** Every ID below was confirmed by pressing
the physical control with `scripts/hid-probe.swift` and reading the bit that changed;
the results agree with `MX2Decoder.buttons` exactly. Note each control gets its own ID
per side — an earlier version of this document wrongly listed one shared ID for both
sides from 62 onward, which shifted the whole block:

- left FX assign 60/61, then channel FX 62, headphone Cue 63
- right FX assign 64/65, then channel FX 66, headphone Cue 67
- global FX 68...71
- Filter 72, microphone 73
- browse press 74/75, loop move 76/77, loop size 78/79, jog touch 80/81
  *(this final group is carried over from the descriptor and has not yet been
  hardware-verified; treat it as unconfirmed)*

The correct reading of the block is left-pair, then right-pair, then the centre
controls. There is no interleaving: 62 and 63 are the left side's channel FX and
headphone Cue, not a second global FX entry.

The remaining left/right deck controls occupy IDs 0...15 and 30...45 in the same order as the decoder table.

Important correction: an earlier investigation treated later raw report bytes as transport buttons and added special overrides. The Traktor descriptor proves that was wrong. Cue and Play are at IDs 28/29 and 58/59, with selectors at 16...19 and 46...49. Do not infer control identity from physical proximity or move bank selectors to accommodate a guessed transport position.

## Evidence addresses

- `NI::NHL2::Traktor::MX2::Device::Device`: `0x100d5fa0c`
- `NI::NHL2::Traktor::MX2::Device::readInputReports`: `0x100d60964`
- `NI::NHL2::ControllerDevice::process`: `0x100d627cc`
- `NI::NHL2::ButtonHandler::process`: `0x100d722e4`
- `csi::communication::nhl::MX2PortDescriptor::MX2PortDescriptor`: `0x100278f84`
- `NI::NHL2::Traktor::MX2::getLEDInfo`: `0x100d60b58`

Targeted disassemblies of these functions (`device-constructor.asm`, `process-report.asm`, `button-process.asm`, `port-descriptor.asm`, `led-map.asm`) were made from that copy and are not in this repo.

## RGB report

The device sends report ID `0x80` followed by a 105-byte LED frame. Traktor exposes `MX2::getLEDInfo` and `MX2::getLEDForControl`; the output report contains 105 LEDs and an 18-byte secondary region in its descriptor.

The established renderer layout is retained while feedback is developed. Inactive LEDs must be written as byte zero when true off is intended; palette `* 4` is dim, `* 4 + 2` is bright.

## Cue behavior in the companion

Deck transport Cue and mixer headphone Cue are distinct. Syndicate documents `/Syndicate/Deck/{n}/Cue` as **Hold**: the bridge sends 1 on press and 0 on release. `/Syndicate/Mixer/CH{n}/Cue` is a separate switch, toggled on each headphone-Cue press.

The app logs native input, outgoing OSC and status changes to `~/.local/state/indirect-input/native-events.log` (**Reveal diagnostic log**). It is diagnostic, includes analog-control traffic, and rotates to `native-events.1.log` past 8 MiB.
