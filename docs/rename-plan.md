# Rename + MIDI removal plan

Decided while five agents were mid-flight on the current names. Do this **only after
every agent has landed and the tree is green and quiet**, because it touches
`Package.swift` and every module boundary.

## Why it was deferred

Renaming Swift targets means editing `Package.swift`, renaming directories, and
updating every `import` across Sources and Tests. Any agent holding an open edit at the
time would either conflict or silently write to a path that no longer exists.

## Target map

The package is already called `IndirectInput`; only the executable module is stale.

| now | after | notes |
| --- | --- | --- |
| `MX2SyndicateBridge` | `IndirectInputApp` | executable target; "App" suffix avoids a module/directory named identically to the package |
| `BridgeCore` | `IndirectInputCore` | |
| `MX2Native` | keep | describes the protocol, not the product |
| `MX2Feedback` | keep | same |
| `MX2CLITest` | **delete** | MIDI-only scratch harness |
| `Sources/MIDITestSource` | **delete** | MIDI-only |
| `Tests/MX2SyndicateBridgeTests` | `IndirectInputAppTests` | keeps the 6 OSC-bridge tests |

## MIDI removal

The MIDI path is inert once the UI drops its tab. Removing it properly:

- delete `Sources/MX2SyndicateBridge/MIDIMonitor.swift`
- delete `Sources/MX2CLITest/` and `Sources/MIDITestSource/`
- delete `Sources/BridgeCore/MIDIEvent.swift`, `MIDIUtilities.swift`
- drop `MX2CLITest` from `Package.swift`
- tidy `BridgeModel` of the dead `MIDIStatus` surface

**Do not** delete `BridgeCore/OSCMessage.swift` — the OSC sender lives there and the
bridge needs it.

Check before deleting each file: `grep -rl "<file symbols>" Sources Tests`.
`MX2Feedback/OSCMessage.swift` is a *different* OSCMessage type from
`BridgeCore/OSCMessage.swift`; keep both.

## Rename steps (order matters)

1. `git mv Sources/MX2SyndicateBridge Sources/IndirectInputApp`
2. `git mv Tests/MX2SyndicateBridgeTests Tests/IndirectInputAppTests`
3. `git mv Sources/BridgeCore Sources/IndirectInputCore`
4. Edit `Package.swift`: target names, paths, dependencies
5. `grep -rl 'import MX2SyndicateBridge' | xargs sed -i '' 's/import MX2SyndicateBridge/import IndirectInputApp/'`
   then the same for `import BridgeCore` → `import IndirectInputCore`
   and `@testable import` forms
6. `swift build && swift test` — all suites green
7. `./scripts/build-app.sh`, confirm `dist/Indirect Input.app`, reinstall
8. Verify the deck still lights (the HID report ID and lamp tables are untouched by a
   rename, but confirm rather than assume)

Use `git mv`, never `mv` — plain moves lose rename detection and make the diff
unreviewable.

## Things a rename must not change

- HID report ID `0x80` with the prefixed ID byte (hard-won; see `MX2HIDDevice.ledReportID`)
- Mixer lamp block 61–73 at the measured `button + 1` offset
- The `logNative("STATUS …")` diagnostics chain
- `MX2Feedback`'s OSCMessage distinct from `BridgeCore`'s

## Verification

- `swift test` green across every suite
- `git diff --stat` shows renames, not delete+add, for directory moves
- app launches and the deck lights
- `grep -rn "MX2SyndicateBridge" Sources Tests Package.swift` returns nothing
