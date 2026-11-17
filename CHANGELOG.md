# Changelog

## M5GPUBoost 1.0.0

First release of the fork, based on M5ScrollBoost 1.0.

- Qualify external displays from 5000 × 2000 pixels, so 5K2K ultrawides at
  100 Hz or more are included.
- Add On activity, While in use and Always while docked modes, plus a
  60-second diagnostic that is never saved as the startup mode. New
  installations default to On activity.
- While in use reacts to pointer movement with a 2-second tail. The other
  input modes keep 0.9 seconds.
- Add a Metal 4 backend for Gentle that reuses three command-buffer and
  allocator lanes. Keep the original engine for Balanced and as a
  creation-time fallback.
- Add a three-second worker lease, renewed by activity or the docked timer.
- Pause on screen lock, and release the engine, input monitor and timer
  while paused.
- Hide the menu icon when no qualifying display is connected.
- Coalesce menu updates and let the boost indicator linger after a burst.
- Rename to M5GPUBoost with bundle identifier
  `io.github.impulsepie.M5GPUBoost`. Settings aren't shared with
  M5ScrollBoost.
- Build into a staging folder and keep previous builds in `build/previous/`.
- Add runtime checks in `Tests/`.

## M5ScrollBoost 1.0

- Remove Continuous mode; saved Continuous selections migrate to On scroll.
- Keep Gentle and Balanced; saved Strong selections migrate to Balanced.
- Default new installations and missing or unrecognized strengths to Gentle.
- Store stable settings identifiers and migrate recognized older labels.
- Restrict the Studio Display XDR name fallback to reported 0 Hz, so a known
  60 Hz mode no longer qualifies.
- Prevent the controller from displaying boosting when Metal initialization
  failed.
- Use the app name M5 Scroll Boost consistently in the menu and simplify the
  strength labels to Gentle and Balanced. Document the actual Balanced workload.
- Add reproducible build instructions and `--no-open` for build verification.
- Preserve the existing Gentle blit workload and regular three-buffer scheduling.

Historical investigation results apply to the versions and workloads noted
in the README; this version has no new scrolling-performance claim.
