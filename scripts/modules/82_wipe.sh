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

function wipe_setup
{
    (( !enable_wipe )) && return 0
    echo "$FUNCNAME filling all devices with random data"
    for i in $(eval echo {0..$replay_max}); do
	cmd="time ./random_data.exe > ${replay_device[$i]}"
	echo "host $host: running command '$cmd'"
	remote "${replay_host[$i]}" "$cmd" &
    done
    echo "$(date) Waiting ... (this may take a VERY long time) ..."
    wait
    echo "$(date) Done."
    return 0
}

setup_list="$setup_list wipe_setup"
