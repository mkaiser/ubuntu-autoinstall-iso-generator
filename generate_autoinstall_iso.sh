#!/bin/bash
# Author: Martin Kaiser
# SPDX-License-Identifier: MIT
#
# MIT License
# Copyright (c) 2026 Martin Kaiser
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.
set -e
timestamp=$(date +%Y-%m-%d__%H-%M)
start_time=$(date +%s)

# All known Ubuntu releases.
# Current releases + codenames: https://releases.ubuntu.com/
declare -A ubuntu_releases=(
  [questing]="25.10"
  [resolute]="26.04"
)

usage() {
  echo "Usage: $0 <flavor> <version>"
  echo "  flavor   : server | desktop"
  echo "  version  : codename (e.g. questing) or numeric (e.g. 25.10)"
  echo "  Known codenames: ${!ubuntu_releases[*]}"
  exit 1
}

[[ $# -ne 2 ]] && usage

flavor="$1"
version_arg="$2"

# Resolve version_arg: accept codename or numeric version
if [[ -v ubuntu_releases["$version_arg"] ]]; then
  code_name="$version_arg"
  ubuntu_version="${ubuntu_releases[$code_name]}"
else
  # Treat as numeric version; find the matching codename for display
  ubuntu_version="$version_arg"
  code_name=""
  for cn in "${!ubuntu_releases[@]}"; do
    if [[ "${ubuntu_releases[$cn]}" == "$version_arg" ]]; then
      code_name="$cn"
      break
    fi
  done
  if [[ -z "$code_name" ]]; then
    echo "ERROR: version '${version_arg}' not found in known releases"
    exit 1
  fi
fi

case "$flavor" in
  server)  iso_suffix="live-server-amd64.iso" ;;
  desktop) iso_suffix="desktop-amd64.iso" ;;
  *)
    echo "ERROR: Unknown flavor '${flavor}'. Use 'server' or 'desktop'."
    exit 1
esac

source_iso="ubuntu-${ubuntu_version}-${iso_suffix}"
source_iso_url="https://releases.ubuntu.com/${ubuntu_version}/${source_iso}"
output_iso="ubuntu_${ubuntu_version}_${flavor}_autoinstall_${timestamp}.iso"

if ! command -v xorriso &>/dev/null; then
  echo "ERROR: xorriso not found. Install it with: sudo apt install xorriso"
  exit 1
fi

echo "Generating autoinstall provisioning ISO at ${timestamp} (Ubuntu ${ubuntu_version} ${code_name} ${flavor})"

# ── Step 1: Download source ISO (cached) ─────────────────────────────────────
if [[ ! -f "$source_iso" ]]; then
  echo "Downloading Ubuntu ${ubuntu_version} ${flavor} from ${source_iso_url} ..."
  wget --show-progress -O "$source_iso" "$source_iso_url"
else
  echo "Using cached source ISO: $source_iso"
fi

# ── Step 2: Set up work directory ────────────────────────────────────────────
work_dir=$(mktemp -d /tmp/trecs_iso_XXXXXX)
cleanup() { rm -rf "$work_dir"; }
trap cleanup EXIT

# ── Step 3: Extract ISO filesystem content ────────────────────────────────────
echo "Extracting ISO content ..."
xorriso -osirrox on -dev "$source_iso" -extract / "$work_dir" 2>/dev/null
chmod -R u+w "$work_dir"

# ── Step 4: Patch grub.cfg ────────────────────────────────────────────────────
# - timeout=0              : boot immediately, no interactive menu (headless)
# - autoinstall            : trigger subiquity unattended installer
# - ds=nocloud\;s=/cdrom/nocloud/ : point cloud-init at the seed dir baked into the ISO
# - toram                  : copy live system to RAM so the SSD can be wiped + reinstalled
echo "Patching grub.cfg ..."
sed -i \
  -e 's/^set timeout=.*/set timeout=0/' \
  -e 's/^set timeout_style=.*/set timeout_style=countdown/' \
  -e '/linux.*casper\/vmlinuz/s/$/ autoinstall ds=nocloud\\;s=\/cdrom\/nocloud\/ toram/' \
  "${work_dir}/boot/grub/grub.cfg"

# ── Step 5: Inject nocloud seed ───────────────────────────────────────────────
# user-data : the autoinstall / cloud-init config
# meta-data : required by the nocloud datasource (can be empty)
echo "Injecting autoinstall config ..."
mkdir -p "${work_dir}/nocloud"
cp "$(pwd)/user-data.trecs" "${work_dir}/nocloud/user-data"
touch "${work_dir}/nocloud/meta-data"

# ── Step 6: Repack with correct El Torito / EFI boot structure ───────────────
# Problem with the previous cp + xorriso-dev approach: xorriso growing the ISO
# 9660 section did not update the GPT, so the appended EFI partition became
# unreachable. Proxmox/UEFI boot then fails with "not a bootable disk".
#
# Fix: full remaster via xorriso -as mkisofs, which rebuilds the entire boot
# structure (MBR hybrid, El Torito BIOS entry, appended EFI partition + GPT).
#
# Boot parameters are derived dynamically from the source ISO so this works for
# any Ubuntu version and both server and desktop flavors.
#
# The '-e' EFI El Torito entry from the source ISO encodes the appended EFI
# partition at its original offset/size. We replace it with the generic
# 'appended_partition_2:::' form so xorriso resolves it against the newly
# appended EFI partition image in the output ISO.
echo "Repacking ISO (this takes a while) ..."

el_torito=$(xorriso -indev "$source_iso" -report_el_torito as_mkisofs 2>/dev/null | \
  sed "s|'--interval:appended_partition_2[^']*'|'--interval:appended_partition_2:::'|" | \
  tr '\n' ' ')

if ! eval "xorriso -as mkisofs $el_torito -r -V Ubuntu-Autoinstall -o '${output_iso}' '${work_dir}'" >/dev/null; then
  echo "ERROR: xorriso repack failed (see error output above)"
  exit 1
fi

elapsed=$(( $(date +%s) - start_time ))
printf "Successfully created %s after %02d:%02d:%02d elapsed.\n" \
  "$output_iso" $(( elapsed/3600 )) $(( elapsed%3600/60 )) $(( elapsed%60 ))


