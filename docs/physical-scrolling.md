# Physical trackpad scrolling

GameController scroll deltas pass through `HardwareMouse` to the guest's virtio
mouse wheel. The old conversion, `22 * sensitivity * sqrt(abs(delta))`, rounded
each callback separately and capped it at 32 wheel detents. Even a small trackpad
movement could become several detents, followed by the guest's wheel acceleration.

The physical-input portion of [upstream PR #98](https://github.com/Leviidev/Henge/pull/98)
(`bd5236963fcfc7fb4159fe9fe655c4450f8e4b42`, ZackLiuzeyu) supplies the replacement:
bound each raw delta to ±4, multiply by twice the configured sensitivity, and keep
fractional detents for later callbacks. Default sensitivity remains 0.3; the slider
now permits 0.05–1.5. Existing saved settings remain effective. Each attached device
owns its own previous-axis state and fractional motion; disconnect/session stop
discards that state. Non-finite input is ignored before changing it.

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

[Upstream PR #167](https://github.com/Leviidev/Henge/pull/167) takes a different
approach: emulate two Magic Trackpad contacts, including lift, inertia and edge
repositioning. This patch retains wheel events and the existing pointer-report
ordering/drift fix. It addresses excessive speed; pixel scrolling and native
trackpad inertia would require the larger gesture change. Touchscreen gestures
keep their existing behavior.

## Validation

On an Apple Silicon Mac, run `make test-physical-mouse-scroll test-mouse-reports`
and `bash ios/scripts/check_display.sh`. The package workflow runs these checks.
Scroll tests replay captured deltas, check small-motion accumulation, both axes,
direction reversal, stale-axis filtering, separate devices, invalid values and
speed bounds. The captured vertical sequence `0.017333984, 9.184784, 36.241714,
51.288696, 0`, at its recorded intervals, emits `0, -2, -1, -1, 0` detents at the
default setting. Ten-second traces at 30/60/125/1000 Hz check sustained output,
and same-time bursts, clock anomalies and releases check that no excess is replayed.

On iPad, compare slow and fast two-finger swipes in the same long macOS document
at 0.3, then 0.05. At 0.05 compare a short swipe with a continuous ten-second
swipe, and check that lifting does not trigger delayed scrolling. Check horizontal
scrolling, reverse scrolling and an ordinary
mouse wheel. Confirm the pointer stays still while scrolling, and repeat after
disconnecting the input device or restarting the VM. Exact perceived speed still
depends on the guest application's wheel handling and needs device validation.
