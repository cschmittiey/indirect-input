# Latency of the Indirect Input OSC path

A reproducible, hardware-free benchmark of the release build's input path:

```
HID-shaped report bytes → MX2Decoder → MX2NativeController.handle → MX2Mapping
  → OSCMessage.packet → UDP loopback → OSCParser
```

Everything in that chain is production code. The only substituted component is the
send syscall — see [What this does not measure](#what-this-does-not-measure).

## Run it

```sh
swift test -c release --filter MX2LatencyBenchmarkTests
```

Release mode is not optional. A debug build is dominated by unoptimised Swift and its
numbers say nothing about the shipped app.

To capture machine-readable results:

```sh
INDIRECT_INPUT_BENCH_JSON="$PWD/.build/latency.json" \
  swift test -c release --filter MX2LatencyBenchmarkTests
```

The test is self-contained: it opens no device, needs no Traktor or Syndicate, and
binds only ephemeral loopback ports. It prints the endpoints it used on every run.

## Endpoints

Both sockets bind `127.0.0.1:0`, so the kernel assigns the ports and each run reports
its own pair:

```
udp endpoints   127.0.0.1:56797 → 127.0.0.1:51465  (SO_RCVBUF 8388608 bytes)
```

The test asserts that neither port is **9090** (the app's OSC destination) or **9096**
(its feedback listener), and that both are above 1023. The app's fixed ports are never
touched, so a benchmark run cannot disturb a live session.

`SO_RCVBUF` is raised to 8 MiB. The default loopback buffer is a few hundred kilobytes,
which an unpaced burst overruns; the kernel then drops silently and the run would report
a transport artifact as if it were app behaviour. The staged pass asserts zero datagrams
are left queued, so a buffer problem surfaces as a failure rather than as a fake number.

## Corpus

Deterministic and generated in-process: 2,336 reports producing 1,902 OSC messages over
20 cycles, plus a one-shot semantics phase.

The corpus is a report script built from absolute snapshots, using the byte layouts the
decoder documents — report 1 is 82 button bits plus six 4-bit encoder nibbles, report 2 is
26 little-endian 12-bit axes, report 3 is two little-endian u32 platter counters. Reports
are derived from generator state, so replaying the script reproduces byte-identical input;
only the measured times vary.

Coverage is the whole mapped surface: transport, hotcues, slip loops, sampler lanes, all
26 analog axes, all six encoders, platter seek and bend, both deck sides, and the pinned
deliberate silences (deck FX 1–4, global FX, crossfader, preview, filter, microphone,
stems bank). Silences are asserted, not merely skipped: a benchmark that quietly stopped
checking them could hide a regression into an address that should not exist.

In process prefix is measured on the same reports the end-to-end pass sends, and the wire
addresses are compared against the script after the UDP hop — so the timed pass is
provably the corpus, not a lookalike.

## Results

Apple M3 Pro, macOS 27.2.1, Swift 6.4.2, release. Medians and observed ranges across four
consecutive runs of the final test; per-run spread is normal scheduler and cache noise on a
laptop, so quote the range rather than a single run.

### Serialized end-to-end

One message set in flight at a time: decode, map, encode, `sendto`, receive, parse. n=1842
per run.

| measurement | p50 µs | p90 µs | p99 µs | max µs |
| --- | --- | --- | --- | --- |
| full path (decode→map→encode→UDP→parse) | 17.3 (16.8–18.2) | 25.0 (19.8–33.1) | 40.3 (27.0–62.9) | 100.5 (83.3–128.3) |
| in-process prefix (decode→map→encode) | 1.32 (1.25–1.33) | 1.8 | 2.8 | 16.9 |

The end-to-end figure is **dominated by the loopback round trip, not by the bridge.** A
null-path control measures the identical send/receive loop with a pre-encoded constant
packet and no decode, map, encode or parse:

| | p50 µs | p90 µs | p99 µs |
| --- | --- | --- | --- |
| null-path control (n=2000) | 11.25 (11.2–11.8) | 12.6 | 19.3 |
| **bridge share of the serialized p50** | **6.1 (5.1–7.0)** | | |

So of a ~17 µs serialized round trip, roughly 6 µs is the bridge and ~11 µs is the
harness plus kernel turnaround. Treat the end-to-end number as an upper bound with a
known overhead floor, and the stage table below as the real attribution.

### Stage costs, isolated

Per operation, over 4,000 reports.

| stage | ns/op |
| --- | --- |
| decode (report → events) | 352 |
| map (event → OSC, controller state) | 441 |
| encode (`OSCMessage` → datagram) | 270 |
| parse (datagram → arguments) | 508 |
| `sendto` (packet → kernel) | 4176 |

`sendto` is an order of magnitude above every other stage: the bridge's own per-message
work — decode plus map plus encode, amortised over the 1.70 messages each report produces
— is about 0.9 µs. Note the parse cost is measured on the same loopback socket the app
writes to, so it reflects what a local OSC receiver pays; it is not part of the app's own
egress cost.

### Paced stream at hardware cadence

2,000 reports at 1 kHz (2 s), finger on the platter, receiving every message.

| | value |
| --- | --- |
| reports / packets / received | 2000 / 3397 / 3397 |
| lost | 0 |
| steps over the 1 ms interval | 0–15 |
| latency p50 / p99 / max | 43.3 / 118.5 / 211 µs |

Zero loss at 1 kHz with ~1.7 messages per report — roughly 1.7 kHz of OSC egress. The
"steps over the interval" count is how often the loop overran its own 1 ms budget on a
busy laptop; it was 0 on most runs and 15 on one, which is scheduling jitter in the
harness, not loss (nothing was dropped).

### Unpaced throughput

| | value |
| --- | --- |
| messages per second | ~139,000 (122k–140k) |
| per message | 7.2 µs |
| delivered | 33,997 / 33,997 |

About 80× the ~1.7 kHz of egress a 1 kHz controller needs at this corpus's 1.70 messages
per report.

### The phase-bend tail

| | value |
| --- | --- |
| bend to release, as emitted | 81.8 ms (80.7–83.1) |

Not a latency defect: a platter moving with no finger on it sends `PhaseBend`, and the
controller deliberately schedules the release 80 ms out so the bend decays instead of
sticking. This is measured from the routed bend to the release *emission*, timestamped
inside `onControl` — timing it after a sleep would only measure the sleep.

## What this does not measure

- **The `NWConnection` wrapper.** The app sends through `OSCSender`, which wraps a
  Network.framework `NWConnection` in the executable target. A test target cannot import
  it, so this harness calls `sendto(2)` directly: one datagram per message, using the
  production encoder's bytes. It does not measure the framework's queueing overhead,
  which for a large burst is the more likely place to find additional latency. A
  measurement that includes it needs a harness inside the app bundle.
- **HID transport.** Reports are synthesised from the decoder's documented byte layouts,
  not captured from a device. USB polling and IOKit delivery are excluded by design —
  this is the bridge's latency, not the controller's.
- **Syndicate's receive side.** `OSCParser` stands in for "a local OSC receiver"; how
  Syndicate parses and applies messages is its own concern.
- **RGB feedback.** The outbound control path only. The feedback listener is a separate
  socket on a separate port and is not exercised here.
- **The diagnostic log.** The controller is driven directly rather than through
  `BridgeModel`'s hooks, so the log write is excluded. The running app writes it
  synchronously on the main actor, one `write(2)` per line (about 3.5 µs) for each
  input, outgoing message and status change, so add a few lines' worth per report
  when comparing against the live app.

The numbers to trust are the stage table (isolated, attributable) and the zero-loss paced
run (the cadence that actually matters). The serialized end-to-end p50 is an upper bound
whose floor is the 11.25 µs null-path control.

## Reproducing on another machine

The corpus, the assertions and the endpoints logic are machine-independent; the absolute
times are not. Expect a slower machine to move every figure, and an Intel Mac to move
`sendto` most. Compare within a machine across commits, not across machines.
