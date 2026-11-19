# MX2 control coverage (Syndicate 0.3.10)

This inventory describes the **software mapping**, not a hardware acceptance test. Paths below omit `/Syndicate`. `n` is the selected logical deck; SHIFT, bank selection and platter touch belong to the physical side. See `Sources/MX2Native/MX2Mapping.swift` for exact packet arguments and `MX2Decoder.swift` for report indices.

| Control | What the bridge sends |
| --- | --- |
| PLAY; SHIFT + PLAY | `Deck/{n}/PlayPause`; `GridStart` |
| CUE; REVERSE | `Deck/{n}/Cue`; `Reverse`, with press and release |
| SYNC; MASTER | `Deck/{n}/TempoSync`; `TempoMaster` |
| KEYLOCK; FLUX | `Deck/{n}/PitchPreserve`; `CueSlip`, toggled per deck |
| Browser buttons (`favorite`, `addToList`); VIEW | `Browser/Navigation/Left`, `Enter`; cycle `Header/Browser` through embedded, detached and hidden |
| BROWSE turn; press | `Browser/Navigation/Up` or `Down` per tick (SHIFT: `Left` or `Right`); `Browser/L{n}` loads the selection |
| MOVE turn; press | `Deck/{n}/BeatSkip`; `LoopIn` |
| SIZE turn; press | `Deck/{n}/LoopIn` or `LoopOut` (SHIFT: `LoopMoveBeat`); `Loop` |
| Hotcue pads; SHIFT + pad | `Deck/{n}/HotCue` press and release; `SetCueLoop` on press |
| Loop pads | Hold `Deck/{n}/SlipLoop/{size}` |
| Pattern pads; SHIFT + pad | Select `Sampler/Lane` (0–7); toggle mute via `Sampler/LaneSet` (1–8). Selection does not trigger a sample. |
| Platter | `PhaseBend` by direction, `WaveformSeek` when touched, zoom in/out with SHIFT. Seek is absolute track position, not vinyl scratch velocity. |
| GFX toggle; headphone CUE | `Mixer/CH{n}/FX`; `Mixer/CH{n}/Cue`, toggled per deck |
| FX knobs; two `fxAssign` buttons per side | Continuous `Mixer/CH{n}/FX/Macro/{i}`; the buttons currently set macro 1 or 2 to full, not an effect-enable switch |
| Gain, EQ, channel filter and channel volume | `Mixer/CH{n}/Trim`, `EQ/{High,Mid,Low}`, `Filter1`, `Volume` |
| Master volume, cue mix and cue volume | `Header/MasterVolume`, `CueMix`, `CueVolume` |
| Tempo slider | `Deck/{n}/TempoSlider` (−1 to +1) |

**Local only:** SHIFT, bank selectors, turntable/jog-mode buttons and jog touch send no standalone OSC packet. Touch and SHIFT select the platter route; the turntable/jog-mode flag does not select a different OSC scratch algorithm.

**Unmapped:** crossfader, preview, microphone, centre filter button, stems pads, the four `fxButton` controls per side, and global Quick Effect preset buttons. No matching route is documented for their intended function. Do not emulate a crossfader with channel volumes or stems with insert macros.

## Open checks

- Verify the remaining button labels and report bits with the physical deck. In particular, distinguish `fxAssign` from `fxButton` by position and confirm whether punching macro 1/2 to full is wanted before changing it.
- Verify press, release and audible response on loaded tracks. Packet tests cannot establish what the host accepted or when the audio changed.
- Compare local toggle state with Syndicate after changing a switch in the host UI or reconnecting. A controller-side toggle test does not establish resynchronization.
