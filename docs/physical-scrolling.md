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
51.288696, 0` now emits `0, -2, -2, -3, 0` detents at the default setting.

On iPad, compare slow and fast two-finger swipes in the same long macOS document
at 0.3, then 0.1. Check horizontal scrolling, reverse scrolling and an ordinary
mouse wheel. Confirm the pointer stays still while scrolling, and repeat after
disconnecting the input device or restarting the VM. Exact perceived speed still
depends on the guest application's wheel handling and needs device validation.
