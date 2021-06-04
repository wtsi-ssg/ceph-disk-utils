#!/bin/bash
# Script to manage a failed OSD (up to the point the disk is ready to swap)
# Run from a mon/mgr node with ssh agent-forwarding enabled
# (i.e. ssh -A hostname) so this can ssh to the node with the OSD on

# Copyright (C) 2021 Genome Research Limited
#
# Author: Matthew Vernon <mv3@sanger.ac.uk>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

set -e
set -o pipefail

if [ ! -r /etc/ceph/ceph.client.admin.keyring ]; then
    echo "Must be run on a mon/mgr host (with the admin keyring available)"
    exit 1
fi

if [ -z "$SSH_AUTH_SOCK" ]; then
    echo "You must run this with agent-forwarding enabled (i.e. ssh -A)"
    exit 1
fi

if [ "$#" -ne 1 ]; then
    echo "usage: ceph_manage_failed_osd.sh OSD"
fi

# Print a little picture showing which drive should be pulled
# Rows start at bays 45, 30, 15, 0
# each row is split into 6 + 6 + 3 by little dividers
show_bay()
{
    if [ "$#" -ne 1 ] ; then
	echo "Internal Error: show_bay requires a single argument"
	return 1
    fi
    if [ "$1" -lt 0 -o "$1" -gt 59 ] ; then
	echo "Only bays 0-59 exist"
	return 1
    fi
    echo -e "Drive is in bay ${1}, located as follows:\n      BACK"
    for row in 45 30 15 0 ;
    do for i in $(seq 0 14) ;
	do if [ "$(( row + i ))" -eq "$1" ] ; then
		echo -n "X"
	    else echo -n "O"
	    fi
	    if [ "$i" -eq 5 -o "$i" -eq 11 ] ; then
		echo -n "|"
	    fi
	done
	echo # emit newline at end of row
    done
    echo "      FRONT"
}

#Find our OSD
osd="$1"

if ! target=$( ceph osd find "$osd" | jq -r ".crush_location.host" ) ; then
    echo "Unable to find host for OSD ${osd}, giving up"
    exit 1
fi

if ! j=$( ssh "$target" /usr/local/sbin/ceph_remove_failed_osd.sh "$osd" ) ; then
    echo "Removal on target system $target failed. Stdout (if any) follows."
    echo "$j"
    exit 1
fi

#parse returned JSON
disk=$(echo "$j" | jq -r ".disk")
bay=$(echo "$j" | jq -r ".bay")
serial=$(echo "$j" | jq -r ".serial")
nvme=$(echo "$j" | jq -r ".nvme")
smart=$(echo "$j" | jq -r ".smart")

#output removal destructions

echo "Removal details for disk ${disk:-[device node missing]} on host $target:"
echo -e "It has ${serial},\nand has block.db on $nvme"
if [ "$smart" != "healthy" -a "$smart" != "absent" ]; then
    echo "SMART status: $smart"
fi
if [[ "$bay" =~ ^[[:digit:]]+$ ]] ; then
    show_bay "$bay"
fi
if [ "$smart" != "absent" ]; then
    echo "To illuminate the drive bay,"
    echo "run '/usr/local/sbin/ceph_drive_led.sh $disk' on $target"
else
    echo "To illuminate the not-failed drive bays,"
    echo "run '/usr/local/sbin/ceph_drive_led.sh' on $target"
fi
echo -e "\nRemoving OSD $osd from cluster"
ceph osd out "osd.$osd"
echo "Waiting for OSD $osd to be safe to destroy (takes a long time!)"
while ! ceph osd safe-to-destroy "osd.$osd" 2>/dev/null ; do
    sleep 60
    echo -n "."
done
echo
ceph osd purge "$osd" --yes-i-really-mean-it
echo "All done, safe to replace drive"
