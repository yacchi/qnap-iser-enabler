# iSER Enabler for QNAP

A small QPKG that lets QTS / QuTS hero use **RDMA and iSER (iSCSI Extensions for RDMA)** on
**non-QNAP Mellanox / NVIDIA ConnectX-4 or later** cards.

## Why

QNAP's *Advanced Network Driver* app provides the RDMA driver (`mlx5_ib`) and turns on iSER in the
iSCSI target, but only for cards it recognises:

- QNAP-branded cards (PCI subsystem vendor `1baa`), or
- cards listed in `/etc/nic_third_party.conf` (out of the box: two ConnectX-6 Dx models, for a few NAS models only).

A retail Mellanox card (for example MCX4131A-GCAT) is skipped, so no RDMA device appears and the
iSER option never shows up. Adding the card to `/etc/nic_third_party.conf` by hand works, but `/etc`
is rebuilt on every boot.

## What it does

On every start (boot, or enabling the app):

1. Finds the PCI physical functions driven by `mlx5_core` (ConnectX-4 and later), skipping QNAP-branded ones.
2. Adds each one to `/etc/nic_third_party.conf` (`SUPPORT_MODEL=ALL`), marked with a comment so it can be removed again.
3. Waits in the background for an `mlx5_*` RDMA device, then runs `iscsiadmin enable_iser 1`.
   If Advanced Network Driver had already started before this app, it is started once more so it
   picks up the new entries.

4. About a minute later, makes sure this package starts **before** Advanced Network Driver on the
   next boot (see below).

On stop / uninstall it removes only the entries it added. iSER stays enabled until the next reboot.

### Start order

QTS starts apps in the order of their sections in `qpkg.conf` (`/etc/rcS.d/QS100…`), and a newly
installed app is appended, so right after installation this package starts *after* Advanced Network
Driver. On the first boot it therefore falls back to starting Advanced Network Driver once more.

To make Advanced Network Driver see the card on its own first start, this package moves its
`[iSEREnabler]` section to just before `[AdvancedNetDriver]` in `/etc/config/qpkg.conf` and
`/etc/config.local/qpkg.conf`. It checks again on every start, so the order is restored if QTS
appends the section again (for example after an update). Before writing, it verifies that the new file
holds exactly the same non-blank lines and the same sections in the same order apart from its own,
otherwise it leaves the file alone; the previous file is kept as `qpkg.conf.iser-enabler.bak`.

QTS does not wait for one app to finish starting before it starts the next, so even in this order
Advanced Network Driver can check the card list a moment before this package has added its entries.
The entries are therefore written as the very first step of the start, and if Advanced Network Driver
still missed the card (it records `Sys_App = 0` in `/etc/config.local/qpkg.conf`), it is started once
more right away. In practice iSER is enabled within seconds of Advanced Network Driver either way.

Advanced Network Driver still skips `iscsiadmin enable_iser 1` when `isert_scst` is already loaded,
so this package runs that one command itself once the RDMA device exists.

Apart from the section order above, it changes nothing else: no QNAP files are patched, and the card's firmware is never touched.
Advanced Network Driver's own NIC firmware updater only targets cards with a QNAP PSID (`QNP*`).

## Requirements

- QTS / QuTS hero 5.0 or later (tested on QuTS hero h6.0.2 on a TS-873A)
- QNAP **Advanced Network Driver** installed and enabled (App Center)
- A Mellanox / NVIDIA ConnectX-4 or later card (`mlx5_core`). ConnectX-3 (`mlx4`) is not supported:
  Advanced Network Driver ships no `mlx4_ib`.

## Install

1. Download `iSEREnabler_<version>.qpkg` from [Releases](../../releases).
2. App Center → Settings → allow installation of applications without a valid digital signature
   (this package is not signed by QNAP).
3. App Center → *Install Manually* → choose the `.qpkg`.
4. Reboot, or disable and enable the app once.

## Check

```sh
cat /share/<volume>/.qpkg/iSEREnabler/iser-enabler.log   # or: /etc/init.d/iser-enabler.sh status
ls /sys/class/infiniband/                                 # mlx5_0
```

From a Linux initiator, an iSER discovery that does not write node records:

```sh
iscsiadm -m iface -I iser0 -o new
iscsiadm -m iface -I iser0 -o update -n iface.transport_name -v iser
iscsiadm -m discovery -t st -p <nas-ip>:3260 -I iser0 -o nonpersistent
```

## Notes

- The QTS UI may still not show an iSER option for a non-QNAP card; iSER is enabled from the CLI regardless.
- Changing iSCSI settings in the UI may turn iSER off again until the next start of this app.
- For lossless RoCE, enable flow control (802.3x PAUSE or PFC) on the switch ports.

## Configuration

Optional. Copy `iser-enabler.conf.sample` to `iser-enabler.conf` in the package directory:

```sh
EXTRA_IDS="15b3:1017:15b3:0007"   # cards not bound to mlx5_core when the service starts
EXCLUDE_IDS=""                    # cards that must never be added
```

## Build

GitHub Actions builds the `.qpkg` with [QDK](https://github.com/qnap-dev/QDK) on every push and
attaches it to the release on `v*` tags. Locally, on Ubuntu with QDK installed: `qbuild`.

## License

GPL-3.0
