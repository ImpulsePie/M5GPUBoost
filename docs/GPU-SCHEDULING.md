# GPU scheduling notes

How the two backends in `Sources/M5GPUBoost.swift` submit work, and what was
tried along the way.

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
don't count towards telemetry and can't renew the lease.

## Original engine (Balanced, and Gentle fallback)

This is Fred's engine with minor changes. Each submission creates a new
`MTLCommandBuffer` from a queue limited to eight buffers, encodes either a
four-byte blit fill (Gentle) or a short sin/cos compute dispatch (Balanced),
adds a completed handler and commits.

## Metal 4 engine (Gentle)

Used for Gentle when the device supports the Metal 4 family. At creation it
builds three lanes. Each lane has its own:

- `MTL4CommandAllocator` and `MTL4CommandBuffer`
- 4 KB shared `MTLBuffer`
- `MTLResidencySet` holding that buffer

Separate buffers per lane avoid overlapping writes, because Metal 4 doesn't
track resource hazards automatically.

For each submission the lane resets its allocator, begins the same command
buffer again, attaches its residency set and encodes a four-byte fill. The
compute encoder handles fills in Metal 4. It then ends the buffer and
commits with a feedback handler. A lane is marked busy until its feedback
arrives. A rapid stop and restart therefore can't reset an allocator the GPU
may still be using; the lane is refilled when its old work completes.

Metal 4 doesn't retain resources for you, so the feedback handler holds the
lane's allocator, command buffer, buffer, residency set and queue until
completion.

Compared with the original engine, this avoids creating a command buffer and
encoder per submission. In short continuous runs on an M5 Max, the boost
loop used about 30% less CPU at almost the same submission rate. Both
backends held the GPU at 1620 MHz, so the change is CPU overhead, not
clock speed.

## Tried and dropped

- **Custom feedback queue.** Delivering feedback on a dedicated dispatch
  queue failed in testing. The engine uses Metal's default feedback
  delivery and hops to its worker queue.
- **Reusing `MTL4CommitOptions`.** Keeping commit options between
  submissions failed in testing. A new options object, with its own feedback
  handler, is created for each commit.

## Known gaps

- A runtime Metal 4 failure stops boosting and reports the error. Fallback to
  the original engine only happens when the engine is created, for example
  after **Check Displays Again**.
- If feedback never arrives for a lane, that lane stays busy. There's no
  separate watchdog for a stalled lane.
