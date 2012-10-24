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

function pipe_select_prepare
{
    (( !enable_pipe_select )) && return 0
    echo "$FUNCNAME selecting [$pipe_select_from,$pipe_select_to] from the input"
    input_pipe_list="$input_pipe_list | gawk -F ';' '{ if (\$1 >= $pipe_select_from && \$1 < $pipe_select_to) print; }'"
    return 0
}

prepare_list="$prepare_list pipe_select_prepare"
