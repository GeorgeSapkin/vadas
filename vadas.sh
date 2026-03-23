#!/bin/bash
#
# Copyright (c) 2025-2026 George Sapkin
#
# SPDX-License-Identifier: GPL-2.0-only

# TODO: armsr/armv7 is missing UEFI firmware in Fedora
# TODO: malta/be64 and malta/le64 don't seem to boot
readonly TARGETS=(
  'armsr/armv8'
  'malta/be'
  'malta/le'
  'x86/64'
  'x86/generic'
)

readonly OPENWRT_DOWNLOAD_URL='https://downloads.openwrt.org'
readonly MIN_OPENWRT_VER=21

readonly VADAS_CACHE_DIR="${VADAS_CONFIG_DIR:-${HOME}/.cache/vadas}"
readonly VADAS_CONFIG_DIR="${VADAS_CONFIG_DIR:-${HOME}/.config/vadas}"
readonly VADAS_IMAGE_DIR="${VADAS_IMAGE_DIR:-${VADAS_CONFIG_DIR}/images}"
readonly VADAS_TEMPLATE_DIR="${VADAS_TEMPLATE_DIR:-${VADAS_CONFIG_DIR}/templates}"
readonly VADAS_TEMP_DIR="${VADAS_TEMP_DIR:-/tmp/vadas}"

readonly MENU_HELP_BACK='(Enter to select, Esc to go back)'
readonly MENU_HELP_EXIT='(Enter to select, Esc to exit)'

readonly MENU_ITEM_LIMIT=10

readonly NET_NAME='vadas'
readonly NET_MASK='255.255.255.0'
readonly NET_RANGES=('10.0.0.0/8' '172.16.0.0/12' '192.168.0.0/16')

readonly VM_CORES=2
readonly VM_RAM=524288

readonly ICON_ON='●'
readonly ICON_OFF='○'

function _print_help() {
	local cmd="$1"

	printf 'vadas - OpenWrt libvirt VM manager\n\nUsage: %s %s ' "$(basename "$0")" "$cmd"

	case "$cmd" in
	env)
		cat <<-EOF


		Display current environment configuration variables (e.g. directories).
		EOF
		;;
	configure)
		cat <<-EOF
		<subcommand>

		Subcommands:
		  vm [<vm_name>]  Configure VM's network
		EOF
		;;
	create)
		cat <<-EOF
		<subcommand>

		Subcommands:
		  network         Interactively create the virtual network
		  vm              Interactively create a new VM
		EOF
		;;
	clean)
		cat <<-EOF
		<subcommand>

		Subcommands:
		  cache           Clean up cache files
		  images          Clean up unused disk images
		  temp            Clean up temporary files
		EOF
		;;
	cp|copy)
		cat <<-EOF
		[-r] <source> <destination>

		Copy files and directories to and from a VM.
		Source or destination can be a local path or <vm_name>:[<remote_path>].
		EOF
		;;
	list)
		cat <<-EOF
		<subcommand>

		Subcommands:
		  images          List all image files
		  vm              List all created VMs
		EOF
		;;
	remove)
		cat <<-EOF
		<subcommand>

		Subcommands:
		  network         Remove the virtual network
		  vm              Remove a VM
		EOF
		;;
	ps)
		cat <<-EOF
		[--all]

		List running VMs. Use --all to list suspended VMs as well.
		EOF
		;;
	show)
		cat <<-EOF
		<subcommand>

		Subcommands:
		  ip [<vm_name>]  Show the IP address of a VM
		EOF
		;;
	start)
		cat <<-EOF
		[<vm_name>]

		Start a VM and connect to its console.
		EOF
		;;
	stop)
		cat <<-EOF
		[<vm_name>] [--force]

		Stop a running VM. Use --force to immediately destroy the VM.
		EOF
		;;
	*)
		cat <<-EOF
		<command> [<arguments>...]

		When no arguments are supplied, most commands are interactive.

		Resource creation and removal:
		  create          Create resources (e.g., 'vm')
		  configure       Configure a resource (e.g., 'vm')
		  remove|rm       Remove resources (e.g., 'network')
		  list            List resources (e.g., 'vm')
		  clean           Clean up resources (e.g., 'temp')

		Resource management:
		  start           Start a VM and connect to it
		  stop|kill       Stop a running VM (use --force for immediate stop)
		  pause|suspend   Pause a running VM
		  resume          Resume a paused VM
		  cp              Copy files and directories to and from a VM
		  ps              List running VMs (--all includes paused VMs)
		  show            Show resource details (e.g., 'ip')

		Miscellaneous:
		  env             Display environment variables
		  ---help|-h      This help message
		EOF
		;;
	esac
}

function _clean_vm_name() {
	# Strip ANSI color codes and status prefix from the selection to get the raw
	# VM name
	<<< "$1" sed -e 's/\x1b\[[0-9;]*m//g' -e "s/^[${ICON_ON}${ICON_OFF}] //"
}

function _confirm() {
	local prompt="$1"
	local default="${2:-n}"
	local choice
	local options

	if [[ "$default" =~ ^[yY]$ ]]; then
		options='[Y/n]'
		read -r -p "$prompt $options " choice
		case "$choice" in
		[nN] | [nN][oO]) return 1 ;; # No
		*) return 0 ;;               # Yes is default
		esac
	else
		options='[y/N]'
		read -r -p "$prompt $options " choice
		case "$choice" in
		[yY] | [yY][eE][sS]) return 0 ;; # Yes
		*) return 1 ;;                   # No is default
		esac
	fi
}

function _confirm_overwrite() {
	local file_path="$1"
	if [ -f "$file_path" ]; then
		_confirm "Image file '$(basename "$file_path")' already exists. Overwrite?"
		return $?
	fi
	return 0
}

function _connect_to_vm() {
	_ensure virsh

	local vm_name="$1"
	local boot_wait="${2:-0}"

	if _confirm "Connect to console of '$vm_name'?"; then
		stty sane
		echo 'Please press Enter to activate this console after connecting.'
		if [ "$boot_wait" -ne 0 ]; then
			_countdown "$boot_wait" \
				'Waiting for VM to boot to avoid mangled console output...'
		fi
		virsh console "$vm_name"
	fi
}

function _countdown() {
	local seconds="$1"
	local msg="$2"

	tput civis
	trap 'tput cnorm; exit' INT TERM

	echo -n "$msg"
	while [ "$seconds" -gt 0 ]; do
		printf ' %-2d' "$seconds"
		sleep 1
		printf '\b\b\b'
		((seconds--))
	done
	echo ' 0 '

	tput cnorm
	trap - INT TERM
}

function _create_vm() {
	_ensure virsh
	_ensure virt-xml

	local version="$1"
	local target="$2"

	local image_name kernel_name
	local arch boot_wait loader machine nvram_file nvram_template qemu_bin \
		template

	local used_images
	used_images=$(_get_used_images)

	local target_flat=${target//\//-}

	# malta releases don't have profiles.json as of 25.12.1, but snapshots do
	if [[ "$target" == malta/* && "$version" != 'snapshot' ]]; then
		local checksums_path
		checksums_path=$(_get_cached_file_path "$version" "openwrt-$version-$target_flat-checksums.txt")
		if ! _fetch_checksums "$version" "$target" "$checksums_path"; then
			echo "Error: Failed to fetch checksums. The target '$target' may not be available for release '$version'."
			exit 1
		fi

		local options=('ext4' 'squashfs')
		local selected_image
		selected_image=$(_interactive_menu \
			"Select an image ${MENU_HELP_BACK}:" "${options[@]}" \
		)
		if [ $? -ne 0 ]; then
			return 1
		fi

		local file_prefix="openwrt-${version}-"
		if [ "$version" == 'snapshot' ]; then
			file_prefix='openwrt-'
		fi
		local kernel_filename="${file_prefix}${target_flat}-vmlinux.elf"
		local image_filename="${file_prefix}${target_flat}-rootfs-${selected_image}.img.gz"

		local kernel_url image_url
		kernel_url=$(_get_image_url "$version" "$target" "$kernel_filename")
		image_url=$(_get_image_url "$version" "$target" "$image_filename")

		local local_kernel_path
		local_kernel_path=$(_get_cached_file_path "$version" "$kernel_filename")
		local local_image_path
		local_image_path=$(_get_cached_file_path "$version" "$image_filename")

		local kernel_sha256 image_sha256
		if [ -f "$checksums_path" ]; then
			kernel_sha256=$(awk -v f="$kernel_filename" '$1 == f {print $2}' "$checksums_path")
			image_sha256=$(awk -v f="$image_filename" '$1 == f {print $2}' "$checksums_path")
		fi

		_download_image "$kernel_url" "$local_kernel_path" "$kernel_sha256"
		_download_image "$image_url" "$local_image_path" "$image_sha256"

		kernel_name=$(_install_image_file cp "$local_kernel_path" "$used_images")
		image_name=$(_install_image_file gunzip "$local_image_path" "$used_images")
	else
		local profiles_path
		profiles_path=$(_get_cached_file_path "$version" "openwrt-$version-$target_flat-profiles.json")
		if ! _fetch_profiles "$version" "$target" "$profiles_path"; then
			echo "Error: Failed to fetch profiles. The target '$target' may not be available for release '$version'."
			exit 1
		fi

		local profiles_json
		profiles_json=$(cat "$profiles_path")

		# Extract version code from profiles for snapshots
		local version_code
		version_code=$(<<< "$profiles_json" jq -r '.version_code // empty')

		local image_query
		if [[ "$target" == malta/* ]]; then
			image_query='
				.profiles[].images[] |
				select(.type == "rootfs") |
				select(.filesystem == "ext4" or .filesystem == "squashfs") |
				"\(.filesystem) \(.type)"
			'
		else
			image_query='
				.profiles[].images[] |
				select(.type == "combined" or .type == "combined-efi") |
				select(.filesystem == "ext4" or .filesystem == "squashfs") |
				"\(.filesystem) \(.type)"
			'
		fi

		local image_list
		image_list=$(<<< "$profiles_json" jq -r "$image_query" | sort | uniq)

		if [ -z "$image_list" ]; then
			echo 'Error: No images found or failed to parse JSON.'
			exit 1
		fi

		local options
		readarray -t options <<< "$image_list"

		local selected_image
		selected_image=$(_interactive_menu \
			"Select an image ${MENU_HELP_BACK}:" "${options[@]}" \
		)
		if [ $? -ne 0 ]; then
			return 1
		fi

		local fs type
		read -r fs type <<< "$selected_image"

		local image_info
		image_info=$(<<< "$profiles_json" jq -r --arg fs "$fs" --arg type "$type" '
			.profiles[].images[] |
			select(.filesystem == $fs and .type == $type) |
			"\(.name) \(.sha256)"
		' | head -n 1)

		local image_filename image_sha256
		read -r image_filename image_sha256 <<<"$image_info"

		if [ -z "$image_filename" ]; then
			echo 'Error: Could not determine image filename for selection.'
			exit 1
		fi

		local local_image_filename="$image_filename"

		if [ "$version" == 'snapshot' ] && [ -n "$version_code" ]; then
			local_image_filename="${image_filename/openwrt-/openwrt-snapshot-}"
			if [[ "$local_image_filename" == *'.img.gz' ]]; then
				local_image_filename="${local_image_filename/.img.gz/-${version_code}.img.gz}"
			else
				local_image_filename="${local_image_filename%.*}-${version_code}.${local_image_filename##*.}"
			fi
		fi

		local local_image_path
		local_image_path=$(_get_cached_file_path "$version" "$local_image_filename")
		local image_url
		image_url=$(_get_image_url "$version" "$target" "$image_filename")
		_download_image "$image_url" "$local_image_path" "$image_sha256"
		image_name=$(_install_image_file gunzip "$local_image_path" "$used_images")

		# malta targets don't have combined images
		if [[ "$target" == malta/* ]]; then
			local kernel_filename kernel_sha256
			if [[ "$target" == malta/* ]]; then
				local kernel_info
				kernel_info=$(<<< "$profiles_json" jq -r '
					.profiles[].images[] |
					select(.type == "kernel") |
					"\(.name) \(.sha256)"
				' | head -n 1)
				read -r kernel_filename kernel_sha256 <<<"$kernel_info"
			fi

			local local_kernel_filename="$kernel_filename"
			if [ "$version" == 'snapshot' ] && [ -n "$version_code" ] && [ -n "$kernel_filename" ]; then
				local_kernel_filename="${kernel_filename/openwrt-/openwrt-snapshot-}"
				local_kernel_filename="${local_kernel_filename%.*}-${version_code}.${local_kernel_filename##*.}"
			fi

			local local_kernel_path
			local_kernel_path=$(_get_cached_file_path "$version" "$local_kernel_filename")
			local kernel_url
			kernel_url=$(_get_image_url "$version" "$target" "$kernel_filename")
			_download_image "$kernel_url" "$local_kernel_path" "$kernel_sha256"
			kernel_name=$(_install_image_file cp "$local_kernel_path" "$used_images")
		fi
	fi

	case "$target" in
	armsr/armv8)
		arch='aarch64'
		boot_wait=40
		loader='/usr/share/edk2/aarch64/QEMU_EFI-silent-pflash.qcow2'
		machine='virt'
		nvram_file="$VADAS_IMAGE_DIR/$(basename "$image_name" .img).nvram"
		nvram_template='/usr/share/edk2/aarch64/vars-template-pflash.qcow2'
		qemu_bin='/usr/bin/qemu-system-aarch64'
		template=vm_arm
		;;
	malta/be)
		arch='mips'
		qemu_bin='/usr/bin/qemu-system-mips'
		boot_wait=30
		template=vm_malta
		;;
	malta/le)
		arch='mipsel'
		qemu_bin='/usr/bin/qemu-system-mipsel'
		boot_wait=30
		template=vm_malta
		;;
	x86/64)
		arch='x86_64'
		boot_wait=15
		machine='q35'
		qemu_bin='/usr/bin/qemu-system-x86_64'
		template=vm_x86
		;;
	x86/generic)
		arch='i686'
		boot_wait=15
		machine='pc'
		qemu_bin='/usr/bin/qemu-system-i386'
		template=vm_x86
		;;
	esac

	local vm_base_name
	vm_base_name="${image_name%.img}"

	local vm_name
	vm_name=$(_get_unique_vm_name "$vm_base_name")

	local ip
	ip=$(_get_next_ip)
	if [ -z "$ip" ]; then
		echo 'Error: Failed to find an available IP address for the VM.' >&2
		return 1
	fi
	echo "Allocated IP: $ip"

	local vm_xml
	vm_xml=$(_render_template "$VADAS_TEMPLATE_DIR/$template.xml" \
		'VM_CORES'        "$VM_CORES" \
		'VM_NAME'         "$vm_name" \
		'VM_RAM'          "$VM_RAM" \
		'ARCH'            "$arch" \
		'EMULATOR'        "$qemu_bin" \
		'IMAGE'           "$VADAS_IMAGE_DIR/$image_name" \
		'KERNEL'          "$VADAS_IMAGE_DIR/$kernel_name" \
		'LOADER'          "$loader" \
		'MACHINE'         "$machine" \
		'NET_IP'          "$ip" \
		'NET_NAME'        "$NET_NAME" \
		'NVRAM_FILE'      "$nvram_file" \
		'NVRAM_TEMPLATE'  "$nvram_template"
	)

	if _define_vm "$vm_name" "$vm_xml"; then
		if [[ "$target" == malta/* ]]; then
			# MIPS-specific as virsh doesn't preserve the slot definition
			if ! virt-xml "$vm_name" --edit --network address.slot=0x12; then
				echo 'Error: Failed to update network configuration.' >&2
				exit 1
			fi
		fi

		cmd_start "$vm_name" --no-connect

		if _confirm "Configure network for '$vm_name'?" y; then
			sub_cmd_configure_vm "$vm_name" "$boot_wait"
			boot_wait=0
		fi

		_connect_to_vm "$vm_name" "$boot_wait"
	fi

	return 0
}

function _define_vm() {
	_ensure virsh
	_ensure_net "$NET_NAME"

	local vm_name="$1"
	local vm_xml="$2"

	local tmp_xml="$VADAS_TEMP_DIR/${vm_name}.xml"
	mkdir -p "$VADAS_TEMP_DIR"
	echo "$vm_xml" > "$tmp_xml"
	virsh define "$tmp_xml"
	local ret=$?
	rm -f "$tmp_xml"
	return $ret
}

function _download_image() {
	_ensure curl
	_ensure sha256sum

	local url="$1"
	local path="$2"
	local sha256="$3"

	if [ -f "$path" ]; then
		if [ -z "$sha256" ]; then
			echo "File already exists, skipping download: $path"
			return 0
		fi

		echo -n 'Local file found. Verifying checksum...'
		local local_sha
		local_sha=$(sha256sum "$path" | awk '{print $1}')
		if [ "$local_sha" == "$sha256" ]; then
			echo ' OK. Skipping download.'
			return 0
		fi
		echo ' mismatch. Redownloading.'
	fi

	echo "Downloading image from $url..."
	if ! curl -L --progress-bar -o "$path" "$url"; then
		echo 'Error: Download failed.'
		rm -f "$path"
		exit 1
	fi

	if [ -n "$sha256" ]; then
		echo -n 'Verifying checksum of downloaded file...'
		local local_sha
		local_sha=$(sha256sum "$path" | awk '{print $1}')
		if [ "$local_sha" != "$sha256" ]; then
			echo ' checksum of downloaded file is incorrect!'
			exit 1
		fi
		echo ' OK.'
	fi
}

function _ensure() {
	local cmd="$1"
	if ! command -v "$cmd" >/dev/null 2>&1; then
		echo "Error: '$cmd' command not found."
		exit 1
	fi
}

function _ensure_net() {
	_ensure virsh

	local name="$1"

	if ! virsh net-info "$name" >/dev/null 2>&1; then
		echo "Error: Virtual network '$name' does not exist. Please create it first using '$(basename "$0") create network'." >&2
		exit 1
	fi
}

function _fetch_checksums() {
	_ensure curl

	local version="$1"
	local target="$2"
	local checksums_path="$3"

	local url
	url=$(_get_image_url "$version" "$target" '')

	# Checksums are only used for releases so no need to check for snapshots
	if [ ! -f "$checksums_path" ]; then
		_print_msg -n 'Fetching image checksums...'
		# Use a subshell with pipefail to catch curl errors
		if ! ( set -o pipefail; curl -sf "$url" | \
			sed -n 's/.*href="\([^"]*\)".*class="sh">\([^<]*\)<.*/\1 \2/p' > "$checksums_path" )
		then
			_print_msg ' failed.'
			rm -f "$checksums_path"
			return 1
		fi
		_print_msg ' OK.'
	fi
}

function _fetch_dir_list() {
	_ensure curl

	local version="$1"
	local target="$2"
	local output_path="$3"
	local msg="$4"

	local url
	url=$(_get_image_url "$version" "$target" '')

	if [ "$version" == 'snapshot' ] || [ ! -f "$output_path" ]; then
		_print_msg -n "Fetching $msg..."
		if ! curl -sf "$url" |
			grep 'class="n"' |
			sed -n 's/.*href="\([^"]*\)\/".*/\1/p' |
			grep -v '^\.\.$' |
			sort -u > "$output_path"
		then
			_print_msg ' failed.'
			rm -f "$output_path"
			return 1
		fi
		_print_msg ' OK.'
	fi
}

function _fetch_profiles() {
	_ensure curl

	local version="$1"
	local target="$2"
	local profiles_path="$3"

	local url
	url=$(_get_image_url "$version" "$target" 'profiles.json')

	if [ "$version" == 'snapshot' ] || [ ! -f "$profiles_path" ]; then
		_print_msg -n 'Fetching image profiles...'
		if ! curl -sf -o "$profiles_path" "$url"; then
			_print_msg ' failed.'
			rm -f "$profiles_path"
			return 1
		fi
		_print_msg ' OK.'
	fi
}

function _fetch_releases() {
	_ensure curl
	_ensure jq

	echo -n 'Fetching OpenWrt releases...' >&2
	local json
	if ! json=$(curl -sf "$OPENWRT_DOWNLOAD_URL/.versions.json"); then
		echo ' failed.' >&2
		exit 1
	fi
	echo ' OK.' >&2

	<<< "$json" jq -r --argjson min_ver "$MIN_OPENWRT_VER" '
		.versions_list[] |
		select(test("^[0-9]+\\.[0-9]+\\.[0-9]+$")) |
		select(split(".")[0] | tonumber >= $min_ver)
	'
}

function _format_vms_for_menu() {
	local vms="$1"
	vms=$(sort <<< "$vms")

	for vm in $vms; do
		local state
		state=$(_get_vm_state "$vm")
		if [ "$state" == 'running' ]; then
			echo -e "\e[32m${ICON_ON}\e[0m $vm"
		elif [ "$state" == 'paused' ]; then
			echo -e "\e[33m${ICON_ON}\e[0m $vm"
		else
			echo "$ICON_OFF $vm"
		fi
	done
}

function _get_available_image_name() {
	local name="$1"
	local used_images="$2"
	local ext="${name##*.}"
	local base="${name%.*}"
	local suffix=1

	local candidate="$name"
	while true; do
		local path="$VADAS_IMAGE_DIR/$candidate"
		if [ -f "$path" ]; then
			if grep -Fqx "$path" <<< "$used_images"; then
				candidate="${base}-${suffix}.${ext}"
				((suffix++))
				continue
			fi
		fi
		echo "$candidate"
		return 0
	done
}

function _get_cached_file_path() {
	local version="$1"
	local filename="$2"

	if [ "$version" == 'snapshot' ]; then
		mkdir -p "$VADAS_TEMP_DIR"
		echo "$VADAS_TEMP_DIR/$filename"
	else
		mkdir -p "$VADAS_CACHE_DIR"
		echo "$VADAS_CACHE_DIR/$filename"
	fi
}

function _get_image_url() {
	local version="$1"
	local target="$2"
	local filename="${3:-}"
	if [ "$version" == 'snapshot' ]; then
		echo "$OPENWRT_DOWNLOAD_URL/snapshots/targets/$target/$filename"
	else
		echo "$OPENWRT_DOWNLOAD_URL/releases/$version/targets/$target/$filename"
	fi
}

function _get_ip() {
	_ensure virsh
	_ensure xmllint

	local vm_name="$1"
	virsh metadata "$vm_name" --uri urn:vadas 2>/dev/null |
		xmllint --xpath "string(//*[local-name()='ip'])" -
}

function _get_next_ip() {
	_ensure virsh
	_ensure xmllint
	_ensure_net "$NET_NAME"

	local end_ip gateway net_xml start_ip
	net_xml=$(virsh net-dumpxml "$NET_NAME")
	gateway=$(<<< "$net_xml" xmllint --xpath 'string(//ip/@address)' -)
	start_ip=$(<<< "$net_xml" xmllint --xpath 'string(//range/@start)' -)
	end_ip=$(<<< "$net_xml" xmllint --xpath 'string(//range/@end)' -)

	if [ -z "$start_ip" ] || [ -z "$end_ip" ]; then
		return 1
	fi

	local used_ips="$gateway"
	local vms
	vms=$(_get_vm_list --all)
	for vm in $vms; do
		local ip
		ip=$(_get_ip "$vm")
		if [ -n "$ip" ]; then
			used_ips="$used_ips $ip"
		fi
	done

	local a b c d
	IFS=. read -r a b c d <<< "$start_ip"
	local start_int=$((a * 256 ** 3 | b * 256 ** 2 | c * 256 | d))

	IFS=. read -r a b c d <<< "$end_ip"
	local end_int=$((a * 256 ** 3 | b * 256 ** 2 | c * 256 | d))

	local cur="$start_int"
	while [ "$cur" -le "$end_int" ]; do
		local ip_cur=''
		local val=$cur
		for _ in {1..4}; do
			ip_cur=$((val % 256))${ip_cur:+.}$ip_cur
			val=$((val / 256))
		done

		if ! <<< "$used_ips" grep -qFw "$ip_cur"; then
			echo "$ip_cur"
			return 0
		fi
		((cur++))
	done
	return 1
}

function _get_used_images() {
	_ensure virsh
	_ensure xmllint

	local all_xml
	all_xml=$(
		echo '<domains>'
		virsh list --all --name | while read -r vm; do
			[[ -n "$vm" ]] && virsh dumpxml "$vm" 2>/dev/null
		done
		echo '</domains>'
	)

	{
		local disks
		disks=$(<<< "$all_xml" xmllint --xpath '//source/@file' - 2>/dev/null)
		disks="${disks// file=\"/$'\n'}"
		echo "${disks//\"/}"

		<<< "$all_xml" xmllint --xpath '//kernel | //initrd | //loader | //nvram' - 2>/dev/null | \
			sed 's/<[^>]*>/\n/g'
	} | grep -v '^$' | sort -u
}

function _get_unique_vm_name() {
	local name="$1"
	local existing_vms
	existing_vms=$(virsh list --all --name)

	local candidate="$name"
	local base="$name"
	local counter=1
	if [[ "$name" =~ ^(.*)-([0-9]+)$ ]]; then
		base="${BASH_REMATCH[1]}"
		counter="${BASH_REMATCH[2]}"
	fi

	while grep -qFx "$candidate" <<< "$existing_vms"; do
		if [[ "$candidate" == "$base" ]]; then
			candidate="${base}-${counter}"
		else
			((counter++))
			candidate="${base}-${counter}"
		fi
	done

	local new_name
	while true; do
		read -r -e -p 'VM name (allowed: alphanumeric, dot, dash): ' -i "$candidate" new_name >&2
		if [ -z "$new_name" ]; then
			echo 'Error: Name cannot be empty.' >&2
			continue
		fi
		if [[ ! "$new_name" =~ ^[a-zA-Z0-9.-]+$ ]]; then
			echo 'Error: Name must contain only alphanumeric characters, dots, and dashes.' >&2
			continue
		fi
		if grep -qFx "$new_name" <<< "$existing_vms"; then
			echo "Error: VM '$new_name' already exists." >&2
			base="$new_name"
			counter=1
			if [[ "$new_name" =~ ^(.*)-([0-9]+)$ ]]; then
				base="${BASH_REMATCH[1]}"
				counter="${BASH_REMATCH[2]}"
			fi
			candidate="$new_name"
			while grep -qFx "$candidate" <<< "$existing_vms"; do
				if [[ "$candidate" != "$base" ]]; then
					((counter++))
				fi
				candidate="${base}-${counter}"
			done
			continue
		fi
		echo "$new_name"
		return 0
	done
}

function _get_vm_list() {
	_ensure virsh

	local state_flags
	IFS=' ' read -r -a state_flags <<< "$@"
	local vms
	vms=$(virsh list "${state_flags[@]}" --name | grep .)

	for vm in $vms; do
		if virsh metadata "$vm" --uri urn:vadas 2>/dev/null |
			grep -q 'tags'
		then
			echo "$vm"
		fi
	done
}

function _get_vm_state() {
	_ensure virsh

	local vm_name="$1"
	local state
	state=$(virsh domstate "$vm_name" 2>&1)
	if [ $? -ne 0 ]; then
		echo "Error: Unable to get state for '$vm_name':"
		echo "$state"
		exit 1
	fi
	echo "${state/$'\n'/}"
}

function _install_image_file() {
	local method="$1" # cp or gunzip
	local src="$2"
	local used_images="$3"

	local name
	if [ "$method" == 'gunzip' ]; then
		name=$(basename "$src" .gz)
	else
		name=$(basename "$src")
	fi

	name=$(_get_available_image_name "$name" "$used_images")
	local dest="$VADAS_IMAGE_DIR/$name"

	mkdir -p "$VADAS_IMAGE_DIR" >/dev/null 2>&1

	if _confirm_overwrite "$dest"; then
		if [ "$method" == 'gunzip' ]; then
			echo "Unpacking $name image..." >&2
			gunzip -c "$src" > "$dest"
		else
			echo "Copying $name file..." >&2
			cp "$src" "$dest" >&2
		fi
	else
		echo 'Using existing file.' >&2
	fi
	echo "$name"
}

function _interactive_menu() {
	local prompt="$1"
	shift
	local options=("$@")
	local selected=0
	local count=${#options[@]}
	local menu_height=$((MENU_ITEM_LIMIT + 1))

	# Hide cursor
	stty -echo
	tput civis >&2
	trap 'stty echo; tput cnorm >&2; exit' INT TERM

	local first_run=1
	local last_selected=-1

	while true; do
		if (( selected != last_selected )); then
			local start=$((selected - MENU_ITEM_LIMIT / 2))
			if (( start < 0 )); then start=0; fi
			if (( count > MENU_ITEM_LIMIT && start > count - MENU_ITEM_LIMIT )); then
				start=$((count - MENU_ITEM_LIMIT))
			fi

			# Move cursor up to the start of the menu to overwrite
			if (( first_run == 0 )); then
				tput cuu "$menu_height" >&2
			fi

			# Print prompt
			tput el >&2
			echo "$prompt" >&2

			# Print items
			for (( i=0; i<MENU_ITEM_LIMIT; i++ )); do
				local idx=$(( start + i ))
				tput el >&2
				if (( idx < count )); then
					if (( idx == selected )); then
						local clean_item
						clean_item=$(sed 's/\x1b\[[0-9;]*m//g' <<< "${options[idx]}" )
						echo -e "\e[1;34m> ${clean_item}\e[0m" >&2
					else
						echo "  ${options[idx]}" >&2
					fi
				else
					echo '' >&2
				fi
			done
			last_selected=$selected
			first_run=0
		fi

		# Read keyboard input. Arrow keys are sent as escape sequences. Read one
		# byte, and if it's an escape char, try to read the rest of the sequence
		# with a very short timeout.
		read -rsn1 key
		if [[ $key == $'\x1b' ]]; then
			read -rsn5 -t 0.01 rest
			key+="$rest"
		fi

		case "$key" in
			$'\x1b[A') # Up arrow
				((selected--))
				if (( selected < 0 )); then selected=$((count - 1)); fi
				;;
			$'\x1b[B') # Down arrow
				((selected++))
				if (( selected >= count )); then selected=0; fi
				;;
			$'\x1b[5~') # Page Up
				((selected -= MENU_ITEM_LIMIT))
				;;
			$'\x1b[6~') # Page Down
				((selected += MENU_ITEM_LIMIT))
				;;
			$'\x1b') # Escape key
				tput cuu "$menu_height" >&2
				tput ed >&2
				stty echo
				tput cnorm >&2
				trap - INT TERM
				return 1 ;;
			'') # Enter key
				break
				;;
		esac

		if (( selected < 0 )); then selected=0;
		elif (( selected >= count )); then selected=$((count - 1)); fi
	done

	# Clear the menu area completely on exit
	tput cuu "$menu_height" >&2
	tput ed >&2

	stty echo
	tput cnorm >&2
	trap - INT TERM # Clear the trap

	echo "${options[selected]}"
}

function _print_msg() {
	if [[ "$1" == '-n' ]]; then
		echo -n "$2" >&2
	else
		echo "$1" >&2
		((lines_printed++))
	fi
}

function _read_octet() {
	local prompt="$1"
	local min="$2"
	local max="$3"
	local octet
	while true; do
		read -r -p "$prompt (range: $min-$max) [default: $min]: " octet
		if [[ -z "$octet" ]]; then
			octet="$min"
		fi
		if [[ "$octet" =~ ^[0-9]+$ ]] && (( octet >= min && octet <= max )); then
			echo "$octet"
			return 0
		else
			echo "Invalid input. Please enter a number between $min and $max." >&2
		fi
	done
}

function _render_template() {
	local template="$1"
	shift
	if [ ! -f "$template" ]; then
		echo "Error: Template '$template' not found." >&2
		exit 1
	fi
	local content
	content=$(cat "$template")
	while [ "$#" -gt 0 ]; do
		local key="$1"
		local val="$2"
		content="${content//\{\{$key\}\}/$val}"
		shift 2
	done
	echo "$content"
}

function _select_vm() {
	local state_flags
	IFS=' ' read -r -a state_flags <<< "$@"

	local vms
	vms=$(_get_vm_list "${state_flags[@]}")
	if [ -z "$vms" ]; then
		echo 'No VMs with matching state found.' >&2
		return 1
	fi

	local options=()
	while IFS= read -r line; do
		options+=("$line")
	done < <(_format_vms_for_menu "$vms")

	local selected_vm
	selected_vm=$(_interactive_menu \
		"Select a VM ${MENU_HELP_EXIT}:" \
		"${options[@]}" \
	)
	if [ $? -ne 0 ]; then
		return 1
	fi

	_clean_vm_name "$selected_vm"
}

function cmd_clean() {
	local sub_command="$1"
	case "$sub_command" in
	--help|-h)
		_print_help clean
		exit 0
		;;
	cache)
		sub_cmd_clean_cache
		;;
	image|images)
		sub_cmd_clean_images
		;;
	temp)
		sub_cmd_clean_temp
		;;
	*)
		_print_help clean
		exit 1
		;;
	esac
}

function cmd_configure() {
	local sub_command="$1"
	case "$sub_command" in
	--help|-h)
		_print_help configure
		exit 0
		;;
	vm)
		shift
		sub_cmd_configure_vm "$@"
		;;
	*)
		_print_help configure
		exit 1
		;;
	esac
}

function cmd_cp() {
	_ensure scp
	_ensure virsh

	local scp_opts=''
	if [[ "$1" == '-r' ]]; then
		scp_opts='-r'
		shift
	fi

	local src="$1"
	local dest="$2"
	if [ -z "$src" ] || [ -z "$dest" ]; then
		_print_help cp
		exit 1
	fi

	local scp_src="$src"
	if [[ "$src" == *:* ]]; then
		local vm_name="${src%%:*}"
		local remote_path="${src#*:}"
		local vm_ip
		vm_ip=$(sub_cmd_show_ip "$vm_name") || exit 1
		scp_src="root@${vm_ip}:${remote_path}"
	fi

	local scp_dest="$dest"
	if [[ "$dest" == *:* ]]; then
		local vm_name="${dest%%:*}"
		local remote_path="${dest#*:}"
		local vm_ip
		vm_ip=$(sub_cmd_show_ip "$vm_name") || exit 1
		scp_dest="root@${vm_ip}:${remote_path}"
	fi

	scp -O $scp_opts \
		-o LogLevel=ERROR \
		-o StrictHostKeyChecking=no \
		-o UserKnownHostsFile=/dev/null \
		"$scp_src" "$scp_dest"
}

function cmd_create() {
	local sub_command="$1"
	case "$sub_command" in
	--help|-h)
		_print_help create
		exit 0
		;;
	network)
		sub_cmd_create_network
		;;
	vm)
		sub_cmd_create_vm
		;;
	*)
		_print_help create
		exit 1
		;;
	esac
}

function cmd_env() {
	local sub_command="$1"
	case "$sub_command" in
	--help|-h)
		_print_help env
		exit 0
		;;
	esac

	cat <<-EOF
		VADAS_CACHE_DIR=$VADAS_CACHE_DIR
		VADAS_CONFIG_DIR=$VADAS_CONFIG_DIR
		VADAS_IMAGE_DIR=$VADAS_IMAGE_DIR
		VADAS_TEMPLATE_DIR=$VADAS_TEMPLATE_DIR
		VADAS_TEMP_DIR=$VADAS_TEMP_DIR
	EOF
}

function cmd_list() {
	local sub_command="$1"
	case "$sub_command" in
	--help|-h)
		_print_help list
		exit 0
		;;
	image|images)
		sub_cmd_list_images
		;;
	vm|vms)
		cmd_ps --list
		;;
	*)
		_print_help list
		exit 1
		;;
	esac
}

function cmd_pause() {
	_ensure virsh

	local vm_name
	vm_name="$1"

	case "$vm_name" in
	--help|-h)
		_print_help pause
		exit 0
		;;
	esac

	if [ -z "$vm_name" ]; then
		vm_name=$(_select_vm --state-running)
		[ $? -ne 0 ] && exit 0
	fi

	local state
	state=$(_get_vm_state "$vm_name")
	if [ "$state" != 'running' ]; then
		exit 0
	fi

	if ! virsh suspend "$vm_name"; then
		echo "Failed to pause '$vm_name'."
		exit 1
	fi
}

function cmd_ps() {
	_ensure virsh

	local arg="$1"
	case "$arg" in
	--help|-h)
		_print_help ps
		exit 0
		;;
	--list) arg='--all' ;;
	--all)  arg='--state-running --state-paused' ;;
	*)      arg='--state-running' ;;
	esac

	local vms
	vms=$(_get_vm_list "$arg")
	[ -z "$vms" ] && return 0
	_format_vms_for_menu "$vms"
}

function cmd_remove() {
	local sub_command="$1"
	local arg="$2"
	case "$sub_command" in
	--help|-h)
		_print_help remove
		exit 0
		;;
	network)
		sub_cmd_remove_network
		;;
	vm)
		sub_cmd_remove_vm "$arg"
		;;
	*)
		_print_help remove
		exit 1
		;;
	esac
}

function cmd_resume() {
	_ensure virsh

	local vm_name
	vm_name="$1"
	case "$vm_name" in
	--help|-h)
		_print_help resume
		exit 0
		;;
	esac

	if [ -z "$vm_name" ]; then
		vm_name=$(_select_vm --state-paused)
		[ $? -ne 0 ] && exit 0
	fi

	local state
	state=$(_get_vm_state "$vm_name")
	if [ "$state" != 'paused' ]; then
		exit 1
	fi

	if ! virsh resume "$vm_name"; then
		echo "Failed to resume '$vm_name'."
		exit 1
	fi

	_connect_to_vm "$vm_name"
}

function cmd_show() {
	local sub_command="$1"
	case "$sub_command" in
	--help|-h)
		_print_help show
		exit 0
		;;
	ip)
		shift
		sub_cmd_show_ip "$@"
		;;
	*)
		_print_help show
		exit 1
		;;
	esac
}

function cmd_start() {
	_ensure virsh

	local vm_name
	local connect=1

	for arg in "$@"; do
		case "$arg" in
		--help|-h)
			_print_help start
			exit 0
			;;
		--no-connect)
			connect=0
			;;
		*)
			if [ -z "$vm_name" ]; then
				vm_name="$arg"
			fi
			;;
		esac
	done

	if [ -z "$vm_name" ]; then
		vm_name=$(_select_vm --all)
		[ $? -ne 0 ] && exit 0
	fi

	local state
	state=$(_get_vm_state "$vm_name")
	local cmd
	case "$state" in
	paused)
		cmd=resume
		;;
	'shut off')
		cmd=start
		;;
	*)
		;;
	esac

	if [ -n "$cmd" ] && ! virsh "$cmd" "$vm_name"; then
		echo "Failed to $cmd '$vm_name'."
		exit 1
	fi

	if [ "$connect" -eq 1 ]; then
		_connect_to_vm "$vm_name"
	fi
}

function cmd_stop() {
	_ensure virsh

	local vm_name
	local force=0

	for arg in "$@"; do
		case "$arg" in
		--help|-h)
			_print_help stop
			exit 0
			;;
		--force)
			force=1
			;;
		*)
			if [ -z "$vm_name" ]; then
				vm_name="$arg"
			fi
			;;
		esac
	done

	if [ -z "$vm_name" ]; then
		vm_name=$(_select_vm --state-running --state-paused)
		[ $? -ne 0 ] && exit 0
	fi

	local state
	state=$(_get_vm_state "$vm_name")
	if [ "$state" = 'running' ]; then
		if (( force == 1 )); then
			virsh destroy "$vm_name"
		else
			virsh shutdown "$vm_name"
		fi
	else
		echo "'$vm_name' is not running."
	fi
}

function sub_cmd_clean_cache() {
	if [ -d "$VADAS_CACHE_DIR" ]; then
		if _confirm "Are you sure you want to remove all files in '$VADAS_CACHE_DIR'?"; then
			rm -rf "${VADAS_CACHE_DIR:?}"/*
		fi
	else
		echo "Cache directory '$VADAS_CACHE_DIR' does not exist."
	fi
}

function sub_cmd_clean_images() {
	_ensure virsh

	local used_images
	used_images=$(_get_used_images)

	local all_images
	all_images=$(ls -1 "$VADAS_IMAGE_DIR"/* 2>/dev/null)

	local unused_images=()
	for img in $all_images; do
		if ! grep -qF "$img" <<< "$used_images"; then
			unused_images+=("$img")
		fi
	done

	if [ ${#unused_images[@]} -eq 0 ]; then
		echo 'No unused images found.'
		return 0
	fi

	echo 'The following images are not used by any VM:'$'\n'
	for img in "${unused_images[@]}"; do
		echo "$ICON_OFF $(basename "$img")"
	done

	if _confirm $'\n''Are you sure you want to remove these images?'; then
		for img in "${unused_images[@]}"; do
			rm -f "$img"
		done
	fi
}

function sub_cmd_clean_temp() {
	if [ -d "$VADAS_TEMP_DIR" ]; then
		if _confirm "Are you sure you want to remove all files in '$VADAS_TEMP_DIR'?"; then
			rm -rf "${VADAS_TEMP_DIR:?}"/*
		fi
	else
		echo "Temporary directory '$VADAS_TEMP_DIR' does not exist."
	fi
}

function sub_cmd_configure_vm() {
	_ensure expect
	_ensure virsh
	_ensure xmllint
	_ensure_net "$NET_NAME"

	local vm_name="$1"
	local boot_wait="${2:-0}"
	local sleep_time="${3:-0.5}"
	if [ -z "$vm_name" ]; then
		vm_name=$(_select_vm --all)
		[ $? -ne 0 ] && exit 0
	fi

	local state
	state=$(_get_vm_state "$vm_name")
	if [ "$state" != "running" ]; then
		echo "Error: VM '$vm_name' is not running. Please start it first." >&2
		exit 1
	fi

	local gateway net_xml netmask
	net_xml=$(virsh net-dumpxml "$NET_NAME")
	gateway=$(<<< "$net_xml" xmllint --xpath 'string(//ip/@address)' -)
	netmask=$(<<< "$net_xml" xmllint --xpath 'string(//ip/@netmask)' -)

	if [ -z "$gateway" ]; then
		echo "Error: Could not parse network configuration for '$NET_NAME'." >&2
		exit 1
	fi

	local vm_ip
	vm_ip=$(_get_ip "$vm_name")

	if [ -z "$vm_ip" ]; then
		echo "Error: VM '$vm_name' does not have an assigned IP in metadata." >&2
		exit 1
	fi

	if [ "$boot_wait" -ne 0 ]; then
		_countdown "$boot_wait" 'Waiting for VM to boot before configuring...'
	fi

	local cmds
	cmds=$(cat <<-EOF
	uci set network.lan=interface
	uci set network.lan.device='br-lan'
	uci set network.lan.proto='static'
	uci set network.lan.ipaddr='$vm_ip'
	uci set network.lan.netmask='${netmask:-255.255.255.0}'
	uci set network.lan.ip6assign='60'
	uci add_list network.lan.dns='$gateway'

	uci add network route
	uci set network.@route[-1].interface='lan'
	uci set network.@route[-1].target='0.0.0.0/0'
	uci set network.@route[-1].gateway='$gateway'

	uci commit network
	service network restart
	EOF
	)

	expect <<-EOF
	set cmds {$cmds}

	set timeout 30
	spawn virsh console $vm_name

	expect {
		"Connected to domain" { exp_continue }
		"Escape character is" {
			sleep 0.5
			send "\r"
		}
		timeout { exit 1 }
	}

	sleep $sleep_time
	send "\r"

	expect {
		-re "root@.*#" {}
		timeout { exit 1 }
	}

	foreach line [split \$cmds "\n"] {
		if {\$line ne ""} {
			send "\$line\r"
			sleep 0.1
		}
	}

	expect "br-lan: port 1(eth1) entered forwarding state"

	sleep 0.5
	send "\x1d"
	expect eof
	EOF
}

function sub_cmd_create_network() {
	_ensure ip
	_ensure virsh

	if virsh net-info "$NET_NAME" >/dev/null 2>&1; then
		echo "Error: Network '$NET_NAME' already exists."
		exit 1
	fi

	while true; do
		local interfaces
		interfaces=$(ip -o link show | awk -F': ' '{print $2}' | grep -v "^lo$" | sort)

		if [ -z "$interfaces" ]; then
			echo 'Error: No network interfaces found.'
			exit 1
		fi

		local options
		readarray -t options <<< "$interfaces"

		local selected_iface
		selected_iface=$(_interactive_menu \
			"Select an interface ${MENU_HELP_EXIT}:" "${options[@]}" \
		)
		[ $? -ne 0 ] && exit 0
		echo "Selected interface: $selected_iface"

		while true; do
			local selected_range
			selected_range=$(_interactive_menu \
				"Select a network range ${MENU_HELP_BACK}:" \
				"${NET_RANGES[@]}" \
			)
			if [ $? -ne 0 ]; then
				tput cuu1
				tput el
				break # go back to interface selection
			fi
			echo "Selected range: $selected_range"

			local ip_addr octet2 octet3
			case "$selected_range" in
			'10.0.0.0/8')
				octet2=$(_read_octet 'Enter second octet' 0 254)
				octet3=$(_read_octet 'Enter third octet' 0 254)
				ip_addr="10.$octet2.$octet3.1"
				;;
			'172.16.0.0/12')
				octet2=$(_read_octet 'Enter second octet' 16 31)
				octet3=$(_read_octet 'Enter third octet' 0 254)
				ip_addr="172.$octet2.$octet3.1"
				;;
			'192.168.0.0/16')
				octet3=$(_read_octet 'Enter third octet' 0 254)
				ip_addr="192.168.$octet3.1"
				;;
			esac

			echo "Virtual gateway IP: $ip_addr"
			echo "Virtual gateway netmask: $NET_MASK"

			local ip_base="${ip_addr%.*}"
			local net_xml
			net_xml=$(_render_template "$VADAS_TEMPLATE_DIR/network.xml" \
				'NET_NAME'   "$NET_NAME" \
				'INTERFACE'  "$selected_iface" \
				'IP_ADDR'    "$ip_addr" \
				'IP_START'   "${ip_base}.2" \
				'IP_END'     "${ip_base}.254" \
				'NET_MASK'   "$NET_MASK"
			)
			local tmp_xml="$VADAS_TEMP_DIR/$NET_NAME.xml"
			mkdir -p "$VADAS_TEMP_DIR"
			echo "$net_xml" > "$tmp_xml"
			virsh net-define "$tmp_xml"
			virsh net-start "$NET_NAME"
			virsh net-autostart "$NET_NAME"
			rm -f "$tmp_xml"

			return 0
		done
	done
}

function sub_cmd_create_vm() {
	_ensure curl
	_ensure gunzip
	_ensure jq
	_ensure sha256sum
	_ensure virsh
	_ensure virt-xml

	_ensure_net "$NET_NAME"

	mkdir -p "$VADAS_IMAGE_DIR"
	mkdir -p "$VADAS_TEMP_DIR"

	readarray -t releases < <(_fetch_releases)

	if [ "${#releases[@]}" -eq 0 ]; then
		echo 'Error: No releases found.'
		exit 1
	fi

	while true; do
		local series_options=('snapshot')
		local major_minors
		if [ "${#releases[@]}" -gt 0 ]; then
			major_minors=$(printf '%s\n' "${releases[@]}" | cut -d. -f1,2 | sort -rV | uniq)
			readarray -t mm_arr <<< "$major_minors"
			series_options+=("${mm_arr[@]}")
		fi

		local series
		series=$(_interactive_menu \
			"Select a release series ${MENU_HELP_EXIT}:" "${series_options[@]}" \
		)
		[ $? -ne 0 ] && exit 0

		local version
		if [[ "$series" == 'snapshot' ]]; then
			version='snapshot'
		else
			local point_releases=()
			for r in "${releases[@]}"; do
				if [[ "$r" == "$series".* ]]; then
					point_releases+=("$r")
				fi
			done
			readarray -t point_releases < <(printf '%s\n' "${point_releases[@]}" | sort -rV)

			version=$(_interactive_menu \
				"Select a ${series} point release ${MENU_HELP_BACK}:" "${point_releases[@]}" \
			)
			if [ $? -ne 0 ]; then
				continue
			fi
		fi

		local lines_printed=0
		_print_msg "Selected release: $version"

		local target_list=("${TARGETS[@]}")
		local targets_path
		targets_path=$(_get_cached_file_path "$version" "openwrt-$version-targets.txt")
		if _fetch_dir_list "$version" '' "$targets_path" 'targets'; then
			local available_targets
			available_targets=$(cat "$targets_path")
			local filtered_targets=()
			local fetched_subtargets=' '
			for t in "${target_list[@]}"; do
				local target="${t%%/*}"
				local subtarget="${t#*/}"
				if grep -qFw "$target" <<< "$available_targets"; then
					local subtargets_path
					subtargets_path=$(_get_cached_file_path "$version" "openwrt-$version-$target-subtargets.txt")
					if [[ "$fetched_subtargets" != *" $target "* ]]; then
						_fetch_dir_list "$version" "$target" "$subtargets_path" "subtargets for $target"
						fetched_subtargets+="$target "
					fi
					if [ -f "$subtargets_path" ] && grep -qFw "$subtarget" "$subtargets_path"; then
						filtered_targets+=("$t")
					fi
				fi
			done
			target_list=("${filtered_targets[@]}")
		fi

		while true; do
			local target
			target=$(_interactive_menu \
				"Select a target ${MENU_HELP_BACK}:" "${target_list[@]}" \
			)
			if [ $? -ne 0 ]; then
				tput cuu "$lines_printed"
				tput ed
				break
			fi
			local lines_checkpoint=$lines_printed
			_print_msg "Selected target: $target"

			if ! _create_vm "$version" "$target"; then
				tput cuu $((lines_printed - lines_checkpoint))
				tput ed
				lines_printed=$lines_checkpoint
				continue
			fi
			return 0
		done
	done
}

function sub_cmd_list_images() {
	local used_images
	used_images=$(_get_used_images)

	local all_images
	all_images=$(ls -1 "$VADAS_IMAGE_DIR" 2>/dev/null)

	if [ -z "$all_images" ]; then
		echo "No images found in $VADAS_IMAGE_DIR."
		return 0
	fi

	for img in $all_images; do
		if grep -qF "$img" <<< "$used_images"; then
			echo -e "\e[32m${ICON_ON}\e[0m $(basename "$img")"
		else
			echo "$ICON_OFF $(basename "$img")"
		fi
	done
}

function sub_cmd_remove_network() {
	_ensure virsh
	_ensure xmllint

	if ! virsh net-info "$NET_NAME" >/dev/null 2>&1; then
		echo "Network '$NET_NAME' not found."
		return 0
	fi

	local dependent_vms=''
	local network vms
	# filter out empty lines
	vms=$(virsh list --all --name | grep .)
	for vm in $vms; do
		network=$(virsh dumpxml "$vm" 2>/dev/null |
			xmllint --xpath "string(//interface/source[@network='$NET_NAME']/@network)" - 2>/dev/null)
		if [ -n "$network" ]; then
			dependent_vms="$dependent_vms $vm"
		fi
	done

	if [ -n "$dependent_vms" ]; then
		echo -e "Error: The following VMs are using network '$NET_NAME':\n"
		_format_vms_for_menu "${dependent_vms// /$'\n'}"
		echo -e '\nPlease remove them before removing the network.'
		exit 1
	fi

	if _confirm "Are you sure you want to remove network '$NET_NAME'?"; then
		virsh net-destroy "$NET_NAME"
		virsh net-undefine "$NET_NAME"
	fi
}

function sub_cmd_remove_vm() {
	_ensure virsh

	local vm_name="$1"

	if [ -z "$vm_name" ]; then
		vm_name=$(_select_vm --all)
		[ $? -ne 0 ] && exit 0
	fi

	if [ "$(_get_vm_state "$vm_name")" == 'running' ]; then
		echo "WARNING: VM '$vm_name' is running!"
		if ! _confirm 'Are you sure you want to force stop and remove it?'; then
			return 0
		fi
		virsh destroy "$vm_name"
	elif ! _confirm "Are you sure you want to remove VM '$vm_name'?"; then
		return 0
	fi

	virsh undefine "$vm_name" --nvram --remove-all-storage
}

function sub_cmd_show_ip() {
	_ensure virsh
	_ensure xmllint

	local vm_name="$1"
	if [ -z "$vm_name" ]; then
		vm_name=$(_select_vm --all)
		[ $? -ne 0 ] && exit 0
	fi

	local vm_ip
	vm_ip=$(_get_ip "$vm_name")

	if [ -n "$vm_ip" ]; then
		echo "$vm_ip"
	else
		echo "Error: No IP found in metadata for '$vm_name'." >&2
		exit 1
	fi
}

case "${1:-}" in
clean)           cmd_clean "$2" ;;
configure)       cmd_configure "${@:2}" ;;
cp|copy)         cmd_cp "${@:2}" ;;
create)          cmd_create "$2" ;;
env)             cmd_env "$2" ;;
images)          sub_cmd_list_images ;;
list)            cmd_list "$2" ;;
pause|suspend)   cmd_pause "${@:2}" ;;
ps)              cmd_ps "$2" ;;
remove|rm)       cmd_remove "$2" "$3" ;;
resume)          cmd_resume "${@:2}" ;;
show)            cmd_show "${@:2}" ;;
start)           cmd_start "${@:2}" ;;
stop|kill)       cmd_stop "${@:2}" ;;
--help|-h)       _print_help ;;
*)               _print_help; exit 1 ;;
esac
