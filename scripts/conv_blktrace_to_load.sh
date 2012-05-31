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

#
# Convert binary blktrace(8) data to internal format
# suitable as input for blkreplay.
#
# Usage: /path/to/script blktrace-binary-logfile
#
# The output format of this script is called .load.gz
# and is later used by blkreplay as input.
#
# TST 2010-01-26

filename="$1"

if ! [ -f "$filename.blktrace.0" ]; then
    echo "Input file $filename.blktrace.0 does not exist"
    exit -1
fi

# check some preconditions
script_dir="$(cd "$(dirname "$(which "$0")")"; pwd)"
source "$script_dir/modules/lib.sh" || exit $?

check_list="grep sed cut gzip blkparse"
check_installed "$check_list"

{
    echo_copyright "$filename.blktrace.*"
    echo "start ; sector; length ; op ;  replay_delay=0 ; replay_duration=0"
    
    blkparse -v -i "$filename" -f '%2a ; %6T.%9t ; %12S ; %4n ; %3d ; 0.0 ; 0.0\n' |\
	sed 's/^ Q/ D/' |\
	sed 's/ WB/  W/' |\
	sed 's/ WS /  W /' |\
	sed 's/  \([RW]\)/\1/' |\
	grep "^ D" |\
	cut -d';' -f2-
} | gzip -9 > "$filename.load.gz"

