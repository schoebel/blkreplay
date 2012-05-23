#!/bin/bash
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

# New modularized version May 2012

# Make many measurements in subtrees of current working directory.
# Use directory names as basis for configuration variants

base_dir="$(dirname "$(which "$0")")"
source "$base_dir/modules/lib.sh" || exit $?

dry_run_script=0

# check some preconditions

check_list="grep sed awk head tail cat cut nice date gzip gunzip zcat ssh rsync buffer"
check_installed "$check_list"

# include modules
prepare_list=""
setup_list=""
run_list=""
cleanup_list=""
finish_list=""
shopt -s nullglob
for module in $base_dir/modules/[0-9]*.sh; do
    modname="$(basename $module | sed 's/^[0-9]*_\([^.]*\)\..*/\1/')"
    if source_config default-$modname; then
	echo "Sourcing module $modname"
	source $module || exit $?
    elif [ "$modname" = "main" ]; then
	echo "Cannot use main module. Please provide some config file 'default-$modname.conf' in $(pwd) or in some parent directory."
	exit -1
    fi
done

# parse options.
while [ $# -ge 1 ]; do
    key="$(echo "$1" | cut -d= -f1)"
    val="$(echo "$1" | cut -d= -f2-)"
    case "$key" in
	--test | --dry-run)
        dry_run_script="$val"
	shift
        ;;
	--override)
	shift
	echo "=> Overriding $1"
	eval $1
	shift
        ;;
	*)
	break
        ;;
    esac
done

ignore="grep -v '[/.]old' | grep -v 'ignore'"

# find directories
resume=1
while (( resume )); do
    echo "Scanning directory structure starting from $(pwd)"
    resume=0
    for test_dir in $(find . -type d | eval "$ignore" | sort); do
	(( dry_run_script )) || rm -f $test_dir/dry-run.replay.gz
	if [ -e "$test_dir/skip" ]; then
	    echo "Skipping directory $test_dir"
	    continue
	fi
	if [ $(find $test_dir -type d | eval "$ignore" | wc -l) -gt 1 ]; then
	    echo "Ignoring inner directory $test_dir"
	    continue
	fi
	shopt -u nullglob
	if ls $test_dir/*.replay.gz > /dev/null 2>&1; then
	    echo "Already finished $test_dir"
	    continue
	fi
	echo ""
	echo "==============================================================="
	echo "======== $test_dir"
	(
	    shopt -s nullglob
	    for i in $(echo $test_dir | sed 's/\// /g'); do
		[ "$i" = "." ] && continue
		if ! source_config "$i"; then
		    echo "Cannot source config file '$i.conf' -- please provide one."
		    exit -1
		fi
	    done
	    export sub_prefix=$(echo $test_dir | sed 's/\//./g' | sed 's/\.\././g')
	    cd $test_dir
	    if (( dry_run_script )); then
		echo "==> Dry Run ..."
		touch dry-run.replay.gz
	    else
		echo "==> $(date) Starting $sub_prefix"
		main || { echo "Replay failure $?"; exit -1; }
	    fi
	    echo "==> $(date) Finished."
	) || { echo "Failure $?"; exit -1; }
	echo "==============================================================="
	echo ""
	(( resume++ ))
	break
    done
done

echo "======== Finished pwd=$(pwd)"
exit 0