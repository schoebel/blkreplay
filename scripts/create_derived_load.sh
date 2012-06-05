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

# Create derived loads from original loads.
#
# The original loads "$@" are split into snippets having length $window each.
# The snippets are sorted according to IOPS and distributed to
# 0..($max-1) output files in a round-robin fashion.
#
# The rationale is explained at
# http://www.blkreplay.org/loads/natural/1and1/natural-derived/00README
#
# TST 2012-06-03

# check some preconditions
noecho=1
script_dir="$(cd "$(dirname "$(which "$0")")"; pwd)"
source "$script_dir/modules/lib.sh" || exit $?

check_list="cat gunzip grep sed gawk cut gzip"
check_installed "$check_list"

window=${window:-600}
max=${max:-32}

function paste_together
{
    gawk -F";" 'BEGIN{ old = 0.0; offset = 0.0; } { if ($1 < old) offset += old; printf("%17.9f ;%s;%s;%s;%s;%s\n", $1 + offset, $2, $3, $4, $5, $6); old = $1; }'
}

function from_start
{
    gawk -F";" 'BEGIN{ offset = -1; } { if (offset < 0) offset = $1; printf("%17.9f ;%s;%s;%s;%s;%s\n", $1 - offset, $2, $3, $4, $5, $6); }'
}

tmp="${TMPDIR:-/tmp}/snippets.$$"
mkdir -p $tmp/s || exit $?

echo "List of output files:"
for i in $(eval "echo {0..$(($max-1))}"); do
    base="$(basename $1 | sed 's/\.\(load\|gz\|[0-9]\+\)//g')"
    out[i]="$(printf "$base.derived.%03d.load.gz" $i)"
    list[i]=""
    echo "  ${out[i]}"
done

echo "Creating snippets. This may take a long time...."
limit=$window
snippet=0
count=0
cat "$@" |\
    gunzip -f |\
    grep ";" |\
    grep -v "[a-z]" |\
    #head -n 200000 |\
    paste_together |\
    while IFS="." read time rest; do
    if (( time >= limit )); then
	(( iops = count / window ))
	echo "  snippet $snippet at $limit has $count requests ($iops IOPS)"
	from_start < $tmp/xxx > $tmp/s/$count.$snippet
	rm -f $tmp/xxx
	count=0
	(( snippet++ ))
	(( limit += window ))
    fi
    echo "$time.$rest" >> $tmp/xxx
    (( count++ ))
done

echo "------------------------------------------------"

j=0
for i in $( (cd $tmp/s && ls) | sort -n -r ); do
    echo "$i => $j"
    list[j]="${list[j]} $i"
    (( j = (j+1) % max ))
done

echo "Assignment of snippets to output files:"
for i in $(eval "echo {0..$(($max-1))}"); do
    [ -z "${list[i]}" ] && continue
    echo "${out[i]} ${list[i]}"
    (
	echo_copyright "$(basename "$1")..."
	echo "start ; sector; length ; op ;  replay_delay ; replay_duration"
	cd $tmp/s
	cat ${list[i]} | paste_together
    ) | gzip -8 > ${out[i]} &
done

echo "Waiting for termination of subprocesses...."
wait

rm -rf $tmp
