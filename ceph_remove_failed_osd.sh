#!/bin/bash -e
#Script to remove a failing OSD. Expected to be called by
#ceph_manage_failed_osd.sh

#On success, exits 0 and emits JSON with necessary details for swapping
#Exits non-zero on failure (and outputs details about the failed OSD)

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

if [ "$#" -ne 1 ]; then
    echo "Usage: ceph_remove_failed_osd.sh osd_id"
    exit 1
fi
osd=$1

#Sanity-check drive layout
if [ $(lsscsi | grep -cE '\[0:0:((30)|(61)):0\]   enclosu') != "2" ] ; then
    echo -e "XXX WARNING XXX\nXXX LUN ARRANGEMENT SUSPECT XXX"
    echo "XXX DRIVE LOCATION IMPOSSIBLE TO PREDICT XXX"
    echo "XXX PLEASE REPORT TO ssg-isg@sanger.ac.uk XXX"
    echo "XXX DO NOT ATTEMPT TO HOT-SWAP DRIVE XXX"
    exit 1
fi

# Check we can find the mount point for this osd
set +e
part=$(findmnt -n -o SOURCE "/var/lib/ceph/osd/ceph-${osd}")
if [ $? -ne 0 ] ; then
    echo "Unable to locate mount point for osd ${osd}"
    exit 1
fi
# -E makes any trap on ERR apply to shell functions, command
# substitutions, subshells
set -eE

# Script is silent in normal operation; if we fail for some reason,
# output what we've found about the failed OSD. Each command must succeed
# as we're in set -e, hence the slightly odd idiom
# A trap on ERR, if set, is executed before the shell exits, so no exit
# call is needed here.
barf()
{
    [ -z "$disk" ]   || echo "disk: $disk"
    [ -z "$serial" ] || echo "$serial"
    [ -z "$smart" ]  || echo "SMART status: $smart"
    [ -z "$nvme" ]   || echo "block.db on $nvme"
    [ -z "$bay" ]    || echo "bay: $bay"
}
trap barf ERR

#$part is tmpfs if this is a ceph-volume lvm setup
if [ "$part" = "tmpfs" ] ; then
    disk=$(pvs --noheadings -o pv_name -S lv_path=$(readlink -n "/var/lib/ceph/osd/ceph-${osd}/block") | sed -e 's/ //g')
else
    # strip all trailing digits
    shopt -s extglob
    disk="${part%%+([0-9])}"
fi
bnd=$(basename "$disk")

find_missing_disk_bay()
{
    # Finding the LUN is a bit tricker - the failed drive is no longer
    # in lsscsi output. But, we know which luns should be there (that
    # are the disks) - [0:0:0:0]-[0:0:29:0] and [0:0:31:0]-[0:0:60:0] -
    # 30 and 61 are the enclosures.

    # So, we can construct a list of the LUNs that should be present,
    # and use "join" to match it with the LUNs that are actually
    # present (from lsscsi output, filtered to only tell us about
    # disks); we then use the -v 1 argument to join to tell us only
    # about the record in the first list that couldn't be matched -
    # which is the LUN corresponding to the missing disk.

    # Each join argument is a redirection from a subshell, so the
    # command is of the form:
    #  join -v 1 <(sorted LUN list) <(sorted lsscsi output)
    # we then extract the LUN from the output, which is of the form
    # [0:0:LUN:0] hence the final sed.

    # A slight wrinkle is that both lists need to be sorted
    # alphabetically rather than numerically for join, hence the sort
    # at the end of each subshelled pipeline.

    # NB, this command is one logical line, using line continuation
    lun=$(join -v 1 \
	<( for i in $(seq 0 29 ; seq 31 60);
	    do echo "[0:0:${i}:0]"; done | sort -k 1b,1) \
	<( lsscsi | sed -ne '/\[0.*disk.*/s/ .*$//p' | sort -k 1b,1) \
    | sed -e 's/\[0:0:\([0-9]*\):0\]/\1/')

    # check for multiple matches (by string length)
    if [ "${#lun}" -gt 2 ]; then
	echo "multiple bays"
    elif [ "${#lun}" -eq 0 ] ; then
	echo "bay not found"
    else
	if [ "$lun" -gt 30 ]; then
	    bay=$(($lun - 1))
	else
	    bay="$lun"
	fi
	echo "$bay"
    fi
}

# /usr/local/sbin/log_osd_journals.sh logs which journal partition is used
# by each osd nightly; use that to find the journal partition
find_logged_journal()
{
    if [ "$#" -ne 1 ] ; then
	echo "Internal Error: find_logged_journal requires a single argument"
	return 1
    fi
    zcat -f /var/log/syslo* | sed -ne "/osdtojour: osd ${1} has/s/^.* on \(.*\)\$/\1/p" | head -n 1
}

# It also logs the serial number of each drive
find_logged_serial()
{
    if [ "$#" -ne 1 ] ; then
	echo "Internal Error: find_logged_serial requires a single argument"
	return 1
    fi
    zcat -f /var/log/syslo* | sed -ne "/osdtojour: osd ${1} is/s/^.*serial \(.*\)/serial number \1/p" | head -n 1
}

#If the device node exists, try and extract the data we need from it
if [ -b "$disk" ]; then
    #SMART status
    if smartctl -Hq silent "$disk"; then
	smart="healthy"
	#zgrep -qE [thing] /var/log/kern.* only returns 0 if every file matches
	if ! zcat -f /var/log/kern.lo* | grep -qE "(\[${bnd}\])|(dev ${bnd},)" ; then
	    echo "Drive healthy and no mentions in kernel log"
	    echo "Assuming this isn't a disk issue"
	    exit 1
	fi
    else
	smart=$(smartctl -Hq errorsonly "$disk") || true
    fi
    #Serial number
    serial=$(smartctl -i "$disk" | grep Serial || find_logged_serial "${osd}")

    #Drive bay
    lun=$(lsscsi | sed -nre "/\/dev\/$bnd ?\$/s/\[0:0:([0-9]+):0].*\$/\1/p")
    # If LUN is over 60, this is a false value caused by the disk having been
    # unplugged and replugged; so instead look in lsscsi output to infer
    # which the faulty drive is
    if [ "$lun" -gt 60 ] ; then
	bay=$(find_missing_disk_bay)
    elif [ "$lun" -gt 30 ]; then
	bay=$(($lun - 1))
    else
	bay="$lun"
    fi

    #journal/block.db location (i.e. which is the relevant NVME partition)
    if readlink -e "/var/lib/ceph/osd/ceph-${osd}/journal" >/dev/null ; then
	nvme=$(readlink -e "/var/lib/ceph/osd/ceph-${osd}/journal")
    elif readlink -e "/var/lib/ceph/osd/ceph-${osd}/block.db" >/dev/null ; then
	nvme=$(readlink -e "/var/lib/ceph/osd/ceph-${osd}/block.db")
    else
	nvme=$(find_logged_journal "${osd}")
    fi

else #device node doesn't exist
    smart="absent"
    serial=$(find_logged_serial "${osd}")
    nvme=$(find_logged_journal "${osd}")
    bay=$(find_missing_disk_bay)
fi

#Now stop the OSD, umount the filesystem
systemctl -q stop ceph-osd@${osd}.service
systemctl -q disable ceph-osd@${osd}.service
umount -l /var/lib/ceph/osd/ceph-${osd}

#Finally, emit a JSON object
#18.04 and later has "jo" which does this more concisely

jq --arg disk "$disk" \
   --arg bay "$bay" \
   --arg serial "$serial" \
   --arg nvme "$nvme" \
   --arg smart "$smart" \
   '.["disk"]=$disk|.["bay"]=$bay|.["serial"]=$serial|.["nvme"]=$nvme|.["smart"]=$smart' <<< '{}'
