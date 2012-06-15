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

check_list="grep sed gawk head tail cut tee mkfifo nice date find gzip gunzip zcat gnuplot"
check_installed "$check_list"

tmp="${TMPDIR:-/tmp}/graph.$$"
rm -rf "$tmp"
mkdir -p "$tmp"
mkfifo "$tmp/master.fifo"

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

myfifo="$tmp/myfifo"
mkfifo $myfifo.pre
for k in {0..3}; do
    mkfifo $myfifo.all.sort0.$k
done
for k in {1..3}; do
    mkfifo $myfifo.all.sort2.$k
done
ws_fifos=""
for window in $ws_list; do
    ws=$myfifo.all.sort2.$window
    mkfifo $ws
    ws_fifos="$ws_fifos $ws"
    mkfifo $myfifo.all.dist1.$window
    mkfifo $myfifo.all.dist2.$window
done
for mode in reads writes; do
    for k in {0..10}; do
	mkfifo $myfifo.$mode.sort0.$k
    done
    for k in {0..2}; do
	mkfifo $myfifo.$mode.sort2.$k
    done
done

function make_statistics
{
    bad=$1
    gawk -F ";" "BEGIN{min=0.0; max=0.0; sum=0.0; count=0; hit=0; start=0.0; } { sum += \$2; count++; if (\$2 > max) max = \$2; if (\$2 < min || !min) min = \$2; if(\$2 > $bad) { if(!hit) start=\$1; hit++; } } END { printf (\"min=%f\nmax=%f\ncount=%d\navg=%f\nhit=%d\nstart=%f\n\", min, max, count, (count > 0 ? sum/count : 0), hit, start); }"
}

function compute_ws
{
    window=$1
    advance=$1
    (( advance <= 0 )) && advance=1
    gawk -F ";" "BEGIN{ start = 0.0; count = 0; } { if (!start) start = \$1; while (\$1 >= start + $advance) { delta = 0.0; if ($window) { c = asorti(table); delta = table[c-1] - table[0]; } printf(\"%f %d %f %f\n\", start+$advance, count, delta, (c > 0 ? delta/c : 0)); if ($window) { count = 0; delete table; } start += $advance; } if (!table[\$2]) { table[\$2] = \$2; count++; } }"
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
	gawk '{ if ($1 == oldx) { oldy += $2; } else { printf("%f %f\n", oldx, oldy); oldx = $1; oldy = $2; } } END{ printf("%f %f\n", oldx, oldy); }'
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
    gawk -F":" '{ if (count++ % 2) { printf("%f\n", $2 - old); } old = $2; }'
}

function diff_timestamps
{
    extract_fields "real_time seqnr" '\2:\1' |\
	$sort -n -s |\
	_diff_timestamps
}

function cumul
{
    gawk '{ sum += $1; printf("%f\n", sum); }'
}

[[ "$name" =~ impulse ]] && thrp_window=${thrp_window:-1}
thrp_window=${thrp_window:-3}

gawk_thrp="{ time=int(\$1); if(time - oldtime >= $thrp_window) { printf(\"%d %13.3f\\n\", oldtime, count / $thrp_window.0); oldtime += $thrp_window; while(time - oldtime >= $thrp_window) { printf(\"%d 0.0\\n\", oldtime); oldtime += $thrp_window; }; count=0; }; count++; }"

out="$tmp/$name"

# worker pipelines for reads / writes
for mode in reads writes; do
    inp=$myfifo.$mode
    i="$mode.tmp"
    if (( static_mode )); then
	cat $inp.sort0.8 | cut -d ';' -f 4 | $bin_dir/bins.exe >\
	    $out.g40.rqsize.$i.bins &
	cat $inp.sort0.9 | cut -d ';' -f 3 |\
	    gawk '{ i = int($1 / 2097152); table[i]++; if (i > max) max = i;} END{for (i = 0; i <= max + 1; i++) printf("%5d %5d\n", i, table[i]); }' >\
	    $out.g41.rqpos.$i.bins &
    else
	cat $inp.sort0.8 > /dev/null &
	cat $inp.sort0.9 > /dev/null &
    fi
    if (( dynamic_mode )); then
	cat $inp.sort0.1 | gawk -F ";" '{ printf("%f %f\n", $2+$6, $7); }' >\
	    $out.g01.latency.$i.realtime &
	cat $inp.sort2.1 | cut -d ';' -f 2,7 | sed 's/;/ /' >\
	    $out.g02.latency.$i.setpoint &
	cat $inp.sort0.2 | cut -d ';' -f 1,7 | sed 's/;/ /' >\
	    $out.g03.latency.$i.points &
	cat $inp.sort2.2 | cut -d ';' -f 2,6 | sed 's/;/ /' >\
	    $out.g04.delay.$i.setpoint &
	cat $inp.sort0.3 | cut -d ';' -f 1,6 | sed 's/;/ /' >\
	    $out.g05.delay.$i.points &
	cat $inp.sort0.4 | cut -d ';' -f 7 | $bin_dir/bins.exe >\
	    $out.g06.latency.$i.bins &
	cat $inp.sort0.5 | cut -d ';' -f 6 | $bin_dir/bins.exe >\
	    $out.g07.delay.$i.bins &
	mkfifo $inp.side.{1..2}
	cat $inp.sort0.6 |\
	    compute_flying "+\$6" 7 |\
	    tee $inp.side.{1..2} |\
	    cut -d";" -f1,2 |\
	    sed 's/;/ /' >\
	    $out.g08.latency.$i.flying &
	cat $inp.sort0.7 |\
	    compute_flying "" 6 |\
	    cut -d";" -f1,2 |\
	    sed 's/;/ /' >\
	    $out.g09.delay.$i.flying &
	cat $inp.side.1 |\
	    cut -d";" -f2,4 |\
	    grep -v "x" |\
	    sed 's/;/ /' >\
	    $out.g10.latency.$i.xy &
	cat $inp.side.2 |\
	    cut -d";" -f2,3 |\
	    grep -v "x" |\
	    sed 's/;/ /' >\
	    $out.g11.delay.$i.xy &
	cat $inp.sort0.10 | cut -d ';' -f 6,7 | sed 's/;/ /' >\
	    $out.g12.$i.latency.delay.xy &
    else
	for i in $inp.sort?.*; do
	    cat $i > /dev/null &
	done
    fi
done

# worker pipelines for all requests
if (( verbose_mode )); then
    extra_modes="submit_level pushback_level submit_ahead submit_lag answer_lag submit_lag_cumul answer_lag_cumul input_wait answer_wait input_wait_cumul answer_wait_cumul"
    mkfifo $myfifo.verbose.{1..7}
    grep "^INFO: action=" $myfifo.all.sort0.0 |\
	tee $myfifo.verbose.{1..7} > /dev/null &
    grep "'\(submit\|got_answer\)'" < $myfifo.verbose.1 |\
	extract_fields "count_submitted" '\1' >\
	$out.g50.submit_level &
    grep "'\(submit\|got_answer\)'" < $myfifo.verbose.2 |\
	extract_fields "count_pushback" '\1' >\
	$out.g51.pushback_level &
    grep "'submit'" < $myfifo.verbose.3 |\
	extract_fields "real_time rq_time" '\1:\2' |\
	gawk -F":" '{ printf("%f\n", $2 - $1); }' >\
	$out.g52.submit_ahead &
    grep "'\(submit\|worker_got_rq\)'" < $myfifo.verbose.4 |\
	diff_timestamps |\
	tee $out.g53.submit_lag |\
	cumul >\
	$out.g53.submit_lag_cumul &
    grep "'\(worker_send_answer\|got_answer\)'" < $myfifo.verbose.5 |\
	diff_timestamps |\
	tee $out.g54.answer_lag |\
	cumul >\
	$out.g54.answer_lag_cumul &
    grep "'\(wait_for_input\|got_input\)'" < $myfifo.verbose.6 |\
	extract_fields "real_time" ':\1' |\
	_diff_timestamps |\
	tee $out.g55.input_wait |\
	cumul >\
	$out.g55.input_wait_cumul &
    grep "'\(wait_for_answer\|got_answer\)'" < $myfifo.verbose.7 |\
	extract_fields "real_time" ':\1' |\
	_diff_timestamps |\
	tee $out.g56.answer_wait |\
	cumul >\
	$out.g56.answer_wait_cumul &
else
    cat $myfifo.all.sort0.0 > /dev/null &
fi
if (( static_mode )); then
    cat $myfifo.all.sort2.1 | cut -d ';' -f 2 | gawk "$gawk_thrp" >\
	$out.g20.demand.thrp &
    cat $myfifo.all.sort0.1 | gawk -F ";" '{ printf("%d\n", $2+$6+$7); }' | $sort -n | gawk "$gawk_thrp" >\
	$out.g20.actual.thrp &
    cat $myfifo.all.sort0.2 |\
	compute_flying "+\$6" 7 |\
	cut -d";" -f1,2 |\
	sed 's/;/ /' >\
	$out.g08.latency.sum.tmp.flying &
    cat $myfifo.all.sort0.3 |\
	compute_flying "" 6 |\
	cut -d";" -f1,2 |\
	sed 's/;/ /' >\
	$out.g09.delay.sum.tmp.flying &
else
    cat $myfifo.all.sort2.1 > /dev/null &
    cat $myfifo.all.sort0.1 > /dev/null &
    cat $myfifo.all.sort0.2 > /dev/null &
    cat $myfifo.all.sort0.3 > /dev/null &
fi
if (( dynamic_mode )); then
    cat $myfifo.all.sort2.2 | cut -d ';' -f 2,7 | make_statistics $bad_latency >\
	$tmp/latencies &
    cat $myfifo.all.sort2.3 | cut -d ';' -f 2,6 | make_statistics $bad_delay   >\
	$tmp/delays &
else
    cat $myfifo.all.sort2.2 > /dev/null &
    cat $myfifo.all.sort2.3 > /dev/null &
fi
for window in $ws_list; do
    cat $myfifo.all.sort2.$window | cut -d ';' -f 2,3 | compute_ws $window |\
	tee $myfifo.all.dist1.$window $myfifo.all.dist2.$window |\
	gawk '{print $1, $2; }' >\
	$out.g30.ws_log.$window.extra &
    ln -sf $out.g30.ws_log.$window.extra $out.g31.ws_lin.$window.extra 
    cat $myfifo.all.dist1.$window |\
	gawk '{print $1, $3; }' >\
	$out.g32.sum_dist.$window.extra &
    cat $myfifo.all.dist2.$window |\
	gawk '{print $1, $4; }' >\
	$out.g33.avg_dist.$window.extra &
done

# intermediate pipelines for Reads/Writes
for mode in reads writes; do
    regex=" R "
    [ $mode = "writes" ] && regex=" W "
    grep "$regex" < $myfifo.$mode.sort0.0 |\
	tee  $myfifo.$mode.sort0.{1..10} > /dev/null &
    grep "$regex" < $myfifo.$mode.sort2.0 |\
	tee  $myfifo.$mode.sort2.1 >\
	     $myfifo.$mode.sort2.2 &
done
#  read FILE, add line numbers, and fill the main pipelines
zcat -f < "$tmp/master.fifo" |\
    tee $myfifo.pre $myfifo.all.sort0.0 |\
    grep ";" |\
    grep -v replay_ |\
    nl -s ';' |\
    tee $myfifo.all.sort0.{1..3} |\
    tee $myfifo.{reads,writes}.sort0.0 |\
    $sort -t';' -k2 -n |\
    tee $myfifo.all.sort2.{1..3} |\
    tee $ws_fifos |\
    tee $myfifo.reads.sort2.0 >\
        $myfifo.writes.sort2.0 &

# fill the master pipeline...
echo "Start preparation phase...."
zcat -f $(cat $tmp/files) > "$tmp/master.fifo" &

# really start all the background pipelines by this in _foreground_ ...

start_time="$(grep " started at " < $myfifo.pre | sed 's/^.*started at //' | (head -1; cat > /dev/null))"

echo "Waiting for completion..."
wait
echo "Done preparation phase."

# finally start all the gnuplot commands in parallel; they can take much time on huge plots

for reads_file in $tmp/*.reads.tmp.* ; do
    writes_file=$(echo $reads_file | sed 's/\.reads\./.writes./')
    if grep -q "inf" $reads_file $writes_file; then
	echo "Skipping $reads_file due to errors"
	continue
    fi
    title=$(basename $reads_file | sed 's/\.reads\././; s/\.log\|\.tmp//g')
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
	eval $(cat $tmp/latencies)
	;;
	*.delay.*)
	eval $(cat $tmp/delays)
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
	color="green"
	lt_color=2
	case $reads_file in
	    *.xy)
	    ;;
	    *.bins | *.flying)
            sum_file=$(echo $reads_file | sed 's/\.reads\./.sum./')
	    if ! [ -e $sum_file ]; then
		cat $reads_file $writes_file | compute_sum > $sum_file
	    fi
	    extra2=", '$sum_file' title 'Reads+Writes' with lines lt 7"
	    ;;
	    *.latency.* | *.delay.*)
	    test_title="Test"
	    delay_title="$test_title passed: no $items beyond ${bad}s (max=${max}s)"
	    if [[ hit -gt 0 ]]; then
		color="purple"
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
	    ;;
	esac
	case $reads_file in
	    *.realtime)
	    xlabel="Real Duration [sec]"
	    ;;
	    *.setpoint)
	    xlabel="Intended Duration [sec]"
	    ;;
	    *.points)
	    xlabel="Requests [count]"
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
	    ;;
	esac
	
	echo "---> plot on $title.$picturetype ($color)"
    
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

    echo "---> plot on $mode"
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
