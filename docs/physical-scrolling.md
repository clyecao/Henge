# Physical trackpad scrolling

`HardwareMouse` routes Magic Keyboard and Magic Trackpad scroll deltas to virtual
trackpad contacts. Other devices keep the guest's virtio mouse wheel. Device names
are matched case-insensitively; an unknown name defaults to the wheel path. Logs
include each device's name and selected scroll mode. The user's captured devices
identify themselves as `Magic Keyboard` and `Bluetooth Mouse M558`.

## Mouse wheels

The old conversion, `22 * sensitivity * sqrt(abs(delta))`, rounded
each callback separately and capped it at 32 wheel detents. Even a small trackpad
movement could become several detents, followed by the guest's wheel acceleration.

The physical-input portion of [upstream PR #98](https://github.com/Leviidev/Henge/pull/98)
(`bd5236963fcfc7fb4159fe9fe655c4450f8e4b42`, ZackLiuzeyu) supplies the replacement:
bound each raw delta to ±4, multiply by twice the configured sensitivity, and keep
fractional detents for later callbacks. Default sensitivity remains 0.3; the slider
now permits 0.05–1.5. Existing saved settings remain effective. Each attached device
owns its own previous-axis state and fractional motion; disconnect/session stop
discards that state. Non-finite input is ignored before changing it.
An isolated notch emits at least one detent. During fine scrolling, the next
nonzero input on an axis can emit a detent after 180 ms without a step on that
axis. Equal wheel values at least 3 ms apart count as separate reports.

## Sustained scrolling

Per-callback limits alone still allowed about 50 detents/second at sensitivity
0.05 with a 125 Hz trackpad. The guest also uses event timing when applying
[scroll acceleration](https://github.com/apple-oss-distributions/IOHIDFamily/blob/main/IOHIDEventSystemPlugIns/IOHIDPointerScrollFilter.cpp).
That explains why reducing each callback could improve a short swipe while a
long swipe remained too fast; exact guest acceleration varies by configuration.

Each axis now has a time-based output budget: `120 * sensitivity` detents/second,
with an initial burst of `max(1, ceil(8 * sensitivity))`. At 0.05 this permits one
initial detent plus at most six per elapsed second. Monotonic host uptime drives
the budget, so extra callbacks or stale-axis updates cannot refill it early.
Excess whole detents are discarded, with no timer or backlog to replay on release.
Fractional movement still accumulates for precise short gestures. Lowering the
slider immediately clamps the stored allowance as well as the refill rate.

## Magic Keyboard and Magic Trackpad

`ScrollFingers.swift` adapts [upstream PR #167](https://github.com/Leviidev/Henge/pull/167),
commit `e158322564d5ad83708a2d44d7e431613544592b` by Jens Köhler. Scroll deltas move
two contacts on the existing Magic Trackpad 2, so macOS handles pixel scrolling
and momentum. They bypass the wheel conversion and rate limit above.

- Merge callbacks within a 3 ms sample window, using the latest two-axis snapshot.
  A steady vertical displacement still counts when the horizontal value changes. Use the input
  profile's event time when available so queued samples can retain separate frames.
- Start the first pair near the center so a light change of direction has room.
- Lift after a zero persists for 16 ms or after 120 ms of inactivity. Cancel pending work on device/session
  teardown, input-source changes or touchscreen contact; touchscreen and hardware
  fingers must not combine into a three/four-finger gesture.
- Alternate finger pairs 14/15 and 12/13, outside the touchscreen's 1–5.
- Reduce finger travel over the last few samples approaching a pad edge. Send
  one stationary report before lifting and start the next pair on a fresh sample.
  Reversing direction while approaching the edge moves the current pair back.
- At default speed, cap virtual finger travel at 7,200 sensor units per second.
  Scale the cap with the slider and sample interval (up to 33 ms). This keeps
  accelerated input from exhausting the sensor in the first few frames of a swipe.
- Submit each pair's placement, movement and stop as complete two-contact USB
  reports. At two pending reports, skip new motion and keep the last accepted
  position. The next sample applies only its own displacement. Lifts still reach
  the queue. The gesture log counts regrips and skipped reports.

Settings and session details now show **Mouse scroll speed** (existing saved
setting) and **Trackpad scroll speed** (new `henge.trackpad.scrollSpeed` preference,
default 0.3). Both apply immediately. Trackpad calibration follows #167: 40 sensor
units per input point at 0.3. The shared reverse-scrolling setting still applies.
Unknown hardware and mouse wheels retain their existing behavior.

## Validation

On an Apple Silicon Mac, run `make test-scroll-fingers test-physical-mouse-scroll test-mouse-reports`
and `bash ios/scripts/check_display.sh`. The package workflow runs these checks.
Scroll tests replay captured deltas, check small-motion accumulation, both axes,
direction reversal, stale-axis filtering, separate devices, invalid values and
speed bounds. The captured vertical sequence `0.017333984, 9.184784, 36.241714,
51.288696, 0`, at its recorded intervals, emits `-1, -2, -1, -1, 0` detents at the
default setting. Ten-second traces at 30/60/125/1000 Hz check sustained output,
and same-time bursts, clock anomalies and releases check that no excess is replayed.
The smooth-scroll tests use a controlled clock and scheduler to check device
routing, merged two-contact frames, speed/direction, idle lift, canceled timers,
edge deceleration, alternating IDs, delayed USB consumption and extreme input bounds. They also replay
97 ms of Magic Keyboard input from an iPad14,6 and check that every sample
advances both contacts without a regrip.

On iPad, start with Trackpad scroll speed 0.3 and leave the mouse's accepted setting
unchanged. Check small movements, long swipes, momentum after release, horizontal
motion, reversal and touchscreen handoff. Compare the Bluetooth mouse, then repeat
after detaching the Magic Keyboard or restarting the VM. Confirm the pointer stays
still while scrolling. Real-device validation is still required for the guest's
gesture recognition, edge transitions and perceived speed.
