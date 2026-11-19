# M5GPUBoost

Current version: **1.1.0**

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
- **One workload that holds the whole GPU clock.** The old Gentle strength
  only held part of it (see [below](#why-theres-no-strength-setting)), so
  the Strength menu is gone.
- **Metal 4 backend.** It reuses three command buffers instead of making a
  new one every time. Fred's original engine is the fallback, at start-up
  and if Metal 4 fails while running. More detail in the
  [GPU scheduling notes](docs/GPU-SCHEDULING.md).
- **The menu says whether the clock is held.** It reads the GPU's
  performance states and shows, for example, "GPU clock held at 1620 MHz".
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

From idle, the GPU takes about a fifth of a second to reach its top clock
on my Mac. That's the hitch, and it's why the input modes can't remove it
completely.

Dragging a System Settings window at 7680 × 3240, the display got about
117 new frames a second with Always while docked and about 86 without the
app (seven drags each, counted from the display controller's swap
counters).

On my M5 Max, Always while docked costs about **2% of total CPU**, a bit
over a third of one core, and roughly 9 W of GPU power against about 2 W
idle. That's an easy trade for me when I'm at my desk. It won't fix
buffering, low frame-rate video or every kind of stutter.

## Why there's no Strength setting

1.0 had two strengths: Gentle (a four-byte buffer fill) and Balanced (a
compute dispatch). IOReport lists two performance-state channels for the
GPU, GPUPH and AFRSTATE. Apple doesn't document either. GPU monitors read
the first, and both strengths hold it at the top state. Only the compute
dispatch holds the second.

Share of time in the top state (1620 MHz) on my Mac, three lanes, no pause
between submissions:

| Workload                         | GPUPH | AFRSTATE | CPU (one core) |
| -------------------------------- | ----- | -------- | -------------- |
| No boost                         | 0%    | 0%       | -              |
| Four-byte fill (1.0 Gentle)      | 99%   | 10-25%   | 38%            |
| Compute, 256 threads             | 99%   | 21%      | -              |
| Compute, 1,024 threads           | 99%   | 73%      | -              |
| Compute, 2,048 threads           | 99%   | 99%      | -              |
| Compute, 4,096 threads (1.1)     | 99%   | 99%      | 37%            |

With the fill, AFRSTATE cycles through every state the whole time. Dragging
a freshly opened window felt better to me on the compute dispatch, and it
costs the same CPU, so 1.1 always uses it. It's Fred's Balanced kernel at half
the thread count and half the iterations.

Two other things I checked: any pause between submissions, even 100
microseconds, drops the clock straight back to the lowest state, and one or
two lanes aren't enough to hold the second channel. So the loop stays as
Fred designed it.

## Original vs Metal 4 backend

Continuous runs of the 1.1 workload on my Mac:

| Backend  | CPU (one core) | Buffers/sec | Both channels at 1620 MHz |
| -------- | -------------- | ----------- | ------------------------- |
| Original | 47%            | about 20,900 | yes                      |
| Metal 4  | 37%            | about 19,400 | yes                      |

That's about a fifth less CPU. A three-second sample of the running app
puts most of what's left in the kernel's submit call, not in this code.

## Checking it yourself

The menu line comes from the same IOReport channels. To log the figures
every two seconds, quit the app and run it from Terminal:

```bash
build/M5GPUBoost.app/Contents/MacOS/M5GPUBoost --diagnostics
```

```text
M5GPUBoost: Clock: GPUPH 100.0%, AFRSTATE 100.0% at 1620 MHz; 20582 batches/s, 3.7 µs GPU each
```

IOReport is a private library. If it can't be read, the menu shows the
submission rate and everything else works as normal.

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

New installs start on On activity. The input modes only boost when the
pointer's on the qualifying display. The 60-second All-motion test from 1.0
is gone; Always while docked does the same job.

While it's boosting, the third line of the menu reads "GPU clock held at
1620 MHz", or the share of time at that speed if it's under 97%. After a
short burst it's normal to see a lower figure, because the ramp from idle
is counted. Once there's a minute of boosted time it adds the share for
the whole session, for example "(99.8% this session)", so a slip is still
visible after the moment has passed. Changing mode resets it.

Variable refresh works. A display that reports 0 Hz in an adaptive mode
qualifies if its fastest refresh is 100 Hz or more.

## Known issues

- It is real GPU work, so quit it before gaming or benchmarking.
- The first drag of a window that has just opened can still hitch now and
  then. In my recordings the clock was held and frames were arriving at the
  normal rate when I did it, so I don't think the GPU clock is the cause,
  and I haven't found one this app could fix.
- The clock readout depends on IOReport and on the GPU's device-tree entry
  being named as it is on current Apple silicon. Where either is missing
  the menu shows the submission rate.
- I've only measured the two clock channels on an M5 Max. The thread count
  has a 2x margin over what held both here; other GPUs may differ.
- "On AC power" now uses the providing power source, so desktop Macs should
  qualify. I haven't got one to test.

## Tests

```bash
./Tests/run-runtime-checks.command
```

Runs 85 checks against the real engines and controller, covering leases,
restarts, stalled lanes, runtime fallback, the clock hold on both backends,
mode timing, and sleep, wake, lock and unlock. They need a qualifying
display and AC power, so CI only compiles them. Quit the app first; the
script won't run while it's holding the clock.

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
