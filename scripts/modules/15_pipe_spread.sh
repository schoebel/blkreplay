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

function pipe_spread_prepare
{
    (( !enable_pipe_spread )) && return 0
    echo "$FUNCNAME increasing sector range by factor $pipe_spread_factor, aligned to $pipe_spread_align, offset $pipe_spread_offset"
    input_pipe_list="$input_pipe_list | gawk -F';' '!/[a-z]/ && /[0-9] ;/ { rest = \$2 % $pipe_spread_align; newpos = int(\$2 * $pipe_spread_factor / $pipe_spread_align) * $pipe_spread_align + rest + $pipe_spread_offset; printf(\"%s ; %10d ; %s ; %s ; %s ; %s\n\", \$1, newpos, \$3, \$4, \$5, \$6); }'"
    return 0
}

prepare_list="$prepare_list pipe_spread_prepare"
