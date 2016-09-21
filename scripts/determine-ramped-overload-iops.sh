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

#
# Rationale: RAMPED loads have a start phase where the target IOPS
# is not yet fully exploitet, because less IOPS are demanded than could
# be delivered.
#
# This can make a difference on the report of agerage IOPS.
#
# For compensation, this script simply skips the starting phase
# until a deay of at least 1 second is reached.

echo "Overload IOPS for $@"

for i in $@; do
    zgrep ";" $i |\
	grep -v [a-z] |\
	awk -F';' '{ if ($5 > 1.0) { enable = 1; } if (enable) { print $0; } }' |\
	awk -F';' 'BEGIN{ mi = 999999; } { count++; t = $1 + $5 + $6; if (t < mi) { mi = t; } if (t > mx) { mx = t; } } END{ printf("OPS=%d FROM=%f TO=%f\n", count, mi, mx); printf("IOPS=%f\n", count / (mx - mi)); }'
done
