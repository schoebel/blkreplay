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

function pipe_resize_prepare
{
    (( !enable_pipe_resize )) && return 0
    echo "$FUNCNAME increasing request size by factor $pipe_resize_factor, bounded to min=$pipe_resize_min max=$pipe_resize_max"
    input_pipe_list="$input_pipe_list | gawk -F';' '!/[a-z]/ && /[0-9] ;/ { newsize = int(\$3 * $pipe_resize_factor); if (newsize < $pipe_resize_min) newsize = $pipe_resize_min; if (newsize > $pipe_resize_max) newsize = $pipe_resize_max; printf(\"%s ; %10d ; %s ; %s ; %s ; %s\n\", \$1, \$2, newsize, \$4, \$5, \$6); }'"
    return 0
}

prepare_list="$prepare_list pipe_resize_prepare"
