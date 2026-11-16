#!/usr/bin/env bash
# Build OpenSSH .ipk packages for GL.iNet routers whose firmware is based on
# OpenWrt 23.05 (aarch64 Cortex-A53, e.g. GL-BE6500).
#
# Uses the stock OpenWrt 23.05 armsr/armv8 SDK (same gcc 12.3 / musl 1.2.4 /
# OpenSSL 3.0 ABI as the GL base) and OpenWrt's current openssh package
# (package/openssh, taken from openwrt/packages). The finished .ipk files get
# GL's architecture string so opkg installs them without --add-arch.
#
# Same script runs in CI and locally:  ./build.sh   (output in ./output)
set -euo pipefail

OPENWRT_VERSION=${OPENWRT_VERSION:-23.05.5}
TARGET=armsr
SUBTARGET=armv8
REPACK_ARCH=${REPACK_ARCH:-aarch64_cortex-a53_neon-vfpv4}
PACKAGES="openssh-server openssh-keygen openssh-sftp-server"

ROOT=$(cd "$(dirname "$0")" && pwd)
WORK=${WORK:-$ROOT/work}
OUT=${OUT:-$ROOT/output}
BASE=https://downloads.openwrt.org/releases/$OPENWRT_VERSION/targets/$TARGET/$SUBTARGET
SDK_FILE=openwrt-sdk-$OPENWRT_VERSION-$TARGET-${SUBTARGET}_gcc-12.3.0_musl.Linux-x86_64.tar.xz

PKG_VERSION=$(sed -n 's/^PKG_VERSION:=//p' "$ROOT/package/openssh/Makefile")
PKG_RELEASE=$(sed -n 's/^PKG_RELEASE:=//p' "$ROOT/package/openssh/Makefile")
WANT="OpenSSH_${PKG_VERSION/_p/p}"

echo "=== $WANT (release $PKG_RELEASE), OpenWrt $OPENWRT_VERSION SDK, arch $REPACK_ARCH"

mkdir -p "$WORK"
rm -rf "$OUT"
mkdir -p "$OUT"
cd "$WORK"

# 1. SDK, verified against the release's sha256sums
if [ ! -d sdk ]; then
  curl -fsSLO "$BASE/$SDK_FILE"
  curl -fsSL "$BASE/sha256sums" | grep " \*$SDK_FILE\$" | sed 's/ \*/  /' > sdk.sha256
  [ -s sdk.sha256 ] || { echo "SDK not listed in sha256sums"; exit 1; }
  sha256sum -c sdk.sha256
  tar xf "$SDK_FILE"
  mv "${SDK_FILE%.tar.xz}" sdk
  rm -f "$SDK_FILE" sdk.sha256
fi
cd sdk

# 2. Our openssh package + its build deps from the 23.05 base feed
rm -rf package/openssh
cp -r "$ROOT/package/openssh" package/
./scripts/feeds update base
./scripts/feeds install libopenssl zlib

# 3. Configure: only the packages we ship. The SDK selects every package by
# default; openssh-sk-helper would switch on --with-security-key-builtin, which
# needs libfido2 (not in the base feed) and links sshd against it. That is
# only for using a token plugged into the router itself. Server-side checks
# of security-key (sk-*) logins are on regardless and are verified in step 6.
cat > .config <<EOF
# CONFIG_ALL is not set
# CONFIG_ALL_NONSHARED is not set
# CONFIG_ALL_KMODS is not set
# CONFIG_PACKAGE_openssh-sk-helper is not set
$(for p in $PACKAGES; do echo "CONFIG_PACKAGE_$p=m"; done)
EOF
make defconfig
if grep -q '^CONFIG_PACKAGE_openssh-sk-helper=' .config; then
  echo "openssh-sk-helper still selected"; exit 1
fi

# 4. Compile
make package/openssh/compile -j"$(nproc)" V=s

# 5. Harvest, set GL's arch string (SDK arch is aarch64_generic)
for p in $PACKAGES; do
  f=$(find "$PWD/bin/packages" -name "${p}_${PKG_VERSION}-${PKG_RELEASE}_*.ipk" | head -1)
  [ -n "$f" ] || { echo "missing package: $p"; exit 1; }
  tmp=$(mktemp -d)
  ( cd "$tmp"
    tar xzf "$f"
    mkdir ctrl && tar xzf control.tar.gz -C ctrl
    sed -i "s/^Architecture: .*/Architecture: $REPACK_ARCH/" ctrl/control
    (cd ctrl && tar czf ../control.tar.gz --owner=0 --group=0 .)
    tar czf "$OUT/${p}_${PKG_VERSION}-${PKG_RELEASE}_$REPACK_ARCH.ipk" --owner=0 --group=0 \
      ./debian-binary ./control.tar.gz ./data.tar.gz )
  rm -rf "$tmp"
done
cd "$OUT"

# 6. Verify: arch, version string, linked libraries
fail=0
for ipk in *.ipk; do
  tmp=$(mktemp -d)
  ( cd "$tmp" && tar xzf "$OUT/$ipk" && mkdir c d && tar xzf control.tar.gz -C c && tar xzf data.tar.gz -C d )
  echo "--- $ipk"
  grep -E '^(Package|Version|Depends|Architecture|Alternatives):' "$tmp/c/control"
  grep -q "^Architecture: $REPACK_ARCH\$" "$tmp/c/control" || { echo "ERROR: wrong arch"; fail=1; }
  (cd "$tmp/d" && find . -type f -o -type l | sort)
  # Only sshd embeds the version banner.
  if [ -f "$tmp/d/usr/sbin/sshd" ]; then
    grep -aq "$WANT" "$tmp/d/usr/sbin/sshd" || { echo "ERROR: $WANT not in sshd"; fail=1; }
  fi
  # FIDO2 security-key logins: the key types must be compiled in (configure
  # without --disable-security-key). sshd-auth does the signature check.
  for bin in "$tmp"/d/usr/sbin/sshd "$tmp"/d/usr/lib/sshd-auth; do
    [ -f "$bin" ] || continue
    for kt in sk-ssh-ed25519@openssh.com sk-ecdsa-sha2-nistp256@openssh.com; do
      grep -aq "$kt" "$bin" || { echo "ERROR: $kt not in $(basename "$bin")"; fail=1; }
    done
    echo "$(basename "$bin"): security-key types OK"
  done
  # Binaries are sstripped (no section headers), so readelf warns; NEEDED
  # comes from the dynamic segment and is still reliable.
  for bin in "$tmp"/d/usr/sbin/sshd "$tmp"/d/usr/lib/sshd-session "$tmp"/d/usr/lib/sshd-auth \
             "$tmp"/d/usr/libexec/ssh-keygen-openssh "$tmp"/d/usr/lib/sftp-server; do
    [ -f "$bin" ] || continue
    echo "$(basename "$bin"): $(readelf -d "$bin" 2>/dev/null | sed -n 's/.*Shared library: \[\(.*\)\]/\1/p' | tr '\n' ' ')"
  done
  rm -rf "$tmp"
done
[ "$fail" = 0 ] || exit 1

sha256sum -- *.ipk > SHA256SUMS.txt
echo "=== Packages"
ls -l
cat SHA256SUMS.txt
