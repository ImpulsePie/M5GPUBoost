# GPU scheduling notes

How the two backends in `Sources/M5GPUBoost.swift` submit work, what the
workload is and why, and what was tried along the way.

## Shared behaviour

Both backends keep three command buffers in flight. When one completes, its
completion handler hops back to the backend's serial worker queue, which
submits the next one straight away. There's no timer or sleep between
submissions, so the GPU always has work queued while the boost is active.

Each backend has a three-second lease. Every start request from the
controller renews it, and every submission checks it. If the lease runs out,
the backend stops submitting. During a burst, each accepted input event
renews it. In Always while docked, the controller's two-second timer renews
it. An App Nap activity assertion keeps that timer on schedule in a
windowless app without preventing system sleep.

Stopping bumps a generation counter. Completions from an earlier generation
don't count towards the loop figures and can't renew the lease.

## The workload

Every submission is one compute dispatch: 4,096 threads, each running 64
iterations of `value = sin(value) * cos(value) + 0.001`. It takes about 4
microseconds of GPU time, so at roughly 20,000 submissions a second the GPU
is busy under 10% of the time.

IOReport lists two performance-state channels in its GPU Stats group,
GPUPH and AFRSTATE. Neither is documented. With no boost both sit at OFF or
P1. P13 is the top state, 1620 MHz in the GPU's `perf-states` table.

Share of time at P13 on an M5 Max, three lanes, sampled over 3 to 40
seconds:

| Workload                     | GPUPH | AFRSTATE |
| ---------------------------- | ----- | -------- |
| No boost                     | 0%    | 0%       |
| Four-byte fill (1.0 Gentle)  | 99%   | 10-25%   |
| Render pass, 16 x 16 target  | 98%   | 43%      |
| Render pass, 512 x 512       | 98%   | 98%      |
| Compute, 256 threads         | 99%   | 21%      |
| Compute, 512 threads         | 99%   | 41%      |
| Compute, 1,024 threads       | 99%   | 73%      |
| Compute, 1,536 threads       | 99%   | 91%      |
| Compute, 2,048 threads       | 99%   | 99%      |
| Compute, 4,096 threads       | 98%   | 98%      |
| Compute, 8,192 x 128 (1.0 Balanced) | 98% | 98%  |

With the fill, AFRSTATE spends about the same time in every state from P1
to P13, which looks like a constant ramp and reset. The GPU time per
submission is about the same for 256 and 2,048 threads, so what matters is
the width of the dispatch, not how long it runs. 1.1 uses twice the
smallest count that held both channels.

Lanes and pacing, with the 2,048-thread dispatch:

| Lanes | Pause between submissions | GPUPH at P13 | AFRSTATE at P13 |
| ----- | ------------------------- | ------------ | --------------- |
| 3     | none                      | 99%          | 99%             |
| 2     | none                      | 100%         | 89%             |
| 1     | none                      | 97%          | 22%             |
| 1     | 100 microseconds or more  | 0%           | 0%              |

Any pause leaves the GPU at P1 or off. Lower CPU use from pacing isn't
available.

The same group has a PWRCTRL channel naming the mode the GPU's power
controller is in. With the boost running it reads DEADLINE. Over five
minutes of ordinary use with 1.1 installed, GPUPH was at P13 for 99.8% of
the time and AFRSTATE for 100%, with no thermal, power-zone or PPM limit
recorded. The dips that did occur lasted 12 to 42 ms and went no lower than
P11, apart from one 3 ms power-off.

GPU power from IOReport's Energy Model, which bounces around: about 2 W
with no boost, 8 W for the fill, 9 W for the 1.1 workload and 14 W for
1.0 Balanced.

## Metal 4 backend

Used when the device supports the Metal 4 family. At creation it compiles
the kernel into a compute pipeline with `MTL4Compiler` and builds three
lanes. Each lane has its own:

- `MTL4CommandAllocator` and `MTL4CommandBuffer`
- 16 KB shared `MTLBuffer` of floats
- `MTLResidencySet` holding that buffer
- `MTL4ArgumentTable` with the buffer's address bound once

Separate buffers per lane avoid overlapping writes, because Metal 4 doesn't
track resource hazards automatically.

For each submission the lane resets its allocator, begins the same command
buffer again, attaches its residency set, sets the pipeline and argument
table and encodes the dispatch. It then ends the buffer and commits with a
feedback handler. A lane is marked busy until its feedback arrives. A rapid
stop and restart therefore can't reset an allocator the GPU may still be
using; the lane is refilled when its old work completes.

Metal 4 doesn't retain resources for you, so the feedback handler holds the
lane, the queue and the pipeline until completion.

Each start request also checks the lanes. If one has been busy for more
than two seconds, the backend reports a failure and stops.

## Original backend

Fred's engine with the same kernel. Each submission creates a new
`MTLCommandBuffer` from a queue limited to eight buffers, encodes the
dispatch, adds a completed handler and commits.

It counts the submissions in flight. A submission that can't be made is
retried on the next start request. If nothing has completed for two
seconds, the next start abandons the outstanding work and submits three
new buffers. If that doesn't produce a completion either, it reports a
failure.

## Choosing and replacing the backend

`MetalBoostEngine` creates the Metal 4 backend if it can and the original
one otherwise. When the Metal 4 backend reports a failure, the router
drops it, creates the original backend and starts it if a boost was
requested. The controller only hears about a failure when the original
backend fails too. The menu then shows the error until **Check Displays
Again**.

Compared with the original backend, Metal 4 avoids creating a command
buffer and encoder per submission. Continuous runs of the 1.1 workload on
an M5 Max used 37% of one core against 47%, at about the same submission
rate. Most of the remaining time is in the kernel's submit call.

## The clock readout

`GPUClockMonitor` subscribes to the GPUPH and AFRSTATE channels. The
controller opens a window when a boost starts and reads it on the
two-second timer and at the end of a burst. The menu shows the lower of
the two shares: "held" at 97% or more, otherwise the percentage. After a
minute of boosted time it adds the share for the session, rounded down to
a tenth of a percent. A steady hold produces the same text every time, so
it rarely redraws the menu-bar item.

IOReport is private, so the symbols are looked up with `dlsym`. The top
state and its frequency come from `perf-state-count` and `perf-states` on
the `sgx` device-tree node. If any of it is missing the monitor isn't
created and the menu shows the submission rate.

## Tried and dropped

- **Custom feedback queue.** Delivering feedback on a dedicated dispatch
  queue failed in testing. The engine uses Metal's default feedback
  delivery and hops to its worker queue.
- **Reusing `MTL4CommitOptions`.** Keeping commit options between
  submissions failed in testing. A new options object, with its own feedback
  handler, is created for each commit.
- **A four-byte fill.** Holds GPUPH only. See the first table.
- **Pacing the loop, or fewer lanes.** See the second table.
- **A command queue and dispatch queue per lane.** The idea was that one
  delayed thread couldn't then hold up all three lanes. Over four minutes
  it had more gaps of a millisecond or longer between batches (11.9 a
  minute against 3.7) and no fewer clock dips, so the lanes still share one
  queue and one worker.

## Measuring it

Measure the installed app, started the normal way. A copy of the engine run
from a terminal is deprioritised whenever the terminal's app isn't in
front: the same code held the clock anywhere from 52% to 99% of the time
that way, while the installed app read 99.8 to 100%. An activity assertion
in the terminal process made no difference.

`--diagnostics` prints both channels, the session share, the submission
rate and the GPU time per batch every two seconds.

## Known gaps

- The channel measurements are from one M5 Max. Other GPUs may need a
  different thread count, or may not report AFRSTATE at all.
- An abandoned Metal 4 lane keeps its allocator and command buffer until
  its feedback arrives, if it ever does.
