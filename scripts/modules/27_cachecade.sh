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

# TST Sept 2012

function wait_cachecade_clean
{
    cmd="MegaCli LDInfo -LALL -a${megaraid_adaptor} | grep 'Target Id of the Associated'"
    while  remote_all "$target_hosts_unique" "$cmd" | grep -v "None"; do
	sleep 5
    done
    remote_all "$target_hosts_unique" "$cmd"
}

function set_cachecade
{
    mode="$1"
    echo "setting cachecade to $mode"
    if (( !mode )); then
	set_cmd="MegaCli cachecade remove l${megaraid_data_target} a${megaraid_adaptor}; exit 0"
    elif (( mode == 1 )); then
	set_cmd="MegaCli -LDSetProp WT -L${cachecade_target} -a${megaraid_adaptor} && MegaCli cachecade assign l${megaraid_data_target} a${megaraid_adaptor}"
    elif (( mode == 2 )); then
	set_cmd="MegaCli -LDSetProp WB -L${cachecade_target} -a${megaraid_adaptor} && MegaCli cachecade assign l${megaraid_data_target} a${megaraid_adaptor}"
    else
	echo "Invalid mode $mode"
	exit -1
    fi
    remote_all "$target_hosts_unique" "$set_cmd"
}

function cachecade_finish
{
    (( !enable_cachecade )) && return 0
    if (( enable_cachecade == 1 )); then
	echo "leaving cachecade as is."
	return 0
    fi
    set_cachecade 0
}

function cachecade_prepare
{
    (( !enable_cachecade )) && return 0
    set_cachecade 0
    wait_cachecade_clean
    set_cachecade "$cachecade_mode" && sleep 5
}

prepare_list="$prepare_list cachecade_prepare"
finish_list="cachecade_finish $finish_list"
