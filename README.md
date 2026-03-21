# Vadas

Vadas is a command-line tool for managing OpenWrt virtual machines using
QEMU/KVM and libvirt. It simplifies the process of downloading official OpenWrt
images, creating, and configuring VMs for various architectures, and managing
their lifecycle.

Vadas means commander, leader, or chief in Lithuanian.

Supported OpenWrt versions: 23.05+

Supported architectures (depending on availability in release):

- armsr/armv8
- malta/be
- malta/le
- x86/64
- x86/generic

## Dependencies

This script requires the following tools to be installed:
- `bash` (v4.1+)
- `coreutils` (`sha256sum`, `gunzip`)
- `curl`
- `edk2-aarch64` for aarch64 QEMU EFI support
- `expect`
- `iproute2` (`ip`)
- `jq`
- `libvirt`
- `qemu-system-*` (e.g., `qemu-system-x86`, `qemu-system-aarch64`)
- `virt-install` (`virt-xml`)

## Setup

### Virsh (non-root user)

To allow `virsh` to be managed by a non-root user, add your user to the
`kvm` and `libvirt` groups. A new login session is required for this change
take effect.

```shell
sudo usermod -aG kvm,libvirt $(whoami)
```

### Installation

`make install`

## Usage

`vadas <command> [<subcommand>] [<options>]`

When no arguments are supplied, most commands are interactive.

## Commands

- **create network**: Interactively create the `vadas` virtual network.
- **create vm**: Interactively download an OpenWrt image and create a new VM.
- **configure vm [<vm_name>]**: Automatically configure the network for a
  running VM via its console.
- **list vm**: List all VMs managed by `vadas`.
- **ps [--all]**: List running VMs. `--all` includes paused VMs.
- **show ip [<vm_name>]**: Show the IP address of a VM.
- **start [<vm_name>]**: Start a VM and connect to its console.
- **stop [<vm_name>] [--force]**: Shut down a VM. `--force` will destroy it.
- **pause [<vm_name>]**: Pause a running VM.
- **resume [<vm_name>]**: Resume a paused VM.
- **remove vm [<vm_name>]**: Remove a VM and its associated storage.
- **remove network**: Remove the `vadas` virtual network.
- **remove image [<image_name>]**: Remove a downloaded disk image.
- **clean images**: Remove disk images not used by any VM.
- **clean temp**: Remove temporary files.
- **env**: Display environment variables used by `vadas`.

## Environment Variables

- `VADAS_CONFIG_DIR`: Configuration directory (default: `$HOME/.config/vadas`).
- `VADAS_IMAGE_DIR`: Image storage directory (default: `$VADAS_CONFIG_DIR/images`).
- `VADAS_TEMPLATE_DIR`: Template directory (default: `$VADAS_CONFIG_DIR/templates`).
- `VADAS_TEMP_DIR`: Temporary file directory (default: `/tmp/vadas`).


## License

GNU General Public License v2.0 only
