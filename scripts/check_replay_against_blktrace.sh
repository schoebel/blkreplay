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

# Plausibilty checking for the blkreplay system:
#
# Check coincidence between a .replay.gz file and a concurrently
# recorded blktrace set of files (running upon the same device).

if (( $# != 2 )); then
    echo "usage: $0 file1.replay.gz prefix_file2[.blktrace.*]"
    exit -1
fi

replay="$1"
blktrace="$2"

if ! [ -r "$replay" ]; then
    echo "Input file '$replay' does not exist"
    exit -1
fi
if ! [[ "$replay:" =~ ".replay.gz:" ]]; then
    echo "Input file '$replay' is no .replay.gz file"
    exit -1
fi
if ! [ -f "$blktrace.blktrace.0" ]; then
    echo "Blocktrace file '$blktrace.blktrace.0' does not exist"
    exit -1
fi

# check some preconditions
script_dir="$(cd "$(dirname "$(which "$0")")"; pwd)"
noecho=1
source "$script_dir/modules/lib.sh" || exit $?

check_list="mkfifo grep sed cut sort gunzip diff blkparse"
check_installed "$check_list"

######################################################################

tmp="${TMPDIR:-/tmp}/check.$$"
mkdir -p $tmp || exit $?
mkfifo $tmp/replay $tmp/blktrace || exit $?

zgrep ";" "$replay" | cut -d";" -f 2-4 | sort -n -s > $tmp/replay &

$script_dir/conv_blktrace_to_load.sh "$blktrace" - 2>/dev/null | grep ";" | cut -d";" -f 2-4 | sort -n -s > $tmp/blktrace &

diff -y -w --suppress-common-lines --minimal --speed-large-files $tmp/replay $tmp/blktrace

rm -rf $tmp
