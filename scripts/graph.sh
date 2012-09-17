#!/usr/bin/env bash
# Copyright 2009-2012 Thomas Schoebel-Theuer /  1&1 Internet AG
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

# usage: /path/to/graph.sh *.replay.gz
# TST started November 2009

# defaults for picture options

picturetype="${picturetype:-png}" # [ps|jpeg|gif|...]
pictureoptions="${pictureoptions:=small size 1200,800}" # other values: "size 800,600" etc
bad_latency="${bad_latency:-5.0}" # seconds
bad_delay="${bad_delay:-10.0}" # seconds
bad_ignore="${bad_ignore:-1}" # the n'th exceeding the limit
ws_list="${ws_list:-000 001 006 060 600}"

# defaults for colors (RGB values)

declare -A color
declare -A default_color
default_color[reads]="#00BFFF" # DeepSkyBlue
default_color[writes]="#FF0000" # red
default_color[r_push]="#00008B" # DarkBlue
default_color[w_push]="#FF1493" # DeepPink
default_color[all]="#CDCD00" # yellow3

default_color[ok]="#00EE00" # green2
default_color[bad]="#A020F0" # purple
default_color[border]="#000000" # black
default_color[warn]="#B35200"
default_color[fake]="#B35200"

default_color[demand]="#00CD00" # green3
default_color[actual]="#FFA500" # orange1

default_color[000]="#EE0000" # red2
default_color[001]="#228B22" # ForestGreen
default_color[006]="#0000CD" # MediumBlue
default_color[060]="#CD950C" # DarkGoldenrod3

for i in "${!default_color[@]}"; do
    if [ -z "${color[$i]}" ]; then
	color[$i]="${default_color[$i]}"
    fi
done

# check some preconditions

script_dir="${script_dir:-$(cd "$(dirname "$(which "$0")")"; pwd)}"
source "$script_dir/modules/lib.sh" || exit $?

check_list="grep sed gawk nl head tail cut tee mkfifo nice date find gzip gunzip zcat gnuplot"
check_installed "$check_list"

tmp="${TMPDIR:-/tmp}/graph.$$"
rm -rf "$tmp"
mkdir -p "$tmp"
mkfifo "$tmp/fifo.master" || exit $?
prefifo="$tmp/fifo.pre"
mainfifo="$tmp/fifo.main"
subfifo="$tmp/fifo.sub"

# operation modes

static_mode=0
dynamic_mode=0
verbose_mode=0
sequential_mode=1
if echo "$@" | grep -q "\.load"; then
    static_mode=1
fi
if echo "$@" | grep -q "\.replay"; then
    dynamic_mode=1
fi

# compute parts of common name
shopt -s nullglob
for file in $@; do
    if [ "$file" = "--static" ]; then
	static_mode=1
	continue
    fi
    if [ "$file" = "--no-static" ]; then
	static_mode=0
	continue
    fi
    if [ "$file" = "--dynamic" ]; then
	dynamic_mode=1
	continue
    fi
    if [ "$file" = "--no-dynamic" ]; then
	dynamic_mode=0
	continue
    fi
    if [ "$file" = "--verbose" ]; then
	verbose_mode=1
	continue
    fi
    if [ "$file" = "--no-verbose" ]; then
	verbose_mode=0
	continue
    fi
    if [ "$file" = "--sequential" ]; then
	sequential_mode=1
	continue
    fi
    if [ "$file" = "--no-sequential" ]; then
	sequential_mode=0
	continue
    fi
    if ! [ -r "$file" ]; then
	echo "cannot read input file '$file'"
	exit -1
    fi
    echo "$file" >> $tmp/files
    basename "$file" >> $tmp/names
done

grep "\." < $tmp/names |\
    sed 's/\.gz$//' |\
    sed 's/\.\(load\|replay\|log\)$//' |\
    sed 's/$/./' > $tmp/names2

if ! [ -s $tmp/files ]; then
    echo "no usables input files."
    exit -1
fi

if (( !static_mode )); then
    ws_list=""
fi
echo " static_mode=$static_mode"
echo "dynamic_mode=$dynamic_mode"
echo "verbose_mode=$verbose_mode"

i=1
name=""
while true; do
    cut -d'.' -f $i < $tmp/names2 | sort -u > "$tmp/this"
    if [ $(cat "$tmp/this" | wc -l) -le 1 ]; then
	part="$(cat "$tmp/this")"
	#echo "$i: '$part'"
	[ -z "$part" ] && break
	name="$name.$part"
    fi
    (( i++ ))
done
name="$(echo "$name" | sed 's/^\.//')"
echo "common name: '$name'"

if [ -z "$name" ]; then
    echo "it is not possible to produce a common name out of your arguments."
    echo "please provide different / less arguments to this script."
    rm -rf "$tmp"
    exit -1
fi

sort="sort"

# Use lots of named pipes for maximum parallelism (SMP scalability)

function make_statistics
{
    prefix="$1"
    bad_val="$2"
    gawk -F ";" "BEGIN{min=0.0; max=0.0; sum=0.0; count=0; hit=0; start=0.0; } { sum += \$2; count++; if (\$2 > max) max = \$2; if (\$2 < min || !min) min = \$2; if (\$2 > $bad_val) { if (!hit) start=\$1; hit++; } } END { printf (\"${prefix}min=%11.9f\n${prefix}max=%11.9f\n${prefix}count=%d\n${prefix}avg=%11.9f\n${prefix}hit=%d\n${prefix}start=%11.9f\n\", min, max, count, (count > 0 ? sum / count : 0), hit, start); }"
}

function make_statistics_short
{
    prefix="$1"
    gawk -F ";" "BEGIN{min=0.0; max=0.0; sum=0.0; count=0; } { sum += \$1; count++; if (\$1 > max) max = \$1; if (\$1 < min || !min) min = \$1; } END { printf (\"${prefix}min=%f\n${prefix}max=%f\n${prefix}count=%d\n${prefix}avg=%f\n\", min, max, count, (count > 0 ? sum / count : 0)); }"
}

function _output_statistics
{
    outfix="$1"
    mode="$2"
    tee $tmp/stat.$outfix |\
	grep "_max=\|_avg=" |\
	sort |\
	echo $(sed "s/^.*_\([a-z]\+\)=/\1=/") |\
	echo "${mode}_label=\"  ($(sed 's/ /, /'))\"" >\
	$tmp/label.$outfix
}

function output_statistics
{
    prefix="$1"
    bad_val="$2"
    outfix="$3"
    mode="$4"
    make_statistics "$prefix" "$bad_val" |\
	_output_statistics "$outfix.$mode" "$mode"
}

function output_statistics_short
{
    prefix="$1"
    outfix="$2"
    mode="$3"
    make_statistics_short "$prefix" |\
	_output_statistics "$outfix.$mode" "$mode"
}

function compute_ws
{
    window=$1
    advance=$1
    (( advance <= 0 )) && advance=1
    gawk -F ";" "BEGIN{ start = 0.0; count = 0; } { if (!start) start = \$1; while (\$1 >= start + $advance) { delta = 0.0; if ($window) { c = asorti(table); delta = table[c-1] - table[0]; } printf(\"%14.9f %d %14.9f %14.9f\n\", start+$advance, count, delta, (c > 0 ? delta/c : 0)); if ($window) { count = 0; delete table; } start += $advance; } if (!table[\$2]) { table[\$2] = \$2; count++; } }"
}

function compute_turns
{
    window=$1
    advance=$1
    (( advance <= 0 )) && advance=1
    gawk -F ";" "{ if (!start) start = \$1; while (\$1 >= start + $advance) { printf(\"%14.9f %d %d %f\n\", start + $advance, turns, count, count > 0 ? turns * 100.0 / count : 0); start += $advance; if ($window) { turns = 0; count = 0; } } if (\$2 < old) turns++; count++; old = \$2; }"
}

function compute_flying
{
    add="$1"
    diff="$2"
    gawk -F ";" "{ printf(\"%17.9f;1;%s;%s\n\", \$2 $add, \$6, \$7); printf(\"%17.9f;-1;x;x\n\", \$2 $add + \$$diff); }" |\
	$sort -n -s |\
	gawk -F ";" '{ count += $2; printf("%s;%5d;%s;%s\n", $1, count, $3, $4); }'
}

function smooth_y
{
    window=$1
    gawk "{ if (!start) start = \$1; while (\$1 >= start + $window) { printf(\"%14.9f %f\n\", start + $window, count > 0 ? sum / count : 0); start += $window; count = 0; sum = 0.0; } count++; sum += \$2; }"
}

function compute_sum
{
    $sort -g |\
	gawk '{ if ($1 == oldx) { oldy += $2; } else { printf("%14.9f %14.9f\n", oldx, oldy); oldx = $1; oldy = $2; } } END{ printf("%14.9f %14.9f\n", oldx, oldy); }'
}

function extract_variables
{
    spec="$1"
    var_list="$(echo $spec | sed 's/ \+/\\|/g' | sed 's/_/[_ ]\\+/g')"
    grep "^[A-Za-z#]" |\
	sed "s/\($var_list\) *[=:] *\([0-9.]\+\|'[^']*'\)/\n\1=\2\n/g" |\
	grep "^[a-z][a-z_ ]*=\([0-9.]\+\|'[^']*'\)$" |\
	sed 's/ \+/_/g' |\
	sort -u
}

function extract_fields
{
    spec="$1"
    regex1="^.*"
    regex2="$2"
    for i in $spec; do
	regex1="$regex1 $i=\([0-9.]*\|'[^']*'\).*"
    done
    sed "s/$regex1/$regex2/"
}

function _diff_timestamps
{
    gawk -F":" '{ if (count++ % 2) { printf("%14.9f\n", $2 - old); } old = $2; }'
}

function diff_timestamps
{
    extract_fields "real_time seqnr" '\2:\1' |\
	$sort -n -s |\
	_diff_timestamps
}

function cumul
{
    gawk '{ sum += $1; printf("%14.9f\n", sum); }'
}

function rgb
{
    op_name="$1"
    color_name="$2"
    # in case the color_name is a dotted identified a.b.c.d try all the suffixes
    while true; do
	if [ -n "${color[$color_name]}" ]; then
	    echo "$op_name rgb \"${color[$color_name]}\""
	    return 0
	fi
	new_color_name="$(echo "$color_name" | sed 's/^[a-z0-9_]*\.//')"
	[ "$new_color_name" = "$color_name" ] && break
	color_name="$new_color_name"
    done
    return 1
}

function textcolor
{
    for color_name; do
	if rgb "textcolor" "$color_name"; then
	    break;
	fi
    done
}

function lt
{
    for color_name; do
	if rgb "lt" "$color_name"; then
	    break;
	fi
    done
}

out="$tmp/$name"


[[ "$name" =~ impulse ]] && thrp_window=${thrp_window:-1}
thrp_window=${thrp_window:-3}
turn_window=${turn_window:-1}
smooth_latency_flying_window=${smooth_latency_flying_window:-1}

gawk_thrp="{ time=int(\$1); if (time - oldtime >= $thrp_window) { printf(\"%d %13.3f\\n\", oldtime, count / $thrp_window.0); oldtime += $thrp_window; if (time - oldtime >= $thrp_window) { printf(\"%d 0.0\\n\", oldtime); factor = int((time - oldtime) / $thrp_window); oldtime += factor * $thrp_window; if (factor > 1) { printf(\"%d 0.0\\n\", oldtime); } }; count=0; }; count++; }"

# produce throughput graphics always
mkfifo $mainfifo.all.sort2.thrp
cat $mainfifo.all.sort2.thrp |\
    cut -d ';' -f 2 |\
    gawk "$gawk_thrp" >\
    $out.g000.sort0.overview.thrp.demand.extra &
if (( dynamic_mode )); then
    mkfifo $mainfifo.all.sort7.thrp
    cat $mainfifo.all.sort7.thrp |\
	cut -d ';' -f 2 |\
	gawk "$gawk_thrp" >\
	$out.g000.sort1.overview.thrp.actual.extra &
fi

# worker pipelines for reads / writes
for mode in reads writes r_push w_push all; do
    inp="$mainfifo.$mode"
    side="$subfifo.side.$mode"
    outp="$mode.tmp"
    outs="$mode.side"
    if (( static_mode )) && ! [[ "$mode" =~ "_push" ]]; then
	mkfifo $inp.nosort.rqsize
	mkfifo $side.rqsize.stat
	cat $inp.nosort.rqsize |\
	    cut -d ';' -f 4 |\
	    tee $side.rqsize.stat |\
	    $bin_dir/bins.exe >\
	    $out.g40.$outp.rqsize.bins &
	mkfifo $inp.nosort.rqpos
	mkfifo $side.rqpos_tmp
	cat $inp.nosort.rqpos |\
	    cut -d ';' -f 3 |\
	    gawk 'BEGIN{ xmax = -2; ymax = 0; } { i = int($1 / 2097152); table[i]++; if (i > xmax) xmax = i; } END{ for (i = 0; i <= xmax + 1; i++) { printf("%5d %5d\n%5d %5d\n", i, table[i], i+1, table[i]); if (table[i] > ymax) ymax = table[i]; } if (ymax > 0) printf("ymax=%d\n", ymax); }' |\
	    tee $side.rqpos_tmp |\
	    grep -v '^[a-z]' >\
	    $out.g41.$outp.rqpos.bins &
	grep '^[a-z]' < $side.rqpos_tmp >\
	    $tmp/rqpos_$mode.ymax &
	mkfifo $inp.nosort.freq.bins
	mkfifo $side.freq.bins.{0..2}
	cat $inp.nosort.freq.bins |\
	    cut -d ';' -f 3,4 |\
	    gawk '{ i = int($1 / 8); do { table[i]++; i++; $2 -= 8; } while($2 > 0); } END{ for (i in table) { printf("%d\n", table[i]); } }' |\
	    tee $side.freq.bins.0 |\
	    $sort -n -r |\
	    tee $side.freq.bins.2 >\
	    $out.g44.$outp.freq.bins &
	cat $side.freq.bins.0 |\
	    gawk '{ count++; sum += $1; } END{ printf("%d %d\n", count, sum); }' >\
	    $side.freq.bins.1 &
	cat $side.freq.bins.{1,2} |\
	    gawk 'BEGIN{ limit = 1.0 / 64; } { if (!total_sum) { total_count = $1; total_sum = $2; } else { count++; sum += $1; if (sum >= total_sum * limit) { printf("%d %6.3f %6.3f %5.3f\n", count, count * 100.0 / total_count, limit * 100.0, total_sum / (total_sum - sum + count) ); limit *= 2; } } }' >\
	    $out.g44.$outs.freq.bins.quantile &
    fi
    if (( dynamic_mode )) && [ "$mode" != "all" ]; then
	mkfifo $inp.sort6.dyn.1
	cat $inp.sort6.dyn.1 |\
	    cut -d ';' -f 2,7 |\
	    sed 's/;/ /' >\
	    $out.g01.$outp.latency.realtime &
	mkfifo $inp.sort2.dyn.2
	cat $inp.sort2.dyn.2 |\
	    cut -d ';' -f 2,7 |\
	    sed 's/;/ /' >\
	    $out.g02.$outp.latency.setpoint &
	mkfifo $inp.sort7.dyn.3
	cat $inp.sort7.dyn.3 |\
	    cut -d ';' -f 2,7 |\
	    sed 's/;/ /' >\
	    $out.g03.$outp.latency.completed &
	mkfifo $inp.nosort.dyn.3
	cat $inp.nosort.dyn.3 |\
	    cut -d ';' -f 1,7 |\
	    sed 's/;/ /' >\
	    $out.g03.$outp.latency.points &
	mkfifo $inp.sort2.dyn.4
	cat $inp.sort2.dyn.4 |\
	    cut -d ';' -f 2,6 |\
	    sed 's/;/ /' >\
	    $out.g04.$outp.delay.setpoint &
	mkfifo $inp.nosort.dyn.5
	cat $inp.nosort.dyn.5 |\
	    cut -d ';' -f 1,6 |\
	    sed 's/;/ /' >\
	    $out.g05.$outp.delay.points &
	mkfifo $side.tee.{1..2}
	cat $side.tee.1 |\
	    cut -d";" -f2,4 |\
	    grep -v "x" |\
	    sed 's/;/ /' >\
	    $out.g10.$outp.latency.xy &
	cat $side.tee.2 |\
	    cut -d";" -f2,3 |\
	    grep -v "x" |\
	    sed 's/;/ /' >\
	    $out.g11.$outp.delay.xy &
	mkfifo $inp.nosort.dyn.12
	cat $inp.nosort.dyn.12 |\
	    cut -d ';' -f 6,7 |\
	    sed 's/;/ /' >\
	    $out.g12.$outp.latency.delay.xy &
    fi
    mkfifo $inp.sort2.thrp.dedi
    mkfifo $side.thrp.setpoint.stat
    cat $inp.sort2.thrp.dedi |\
	cut -d ';' -f 2 |\
	gawk "$gawk_thrp" |\
	tee $side.thrp.setpoint.stat >\
	$out.g00.$outp.thrp.setpoint &
    if (( dynamic_mode )); then
	mkfifo $inp.sort7.thrp.dedi
	mkfifo $side.thrp.completed.stat
	cat $inp.sort7.thrp.dedi |\
	    cut -d ';' -f 2 |\
	    gawk "$gawk_thrp" |\
	    tee $side.thrp.completed.stat >\
	    $out.g00.$outp.thrp.completed &
	mkfifo $inp.nosort.dyn.6
	cat $inp.nosort.dyn.6 |\
	    cut -d ';' -f 7 |\
	    $bin_dir/bins.exe >\
	    $out.g06.$outp.latency.bins &
	mkfifo $inp.nosort.dyn.7
	cat $inp.nosort.dyn.7 |\
	    cut -d ';' -f 6 |\
	    $bin_dir/bins.exe >\
	    $out.g07.$outp.delay.bins &
	mkfifo $inp.nosort.dyn.8
	mkfifo $side.latency.flying.stat
	cat $inp.nosort.dyn.8 |\
	    compute_flying "+\$6" 7 |\
	    tee $side.tee.* |\
	    cut -d";" -f1,2 |\
	    tee $side.latency.flying.stat |\
	    sed 's/;/ /' |\
	    tee $out.g08.$outp.latency.flying |\
	    smooth_y $smooth_latency_flying_window >\
	    $out.g08.$outp.smooth.latency.flying &
	mkfifo $inp.nosort.dyn.9
	mkfifo $side.delay.flying.stat
	cat $inp.nosort.dyn.9 |\
	    compute_flying "" 6 |\
	    cut -d";" -f1,2 |\
	    tee $side.delay.flying.stat |\
	    sed 's/;/ /' >\
	    $out.g09.$outp.delay.flying &
	if [ "$mode" != "r_push" ] && [ "$mode" != "w_push" ]; then
	    mkfifo $inp.sort7.turns.completed
	    mkfifo $side.turns.completed.stat
	    cat $inp.sort7.turns.completed |\
		cut -d ';' -f 2,3 |\
		compute_turns $turn_window |\
		gawk '{print $1, $4; }' |\
		tee $side.turns.completed.stat >\
		$out.g43.$outp.turns.completed &
	fi
    fi
    if (( static_mode || dynamic_mode )) && [ "$mode" != "r_push" ] && [ "$mode" != "w_push" ]; then
	mkfifo $inp.sort2.turns.setpoint
	mkfifo $side.turns.setpoint.stat
	cat $inp.sort2.turns.setpoint |\
	    cut -d ';' -f 2,3 |\
	    compute_turns $turn_window |\
	    gawk '{print $1, $4; }' |\
	    tee $side.turns.setpoint.stat >\
	    $out.g42.$outp.turns.setpoint &
    fi
    # create statistics
    for i in setpoint completed; do
	if [ -e $side.thrp.$i.stat ]; then
	    cat $side.thrp.$i.stat |\
		gawk '{print $2;}' |\
		output_statistics_short "thrp_${i}_${mode}_" "thrp.$i" $mode &
	fi
    done
    if [ -e $side.rqsize.stat ]; then
	cat $side.rqsize.stat |\
	    output_statistics_short "rqsize_${mode}_" rqsize $mode &
    fi
    if (( dynamic_mode )); then
	mkfifo $inp.nosort.latencies.stat
	cat $inp.nosort.latencies.stat |\
	    cut -d ';' -f 2,7 |\
	    output_statistics "latency_${mode}_" "$bad_latency" latencies $mode &
	mkfifo $inp.nosort.delays.stat
	cat $inp.nosort.delays.stat |\
	    cut -d ';' -f 2,6 |\
	    output_statistics "delay_${mode}_" "$bad_delay" delays $mode &
	cat $side.latency.flying.stat |\
	    cut -d";" -f2 |\
	    output_statistics_short "latency_flying_${mode}_" latency.flying $mode &
	cat $side.delay.flying.stat |\
	    cut -d";" -f2 |\
	    output_statistics_short "delay_flying_${mode}_" delay.flying $mode &
    fi
    if [ -e $side.turns.setpoint.stat ]; then
	cat $side.turns.setpoint.stat |\
	    gawk '{print $2;}' |\
	    output_statistics_short "turns_setpoint_${mode}_" turns.setpoint $mode &
    fi
    if [ -e $side.turns.completed.stat ]; then
	cat $side.turns.completed.stat |\
	    gawk '{print $2;}' |\
	    output_statistics_short "turns_completed_${mode}_" turns.completed $mode &
    fi
done

# global worker pipelines
if (( verbose_mode )); then
    mkfifo $prefifo.verbose
    extra_modes="submit_level pushback_level submit_ahead submit_lag answer_lag submit_lag_cumul answer_lag_cumul input_wait answer_wait input_wait_cumul answer_wait_cumul"
    mkfifo $subfifo.verbose.{1..7}
    grep "^INFO: action=" < $prefifo.verbose |\
	tee $subfifo.verbose.* > /dev/null &
    grep "'\(submit\|got_answer\)'" < $subfifo.verbose.1 |\
	extract_fields "count_submitted" '\1' >\
	$out.g50.submit_level &
    grep "'\(submit\|got_answer\)'" < $subfifo.verbose.2 |\
	extract_fields "count_pushback" '\1' >\
	$out.g51.pushback_level &
    grep "'submit'" < $subfifo.verbose.3 |\
	extract_fields "real_time rq_time" '\1:\2' |\
	gawk -F":" '{ printf("%14.9f\n", $2 - $1); }' >\
	$out.g52.submit_ahead &
    grep "'\(submit\|worker_got_rq\)'" < $subfifo.verbose.4 |\
	diff_timestamps |\
	tee $out.g53.submit_lag |\
	cumul >\
	$out.g53.submit_lag_cumul &
    grep "'\(worker_send_answer\|got_answer\)'" < $subfifo.verbose.5 |\
	diff_timestamps |\
	tee $out.g54.answer_lag |\
	cumul >\
	$out.g54.answer_lag_cumul &
    grep "'\(wait_for_input\|got_input\)'" < $subfifo.verbose.6 |\
	extract_fields "real_time" ':\1' |\
	_diff_timestamps |\
	tee $out.g55.input_wait |\
	cumul >\
	$out.g55.input_wait_cumul &
    grep "'\(wait_for_answer\|got_answer\)'" < $subfifo.verbose.7 |\
	extract_fields "real_time" ':\1' |\
	_diff_timestamps |\
	tee $out.g56.answer_wait |\
	cumul >\
	$out.g56.answer_wait_cumul &
fi

for window in $ws_list; do
    mkfifo $mainfifo.all.sort2.window.$window
    if (( window > 5 )); then
	mkfifo $subfifo.window{1..2}.$window
    fi
    cat $mainfifo.all.sort2.window.$window |\
	cut -d ';' -f 2,3 |\
	compute_ws $window |\
	tee $subfifo.window*.$window |\
	gawk '{print $1, $2; }' >\
	$out.g30.ws_log.$window.extra &
    ln -sf $out.g30.ws_log.$window.extra $out.g31.ws_lin.$window.extra
    if [ -e $subfifo.window1.$window ]; then
	cat $subfifo.window1.$window |\
	    gawk '{print $1, $3; }' >\
	    $out.g32.sum_dist.$window.extra &
	cat $subfifo.window2.$window |\
	    gawk '{print $1, $4; }' >\
	    $out.g33.avg_dist.$window.extra &
    fi
done

# extract some interesting variables
mkfifo $prefifo.vars
var_list="use_my_guess dry_run use_o_direct use_o_sync wraparound_factor size_of_device"
extract_variables "$var_list" < $prefifo.vars > $tmp/vars &

mkfifo $prefifo.warnings
grep "^WARN" < $prefifo.warnings > $tmp/warnings &

# create intermediate pipelines on demand
for mode in reads writes r_push w_push ; do
    regex=" [Rr] "
    [ $mode = "writes" ] && regex=" [Ww] "
    [ $mode = "r_push" ] && regex=" r "
    [ $mode = "w_push" ] && regex=" w "
    for ord in nosort sort2 sort6 sort7; do
	if [ -n "$(echo $mainfifo.$mode.$ord*)" ]; then
	    mkfifo $mainfifo.tee_$mode.$ord
	    grep "$regex" < $mainfifo.tee_$mode.$ord |\
		tee $mainfifo.$mode.$ord* > /dev/null &
	fi
    done
done
if [ -n "$(echo $mainfifo.{all,reads,write}.sort6.*)" ]; then
    mkfifo $mainfifo.all.nosort.tee_sort6
    cat $mainfifo.all.nosort.tee_sort6 |\
	gawk -F ";" '{ printf("%s;%14.9f;%s;%s;%s;%s;%s\n", $1, $2+$6, $3, $4, $5, $6, $7); }' |\
	$sort -t';' -k2 -n |\
tee $mainfifo.all.sort6* $mainfifo.tee_{reads,writes,r_push,w_push}.sort6 > /dev/null &
fi
if [ -n "$(echo $mainfifo.{all,reads,write}.sort7.*)" ]; then
    mkfifo $mainfifo.all.nosort.tee_sort7
    cat $mainfifo.all.nosort.tee_sort7 |\
	gawk -F ";" '{ printf("%s;%14.9f;%s;%s;%s;%s;%s\n", $1, $2+$6+$7, $3, $4, $5, $6, $7); }' |\
	$sort -t';' -k2 -n |\
tee $mainfifo.all.sort7* $mainfifo.tee_{reads,writes,r_push,w_push}.sort7 > /dev/null &
fi

#  read FILE, add line numbers, and fill the main pipelines
mkfifo $prefifo.main
zcat -f < "$tmp/fifo.master" |\
    tee $prefifo.* |\
    grep ";" |\
    grep -v replay_ |\
    gawk -F ";" '{ if ($1 < 100000000000000000 && $5 < 100000000000000000 && $6 < 100000000000000000) { print; } }' |\
    nl -s ';' |\
    tee $mainfifo.{all,tee_reads,tee_writes,tee_r_push,tee_w_push}.nosort* |	\
    $sort -t';' -k2 -n |\
    tee $mainfifo.{all,tee_reads,tee_writes,tee_r_push,tee_w_push}.sort2* > /dev/null &

# fill the master pipeline...
echo "Starting preparation phase...."
zcat -f $(cat $tmp/files) > "$tmp/fifo.master" &

# really start all the background pipelines by this in _foreground_ ...

start_time="$(grep " started at " < $prefifo.main | sed 's/^.*started at //' | (head -1; cat > /dev/null))"

echo "Waiting for completion..."
wait

echo "Checking for errors..."
for reads_file in $tmp/*.reads.tmp.* ; do
    writes_file=$(echo $reads_file | sed 's/\.reads\./.writes./')
    errors_file=$(echo $reads_file | sed 's/\.reads\./.errors./')
    cat $reads_file $writes_file |\
	grep "inf" >\
	$errors_file &
done
wait

echo "Done preparation phase."

# variables may be defined multiple times (e.g. at different input files).
# compute and display {min,max} range for each.

source $tmp/vars
for i in $(cut -d= -f1 < $tmp/vars | sort -u); do
    grep "^$i=" $tmp/vars | cut -d= -f2 | sort -u -n > $tmp/vars.$i
    eval "${i}_min=$(head -n1 < $tmp/vars.$i)"
    eval "${i}_max=$(tail -n1 < $tmp/vars.$i)"
    if eval "[ \"\$${i}_min\" = \"\$${i}_max\" ]"; then
	eval "echo \"$i=\${$i}\""
    else
	eval "echo \"${i}_min=\${${i}_min}\""
	eval "echo \"${i}_max=\${${i}_max}\""
    fi
done

# display wrapoaround factor(s) in the corner

wrap_int_min="$(echo $wraparound_factor_min | cut -d. -f1)"
wrap_int_max="$(echo $wraparound_factor_max | cut -d. -f1)"
wrap_frac_min="$(echo $wraparound_factor_min | cut -d. -f2)"
var_color=""
if (( wrap_int_max > 1 || (!wrap_int_min && wrap_frac_min < 500) )); then
    var_color="$(textcolor warn)"
fi
var_text="wraparound_factor=$(echo "$(echo $(grep 'wraparound' $tmp/vars | cut -d= -f2 | sort -n -u))" | sed 's: :/:')"
var_label=""
if [ -n "$(grep 'wraparound' $tmp/vars)" ]; then
    var_label="set label \"$var_text\" at graph 1.0, screen 0.0 right $var_color front offset 0, character 1"
fi

warn_label=""
if [ -s $tmp/warnings ]; then
    warn_text="$(head -n1 < $tmp/warnings)"
    echo "$warn_text"
    warn_label="set label \"$warn_text\" at graph 0.0, screen 0.0 left $(textcolor warn) front offset 0, character 1"
fi

# display FAKE label if necessary

is_fake=0
fake_label=""
if [ -n "$use_o_direct" ]; then
    if (( !use_o_direct_min || dry_run_max )); then
	echo "detected FAKE results"
	is_fake=1
	fake_text="FAKE RESULT"
	if (( dry_run_max )); then
	    fake_text="DRY RUN -- $fake_text"
	else
	    (( !use_o_direct )) && fake_text="$fake_text -- no O_DIRECT"
	fi
	fake_font="arial,28"
	fake_label="set label \"$fake_text\" at graph 0.5, graph 0.5 center font \"$fake_font\" $(textcolor fake) front rotate by 45"
    fi
fi

# source all statistics values
for i in $tmp/stat.*; do
    source "$i"
done

# finally start all the gnuplot commands in parallel; they can take much time on huge plots

for reads_file in $tmp/*.reads.tmp.* ; do
    writes_file=$(echo $reads_file | sed 's/\.reads\./.writes./')
    r_push_file=$(echo $reads_file | sed 's/\.reads\./.r_push./')
    w_push_file=$(echo $reads_file | sed 's/\.reads\./.w_push./')
    errors_file=$(echo $reads_file | sed 's/\.reads\./.errors./')
    if [ -s $errors_file ]; then
	echo "Skipping $(basename $reads_file) due to errors"
	continue
    fi
    if ! [ -s $reads_file ] && ! [ -s $writes_file ]; then
	echo "Skipping empty $(basename $reads_file)"
	continue
    fi
    title=$(basename $reads_file | sed 's/\.reads\././; s/\.log\|\.tmp//g')
    (( is_fake )) && title="$title.FAKE"
    extra1=""
    extra2=""
    items="delays"
    bad_val=$bad_delay
    min=0
    max=0
    case $reads_file in
	*.latency.*)
	items="latencies"
	bad_val=$bad_latency
	min="$latency_all_min"
	max="$latency_all_max"
	hit="$latency_all_hit"
	start="$latency_all_start"
	;;
	*.delay.*)
	min="$delay_all_min"
	max="$delay_all_max"
	hit="$delay_all_hit"
	start="$delay_all_start"
	;;
	*)
	max=$(cat $reads_file $writes_file | head -n1 | wc -l)
	;;
    esac
    if [ "$min" = "$max" ]; then
	echo "Skipping $(basename $reads_file), no data present"
	continue
    fi
    if [ -z "$reads_file" ] && [ -z "$writes_file" ]; then
	echo "Skipping empty $(basename $reads_file)"
	continue
    fi
    (
	ok_txt=""
	ok_color="ok"
	all_file=""
	quantile_label=""
	case $reads_file in
	    *.xy)
	    ;;
	    *.bins | *.flying | *.turns.* | *.thrp.*)
            all_file=$(echo $reads_file | sed 's/\.reads\./.all./')
	    ;;
	    *.latency.* | *.delay.*)
	    test_title="Test"
	    delay_title="$test_title passed: no $items beyond ${bad_val}s (max=${max}s)"
	    ok_txt="(ok)"
	    if [[ hit -gt 0 ]]; then
		ok_txt="(bad)"
		ok_color="bad"
		echo "$start 0" > $tmp/vfile.$title
		echo "$start $max" >> $tmp/vfile.$title
		delay_title="$test_title failed: $hit $items are beyond ${bad_val}s (max=${max}s)"
		extra2=", '$tmp/vfile.$title' title 'Start=$start' with lines $(lt $ok_color)"
	    fi
	    extra1=", $bad_val title '$delay_title' with lines $(lt $ok_color)"
	    ;;
	esac
	with="with points ps 0.1"
	xlabel="UNDEFINED"
	ylabel="UNDEFINED"
	xlogscale=""
	ylogscale="set logscale y;"
	infix=""
	case $reads_file in
	    *.thrp.setpoint*)
	    infix="thrp.setpoint"
	    ylabel="Demanded Throughput [IO/sec]  (Avg=$thrp_setpoint_all_avg, Max=$thrp_setpoint_all_max)"
	    with="with lines"
	    ylogscale=""
	    ;;
	    *.thrp.completed*)
	    infix="thrp.completed"
	    ylabel="Actual Throughput [IO/sec]  (Avg=$thrp_completed_all_avg, Max=$thrp_completed_all_max)"
	    with="with lines"
	    ylogscale=""
	    ;;
	    *.latency.flying*)
	    infix="latency.flying"
	    ylabel="Flying Requests [count]  (Avg=$latency_flying_all_avg, Max=$latency_flying_all_max)"
	    ;;
	    *.delay.flying*)
	    infix="delay.flying"
	    ylabel="Delayed Requests [count]  (Avg=$delay_flying_all_avg, Max=$delay_flying_all_max)"
	    ;;
	    *.freq.bins*)
	    ylabel="Repetition Frequency [count]"
	    ;;
	    *.latency.bins*)
	    ylabel="Latency [sec]"
	    ;;
	    *.latency.*)
	    infix="latencies"
	    ylabel="Latency [sec]  (Avg=$latency_all_avg, Max=$latency_all_max)"
	    ;;
	    *.delay.bins*)
	    ylabel="Delay [sec]"
	    ;;
	    *.delay.*)
	    infix="delays"
	    ylabel="Delay [sec]  (Avg=$delay_all_avg, Max=$delay_all_max)"
	    ;;
	    *.rqsize.*)
	    infix="rqsize"
	    ylabel="Request Size [blocks]  (Avg=$rqsize_all_avg, Max=$rqsize_all_max)"
	    ;;
	    *.rqpos.*)
	    ylabel="Request Position in Device [GiB]"
	    source $tmp/rqpos_all.ymax
	    for i in $(grep "size_of_device=" $tmp/vars | cut -d= -f2 | sort -n -u); do
		(( device_size = (i - 1) / 2 / 1024 / 1024 + 1 ))
		{
		    echo "$device_size.01 1"
		    echo "$device_size.01 $ymax"
		    echo "$device_size.02 $ymax"
		    echo "$device_size.02 1"
		} > $tmp/vfile.$title.$i
		extra2="$extra2, '$tmp/vfile.$title.$i' title 'Size of Device = $device_size [GiB]' with lines $(lt border)"
	    done
	    ;;
	    *.turns.setpoint*)
	    infix="turns.setpoint"
	    ylabel="Number of Turns during $turn_window sec [%]  (Avg=$turns_setpoint_all_avg, Max=$turns_setpoint_all_max)"
	    ;;
	    *.turns.completed*)
	    infix="turns.completed"
	    ylabel="Number of Turns during $turn_window sec [%]  (Avg=$turns_completed_all_avg, Max=$turns_completed_all_max)"
	    ;;
	esac

	for i in $tmp/label.$infix.*; do
	    source "$i"
	done

	if [ -s "$all_file" ]; then
	    extra1="$extra1, '$all_file' title 'Reads+Writes${all_label}' with lines $(lt all)"
	fi

	case $reads_file in
	    *.turns.*)
	    xlabel="Duration [sec]"
	    ylogscale=""
	    with="with lines"
	    ;;
	    *.realtime)
	    xlabel="Real Duration [sec]"
	    ;;
	    *.setpoint)
	    xlabel="Demanded Duration [sec]"
	    ;;
	    *.points)
	    xlabel="Requests [count]"
	    ;;
	    *.completed)
	    xlabel="Completion Timestamp [sec]"
	    ;;
	    *.flying)
	    xlabel="Duration [sec]"
	    with="with lines"
	    ;;
	    *.freq.bins)
	    with="with lines"
	    xlabel="Some 4k Page [occurrence] (reverse order)"
	    xlogscale="set logscale x;"
	    ;;
	    *.bins)
	    with="with linespoints"
	    xlabel="$ylabel"
	    ylabel="Number in Bin [count]"
	    xlogscale="set logscale x;"
	    ;;
	    *.delay.xy)
	    xlabel="Delay [sec]"
	    xlogscale="set logscale x;"
	    ;;
	    *.xy)
	    xlabel="Flying Requests [count]"
	    ;;
	esac
	case $reads_file in
	    *.rqpos.*)
	    xlogscale=""
	    with="with lines"
	    ;;
	esac

	y0=0
	for mode in reads writes all; do
	    y=1
	    for q in $(echo $reads_file | sed "s/\.reads\./.$mode./" | sed 's/\.tmp\./.side./' | sed 's/$/.quantile/'); do
		[ -s $q ] || continue
		while read x frac limit speedup; do
		    pos="0.$((y++))$y0"
		    text="$mode"
		    [[ "$mode" = "all" ]] && text="ops"
		    quantile_label="$quantile_label set label \"${limit}% of ${text} below ${x} (${frac}% of pages, speedup=$speedup)  \" at $x, graph $pos right font \"arial,7\" $(textcolor $mode) point $(lt $mode);"
		done < $q
	    done
	    (( y0 += 2 ))
	done
	
	echo "---> plot on $title.$picturetype $ok_txt"
    
	plot=""
	if [ -s "$reads_file" ]; then
	    plot="plot '$reads_file' title 'Reads${reads_label}' $with $(lt reads)"
	fi
	if [ -s "$writes_file" ]; then
	    if [ -n "$plot" ]; then
		plot="$plot, "
	    else
		plot="plot "
	    fi
	    plot="$plot '$writes_file' title 'Writes${writes_label}' $with $(lt writes)"
	fi
	if [ -s "$r_push_file" ]; then
	    if [ -n "$plot" ]; then
		plot="$plot, "
	    else
		plot="plot "
	    fi
	    plot="$plot '$r_push_file' title 'Read Pushes${r_push_label}' $with $(lt r_push)"
	fi
	if [ -s "$w_push_file" ]; then
	    if [ -n "$plot" ]; then
		plot="$plot, "
	    else
		plot="plot "
	    fi
	    plot="$plot '$w_push_file' title 'Write Pushes${w_push_label}' $with $(lt w_push)"
	fi
	if [ -n "$plot" ]; then
	    plot="$plot $extra1 $extra2"
	fi
	
	<<EOF gnuplot
	set term $picturetype $pictureoptions;
	set output "$title.$picturetype";
	set title "$title $start_time";
	$xlogscale
	$ylogscale
	set ylabel '$ylabel';
	set xlabel '$xlabel';
	$var_label
	$quantile_label
	$warn_label
	$fake_label
	$plot;
EOF
    ) &
    (( sequential_mode )) && wait
done

for mode in thrp ws_log ws_lin sum_dist avg_dist $extra_modes; do
    plot=""
    delim="plot"
    using=""
    outname=""
    lines="lines"
    [ $mode = latency ] && lines="linespoints"
    for i in $tmp/*.$mode $tmp/*.$mode.*.extra; do
	[ -s $i ] || continue
	mode_title="$mode"
	if [[ "$i" =~ ".extra" ]]; then
	    mode_title="$(echo $i | sed "s/^.*\.$mode\./$mode./" | sed 's/\.extra//')"
	fi
	mode_title="$mode_title  ($(echo $(cat "$i" | sed 's/^ *[^ ]\+ \+//' | make_statistics_short "" | grep "max=\|avg=" | sort) | sed 's/ /, /'))"
	title=$(basename $i | sed 's/\.\(tmp\|extra\|sort[0-9]\+\|000\)//g')
	color_key=$(echo $title | sed 's/^.*\.g[0-9]\+\.//')
	if (( verbose_script )); then
	    expansion="$(rgb "" "$color_key")"
	    [ -z "$expansion" ] && expansion="(no expansion)"
	    echo "Color_Key = $color_key => $expansion"
	fi
	plot="$plot$delim '$i' $using title '$mode_title' with $lines $(lt "$color_key")"
	delim=","
	[ -z "$outname" ] && ! (echo $i | grep -q "\.orig\.") && outname="$(basename $i | sed 's/\.\(tmp\|extra\|sort[0-9]\+\|000\|actual\|demand\)//g').$picturetype"
    done

    if [ -z "$plot" ]; then
	continue
    fi

    echo "---> plot on $title.$picturetype"

    (
	xlabel="Duration [sec]"
	scale=""
	case $mode in
	    thrp)
	    ylabel="Throughput [IOs/sec]"
	    ;;
	    ws_log)
	    ylabel="Workingset Size [count]"
	    scale="set logscale y;"
	    ;;
	    ws_lin)
	    ylabel="Workingset Size [count]"
	    ;;
	    avg_dist)
	    ylabel="Average Distance [sectors]"
	    scale="set logscale y;"
	    ;;
	    sum_dist)
	    ylabel="Total Distance [sectors]"
	    scale="set logscale y;"
	    ;;
	    *_level | *_ahead | *_lag | *_wait | *_cumul)
	    xlabel="Requests [count]"
	    ;;
	esac
	<<EOF gnuplot
	set term $picturetype $pictureoptions;
	set output "$outname";
	set title '$title $start_time'
	$scale
	set ylabel '$ylabel';
	set xlabel '$xlabel';
	$var_label
	$warn_label
	$fake_label
	$plot;
EOF
    ) &
    (( sequential_mode )) && wait
done

echo "Final wait..."
wait
echo "Done all plots."

rm -rf "$tmp"
exit 0
