#!/bin/bash
#
# Copyright (c) 2025-2026 George Sapkin
#
# SPDX-License-Identifier: GPL-2.0-only

readonly VADAS_CONFIG_DIR="${VADAS_CONFIG_DIR:-${HOME}/.config/vadas}"
readonly VADAS_IMAGE_DIR="${VADAS_IMAGE_DIR:-${VADAS_CONFIG_DIR}/images}"

readonly REMOTE_USER='root'

function _comp_cp() {
	local start_idx=2

	if [ "${COMP_WORDS[2]}" == '-r' ]; then
		start_idx=3
	fi

	if [ ${COMP_CWORD} -eq 2 ] && [[ "${cur}" == -* || -z "${cur}" ]]; then
		COMPREPLY+=( $(compgen -W -r -- "${cur}") )
	fi

	if [[ ${COMP_CWORD} -ge ${start_idx} ]]; then
		local cur="${COMP_WORDS[COMP_CWORD]}"
		local prev="${COMP_WORDS[COMP_CWORD-1]}"

		# SCENARIO 1: Word-split has occurred at the colon
		if [[ "$prev" == ":" ]]; then
			local vm_name="${COMP_WORDS[COMP_CWORD-2]}"
			_comp_remote_path "$vm_name" "$cur" 'split'
			return 0
		fi

		# SCENARIO 2: Colon is present in current word (no split happened)
		if [[ "$cur" == *:* ]]; then
			local vm_name="${cur%%:*}"
			local path="${cur#*:}"
			_comp_remote_path "$vm_name" "$path" 'full'
			return 0
		fi

		# SCENARIO 3: Local file OR Start of VM name
		# Mix filenames mode (for local files) and raw mode (for VM names
		# with colons)
		local vm_matches=()
		if [[ "$cur" != */* && "$cur" != .* && "$cur" != ~* ]]; then
			if command -v virsh >/dev/null 2>&1; then
				local vms
				vms=$(_get_vm_ids --state-running)
				for vm in $vms; do
					if [[ "$vm" == "${cur}"* ]]; then
						vm_matches+=("${vm}:")
					fi
				done
			fi
		fi

		if [ ${#vm_matches[@]} -gt 0 ]; then
			# If we have VM matches, we cannot use 'compopt -o filenames'
			# because it will escape the colon in 'vm:'.
			# We must manually list local files and append / to directories.
			compopt +o filenames
			compopt -o nospace

			# Add VMs
			COMPREPLY=( "${vm_matches[@]}" )

			# Add Local files manually
			local files
			files=$(compgen -f -- "$cur")
			for f in $files; do
				if [[ -d "$f" ]]; then f="$f/"; fi
				COMPREPLY+=("$f")
			done
		else
			# No VM matches? Safe to use standard filename completion
			compopt -o filenames
			COMPREPLY=( $(compgen -f -- "${cur}") )
		fi
		return 0
	fi
}

function _comp_remote_path() {
	local vm_name="$1"
	local path="$2"
	local mode="$3"

	local ip
	ip=$(_get_vm_ip "$vm_name")
	if [ -z "$ip" ]; then
		return 1
	fi

	local search_path="$path"
	if [[ "$path" == \~* ]]; then
		local remote_home
		remote_home=$(ssh -q \
			-o BatchMode=yes \
			-o ConnectTimeout=2 \
			-o LogLevel=ERROR \
			-o StrictHostKeyChecking=no \
			-o UserKnownHostsFile=/dev/null \
			"${REMOTE_USER}@${ip}" 'echo $HOME'
		)

		if [ -z "$remote_home" ]; then
			return 1
		fi

		# Replace ~ with the absolute path
		search_path="${remote_home}${path#\~}"
	fi

	# Escape double quotes in the path for safe use in ssh command
	local safe_path="${search_path//\"/\\\"}"
	local remote_pattern="\"${safe_path}\"*"

	local remotes=()
	while IFS= read -r line; do
		[[ -n "$line" ]] && remotes+=("$line")
	done < <(ssh -q \
		-o BatchMode=yes \
		-o ConnectTimeout=2 \
		-o LogLevel=ERROR \
		-o StrictHostKeyChecking=no \
		-o UserKnownHostsFile=/dev/null \
		"${REMOTE_USER}@${ip}" "ls -1dF ${remote_pattern} 2>/dev/null"
	)

	local choices=()
	for r in "${remotes[@]}"; do
		local clean_r="${r%[*@|=]}"
		local item="${clean_r}"

		if [ "$mode" == 'full' ]; then
			choices+=("${vm_name}:${item}")
		else
			choices+=("${item}")
		fi
	done

	if [ ${#choices[@]} -eq 0 ]; then
		return 0
	fi

	compopt -o nospace
	compopt +o filenames
	COMPREPLY=( "${choices[@]}" )

	# If single file match (not dir), allow space
	if [ ${#COMPREPLY[@]} -eq 1 ] && [[ "${COMPREPLY[0]}" != */ ]]; then
		compopt +o nospace
	fi
	return 0
}

function _comp_vms() {
	local state_flag="$1"
	local extra_opts="$2"
	local vm_ids
	vm_ids=$(_get_vm_ids "$state_flag")
	COMPREPLY=( $(compgen -W "${vm_ids} ${extra_opts}" -- "${cur}") )
}

function _get_vm_ids() {
	local state_flag="$1"
	local vms
	vms=$(virsh list "$state_flag" --name 2>/dev/null)

	for vm in $vms; do
		if virsh dumpxml "$vm" 2>/dev/null | grep -q '<vadas:ip>'; then
			echo "$vm"
		fi
	done
}

function _get_vm_ip() {
	local vm_name="$1"
	virsh dumpxml "$vm_name" 2>/dev/null |
		grep '<vadas:ip>' |
		sed -n "s/.*<vadas:ip>\([^<]*\).*/\1/p"
}


function _vadas_sh_completion() {
	local cur prev opts vm_ids
	COMPREPLY=()
	cur="${COMP_WORDS[COMP_CWORD]}"
	prev="${COMP_WORDS[COMP_CWORD-1]}"

	case "${COMP_WORDS[1]}" in
	cp)
		_comp_cp
		return 0
		;;
	esac

	opts='
		clean
		configure
		cp
		create
		env
		images
		kill
		list
		pause
		ps
		remove
		rm
		resume
		show
		start
		stop
		suspend
	'
	local clean_opts='cache images temp'
	local configure_opts='vm'
	local create_opts='network pool vm'
	local help_opts='--help -h'
	local list_opts='images vm'
	local ps_opts='--all'
	local remove_opts='network pool vm'
	local show_opts='ip'
	local stop_opts='--force'

	case "${prev}" in
		clean)
			COMPREPLY=( $(compgen -W "${clean_opts} ${help_opts}" -- "${cur}") )
			return 0
			;;
		configure)
			COMPREPLY=( $(compgen -W "${configure_opts} ${help_opts}" -- "${cur}") )
			return 0
			;;
		create)
			COMPREPLY=( $(compgen -W "${create_opts} ${help_opts}" -- "${cur}") )
			return 0
			;;
		list)
			COMPREPLY=( $(compgen -W "${list_opts} ${help_opts}" -- "${cur}") )
			return 0
			;;
		remove|rm)
			COMPREPLY=( $(compgen -W "${remove_opts} ${help_opts}" -- "${cur}") )
			return 0
			;;
		show)
			COMPREPLY=( $(compgen -W "${show_opts} ${help_opts}" -- "${cur}") )
			return 0
			;;
		vm)
			local parent="${COMP_WORDS[COMP_CWORD-2]}"
			if [[ "${parent}" == 'remove' || "${parent}" == 'rm' || "${parent}" == 'configure' ]]; then
				_comp_vms --all
			fi
			return 0
			;;
		ip)
			local parent="${COMP_WORDS[COMP_CWORD-2]}"
			if [ "${parent}" == 'show' ]; then
				_comp_vms --all
			fi
			return 0
			;;
		pause|suspend)
				_comp_vms --state-running "${help_opts}"
				return 0
				;;
		resume)
				_comp_vms --state-paused "${help_opts}"
				return 0
				;;
		start)
			_comp_vms --all "${help_opts}"
			return 0
			;;
		stop|kill)
			_comp_vms --state-running "${stop_opts} ${help_opts}"
			return 0
			;;
		--force)
			local parent="${COMP_WORDS[COMP_CWORD-2]}"
			if [[ "${parent}" == 'stop' || "${parent}" == 'kill' ]]; then
				_comp_vms --state-running "${help_opts}"
			fi
			return 0
			;;
		ps)
			COMPREPLY=( $(compgen -W "${ps_opts}" -- "${cur}") )
			return 0
			;;
		*)
			if [[ ${COMP_CWORD} -eq 1 ]]; then
				COMPREPLY=( $(compgen -W "${opts} ${help_opts}" -- "${cur}") )
			fi
			return 0
			;;
	esac
}

complete -F _vadas_sh_completion vadas
