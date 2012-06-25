#!/usr/bin/env bash
# Copyright 2010-2012 Thomas Schoebel-Theuer /  1&1 Internet AG
#
# Email: tst@1und1.de
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.

#####################################################################

# TST May 2012, quickly ported from old non-modular script code.

function iscsi_initiator_finish
{
    (( !enable_iscsi_initiator )) && return 0
    echo "$FUNCNAME finishing iSCSI connections to $iscsi_ip"
    cmd="(killall blkreplay.exe; iscsiadm -m node -U all) 2>/dev/null; exit 0"
    remote_all "$replay_hosts_unique" "$cmd"
}

function iscsi_initiator_prepare
{
    (( !enable_iscsi_initiator )) && return 0
    iscsi_ip="${iscsi_ip:-$iscsi_target}"
    check_list="iscsiadm killall diff"
    check_installed "$check_list"
    echo "$FUNCNAME preparing iSCSI connections to $iscsi_ip"
    iscsi_initiator_finish >/dev/null 2>&1 # in case a previous run was interrupted

    # saftey check
    cmd="ping -c1 $(echo $iscsi_ip | cut -d: -f1)"
    if ! remote_all "$replay_hosts_unique" "$cmd"; then
	echo "Sorry, some remote host cannot reach its configured iSCSI IP '$iscsi_ip'"
	return 1
    fi

    # the following is needed due to a misbehaviour/bug (blind login does not work always)
    cmd="iscsiadm -m discovery -p $iscsi_ip --type sendtargets"
    remote_all "$replay_hosts_unique" "$cmd"

    # make iscsi connections
    for i in $(eval echo {0..$replay_max}); do
	host="${replay_host[$i]}"
	target="${replay_device[$i]}"

	# remember old device list
	tmp_list="/tmp/devlist.$$"
	remote "$host" "ls /dev/sd?" > $tmp_list

	cmd="iscsiadm -m node -p $iscsi_ip -T $target -l"
	remote "$host" "$cmd" || return 1

        # wait until device appears
	sleep 3
	while true; do
	    new_dev="$(remote "$host" "ls /dev/sd?" | diff -u $tmp_list - | grep '^+/' | cut -c2-)"
	    [ -n "$new_dev" ] && break
	    echo "waiting for iscsi device to appear on host $host"
	    sleep 6
	done
	rm -f $tmp_list

	# safety check
	if ! remote "$host" "[ -b $new_dev ]" ; then
	    "Sorry, device '$new_dev' on host $host does not appear to be a block device."
	    return 1
	fi

	echo "host $host: renaming $target to $new_dev"

	# remember values (also for other modules)
	iscsi_targets[$i]="$target"
	replay_device[$i]="$new_dev"
    done
}

prepare_list="$prepare_list iscsi_initiator_prepare"
finish_list="iscsi_initiator_finish $finish_list"
