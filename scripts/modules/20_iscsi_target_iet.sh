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

# TST May 2012, quickly ported from old non-modular script code
# (originally written for myself only)
#
# old-style iet target.
# needs overwrite of config file. depends on sysv init.
#
# please improve this in case you are annoyed ;)
#
# in addition, write other iscsi_target_{lio,...} modules
# and submit them to blkreplay.org.

function iscsi_target_iet_finish
{
    (( !enable_iscsi_target_iet )) && return 0
    echo "$FUNCNAME finishing iSCSI connection to $iscsi_target target"
    cmd="(/etc/init.d/iscsitarget stop) 2>/dev/null; exit 0"
    remote "$iscsi_target" "$cmd"
}

function iscsi_target_iet_prepare
{
    (( !enable_iscsi_target_iet )) && return 0
    iqn_base="${iqn_base:-iqn.2000-01.info.test:test}"
    echo "$FUNCNAME preparing iSCSI target $iscsi_target_host iqn_base=$iqn_base"
    all_hosts_unique="$(for i in $all_hosts_unique $iscsi_target_host; do echo $i; done | sort -u)"
    iscsi_target_iet_finish >/dev/null 2>&1 # in case a previous run was interrupted

    for i in $(eval echo {0..$replay_max}); do
	base_dev="${replay_device[$i]}"
	target="$iqn_base.$(echo $base_dev | sed 's/[/-]/_/g')"

	echo "host $host: $base_dev -> $target"

	# remember values (also for other modules)
	base_device[$i]="$base_dev"
	replay_device[$i]="$target"
    done

    # create config file
    hint="# Automatically generated"
    for i in $(eval echo {0..$replay_max}); do
	echo "$hint"
	echo "Target ${replay_device[$i]}"
	echo -e "\tLun 0 Path=${base_device[$i]},Type=${iet_type:-blockio}"
	echo ""
    done | remote "$iscsi_target" "[ -r /etc/ietd.conf ] && ! grep -q '$hint' /etc/ietd.conf && mv -f /etc/ietd.conf /etc/ietd.conf.backup.$$; cat > /etc/ietd.conf"

    # activate it
    remote "$iscsi_target" "/etc/init.d/iscsitarget start; sleep 2"
}

prepare_list="$prepare_list iscsi_target_iet_prepare"
finish_list="iscsi_target_iet_finish $finish_list"
