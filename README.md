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
- The build checks the architecture, the OpenSSH version string, the
  security-key key types and the linked libraries, then writes
  `SHA256SUMS.txt`.

## Why use this instead of Dropbear

GL firmware ships Dropbear, and for many people that is enough. Dropbear
already does key logins, port forwarding, SFTP (install GL's
`openssh-sftp-server`; Dropbear runs `/usr/libexec/sftp-server`) and
security-key (`sk-*`) logins from a token in your laptop. What OpenSSH adds:

- **SSH certificates**: `TrustedUserCAKeys`, `AuthorizedPrincipalsFile`, host
  certificates. Dropbear has no certificate support. A FIDO2 key signed by your
  CA gives a short-lived certificate whose private key never leaves the token.
- **Policy**: `Match` blocks, `AllowUsers`/`AllowGroups`, `PerSourcePenalties`,
  `PubkeyAuthOptions verify-required` (reject security-key logins that skipped
  the PIN), `sshd_config.d/` drop-ins.
- **A current release** instead of the version your firmware or feed carries.
  GL's feed has OpenSSH 9.6p1 (affected by CVE-2025-26466, pre-auth DoS).

### Security keys (FIDO2 / U2F)

The token stays in the client machine. The router only checks the signature,
and sshd does that (`sk-ssh-ed25519@openssh.com`,
`sk-ecdsa-sha2-nistp256@openssh.com`):

```bash
# client
ssh-keygen -t ed25519-sk -O resident -O verify-required
# append ~/.ssh/id_ed25519_sk.pub to /root/.ssh/authorized_keys on the router
```

`ssh-sk-helper` / `libfido2` are not built. A token plugged into the router's
own USB port can't be used (that matters only if the router is the SSH client).

Optional, in `/etc/ssh/sshd_config`: `PubkeyAuthOptions verify-required`
makes sshd require a PIN on every security-key login. Ordinary keys are not
affected.

## Before replacing Dropbear

Read this first, or you can lock yourself out.

- **Keep Dropbear.** Move it to another port and LAN only, and leave it
  enabled:
  `uci set dropbear.@dropbear[0].Port=2222; uci set dropbear.@dropbear[0].Interface=lan; uci commit dropbear; /etc/init.d/dropbear restart`.
  Dropbear is in the firmware image; these packages are not.
- **Firmware upgrades remove these packages.** Only listed files survive
  sysupgrade. Add `/etc/ssh/` and `/root/.ssh/` (keys, config) to
  `/etc/sysupgrade.conf`, keep a copy of the `.ipk` files in a preserved
  directory, and reinstall after each upgrade. If you disabled Dropbear, you
  have no SSH after the upgrade until you get in some other way.
- **Different key file.** sshd reads `/root/.ssh/authorized_keys` (permissions
  `700` on `.ssh`, `600` on the file). Keys set up for Dropbear are in
  `/etc/dropbear/authorized_keys`, and sshd ignores them. Copy them over.
- **Root logins are key-only.** The default `PermitRootLogin prohibit-password`
  refuses the root password. Copy your keys first. Don't set
  `PermitRootLogin yes`.
- **New host key.** sshd generates its own host keys, so clients that knew
  Dropbear on port 22 will refuse to connect with a host-key-changed error.
  This breaks scripts and automation until `known_hosts` is updated
  (`ssh-keygen -R <router>`).
- **Failsafe mode uses Dropbear.** Failsafe boots the firmware image without
  your overlay, so these packages and your sshd keys aren't there.

## Build

```bash
./build.sh            # output/*.ipk + output/SHA256SUMS.txt
```

Needs Ubuntu 24.04 (or similar) with the packages listed in
`.github/workflows/build.yml`. The host only runs the SDK's prebuilt cross
toolchain, so its version doesn't affect the packages. Run as a non-root user. CI runs the same script. A `v*` tag publishes a
GitHub release.

## Install on the router

Read "Before replacing Dropbear" first. Keep a Dropbear session on another port
open until the new sshd is verified.

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
