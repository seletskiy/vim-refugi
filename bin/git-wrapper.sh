#!/bin/bash

### vim: set noet ai sw=4 ts=4:

##
## Git wrapper for vim-fugitive.
##
## Author: s.seletskiy@office.ngs.ru
##

tmp_dir=/tmp

##
## Return list of mounted sshfs.
##
## echo: list of mounted sshfs.
##
get_mounted_sshfs() {
	cat /etc/mtab | grep sshfs
}

##
## Returns mount string for specified directory.
##
## $1: directory to looking for.
##
## echo: mount string for specified directory.
##
get_mount() {
	local dir=$1
	local old_ifs=$IFS
	local mount_dsn=''
	local mount_dir=''

	IFS=$'\n'
	for mount in `get_mounted_sshfs`; do
		mount_dir=`echo $mount | cut -d' ' -f2`

		if [[ "$dir" == "$mount_dir"* ]]; then
			echo $mount
			return 0
		fi
	done
	IFS=$old_ifs

	return 0
}

##
## Opens new ssh tunnel.
## Wrapper for ssh [-S ctl_socket] -fNM user@host
##
## $1: user@host
## $2: ctl_socket, optional.
##
open_ssh_tunnel() {
	local userhost=$1
	local socket=$2

	if [ -z "$socket" ]; then
		ssh -fNM "$userhost"
	else
		ssh -S "$socket" -fNM "$userhost"
	fi
}

##
## Reopen ssh tunnels.
## Tries to reuse already opened ssh tunnels.
## If user does not use ssh multiplexing, then opens
## new ctl_soket in /tmp/ directory.
##
## $1: user@host from mtab file.
##
## echo: "-S ctl_socket" or "", if can reuse already opened connection.
##
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

##
## Close already opened ssh tunnels.
## This function will close only sockets from /tmp/fugitive_.
##
close_ssh_tunnels() {
	for socket in `find $tmp_dir -name 'refugi_*' 2>/dev/null`; do
		echo -n $socket": "
		ssh -O exit -S "$socket" "${socket##refugi_}"
	done
}

##
## Return value for specified argument.
##
## $1: needle.
## $2: arity, 0 for flags and 1 for keys.
## $@: command line arguments to search in.
##
get_arg() {
	local needle=$1
	local arity=$2
	local arg=''
	local match_next=0

	shift 2
	for arg in "$@"; do
		if [ $match_next -gt 0 ]; then
			echo $arg
			return 0
		fi

		case $arg in
			$needle=*)
				echo ${arg##$needle=}
				return 0
				;;
			$needle)
				if [ $arity -gt 0 ]; then
					match_next=1
				else
					echo "$arg"
					return 0
				fi
				;;
		esac
	done

	return 1
}

##
## Returns git command from command line.
##
## $@: command line to parse.
##
get_git_command_name() {
	for arg in "$@"; do
		case "$arg" in
			-*)
				continue
				;;
			*)
				echo "$arg"
				break
				;;
		esac
	done
}

if [ `get_arg --close-ssh-tunnels 0 "@"` ]; then
	close_ssh_tunnels
	exit $?
fi

local_git_dir=`get_arg --git-dir 1 "$@"`
git_command=`get_git_command_name "$@"`

if [[ -z "$local_git_dir" ]]; then
	echo --git-dir must be specified
	exit 2
fi

## If no mount point found, fallback to local git.
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
		remote_git_dir=${mount_root%/}/$remote_git_dir
	fi

	local_working_dir=`pwd`
	remote_working_dir=${mount_root%/}/${local_working_dir##$mount_point}

	# `ssh -fNM ...` for some reason hangs script execution.
	tmp_file=`mktemp`
	reopen_ssh_tunnel "$mount_userhost" > $tmp_file
	ssh_socket_flag=`cat $tmp_file`
	rm $tmp_file

	## Preparing command line for git.
	## We need to replace all local paths to remote in
	## order to use correct path on remote system.
	cmd_line=()
	skip_arg=0
	for arg in "$@"; do
		if [ $skip_arg -gt 0 ]; then
			skip_arg=$((skip_arg-1))
			continue
		fi
		case $arg in
			--git-dir=*)
				new_arg="--git-dir=$remote_git_dir"
				;;
			-F)
				if [ "$git_command" = "commit" ]; then
					local_commit_file=`get_arg -F 1 "$@"`
					new_arg="-F"${mount_root%/}/${local_commit_file##$mount_point}
					skip_arg=1
				fi
				;;
			*)
				new_arg="$arg"
				;;
		esac
		cmd_line[${#cmd_line[*]}]=\"${new_arg//\"/\\\"}\"
	done

	if [ -z "$GIT_EDITOR" ]; then
		GIT_EDITOR="$EDITOR"
	fi

	## TTY allocation hack for some interactive git commands
	tty_flag=""

	if [ "$GIT_EDITOR" == "false" -a $cmd_line == "commit" ]; then
		tty_flag="-t"
	fi

	if [[ "${cmd_line[@]}" == *\ add\ --patch* ]]; then
		tty_flag="-t"
	fi

	ssh $tty_flag $ssh_socket_flag $mount_userhost cd "$remote_working_dir" \; GIT_EDITOR=$GIT_EDITOR git "${cmd_line[@]}"
fi
