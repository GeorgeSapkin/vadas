#!/bin/bash
#
# Copyright (c) 2025-2026 George Sapkin
#
# SPDX-License-Identifier: GPL-2.0-only

readonly VADAS_CONFIG_DIR="${VADAS_CONFIG_DIR:-${HOME}/.config/vadas}"
readonly VADAS_IMAGE_DIR="${VADAS_IMAGE_DIR:-${VADAS_CONFIG_DIR}/images}"

function _get_tagged_vm_ids() {
	local state_flag="$1"
	local vms
	vms=$(virsh list "$state_flag" --name 2>/dev/null)

	for vm in $vms; do
		if virsh dumpxml "$vm" 2>/dev/null | grep -q '<vadas:ip>'; then
			echo "$vm"
		fi
	done
}

_comp_vms() {
	local state_flag="$1"
	local extra_opts="$2"
	local vm_ids
	if command -v virsh >/dev/null 2>&1; then
		vm_ids=$(_get_tagged_vm_ids "$state_flag")
	fi
	COMPREPLY=( $(compgen -W "${vm_ids} ${extra_opts}" -- "${cur}") )
}

_vadas_sh_completion() {
	local cur prev opts vm_ids
	COMPREPLY=()
	cur="${COMP_WORDS[COMP_CWORD]}"
	prev="${COMP_WORDS[COMP_CWORD-1]}"
	opts='
		clean
		configure
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
	local help_opts='--help -h'
	local clean_opts='images temp'
	local configure_opts='vm'
	local create_opts='network vm'
	local list_opts='images vm'
	local ps_opts='--all'
	local remove_opts='image network vm'
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
		image)
			local parent="${COMP_WORDS[COMP_CWORD-2]}"
			if [[ "${parent}" == 'remove' || "${parent}" == 'rm' ]]; then
				local images
				images=$(ls -1 "$VADAS_IMAGE_DIR" 2>/dev/null)
				COMPREPLY=( $(compgen -W "${images}" -- "${cur}") )
			fi
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
			if [[ "${parent}" == 'show' ]]; then
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
