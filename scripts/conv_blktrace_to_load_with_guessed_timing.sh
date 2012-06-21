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
output="${2:-$(basename "$filename").guessed.load.gz}"
action_char="${action_char:-C}" # allow override from extern

# For now, prefer my own conversion. It seems to be more precise by
# using nanosecond resolution (reduction of conversion artifacts),
# and it seems to deliver more plausible queue depth values than blkparse -t.
# In addition, the determined latencies are slightly higher because
# completion timestamps are (usually) compared against prior stages
# in the request handling hierarchy. However, the latter should be
# investigated in more detail in the future (and corrected if necessary).

#use_my_guess="${use_my_guess:=0}"
use_my_guess="${use_my_guess:=1}"

if ! [ -f "$filename.blktrace.0" ]; then
    echo "Input file '$filename.blktrace.0' does not exist"
    exit -1
fi

# check some preconditions
script_dir="$(cd "$(dirname "$(which "$0")")"; pwd)"
noecho=1
source "$script_dir/modules/lib.sh" || exit $?

check_list="grep sed cut head gzip blkparse"
check_installed "$check_list"

blkparse_cmd="blkparse -t -v -i '$filename' -FC,'%a; %6T.%9t ; %12S ; %4n ; %3d ;%u\n'"
awk_cmd="gawk -F';' '{ printf(\"%s;%s;%s;%s; 0.0 ;%14.9f\n\", \$2, \$3, \$4, \$5, \$6 * 0.000001); }'"

if (( !use_my_guess )); then
    echo "Trying whether blkparse option '-t' works..."
    if eval "$blkparse_cmd" > /dev/null ; then
	echo "OK, it seems to work."
    else
	echo ""
	echo "Sorry, it did not work."
	echo ""
	echo "Now trying to GUESS myself ...".
	echo ""
	use_my_guess=1
    fi
fi > /dev/stderr

if (( use_my_guess )); then
    blkparse_cmd="blkparse -v -i '$filename' -f '%a; %6T.%9t ; %12S ; %4n ; %3d ;\n'"
    awk_cmd="gawk -F';' '{ i = sprintf(\"%s:%s:%s\", \$3, \$4, \$5); if (\$1 == \"C\") { old = ti[i]; if (old > 0) { printf(\"%s;%s;%s;%s; 0.0 ;%14.9f\n\", old, \$3, \$4, \$5, \$2 - old); ti[i] = 0; delete ti[i]; } else { printf(\"# cannot find request %s at %s, faking a replacement\n\", i, \$2); printf(\"%s;%s;%s;%s; 0.0 ; 0.0\n\", \$2, \$3, \$4, \$5); } } else { ti[i] = \$2; } } END { for (i in ti) if (ti[i] > 0) { _i = i; gsub(\":\", \";\", _i); printf(\"%s;%s; 0.0 ; 0.00\n\", ti[i], _i); } }'"
    echo "Computing \$action_char ..."
    tmp="${TMPDIR:-/tmp}/blkparse.$$"
    mkdir -p $tmp || exit $?
    blkparse -v -i "$filename" -f '%a:\n' |\
	grep "^[QGIDC][A-Z]\?:$" |\
	sed 's/^\([A-Z]\).\?:/\1:/' >\
	$tmp/actions || exit $?
    char_list="$(sort -u < $tmp/actions)" || exit $?
    echo "Statistics:"
    for i in $char_list; do
	echo "$i$(grep "$i" < $tmp/actions | wc -l)"
    done | sort -t: -k2 -n -r | tee $tmp/list
    action_char="$(grep -v 'C' < $tmp/list | head -n1 | cut -d: -f1)"
    rm -rf $tmp
    if [ -z "$action_char" ]; then
	echo "Sorry, I have no chance to do anything for you here."
	exit -1
    fi
    action_char="C$action_char"
    echo ""
    echo " =====> THE RESULT IS JUST A GUESS AND MAY BE INVALID!"
    echo " =====> CHECK THE RESULT BY HAND!"
    echo ""
fi > /dev/stderr

echo "Using action_char='$action_char'" > /dev/stderr

echo "Starting main conversion to '$output'..." > /dev/stderr

{
    echo_copyright "$filename.blktrace.*"
    echo "INFO: action_char=$action_char"
    echo "INFO: use_my_guess=$use_my_guess"
    echo "start ; sector; length ; op ;  replay_delay=0 ; replay_duration (guessed)"
    
    eval "$blkparse_cmd" |\
	grep "^[${action_char}][A-Z]\?;" |\
	sed 's/; *\([RW]\)[A-Z]* *;/; \1 ;/' |\
	grep '; [RW] ;' |\
	eval "$awk_cmd" |\
	sort -t";" -n -s
} |\
if [ "$output" = "-" ]; then
    cat
elif [[ "$output:" =~ ".gz:" ]]; then
    gzip -9 > "$output"
    ls -l "$output" > /dev/stderr
else
    cat > "$output"
    ls -l "$output" > /dev/stderr
fi

echo "Done. Please consider renaming the output file to something better." > /dev/stderr
