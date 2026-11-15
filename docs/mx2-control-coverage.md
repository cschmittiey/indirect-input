# MX2 control coverage vs Syndicate 0.3.10

Every MX2 control, what the bridge sends today, and what the installed Syndicate build
actually exposes. Source of truth for the address universe is the 0.3.10 OSC reference
(sections 14.4–14.10); "dead" below means the address appears nowhere in that list, so
Syndicate silently ignores it.

Status legend: **done** wired and correct · **partial** wired but loses information ·
**dead** sends an address Syndicate does not have · **unmapped** nothing sent ·
**local** intentionally bridge-local, no OSC.

## Deck controls (per side)

| MX2 control | Today | Target | Status |
| --- | --- | --- | --- |
| PLAY | `/Deck/{n}/PlayPause` trigger | same | done |
| PLAY + Shift | `/Deck/{n}/GridStart` trigger | same | done |
| CUE | `/Deck/{n}/Cue` hold 1/0 | same | done |
| SYNC | `/Deck/{n}/TempoSync` trigger | same | done |
| MASTER | `/Deck/{n}/TempoMaster` trigger | same | done |
| KEYLOCK | `/Deck/{n}/PitchPreserve` int **1** | Switch: needs 0/1 from tracked state | partial |
| REVERSE | `/Deck/{n}/Reverse` int 1/0 | Switch: fine (sends pressed) | done |
| FLUX | `/Deck/{n}/CueSlip` trigger | Switch: needs tracked 0/1 | partial |
| TURNTABLE | none | local mode flag | local |
| JOG MODE | none | local mode flag | local |
| SHIFT | none | local modifier | local |
| FX 1–4 | `/Mixer/CH{n}/FX` for #1, `/FX/Macro/{n}` for 2–4 | same, but #1 should be a Switch with tracked state | partial |
| FAVORITE | `/Browser/Navigation/Left` | `Browser/Left` | done |
| ADD TO LIST | `/Browser/Navigation/Enter` | `Browser/Enter` | done |
| PREVIEW | `/Browser/Preview` int 1 | **address does not exist** | dead |
| VIEW | `/Header/Browser` int 1 | Index 0/1/2, needs tracked state | partial |
| Pads 1–8 (hotcues) | `/Deck/{n}/HotCue` i,i | same | done |
| Pads + Shift (hotcues) | `/Deck/{n}/SetCueLoop` i | same | done |
| Pads (stems bank) | `/Mixer/CH{n}/FX/Macro/{i}` | see stems section | partial |
| Pads (pattern bank) | none | see sampler section | unmapped |
| Pads (loops bank) | `/Deck/{n}/SlipLoop/{size}` hold | same | done |

## Mixer / centre

| MX2 control | Today | Target | Status |
| --- | --- | --- | --- |
| FX ASSIGN 1–2 | `/Mixer/CH{n}/FX/Macro/{i}` | same | done |
| CHANNEL FX button | `/Mixer/CH{n}/FX` int 1/0 | Switch with tracked state | partial |
| HEADPHONE CUE | `/Mixer/CH{n}/Cue` toggle | same | done |
| Global FX 1–4 | `/Mixer/CH{firstDeck}/FX/Macro/{i}` | per-deck pair target | partial |
| FILTER button | `/Mixer/filter{n}.cut` float 0.5 | **dead**; `Filter1Enabled` is feedback-only | dead |
| MICROPHONE | none | no OSC route exists | impossible |
| Browse press L/R | `/Browser/L{deck}` | same | done |
| Move press L/R | `/Deck/{n}/LoopIn` | same | done |
| Size press L/R | `/Deck/{n}/Loop` | same | done |
| Jog touch L/R | none | gates jog behaviour | unmapped |

## Encoders

| MX2 encoder | Today | Target | Status |
| --- | --- | --- | --- |
| BROWSE | `/Browser/Navigation/{Up,Down}` per tick | rename to `Browser/{Up,Down}` | done |
| BROWSE + Shift | `Navigation/{Left,Right}` | `Browser/{Left,Right}` | done |
| MOVE | `/Deck/{n}/BeatSkip` step | same | done |
| SIZE | `/Deck/{n}/Loop{In,Out}` per tick | same | done |
| SIZE + Shift | `/Deck/{n}/LoopMoveBeat` | `WaveformZoomIn`/`Out` is also plausible | partial |

## Analogs

| MX2 analog | Today | Target | Status |
| --- | --- | --- | --- |
| FX knobs 1–4 | `/Mixer/CH{n}/FX/Macro/{i}` | same | done |
| GAIN | `/Mixer/CH{n}/Trim` | same (note: 0.5 = 0 dB) | done |
| EQ high/mid/low | `/Mixer/CH{n}/EQ/{High,Mid,Low}` | same (0.5 neutral) | done |
| Channel filter | `/Mixer/CH{n}/Filter1` | same; `Filter2` (res/width) has no knob | done |
| Main volume | `/Header/MasterVolume` | same | done |
| Cue mix | `/Header/CueMix` | same | done |
| Cue volume | `/Header/CueVolume` | same | done |
| Channel volume | `/Mixer/CH{n}/Volume` | same | done |
| Crossfader | none | **no OSC route in 0.3.10** | impossible |
| Tempo | `/Deck/{n}/TempoSlider` −1..+1 | same | done |
| Jog wheel | `/Deck/{n}/PhaseBend` sign | `WaveformSeek` when touched | partial |

## Feedback gaps

State the renderer cannot show yet, ordered by value:

- `WaveformSeek` / jog position — no suggestion of scrub position on the LEDs
- Stems: nothing to light, because the bank currently sends FX macros
- Sampler lanes: `Lane`, `Steps`, `Mute` exist as feedback but are unused
- `TempoSliderEnabled` arrives but is ignored; could gate the tempo LED
- `Filter1Enabled` arrives but only drives the mixer LED

## Structurally impossible

Documented as impossible rather than left silently broken:

- **Crossfader** — no OSC route. Do not emulate with channel volumes: it fights the
  app's own crossfader lock.
- **Microphone** — no OSC route at all.
- **`Browser/Preview`** — not in the 0.3.10 OSC API.
- **`Filter1Enabled` write** — feedback only; writes are dropped.
- **Native FX routes** (`/Mixer/CH{n}/Reverb/…`) — accepted but do nothing.
