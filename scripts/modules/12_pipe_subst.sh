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

function pipe_subst_prepare
{
    (( !enable_pipe_subst )) && return 0
    echo "$FUNCNAME substituting $pipe_subst_from by $pipe_subst_to"
    input_pipe_list="$input_pipe_list | sed 's/ $pipe_subst_from / $pipe_subst_to /i'"
    return 0
}

prepare_list="$prepare_list pipe_subst_prepare"
