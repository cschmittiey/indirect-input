# MX2 native protocol evidence

Recovered from the arm64 slice of Traktor Pro 4 installed at `/Applications/Native Instruments/Traktor Pro 4`. Analysis copy is under `~/.hermes/cache/scratch/mx2-re/`; the installed application was not modified.

## Input reports

The HID descriptor declares report 1 as 88 one-bit buttons followed by six four-bit encoders, 15 bytes including the report ID. Traktor's `MX2::Device` constructor instantiates `ButtonHandler` with **83 buttons** and `EncoderHandler` with **six encoders**. `ButtonHandler::process` reads the bits sequentially and emits the control ID stored at `handler.baseID + bitIndex`.

The `MX2PortDescriptor` constructor names the controls and gives their actual IDs. Relevant transport and bank IDs:

- left Cue 28, Play 29; right Cue 58, Play 59
- left Hotcues 16, Stems 17, Pattern 18, Loops 19
- right Hotcues 46, Stems 47, Pattern 48, Loops 49
- left pads 20...27; right pads 50...57
- mixer FX assign 60/61, channel FX 62/63, headphone Cue 64/65
- global FX 66...69, Filter 70, microphone 71
- browse press 72/73, loop move 74/75, loop size 76/77, jog touch 78/79

The remaining left/right deck controls occupy IDs 0...15 and 30...45 in the same order as the decoder table.

Important correction: an earlier investigation treated later raw report bytes as transport buttons and added special overrides. The Traktor descriptor proves that was wrong. Cue and Play are at IDs 28/29 and 58/59, with selectors at 16...19 and 46...49. Do not infer control identity from physical proximity or move bank selectors to accommodate a guessed transport position.

## Evidence addresses

- `NI::NHL2::Traktor::MX2::Device::Device`: `0x100d5fa0c`
- `NI::NHL2::Traktor::MX2::Device::readInputReports`: `0x100d60964`
- `NI::NHL2::ControllerDevice::process`: `0x100d627cc`
- `NI::NHL2::ButtonHandler::process`: `0x100d722e4`
- `csi::communication::nhl::MX2PortDescriptor::MX2PortDescriptor`: `0x100278f84`
- `NI::NHL2::Traktor::MX2::getLEDInfo`: `0x100d60b58`

Targeted disassemblies are saved beside the analysis copy as `device-constructor.asm`, `process-report.asm`, `button-process.asm`, `port-descriptor.asm`, and `led-map.asm`.

## RGB report

The device sends report ID `0x80` followed by a 105-byte LED frame. Traktor exposes `MX2::getLEDInfo` and `MX2::getLEDForControl`; the output report contains 105 LEDs and an 18-byte secondary region in its descriptor.

The established renderer layout is retained while feedback is developed. Inactive LEDs must be written as byte zero when true off is intended; palette `* 4` is dim, `* 4 + 2` is bright.

## Cue behavior in the companion

Deck transport Cue and mixer headphone Cue are distinct. Syndicate documents `/Syndicate/Deck/{n}/Cue` as **Hold**: the bridge sends 1 on press and 0 on release. `/Syndicate/Mixer/CH{n}/Cue` is a separate switch, toggled on each headphone-Cue press.

The Native tab logs native input and outgoing OSC to `~/.local/state/indirect-input/native-events.log`. This log is diagnostic and may contain analog-control traffic.
