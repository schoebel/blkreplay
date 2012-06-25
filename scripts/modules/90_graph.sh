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

function graph_finish
{
    (( !enable_graph )) && return 0
    check_list="zgrep"
    check_installed "$check_list"
    echo "$FUNCNAME running graph.sh"
    if ! ls *.replay.gz > /dev/null; then
	echo "no results exist => skip graph.sh"
	return
    fi
    if zgrep -q ERR *.replay.gz; then
	echo "results have ERRORs => skip graph.sh"
	return
    fi

    # use a subshell for
    #   1) propagation of all (ordinary) shell variables defined previously
    #   2) undoing all inside definitions / side effects
    (
	renice -n 19 $BASHPID
	source $script_dir/graph.sh $graph_options *.replay.gz
    )
}

finish_list="$finish_list graph_finish"
