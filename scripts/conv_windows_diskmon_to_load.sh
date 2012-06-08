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

# Filter: convert windows DiskMon .LOG format to our parselog format
#
# TST Jan 2010

# check some preconditions
script_dir="$(cd "$(dirname "$(which "$0")")"; pwd)"
source "$script_dir/modules/lib.sh" || exit $?

check_list="grep sed cut gzip zcat gawk"
check_installed "$check_list"

filename="$1"
echo "input:  $filename"
disks="$(zcat $filename | gawk '{ print $4; }' | sort -u)"
echo "disks: " $disks

#cat $filename | while read Nummer Time Dauer Disk Request Sector Len rest; do
    #printf ": D   %c %10d %13s000 %12d %4d\n" "$Request" "$Nummer" "$Time" "$Sector" "$Len"
    #echo ": $Nummer $Time $Dauer $Disk $Request $Sector $Len"
    #:
#done

for disk in $disks; do
    outname="$(basename "$filename" | sed -e 's/\.log\|\.gz//gi').disk$disk.load.gz"
    echo "output: $outname"
    {
	    echo_copyright "$filename"
	    echo "start ; sector; length ; op ;  replay_delay=0 ; replay_duration=0"
	    zcat $filename |			\
	    gawk \
"{
    if(\$4 == $disk) {
       printf \"%13s000 ; %12d ; %4d ; %c ; 0.0 ; %s\n\", \$2, \$6, \$7, \$5, \$3;
     }
}" |\
	    sort -n -s
    } | gzip -8 > $outname
done
exit $?
