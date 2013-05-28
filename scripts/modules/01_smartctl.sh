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

# TST Oct 2012

function report_smart
{
    at=$1
    for i in $(eval echo {0..$((replay_count_orig-1))}); do
	host="${replay_host_orig[$i]}"
	dev="${replay_device_orig[$i]}"
	devx=$(echo $dev | sed :^/:: | sed 's:[/]:_:g')
	remote "$host" "hdparm -I $dev" >   $smart_report_round.HDPARM.$at.$host.$devx
	remote "$host" "smartctl -a $dev" > $smart_report_round.SMART.a.$at.$host.$devx
	remote "$host" "smartctl -x $dev" > $smart_report_round.SMART.x.$at.$host.$devx
    done
    (( smart_report_round++ ))
    return 0
}

function ssd_trim
{
    for i in $(eval echo {0..$((replay_count_orig-1))}); do
	host="${replay_host_orig[$i]}"
	dev="${replay_device_orig[$i]}"
	cmd="$(cat)" <<EOF
if ! [ -b $dev ]; then
        echo "Device $dev does not exist on $host"
        exit -1
fi
size=$(hdparm -g $dev | grep sectors | sed 's/^.*sectors = \([0-9]\+\).*$/\1/')
echo "size of $dev: $size sectors"

i=0
while (( i < size )); do
        (( rest = size - i ))
        if (( rest > 32768 )); then
                rest=32768
        fi
        echo "$i:$rest"
        (( i += rest ))
done | hdparm --trim-sector-ranges-stdin --please-destroy-my-drive $dev
EOF
	remote "$host" "$cmd" || exit $?
    done
}

function ssd_erase
{
    for i in $(eval echo {0..$((replay_count_orig-1))}); do
	host="${replay_host_orig[$i]}"
	dev="${replay_device_orig[$i]}"
	cmd="hdparm --user-master u --security-set-pass xxx $dev && hdparm --user-master u --security-erase xxx $dev"
	remote "$host" "$cmd" || exit $?
    done
}

function smartctl_finish
{
    (( !enable_smartctl )) && return 0
    echo "$FUNCNAME reporting SMART values"
    report_smart at_end
}

function smartctl_wait
{
    infix=$1
    if (( settle_wait )); then
	echo "$(date) Settling time: sleep for $settle_wait seconds..."
	sleep $settle_wait
	echo "$(date) Settling time has passed."
	report_smart after_${infix}_settling
    fi
}

function smartctl_prepare
{
    (( !enable_smartctl )) && return 0
    echo "$FUNCNAME reporting SMART values"
    report_smart at_start
    if (( enable_ssd_erase )); then
	ssd_erase || exit $?
	report_smart after_erase
	smartctl_wait erase
    fi
    if (( enable_ssd_trim )); then
	ssd_trim || exit $?
	report_smart after_trim
	smartctl_wait trim
    fi
}

smart_report_round=0
prepare_list="$prepare_list smartctl_prepare"
finish_list="smartctl_finish $finish_list"
