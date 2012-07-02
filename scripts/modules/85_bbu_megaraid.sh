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

# TST July 2012

function set_bbu_megaraid
{
    enable_cache="$1"
    echo "setting megaraid BBU cache to $enable_cache"
    if (( enable_cache )); then
	set_cmd="MegaCli -LDsetProp CachedBadBBU -LALL -aALL && MegaCli -LDsetProp -EnDskCache -LALL -aALL"
    else
	set_cmd="MegaCli -LDSetProp -DisDskCache -LALL -aALL && MegaCli -LDsetProp NoCachedBadBBU -LALL -aALL"
    fi
    remote_all "$target_hosts_unique" "$set_cmd"

    query_cmd="MegaCli -LDGetProp -Cache -LALL -aALL"
    remote_all "$target_hosts_unique" "$query_cmd"
}

function bbu_megaraid_finish
{
    (( !enable_bbu_megaraid )) && return 0
    set_bbu_megaraid 1
}

function bbu_megaraid_prepare
{
    (( !enable_bbu_megaraid )) && return 0
    set_bbu_megaraid "$bbu_cache"
}

prepare_list="$prepare_list bbu_megaraid_prepare"
finish_list="bbu_megaraid_finish $finish_list"
