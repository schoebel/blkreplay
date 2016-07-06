#!/usr/bin/env bash
# Copyright 2016 Thomas Schoebel-Theuer /  1&1 Internet AG
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

# Create adjacent load from several original loads.
#
# The original loads "$@" are changed at their _spatial_ locality
# such they will not overlap in space.
# In difference, the timestamps are not changed.

# NOTICE: this is IMPORTANT for testing with HDDs.
# There may be substantial differences because the mechanical seek distances
# typically will have a substantial impact on performance.

# Spatial locality would be WRONG when simply concatenating multiple
# input loads, because they would be treated as multiple IO sources
# going to the SAME target LV instance.

# In contrast, this script treats multiple IO sources as going
# to DIFFERENT target LVs.

# The resulting single target LV must be big enough in order to
# get a low wrap_around factor.

# Check the result of this operation by looking at the *.rqpos.* graphics!

# Usage: ./create_adjacent_load.sh infiles*.load.gz | gzip -9 > outfile.load.gz

# TST 2016-07-04

global_offset=0

function cat_load
{
    local infile="$1"
    m="$(zgrep ";" $infile | gawk -F";" "BEGIN{ m = 0; } { if (m == 0 || \$2 < m) { m = \$2; } } END{ print int(m / 8) * 8; }")"
    [[ "$m" = "" ]] && m=0
    offset="$(zgrep ";" $infile | gawk -F";" "{ if (\$2 + \$3 - $m > offset) { offset = \$2 + \$3 - $m; } } END{ print $global_offset + (int(offset / 8) + 1) * 8; }" )"
    echo "file $infile m=$m offset=$offset" >> /dev/stderr
    zgrep ";" $infile | grep -v "[a-z]" | gawk -F";" "{ printf(\"%s;%s;%s;%s;%s;%s\n\", \$1, \$2 + $offset - $m, \$3, \$4, \$5, \$6); }"
    global_offset=$offset
}

for i in $@; do
    cat_load $i
done | sort -n
