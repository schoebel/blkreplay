#!/usr/bin/env bash
# Copyright 2009-2012 Thomas Schoebel-Theuer, sponsored by 1&1 Internet AG
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

picturetype="${picturetype:-png}" # [ps|jpeg|gif|...]
pictureoptions="${pictureoptions:=small size 1200,800}" # other values: "size 800,600" etc
bad_latency="${bad_latency:-5.0}" # seconds
bad_delay="${bad_delay:-10.0}" # seconds
bad_ignore="${bad_ignore:-1}" # the n'th exceeding the limit
ws_list="${ws_list:-000 001 006 060 600}"

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
    bad=$1
    gawk -F ";" "BEGIN{min=0.0; max=0.0; sum=0.0; count=0; hit=0; start=0.0; } { sum += \$2; count++; if (\$2 > max) max = \$2; if (\$2 < min || !min) min = \$2; if (\$2 > $bad) { if (!hit) start=\$1; hit++; } } END { printf (\"min=%11.9f\nmax=%11.9f\ncount=%d\navg=%11.9f\nhit=%d\nstart=%11.9f\n\", min, max, count, (count > 0 ? sum/count : 0), hit, start); }"
}

function compute_ws
{
    window=$1
    advance=$1
    (( advance <= 0 )) && advance=1
    gawk -F ";" "BEGIN{ start = 0.0; count = 0; } { if (!start) start = \$1; while (\$1 >= start + $advance) { delta = 0.0; if ($window) { c = asorti(table); delta = table[c-1] - table[0]; } printf(\"%14.9f %d %14.9f %14.9f\n\", start+$advance, count, delta, (c > 0 ? delta/c : 0)); if ($window) { count = 0; delete table; } start += $advance; } if (!table[\$2]) { table[\$2] = \$2; count++; } }"
}

function compute_flying
{
    add="$1"
    diff="$2"
    gawk -F ";" "{ printf(\"%17.9f;1;%s;%s\n\", \$2 $add, \$6, \$7); printf(\"%17.9f;-1;x;x\n\", \$2 $add + \$$diff); }" |\
	$sort -n -s |\
	gawk -F ";" '{ count += $2; printf("%s;%5d;%s;%s\n", $1, count, $3, $4); }'
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
	sed "s/\($var_list\) *[=:] *\([0-9.]\+\)/\n\1=\2\n/g" |\
	grep "^[a-z_]\+[a-z_ ]\+=[0-9.]\+$" |\
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

out="$tmp/$name"


[[ "$name" =~ impulse ]] && thrp_window=${thrp_window:-1}
thrp_window=${thrp_window:-3}

gawk_thrp="{ time=int(\$1); if (time - oldtime >= $thrp_window) { printf(\"%d %13.3f\\n\", oldtime, count / $thrp_window.0); oldtime += $thrp_window; if (time - oldtime >= $thrp_window) { printf(\"%d 0.0\\n\", oldtime); factor = int((time - oldtime) / $thrp_window); oldtime += factor * $thrp_window; if (factor > 1) { printf(\"%d 0.0\\n\", oldtime); } }; count=0; }; count++; }"

# produce throughput graphics always
mkfifo $mainfifo.all.sort2.thrp
cat $mainfifo.all.sort2.thrp |\
    cut -d ';' -f 2 |\
    gawk "$gawk_thrp" >\
    $out.g00.demand.thrp &
if (( dynamic_mode )); then
    mkfifo $mainfifo.all.sort7.thrp
    cat $mainfifo.all.sort7.thrp |\
	cut -d ';' -f 2 |\
	gawk "$gawk_thrp" >\
	$out.g00.actual.thrp &
fi

# worker pipelines for reads / writes
for mode in reads writes all; do
    inp="$mainfifo.$mode"
    side="$subfifo.side.$mode"
    i="$mode.tmp"
    if (( static_mode )); then
	mkfifo $inp.nosort.rqsize
	cat $inp.nosort.rqsize |\
	    cut -d ';' -f 4 |\
	    $bin_dir/bins.exe >\
	    $out.g40.rqsize.$i.bins &
	mkfifo $inp.nosort.rqpos
	mkfifo $side.rqpos_tmp
	cat $inp.nosort.rqpos |\
	    cut -d ';' -f 3 |\
	    gawk '{ i = int($1 / 2097152); table[i]++; if (i > xmax) xmax = i; } END{ for (i = 0; i <= xmax + 1; i++) { printf("%5d %5d\n%5d %5d\n", i, table[i], i+1, table[i]); if (table[i] > ymax) ymax = table[i]; } printf("ymax=%d\n", ymax); }' |\
	    tee $side.rqpos_tmp |\
	    grep -v '^[a-z]' >\
	    $out.g41.rqpos.$i.bins &
	grep '^[a-z]' < $side.rqpos_tmp >\
	    $tmp/rqpos_$mode.ymax &
    fi
    if (( dynamic_mode )) && [ "$mode" != "all" ]; then
	mkfifo $inp.sort6.dyn.1
	cat $inp.sort6.dyn.1 |\
	    cut -d ';' -f 2,7 |\
	    sed 's/;/ /' >\
	    $out.g01.latency.$i.realtime &
	mkfifo $inp.sort2.dyn.2
	cat $inp.sort2.dyn.2 |\
	    cut -d ';' -f 2,7 |\
	    sed 's/;/ /' >\
	    $out.g02.latency.$i.setpoint &
	mkfifo $inp.sort7.dyn.3
	cat $inp.sort7.dyn.3 |\
	    cut -d ';' -f 2,7 |\
	    sed 's/;/ /' >\
	    $out.g03.latency.$i.completed &
	mkfifo $inp.nosort.dyn.3
	cat $inp.nosort.dyn.3 |\
	    cut -d ';' -f 1,7 |\
	    sed 's/;/ /' >\
	    $out.g03.latency.$i.points &
	mkfifo $inp.sort2.dyn.4
	cat $inp.sort2.dyn.4 |\
	    cut -d ';' -f 2,6 |\
	    sed 's/;/ /' >\
	    $out.g04.delay.$i.setpoint &
	mkfifo $inp.nosort.dyn.5
	cat $inp.nosort.dyn.5 |\
	    cut -d ';' -f 1,6 |\
	    sed 's/;/ /' >\
	    $out.g05.delay.$i.points &
	mkfifo $side.{1..2}
	cat $side.1 |\
	    cut -d";" -f2,4 |\
	    grep -v "x" |\
	    sed 's/;/ /' >\
	    $out.g10.latency.$i.xy &
	cat $side.2 |\
	    cut -d";" -f2,3 |\
	    grep -v "x" |\
	    sed 's/;/ /' >\
	    $out.g11.delay.$i.xy &
	mkfifo $inp.nosort.dyn.12
	cat $inp.nosort.dyn.12 |\
	    cut -d ';' -f 6,7 |\
	    sed 's/;/ /' >\
	    $out.g12.$i.latency.delay.xy &
    fi
    if (( dynamic_mode )); then
	mkfifo $inp.nosort.dyn.6
	cat $inp.nosort.dyn.6 |\
	    cut -d ';' -f 7 |\
	    $bin_dir/bins.exe >\
	    $out.g06.latency.$i.bins &
	mkfifo $inp.nosort.dyn.7
	cat $inp.nosort.dyn.7 |\
	    cut -d ';' -f 6 |\
	    $bin_dir/bins.exe >\
	    $out.g07.delay.$i.bins &
	mkfifo $inp.nosort.dyn.8
	cat $inp.nosort.dyn.8 |\
	    compute_flying "+\$6" 7 |\
	    tee $side.* |\
	    cut -d";" -f1,2 |\
	    sed 's/;/ /' >\
	    $out.g08.latency.$i.flying &
	mkfifo $inp.nosort.dyn.9
	cat $inp.nosort.dyn.9 |\
	    compute_flying "" 6 |\
	    cut -d";" -f1,2 |\
	    sed 's/;/ /' >\
	    $out.g09.delay.$i.flying &
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

if (( dynamic_mode )); then
    mkfifo $mainfifo.all.sort2.latencies
    cat $mainfifo.all.sort2.latencies |\
	cut -d ';' -f 2,7 |\
	make_statistics $bad_latency >\
	$tmp/latencies &
    mkfifo $mainfifo.all.sort2.delays
    cat $mainfifo.all.sort2.delays |\
	cut -d ';' -f 2,6 |\
	make_statistics $bad_delay   >\
	$tmp/delays &
fi

for window in $ws_list; do
    mkfifo $mainfifo.all.sort2.window.$window
    mkfifo $subfifo.window{1..2}.$window
    cat $mainfifo.all.sort2.window.$window |\
	cut -d ';' -f 2,3 |\
	compute_ws $window |\
	tee $subfifo.window*.$window |\
	gawk '{print $1, $2; }' >\
	$out.g30.ws_log.$window.extra &
    ln -sf $out.g30.ws_log.$window.extra $out.g31.ws_lin.$window.extra 
    cat $subfifo.window1.$window |\
	gawk '{print $1, $3; }' >\
	$out.g32.sum_dist.$window.extra &
    cat $subfifo.window2.$window |\
	gawk '{print $1, $4; }' >\
	$out.g33.avg_dist.$window.extra &
done

# extract some interesting variables
mkfifo $prefifo.vars
var_list="use_my_guess dry_run use_o_direct use_o_sync wraparound_factor size_of_device"
extract_variables "$var_list" < $prefifo.vars > $tmp/vars &

# create intermediate pipelines on demand
for mode in reads writes; do
    regex=" R "
    [ $mode = "writes" ] && regex=" W "
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
	tee $mainfifo.all.sort6* $mainfifo.tee_{reads,writes}.sort6 > /dev/null &
fi
if [ -n "$(echo $mainfifo.{all,reads,write}.sort7.*)" ]; then
    mkfifo $mainfifo.all.nosort.tee_sort7
    cat $mainfifo.all.nosort.tee_sort7 |\
	gawk -F ";" '{ printf("%s;%14.9f;%s;%s;%s;%s;%s\n", $1, $2+$6+$7, $3, $4, $5, $6, $7); }' |\
	$sort -t';' -k2 -n |\
	tee $mainfifo.all.sort7* $mainfifo.tee_{reads,writes}.sort7 > /dev/null &
fi

#  read FILE, add line numbers, and fill the main pipelines
mkfifo $prefifo.main
zcat -f < "$tmp/fifo.master" |\
    tee $prefifo.* |\
    grep ";" |\
    grep -v replay_ |\
    gawk -F ";" '{ if ($1 < 100000000000000000 && $5 < 100000000000000000 && $6 < 100000000000000000) { print; } }' |\
    nl -s ';' |\
    tee $mainfifo.{all,tee_reads,tee_writes}.nosort* |\
    $sort -t';' -k2 -n |\
    tee $mainfifo.{all,tee_reads,tee_writes}.sort2* > /dev/null &

# fill the master pipeline...
echo "Starting preparation phase...."
zcat -f $(cat $tmp/files) > "$tmp/fifo.master" &

# really start all the background pipelines by this in _foreground_ ...

start_time="$(grep " started at " < $prefifo.main | sed 's/^.*started at //' | (head -1; cat > /dev/null))"

echo "Waiting for completion..."
wait
echo "Done preparation phase."

cat $tmp/vars
source $tmp/vars
wrap_int="$(echo $wraparound_factor | cut -d. -f1)"
wrap_frac="$(echo $wraparound_factor | cut -d. -f2)"
var_color=""
if (( wrap_int > 1 || (!wrap_int && wrap_frac < 500) )); then
    var_color="textcolor rgb \"#A300A0\""
fi
var_text="$(echo $(grep 'wrap' $tmp/vars))"
var_label="set label \"$var_text\" at graph 1.0, screen 0.0 right $var_color front offset 0, character 1"
is_fake=0
fake_label=""
if [ -n "$use_o_direct" ]; then
    if (( !use_o_direct || dry_run )); then
	echo "detected FAKE results"
	is_fake=1
	fake_text="FAKE RESULT"
	if (( dry_run )); then
	    fake_text="DRY RUN -- $fake_text"
	else
	    (( !use_o_direct )) && fake_text="$fake_text -- no O_DIRECT"
	fi
	fake_font="arial,28"
	fake_color="#B35200"
	fake_label="set label \"$fake_text\" at graph 0.5, graph 0.5 center font \"$fake_font\" textcolor rgb \"$fake_color\" front rotate by 45"
    fi
fi

# finally start all the gnuplot commands in parallel; they can take much time on huge plots

for reads_file in $tmp/*.reads.tmp.* ; do
    writes_file=$(echo $reads_file | sed 's/\.reads\./.writes./')
    if grep -q "inf" $reads_file $writes_file; then
	echo "Skipping $reads_file due to errors"
	continue
    fi
    title=$(basename $reads_file | sed 's/\.reads\././; s/\.log\|\.tmp//g')
    (( is_fake )) && title="$title.FAKE"
    extra1=""
    extra2=""
    items="delays"
    bad=$bad_delay
    min=0
    max=0
    case $reads_file in
	*.latency.*)
	items="latencies"
	bad=$bad_latency
	source $tmp/latencies
	;;
	*.delay.*)
	source $tmp/delays
	;;
	*)
	max=$(cat $reads_file $writes_file | wc -l)
	;;
    esac
    if [ "$min" = "$max" ]; then
	echo "Skipping $reads_file, no data present"
	continue
    fi
    (
	color=""
	lt_color=2
	case $reads_file in
	    *.xy)
	    ;;
	    *.bins | *.flying)
            sum_file=$(echo $reads_file | sed 's/\.reads\./.all./')
	    extra2=", '$sum_file' title 'Reads+Writes' with lines lt 7"
	    ;;
	    *.latency.* | *.delay.*)
	    test_title="Test"
	    delay_title="$test_title passed: no $items beyond ${bad}s (max=${max}s)"
	    color="(green)"
	    if [[ hit -gt 0 ]]; then
		color="(purple)"
		lt_color=4
		echo "$start 0" > $tmp/vfile.$title
		echo "$start $max" >> $tmp/vfile.$title
		delay_title="$test_title failed: $hit $items are beyond ${bad}s (max=${max}s)"
		extra2=", '$tmp/vfile.$title' title 'Start=$start' with lines lt $lt_color"
	    fi
	    extra1=", $bad title '$delay_title' with lines lt $lt_color"
	    ;;
	esac
	with="with points ps 0.1"
	xlabel="UNDEFINED"
	ylabel="UNDEFINED"
	dlabel="Flying Requests [count]"
	xlogscale=""
	case $reads_file in
	    *.latency.*)
	    ylabel="Latency [sec]  (Avg=$avg)"
	    ;;
	    *.delay.*)
	    ylabel="Delay [sec]  (Avg=$avg)"
	    dlabel="Delayed Requests [count]"
	    ;;
	    *.rqsize.*)
	    ylabel="Request Size [blocks]"
	    ;;
	    *.rqpos.*)
	    ylabel="Request Position in Device [GiB]"
	    if (( size_of_device > 0 )); then
		(( device_size = (size_of_device - 1) / 2 / 1024 / 1024 + 1 ))
		source $tmp/rqpos_all.ymax
		{
		    echo "$device_size.01 1"
		    echo "$device_size.01 $ymax"
		    echo "$device_size.02 $ymax"
		    echo "$device_size.02 1"
		} > $tmp/vfile.$title
		extra2=", '$tmp/vfile.$title' title 'Size of Device = $device_size [GiB]' with lines lt 6"
	    fi
	    ;;
	esac
	case $reads_file in
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
	    ylabel="$dlabel"
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
	
	echo "---> plot on $title.$picturetype $color"
    
	plot=""
	if [ -s "$reads_file" ]; then
	    plot="plot '$reads_file' title 'Reads' $with lt 3"
	fi
	if [ -s "$writes_file" ]; then
	    if [ -n "$plot" ]; then
		plot="$plot, "
	    else
		plot="plot "
	    fi
	    plot="$plot '$writes_file' title 'Writes' $with lt 1 $extra1 $extra2"
	fi
	
	<<EOF gnuplot
	set term $picturetype $pictureoptions;
	set output "$title.$picturetype";
	set title "$title $start_time";
	set logscale y;
	$xlogscale
	set ylabel '$ylabel';
	set xlabel '$xlabel';
	$var_label
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
	case $mode in
	    sum_dist | avg_dist)
	    case $i in
		*.00[0-5].*)
		rm -f "$i"
		continue
		;;
	    esac
	    ;;
	esac
	title=$(basename $i | sed 's/\.\(tmp\|extra\)//g')
	plot="$plot$delim '$i' $using title '$title' with $lines"
	delim=","
	[ -z "$outname" ] && ! (echo $i | grep -q "\.orig\.") && outname="$(basename $i | sed 's/\.\(tmp\|extra\|000\|actual\)//g').$picturetype"
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
	    ylabel="Workingset Size"
	    scale="set logscale y;"
	    ;;
	    ws_lin)
	    ylabel="Workingset Size"
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
	set title '$mode $start_time'
	$scale
	set ylabel '$ylabel';
	set xlabel '$xlabel';
	$var_label
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
