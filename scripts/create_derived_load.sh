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

# Create derived loads from original loads.
#
# The original loads "$@" are split into snippets having length $window each.
# The snippets are sorted according to IOPS and distributed to
# 0..($max-1) output files in a round-robin fashion, where
# max is iterating through the list $split_list.
#
# The rationale is explained at
# http://www.blkreplay.org/loads/natural/1and1/natural-derived/00README
#
# TST 2012-06-03

# check some preconditions
noecho=1
script_dir="$(cd "$(dirname "$(which "$0")")"; pwd)"
source "$script_dir/modules/lib.sh" || exit $?

check_list="gzip gunzip grep sed gawk cut"
check_installed "$check_list"

window=${window:-300}
split_list=${split_list:-001 002 004 008 016 032 064 128}


function paste_together
{
    gawk -F";" 'BEGIN{ old = 0.0; offset = 0.0; } { if ($1 < old) { offset += old; } printf("%17.9f ;%s;%s;%s;%s;%s\n", $1 + offset, $2, $3, $4, $5, $6); old = $1; }'
}

function from_start
{
    gawk -F";" 'BEGIN{ offset = -1; } { if (offset < 0) { offset = $1; } printf("%17.9f ;%s;%s;%s;0;0\n", $1 - offset, $2, $3, $4); }'
}

tmp="${TMPDIR:-/tmp}/snippets.$$"
mkdir -p $tmp/s || exit $?

echo "Creating snippets. This may take a long time...." 1>&2
limit=$window
snippet=0
total=0
cat "$@" |\
    gunzip -f |\
    grep ";" |\
    grep -v "[a-z]" |\
    paste_together |\
{
    count=0
    while true; do
        while IFS="." read time rest; do
	    if (( time >= limit )); then
		break;
	    fi
	    echo "$time.$rest"
	    (( count++ ))
	done >> $tmp/xxx
	if [ -z "$time" ]; then
	    break
	fi
	(( iops = count / window ))
	echo "  snippet $snippet at $limit has $count requests ($iops IOPS)" 1>&2
	(( total += count ))
	from_start < $tmp/xxx > $tmp/s/$count.$snippet
	rm -f $tmp/xxx
	(( snippet++ ))
	(( limit += window ))
	echo "$time.$rest" > $tmp/xxx
	count=1
    done
    echo "------------------------------------------------" 1>&2
    echo "snippets      : $snippet" 1>&2
    echo "reworked lines: $total" 1>&2
    echo "rest     lines: $count" 1>&2
    echo "sum      lines: $(( total + count ))" 1>&2
    echo "average  IOPS : $(( total / snippet / window ))" 1>&2
    echo "------------------------------------------------" 1>&2
}

base="$(basename "$1" | sed 's/\.\(load\|gz\|[0-9]\+\)//g')"

for max in $split_list; do
    max_num=$(echo $max | sed 's/^0*//')
    dir="${base}.derived.split.$max"
    mkdir -p "$dir" || exit $?
    echo "------------------------------------------------" 1>&2
    echo "Splitting into $max:" 1>&2
    for i in $(eval "echo {0..$(($max_num - 1))}"); do
	out[i]="$(printf "$base.derived.%03d.of.$max_num.load.gz" $i)"
	list[i]=""
    done

    j=0
    for i in $( (cd $tmp/s && ls) | sort -n -r ); do
	#echo "$i => $j" 1>&2
	list[j]="${list[j]} $i"
	(( j = (j + 1) % max_num ))
    done

    for i in $(eval "echo {0..$(($max_num - 1))}"); do
	[ -z "${list[i]}" ] && continue
	echo "${out[i]} ${list[i]}" 1>&2
	(
	    echo_copyright "$(basename "$1")..."
	    echo "start ; sector; length ; op ;  replay_delay ; replay_duration"
	    cd $tmp/s
	    cat ${list[i]} | paste_together
	) | gzip -8 > "$dir/${out[i]}" &
    done
    echo "Waiting for termination of subprocesses...." 1>&2
    wait
done

rm -rf $tmp
