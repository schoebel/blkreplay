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

# TST June 2012

function delete_lvm
{
    echo "removing VG '$vg_name'"
    cmd="pv=\"\$(pvdisplay -c | cut -d: -f1,2 | grep ':$vg_name$' | cut -d: -f1 | sort -u)\""
    cmd="$cmd; lvdisplay -c | cut -d: -f1,2 | grep ':$vg_name$' | cut -d: -f1 | xargs lvremove -f"
    cmd="$cmd; vgremove $vg_name"
    cmd="$cmd; for i in \$pv; do pvremove -ff -y -v \$i; done"
    (( verbose_script )) && echo "$cmd"
    remote_all_noreturn "$target_hosts_unique" "$cmd"
}

function create_lvm_series
{
    host="$1"
    series="$2"
    count="$3"
    size="$4"
    echo "creating $count LVs series '$series' on '$host' VG '$vg_name' with size $size"
    stripe_cmd=""
    if (( lvm_striping )); then
	lvm_stripesize=${lvm_stripesize:-64}
	stripe_cmd="-i ${pv_count[$host]} -I $lvm_stripesize"
    fi
    for i in $(eval echo {0..$((count-1))}); do
	dev="/dev/$vg_name/$series$i"
	lvm_device[$i]="$dev"
	lvm_device_all[$lvm_device_count]="$dev"
	(( lvm_device_count++ ))
	cmd="lvcreate -L $size $stripe_cmd -n '${lvm_device[i]}' $vg_name"
	(( verbose_script )) && echo "$host: $cmd"
	remote "$host" "$cmd" || exit $?
    done
}

function create_lvm
{
    if echo $replay_host_list | grep -q ":"; then
	echo "Sorry, no ':' allowed in \$replay_host_list members."
	exit -1
    fi

    unset pv_count
    declare -A pv_count
    unset pv_cmd
    declare -A pv_cmd
    unset vg_cmd
    declare -A vg_cmd
    unset lvm_device
    declare -a lvm_device
    unset lvm_device_all
    declare -a lvm_device_all
    lvm_device_count=0

    for host in $target_hosts_unique; do
	vg_cmd[$host]="vgcreate $vg_name"
    done

    for i in $(eval echo {0..$replay_max}); do
	host="${replay_host[$i]}"
	dev="${replay_device[$i]}"
	pv_cmd[$host]="${pv_cmd[$host]} pvcreate -f -y $dev;"
	vg_cmd[$host]="${vg_cmd[$host]} $dev"
	(( pv_count[$host]++ ))
    done

    for host in $target_hosts_unique; do
	(( verbose_script )) && echo "$host: ${pv_cmd[$host]}"
	remote "$host" "${pv_cmd[$host]}" || exit $?
	(( verbose_script )) && echo "$host: ${vg_cmd[$host]}"
	remote "$host" "${vg_cmd[$host]}" || exit $?
	if (( drbd_meta_size > 0 )); then
	    create_lvm_series "$host" "lv-meta" "$lv_count" "$drbd_meta_size"
	fi
	create_lvm_series "$host" "lv-data" "$lv_count" "$lv_size"
    done

    ## re-create the devices list from scratch
    replay_host_list="$target_hosts_unique"
    replay_device_list=""
    for i in $(eval echo {0..$((lv_count-1))}); do
	replay_device_list="$replay_device_list ${lvm_device[i]}"
    done
    lvm_device_list="$replay_device_list" # remember them, in case other modules like iSCSI would change $replay_device_list later
    (( verbose_script )) && echo "new replay_device_list:$replay_device_list"
    devices_prepare
}

function recreate_lvm_finish
{
    (( !enable_recreate_lvm )) && return 0
    echo "$FUNCNAME deleting LVMs"
    delete_lvm
}

function recreate_lvm_prepare
{
    (( !enable_recreate_lvm )) && return 0
    echo "$FUNCNAME deleting old LVMs for safety"
    delete_lvm || echo "(ignored)"
    echo "$FUNCNAME creating LVMs"
    create_lvm
}

prepare_list="$prepare_list recreate_lvm_prepare"
finish_list="recreate_lvm_finish $finish_list"
