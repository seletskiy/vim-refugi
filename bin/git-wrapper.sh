#!/bin/bash

# TODO: documentation

get_mount() {
	local dir=$1
	local old_ifs=$IFS
	local mount_dsn=''
	local mount_dir=''

	IFS=$'\n'
	for mount in `cat /etc/mtab | grep sshfs`; do
		mount_dir=`echo $mount | cut -d' ' -f2`

		if [[ "$dir" == "$mount_dir"* ]]; then
			echo $mount
			return 0
		fi
	done
	IFS=$old_ifs

	return 0
}

reopen_ssh_tunnel() {
	local userhost=$1
	local socket=$2

	ssh -fNM -S "$socket" "$userhost"
}

local_git_dir=''
cmd_line=()
for arg in "$@"; do
	case $arg in
		--git-dir=*)
			local_git_dir=`echo $arg | cut -b11-`
			;;
		*)
			cmd_line[${#cmd_line[*]}]="$arg"
			continue
			;;
	esac
done

if [[ -z "$local_git_dir" ]]; then
	echo --git-dir must be specified
	exit 2
fi

mount=`get_mount "$local_git_dir"`
if [[ -z "$mount" ]]; then
	git "$@"
else
	mount_point=`echo $mount | cut -d' ' -f2`
	mount_dsn=`echo $mount | cut -d' ' -f1`
	mount_root=${mount_dsn##*:}
	mount_userhost=${mount_dsn%%:*}
	remote_git_dir=${local_git_dir##$mount_point}
	if [[ "$mount_root" != "/" ]]; then
		remote_git_dir=$mount_root/$remote_git_dir
	fi

	ssh_socket=/tmp/refugi_`echo $mount_dsn | sed -re's/[^a-z0-9_.-]/_/g'`
	if [[ ! -a "$ssh_socket" ]]; then
		reopen_ssh_tunnel "$mount_userhost" "$ssh_socket"
	fi

	ssh -O check -S "$ssh_socket" $mount_userhost 2>/dev/null
	if [[ $? -gt 0 ]]; then
		reopen_ssh_tunnel "$mount_userhost" "$ssh_socket"
	fi

	local_working_dir=`pwd`
	remote_working_dir=${local_working_dir##$mount_point}

	ssh -S $ssh_socket $mount_userhost cd "$remote_working_dir" \; git --git-dir="$remote_git_dir" "${cmd_line[@]}"
fi
