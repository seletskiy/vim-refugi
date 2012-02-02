#!/bin/bash

# TODO: documentation

tmp_dir=/tmp

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

open_ssh_tunnel() {
	local userhost=$1
	local socket=$2

	if [ -z "$socket" ]; then
		ssh -fNM "$userhost"
	else
		ssh -S "$socket" -fNM "$userhost"
	fi
}

reopen_ssh_tunnel() {
	local mount_userhost=$1

	ssh_socket_flag=''
	err_msg=`ssh -O check $mount_userhost 2>&1`
	if [[ $? -gt 0 ]]; then
		if [ "`echo $err_msg | grep '^No ControlPath'`" = "" ]; then
			open_ssh_tunnel "$mount_userhost"
		else
			ssh_socket=$tmp_dir/refugi_${mount_userhost}_22

			ssh -O check -S "$ssh_socket" "$mount_userhost" 2>/dev/null
			if [[ $? -gt 0 ]]; then
				open_ssh_tunnel "$mount_userhost" "$ssh_socket"
			fi

			ssh_socket_flag="-S "$ssh_socket
		fi
	fi

	echo "$ssh_socket_flag"
}

cleanup_ssh_tunnels() {
	for socket in `find $tmp_dir -name 'refugi_*' 2>/dev/null`; do
		echo -n $socket": "
		ssh -O exit -S "$socket" "${socket##refugi_}"
	done
}

local_git_dir=''
cmd_line=()
for arg in "$@"; do
	case $arg in
		--git-dir=*)
			local_git_dir=`echo $arg | cut -b11-`
			;;
		--close-ssh-tunnels)
			cleanup_ssh_tunnels
			exit $?
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

	local_working_dir=`pwd`
	remote_working_dir=${local_working_dir##$mount_point}

	# `ssh -fNM ...` for some reason hangs script execution
	tmp_file=`mktemp`
	reopen_ssh_tunnel "$mount_userhost" > $tmp_file
	ssh_socket_flag=`cat $tmp_file`
	rm $tmp_file

	ssh $ssh_socket_flag $mount_userhost cd "$remote_working_dir" \; git --git-dir="$remote_git_dir" "${cmd_line[@]}"
fi
