# M5GPUBoost

Current version: **1.0.0**

This is my fork of Frederic Bossy's
[M5ScrollBoost](https://github.com/fwedbo/M5ScrollBoost). It's a little
menu-bar app that keeps the GPU ticking over with tiny Metal workloads, so
the desktop stays smooth on a big high-refresh external display. It doesn't
touch GPU clocks or system settings.

Fred's version boosts while you scroll. I wanted the whole desktop smooth on
my 5K2K ultrawide, so I added a few more modes and a lighter Metal 4 backend.

## What I changed

- **5K2K ultrawides work now.** The minimum is 5000 × 2000 pixels instead of
  5000 × 2800, still at 100 Hz or more.
- **New modes:** On activity, While in use and Always while docked.
- **Metal 4 backend for Gentle.** It reuses three command buffers instead of
  making a new one every time. Balanced still uses Fred's original engine,
  which is also the fallback. More detail in the
  [GPU scheduling notes](docs/GPU-SCHEDULING.md).
- **Three-second lease.** The GPU loop stops by itself unless the app keeps
  renewing it, so it can't get stuck running.
- **Pauses on screen lock** too, not just battery, display sleep and thermal
  pressure. It lets go of everything while it's paused.
- **The menu icon disappears** when there's no qualifying display plugged in.
- **Fewer menu-bar redraws.**

## Docked mode

Boosting only on input still gave me a small hitch at the start of each
scroll while the GPU woke up. While in use kicks in when you move the
pointer, so it's usually ready by the time you scroll. Always while docked
just runs the whole time, which also covers typing and watching video.

On my M5 Max, Always while docked + Gentle costs about **2% of total CPU**,
roughly a third of one core. That's an easy trade for me when I'm at my desk.
It won't fix buffering, low frame-rate video or every kind of stutter.

## Original vs Metal 4 backend

Quick runs of continuous Gentle on my Mac, done on development builds before
1.0.0:

| Backend  | CPU (one core) | Buffers/sec | GPU clock |
| -------- | -------------- | ----------- | --------- |
| Original | 45.5%          | 18,431      | 1620 MHz  |
| Metal 4  | 32.1%          | 18,175      | 1620 MHz  |

That's about 30% less CPU for the same amount of work. Both held 1620 MHz,
so the win is lower overhead, not a faster GPU clock. Power readings bounced
around too much to compare.

## What you need

- An Apple silicon Mac on macOS 26 or 27
- Command Line Tools or Xcode
- AC power, and an external display that's at least 5000 × 2000 pixels in
  its current mode at 100 Hz or more (a Studio Display XDR reporting 0 Hz
  counts too)

## Build it

```bash
./build.command
```

That builds the app, ad-hoc signs it and opens `build/M5GPUBoost.app`. Add
`--no-open` if you don't want it launched. Your previous build gets moved to
`build/previous/`, not deleted.

It lives in the menu bar. Add it to Login Items if you want it running at
startup. It keeps its own settings, so don't run it at the same time as
M5ScrollBoost.

## Modes

| Mode                | Boosts                                                                     |
| ------------------- | -------------------------------------------------------------------------- |
| Off                 | Never                                                                      |
| On scroll           | While scrolling, for 0.9 seconds after                                     |
| On activity         | Scrolling, dragging, clicks, gestures, app and Space switches; 0.9 seconds |
| While in use        | On activity plus pointer movement; 2 seconds                               |
| Always while docked | All the time while docked, awake and unlocked                              |
| All-motion test     | All the time for 60 seconds, then back to On activity                      |

New installs start on On activity. The input modes only boost when the
pointer's on the qualifying display.

| Strength | Workload                                       |
| -------- | ---------------------------------------------- |
| Gentle   | Four-byte buffer fill (Metal 4 when available) |
| Balanced | Short sin/cos compute dispatch                 |

Gentle is the one to start with.

## Known issues

- If Metal 4 fails while it's running, boosting stops until you hit **Check
  Displays Again**. It only falls back to the original engine at startup.
- There's no watchdog for a GPU lane that never finishes.
- It is real GPU work, so quit it before gaming or benchmarking.

## Tests

```bash
./Tests/run-runtime-checks.command
```

Runs 67 checks against the real engines and controller, covering leases,
restarts, fallback, mode timing, and sleep, wake, lock and unlock. They need
a qualifying display connected, so CI only compiles them.

My setup is an M5 Max MacBook Pro (18 CPU / 40 GPU cores, 64 GB) on macOS
27.2.1, with a Dell U4025QW at 120 Hz scaled to 3840 × 1620. Lower scaled
modes were already smooth. At 3840 × 1620 the difference was obvious.

## Scroll Replay

[Scroll Replay](Tools/ScrollReplay/README.md) is Fred's companion app for
repeatable Chrome scrolling. I haven't changed it.

## Credit

M5ScrollBoost is Frederic Bossy's work ([fwedbo](https://github.com/fwedbo)),
MIT licensed; see [LICENSE](LICENSE). All my functional changes are in one
commit on top of his, before the rename, so it's easy to diff against the
original.
