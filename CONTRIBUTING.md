# Contributing

Issues and pull requests are welcome.

## Reporting a problem

Please include:

- the package version (`opkg list-installed | grep rut360gw`) and the RutOS firmware
  (`cat /etc/version`);
- the output of `rut360gw-check`;
- the relevant log lines (`logread -e rut360gw`, the **Logs** tab), and for SIP problems the
  server side of the exchange;
- whether the SIM uses VoLTE, and the mode used (`register` or `ip`).

**Remove all personal data first**: phone numbers, IMEI/IMSI/ICCID, public IP addresses,
host names, passwords. `rut360gw-config show` already masks passwords.

Security issues: see [docs/SECURITY.md](docs/SECURITY.md#reporting-a-vulnerability). Please
do not open a public issue for them.

## Pull requests

- Run the local CI before submitting: `sh ci/run-local.sh`. See
  [docs/BUILDING.md](docs/BUILDING.md). At least `lint`, `unit` and `package` must pass. For
  changes to the driver, the dialplan, the scripts or the runtime, `integration` and
  `integration-rutos` must pass too.
- Install the pre-commit hook once: `sh ci/install-hooks.sh`.
- Add or update a bench scenario (`tests/`) when you change behaviour.
- Keep changes focused. Never modify `third_party/chan_quectel/`: driver changes go into the
  patch in `patches/`.
- Write code comments, log messages, documentation and commit messages in **English**.
- **Never commit secrets** or site-specific settings: passwords, keys, `.uci` files, real
  phone numbers or addresses. Use neutral examples such as `pbx.example.com`, `10.8.0.0/24`
  or `+15550100`.
- Shell scripts must stay POSIX `sh` (BusyBox `ash` on the router). Lua must stay 5.1 with
  the standard library only.
- Changes that affect the router (firmware support, AT commands, RutOS settings) should be
  tested on a real RUT360. Say in the pull request what was tested on hardware.

By contributing, you agree that your contributions are licensed under GPL-2.0-only.
