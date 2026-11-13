# openssh-openwrt

Current OpenSSH packaged as `.ipk` for GL.iNet routers whose firmware is based
on OpenWrt 23.05 (architecture `aarch64_cortex-a53_neon-vfpv4`, e.g. GL-BE6500
and other IPQ53xx models).

GL's package feed lags upstream OpenSSH (9.6p1 at the time of writing), and the
stock OpenWrt 23.05 feed stops at 9.8p1. Newer OpenWrt releases ship current
OpenSSH, but they cannot run on these routers. This repo builds the current
package for them.

## What gets built

| Package | Contents |
|---------|----------|
| `openssh-server` | `/usr/sbin/sshd`, `/usr/lib/sshd-session`, `/usr/lib/sshd-auth`, init script |
| `openssh-keygen` | `/usr/libexec/ssh-keygen-openssh` (`/usr/bin/ssh-keygen` via alternatives) |
| `openssh-sftp-server` | `/usr/lib/sftp-server` (+ `/usr/libexec/sftp-server` symlink) |

How:

- `package/openssh/` is OpenWrt's current `net/openssh` package from
  [openwrt/packages](https://github.com/openwrt/packages) (branch and commit in
  `package/openssh/UPSTREAM`).
- It is compiled with the stock **OpenWrt 23.05.5 `armsr/armv8` SDK**, which uses
  the same gcc 12.3, musl 1.2.4 and OpenSSL 3.0 ABI as the GL firmware base.
  The SDK download is checked against the release's `sha256sums`.
- Each `.ipk` is relabelled with GL's architecture string, so plain
  `opkg install` works without `--add-arch`.
- The build checks the architecture, the OpenSSH version string in the
  binaries, and the linked libraries, then writes `SHA256SUMS.txt`.

## Build

```bash
./build.sh            # output/*.ipk + output/SHA256SUMS.txt
```

Needs Ubuntu 24.04 (or similar) with the packages listed in
`.github/workflows/build.yml`. The host only runs the SDK's prebuilt cross
toolchain, so its version doesn't affect the packages. Run as a non-root user. CI runs the same script. A `v*` tag publishes a
GitHub release.

## Install on the router

Keep a second way in (e.g. Dropbear on another port) open until the new sshd is
verified.

```bash
cd /tmp
# copy the .ipk files and SHA256SUMS.txt here, then:
sha256sum -c SHA256SUMS.txt
opkg install --force-reinstall ./openssh-keygen_*.ipk ./openssh-server_*.ipk ./openssh-sftp-server_*.ipk
grep -ao 'OpenSSH_[0-9.]*p[0-9]' /usr/sbin/sshd | head -1
sshd -t && /etc/init.d/sshd restart
```

Then, from another machine, test a key login and SFTP before closing the
fallback session.

Notes:

- An existing, modified `/etc/ssh/sshd_config` is kept. opkg writes the
  package default as `sshd_config-opkg`.
- If an earlier OpenSSH was installed from a feed with a different architecture
  string, opkg may warn about it. Installing these packages replaces it.

## Updating to a new OpenSSH

Copy `net/openssh/` from the newest openwrt/packages release branch into
`package/openssh/`, update `package/openssh/UPSTREAM`, and push. CI builds and
verifies the new version.

## License

The packaging in `package/openssh/` comes from OpenWrt and is GPL-2.0. OpenSSH
itself is BSD-licensed (see its `LICENCE`). The build script and workflow in
this repo are GPL-2.0.
