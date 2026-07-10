
# Project Goal

Simplify the process of creating an ISO auto install image for ubuntu server or desktop versions to install the OS on local or virtual machines without the need of any user interaction during the process. Auto-provision users and SSH certificates.

# My use case

In my use case we have multiple headless servers to provision. We use this autoinstall ISO, flash them directly on the servers SSD and boot them. After a while we set a hostname in the router for the machines. The host name will be adapted after a reboot.  

# Approach

- A minimal (debian-slim) devcontainer provides the necessary tools to create an autoinstall iso image.
- The user configures the desired setting including users, ssh certificates, network settings and applications installs in user-data.trecs (you can rename it of course!)
- The `generate_autoinstall_iso.sh` script is used to download the specified ubuntu flavor and versions. The original Ubuntu iso images are patched with a user-data.trecs and modifications to the GRUB bootloader to enable autoboot to RAM. The tool `xorriso` is used  to create the autoinstall iso images.

# Usage

## Step 0 Requirements

- Docker + VScode installed on your machine
- Open the project in VScode and open the devcontainer. The devcontainer will install all necessary tools to create the autoinstall iso images.

## Step 1
In `user-data.trecs`  initial users (cape and trecs) are created with encrypted passwords. See the comments in the file how to generate the encrypted passwords. You can also add ssh keys for the users if you want to be able to ssh into the machine after installation:
```yaml
users:
  - name: trecs
    gecos: trecs developer
    groups: users, admin, docker, sudo
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    shell: /bin/bash
    # password hash created using: openssl passwd -6 YOUR_PASSWORD
    passwd: "$6$wZbZSrDA1OWzPZ7t$qQcjn2sIw1yY8PmluT5dfocYBszOWLrqwXsLXLvrQCJ7umaCGVP5S.lWdGGzQY.lEKbGweGiAZHBjazZGy4S9."
    lock_passwd: false
    ssh_authorized_keys:
      - ssh-ed25519 AAAALALALALALALALAAAALLALALA5AAAAIDSH6TV6Cg0FkJFw3ModUCRQcd9J+QZ5bN3Z8xM2/mti ssh-recs-testbed
```

## Step 2

Invoke ./generate_autoinstall_iso.sh `<flavor>` `<version>` `<tty>` `[baudrate]` in the VScode terminal.

  `flavor`   : `server` | `desktop`

  `version`  : codename (e.g. `questing`) or numeric (e.g. `25.10`)

  `tty`      : serial console TTY (e.g. `ttyS2`)

  `baudrate` : serial console speed (e.g. `115200n8`, default: `115200n8`)

After downloading the original iso, the patching progress will take around 2-4 minutes. 


Example: 
`./generate_autoinstall_iso.sh server 26.04 ttyS2` will create a timestamped ISO file in the root folder, e.g., `ubuntu_26.04_server_ttys2_autoinstall_2026-06-16__19-48.iso` 

## Step 3

Flash on USB or directly on M.2 SSD. I recommend `balena etcher` 


> 🚨 **WARNING — This installer will erase the first found disk**
>
> The autoinstall image is configured to erase the primary disk and install Ubuntu automatically. On first boot the installer is loaded into RAM from the boot device and will wipe the target drive. Carefully verify the correct target device before flashing or booting.
>
> Recommended checks before flashing or booting:
> - Unplug other removable drives if possible to avoid accidental wipes.
> - Test the generated ISO in a VM (for example with QEMU) before using it on real hardware.

Storage config used by the installer:

```yaml
storage:
  layout:
    name: direct  # install to the first (only) available disk
```

## Step 4 

I assume that the BIOS of the machine is configured to boot automatically from USB. 

Wait for 10-15 minutes. 

The machine will auto-install, reboot, update the OS and you will see a machine "ubuntu-autoinstall-$mac" in your network. The $mac (MAC Address) of the first ethernet device helps us to set a DHCP hostname in the router, which will automatically propagate to the Ubuntu as new hostname after a reboot. 

Using openWRT you can set the hostname via:
  1. `Overview:` `Active DHCP Leases` --> find the new node and click on `Set Static`
  2. `Network:` `DHCP and DNS` --> `Static Leases` --> find the new node and click on `Edit` --> set the hostname to "NAME_OF_YOUR_CHOICE" and save.
  3. Reboot the machine and you should see the new hostname in your network and as machine name on login.


Below are some code snippets responsible for this behaviour: 
```yaml
late-commands:
  # Set MAC-based hostname before first boot so the router sees it on the first DHCP request
  - |
    iface=$(ls /sys/class/net | grep -E '^(en|eth|ens|eno)' | grep -v lo | head -n1)
    mac=$(cat /sys/class/net/$iface/address | tr -d ':')
    hostname="ubuntu-autoinstall-$mac"
    echo "$hostname" > /target/etc/hostname
    sed -i '/^127\.0\.1\.1/d' /target/etc/hosts
    printf '127.0.1.1\t%s\n' "$hostname" >> /target/etc/hosts

...
write_files:
  - path: /usr/local/bin/dhcp-hostname-refresh.sh
  ... 
  - path: /etc/systemd/system/dhcp-hostname-refresh.service
```

On first boot the RECSDaemon is automatically installed. RECSDaemon is the communication interface between our servers BMC and the Ubuntu OS. This is probably not your use case. Just comment it :)
```yaml
cd /tmp && git clone https://github.com/christmann/RECSDaemon.git && cd RECSDaemon && mkdir build && cd build && cmake .. && make install
```

# Add new ubuntu versions:

Easy! See the array in `generate_autoinstall_iso.sh` and the desired versions. Don't forget to make a PR :)

```bash
declare -A ubuntu_releases=(
  [questing]="25.10"
  [reso