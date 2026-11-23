# chan_quectel — vendored snapshot

Source: the `mpmc/asterisk-chan-quectel` fork (RoEdAl / chan_dongle lineage), revision `5552c365bfb319eed7cbbf6300a67028ab70db9e`.

Licence: GPL-2.0 (see `chan_quectel/LICENSE.md` and `chan_quectel/COPYRIGHT.txt`).

This directory is **not modified**: the RUT360/RutOS adaptations live in `../patches/0001-chan_quectel-rutos-coexistence.patch`, applied at build time by `build/prepare-sources.sh`.

## Public fork

`RoEdAl/asterisk-chan-quectel` is archived. The patch is also published, split into documented commits, on the public fork **[yasserboutaleb/asterisk-chan-quectel](https://github.com/yasserboutaleb/asterisk-chan-quectel)** (branch `master`, on top of `5552c36`):

| Commit | Content |
|---|---|
| `d2c9604` | `+CME ERROR:` handled as a final error |
| `3f70741` | `sms` option |
| `b0e7539` | `shared_cfg` option |
| `9b7f74f` | `clcc_poll` and `urc_cfg` options |
| `94ec461`, `112088f` | fork README, EG06-E, shared-module mode |
| `8c11045` | hang up again a call the module keeps after a refused hangup |
| `45e2b61` | robust call tracking with `AT+CLCC` polling |
| `0921854` | voice enabled again after a crash during a call |
| `96a8f4d` | call index reused by the module for a new incoming call |
| `d50181e` | call revalidated under the device lock; init retried when `AT+QPCMV?` is refused; missing `break` |
| `558253d`, `82f1213` | neutral comments; README lists the fixes and what was tested |

The code is identical to `patches/0001-chan_quectel-rutos-coexistence.patch` of release 0.2.0; only the comments differ.

**Keeping the fork in step.** Each release that changes the patch also updates the fork: rebuild the patched tree of each patch version on top of `5552c36`, replay those versions onto the fork with three-way merges (conflicts are comment-only: keep the new code, keep the fork's neutral comment style), check that the code matches the patch line for line outside comments, update the fork README, then push `master`.
