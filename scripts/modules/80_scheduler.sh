#!/usr/bin/env bash
# Copyright 2010-2012 Thomas Schoebel-Theuer, sponsored by 1&1 Internet AG
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

function scheduler_setup
{
    (( !enable_scheduler )) && return 0
    echo "$FUNCNAME setting the IO scheduler: $scheduler"
    cmd="for i in /sys/dev/block/*/queue/scheduler; do echo '$scheduler' > \$i; done"
    remote_all_noreturn "$all_hosts_unique" "$cmd"
    return 0
}

setup_list="$setup_list scheduler_setup"
