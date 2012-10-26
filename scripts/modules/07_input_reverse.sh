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

function input_reverse_prepare
{
    (( !enable_input_reverse )) && return 0
    check_installed tac paste
    echo "$FUNCNAME reversing input files"
    for i in $(eval echo {0..$input_file_max}); do
	rev="$(echo ${input_file[$i]} | sed 's/\.gz$/.reverse.gz/')"
	if ! [ -r "$rev" ]; then
	    echo "  converting $rev"
	    fifo="$rev.fifo"
	    fifo2="$rev.fifo2"
	    mkfifo $fifo || exit $?
	    zgrep ";" ${input_file[$i]} |\
		cut -d ";" -f1  \
		> $fifo &
	    zgrep ";" ${input_file[$i]} |\
		cut -d ";" -f2- |\
		tac |\
		paste -d";" $fifo - |\
		gzip -8 > $rev &
	    rm $fifo
	else
	    echo "  re-using $rev"
	fi
	input_file[$i]="$rev"
    done
    wait
    return 0
}

prepare_list="$prepare_list input_reverse_prepare"
