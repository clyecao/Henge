# Physical mouse and trackpad scrolling

Henge sends scroll input from every `GCMouse`, including the Magic Keyboard
trackpad, to the guest's virtio mouse wheel. Direct touches on the iPad screen
still drive the emulated USB Magic Trackpad and support macOS multi-finger
gestures. Hardware two-finger swipes produce wheel detents. macOS sees no
finger-lift event from which to generate trackpad momentum.

## Speed and direction

Use **Settings → Mouse and Trackpad → Scroll speed** or open the running Mac's
session details and adjust **Pointer → Scroll speed**. Both controls change the
same setting immediately, from 0.05× to 1.5× with a default of 0.3×. Existing
mouse scroll preferences apply to attached trackpads as well. **Reverse
scrolling** applies to both devices the next time a Mac starts.

Each device tracks its own axes, fractional movement and rate limit. The first
GameController axis scrolls vertically and the second horizontally. When the
framework delivers the two axis changes separately, Henge filters the repeated
axis. Each wheel report carries zero pointer displacement.

Henge bounds each raw delta to ±4, scales by twice the sensitivity and retains
fractional detents. An isolated notch gets an immediate step even at 0.05×.
During fine scrolling a nonzero sample can produce a step after 180 ms without
a detent on that axis. The fractional conversion originated in
[upstream PR #98](https://github.com/Leviidev/Henge/pull/98).

Each axis can send up to `120 × sensitivity` detents per second after an initial
burst of `max(1, ceil(8 × sensitivity))`. At 0.05× this allows one initial
detent and six more per elapsed second. Excess whole detents expire on the
current callback, so a paused guest cannot accumulate a burst in the converter.

## Why hardware trackpads use the wheel

The previous implementation translated hardware deltas into two virtual fingers.
Long swipes reached the edge of the virtual sensor and needed a lift and a new
contact pair. In an iPad14,6 capture from build `30c2f45`, the first 40 paired
reports arrived at a median interval of 8 ms. After 39 deliveries the queue was
empty. All seven logged gesture summaries reported a contact reposition, and
six recorded zero skipped reports. The wheel carries relative motion and has
no sensor edge.

## Verification

Run `make test-physical-mouse-scroll test-mouse-reports test-vm-lifecycle` on an
Apple Silicon Mac. The Swift suite replays 24 Magic Keyboard callbacks across
115 ms at two sensitivities, as well as slow mouse notches and ten-second
swipes. The native suites check wheel ordering, zero pointer displacement and
restoring a saved VM with old hardware contacts. On iPad, compare a slow swipe,
a long swipe and horizontal scrolling with the same wheel speed.
