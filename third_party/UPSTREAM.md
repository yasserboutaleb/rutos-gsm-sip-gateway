# chan_quectel — vendored snapshot

Source: the `mpmc/asterisk-chan-quectel` fork (RoEdAl / chan_dongle lineage), revision `5552c365bfb319eed7cbbf6300a67028ab70db9e`.

Licence: GPL-2.0 (see `chan_quectel/LICENSE.md` and `chan_quectel/COPYRIGHT.txt`).

This directory is **not modified**: the RUT360/RutOS adaptations live in `../patches/0001-chan_quectel-rutos-coexistence.patch`, applied at build time by `build/prepare-sources.sh`.

## Public fork

`RoEdAl/asterisk-chan-quectel` is archived. The patch is also published, split into documented commits, on the public fork **[yasserboutaleb/asterisk-chan-quectel](https://github.com/yasserboutaleb/asterisk-chan-quectel)** (branch `master`, commits `d2c9604` to `94ec461` on top of `5552c36`):

| Commit | Content |
|---|---|
| `d2c9604` | `+CME ERROR:` handled as a final error |
| `3f70741` | `sms` option |
| `b0e7539` | `shared_cfg` option |
| `9b7f74f` | `clcc_poll` and `urc_cfg` options |
| `94ec461` | fork README, EG06-E |

The code is identical to `patches/0001-chan_quectel-rutos-coexistence.patch`; only the comments differ.
