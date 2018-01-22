#!/bin/bash -e
# Script to query the status of a disk underlying a failed OSD, and
# tell you what to do about replacing it.
# To work out which host an OSD is on, use:
# ceph osd find X | grep host
# Needs to be run as root

# More details of the OSD replacement process on confluence:
# https://ssg-confluence.internal.sanger.ac.uk/display/ISG/Recovering+from+a+failed+OSD+disk

# Copyright (C) 2018 Genome Research Limited
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

usage() 
{
    echo "Usage: ceph_failed_osd.sh osd_id"
    if [ "$1" ]; then exit "$1"; else exit 0; fi
}

[ "$#" -eq 1 ] || usage 1
osd="$1"
[ "$osd" ] || usage 1

# Check we can find the mount pount for this osd
set +e
part=$(findmnt -n -o SOURCE "/var/lib/ceph/osd/ceph-${osd}")
if [ $? -ne 0 ] ; then
    echo "Unable to locate mount point for osd ${osd}"
    exit 1
fi
set -e

# strip all trailing digits
shopt -s extglob
disk="${part%%+([0-9])}"
bnd=$(basename "$disk")

# /usr/local/sbin/log_osd_journals.sh logs which journal partition is used
# by each osd nightly; use that to find the journal partition
find_logged_journal()
{
    if [ "$#" -ne 1 ] ; then
	echo "Internal Error: find_logged_journal requires a single argument"
	return 1
    fi
    echo -n "According to syslog, the journal is on "
    zcat -f /var/log/syslo* | sed -ne "/osdtojour: osd ${1} has/s/^.* on \(.*\)\$/\1/p" | head -n 1
}

# It also logs the serial number of each drive
find_logged_serial()
{
    if [ "$#" -ne 1 ] ; then
	echo "Internal Error: find_logged_serial requires a single argument"
	return 1
    fi
    echo -n "According to syslog, the drive serial number is "
    zcat -f /var/log/syslo* | sed -ne "/osdtojour: osd ${1} is/s/^.*serial \(.*\)/\1/p" | head -n 1
}

# We want the most recent kern.log entries relating to the drive; so
# arrange to grep the logs in order (oldest first) and take the last 5
# entries. It would be nicer to use find -print0 here, but find doesn't
# do the sorting we want.
# Similarly, it would be nice to just go zgrep -qE [pattern] /var/log/kern.*
# rather than zcat -f | grep -q, but zgrep -q is buggy and only returns
# success if *every* file matches
# cf https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=834975
# This function takes a single argument, and returns 1 (i.e. failure)
# if no matchs are found
find_disk_in_kern_logs()
{
    if [ "$#" -ne 1 ] ; then
	echo "Internal Error: find_disk_in_kern_logs requires a single argument"
	return 1
    fi
    if zcat -f /var/log/kern.lo* | grep -qE "(\[${1}\])|(dev ${1},)" ; then
	echo "Most recent kern.log entries:"
	ls -rt /var/log/kern* | xargs zgrep -E "(\[${1}\])|(dev ${1},)" | tail -5
    else
	return 1
    fi
}

# Work out which disk is the "missing" one (see comment in function for
# how this works)
# If you want the serial number of the drive extracted from logs and output
# then pass the osd ID as a single argument. This only happens if only 1
# drive appears to have failed.

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
	<( for i in $(seq 29 ; seq 31 60);
	    do echo "[0:0:${i}:0]"; done | sort -k 1b,1) \
	<( lsscsi | sed -ne '/\[0.*disk.*/s/ .*$//p' | sort -k 1b,1) \
    | sed -e 's/\[0:0:\([0-9]*\):0\]/\1/')

    # check for multiple matches (by string length)
    if [ "${#lun}" -gt 2 ]; then
	echo "There appear to be multiple failed drives."
	echo "These correspond to the following luns:"
	echo "$lun"
    else
	if [ "$lun" -gt 30 ]; then
	    bay=$(($lun - 1))
	else
	    bay="$lun"
	fi

	echo "Drive is LUN ${lun}, corresponding to bay $bay"
	if [ "$#" -eq 1 ] ; then
	    find_logged_serial "${1}"
	fi
    fi
}

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
    echo -e "Bay ${1} is located as follows:\n      BACK"
    for row in 45 30 15 0 ;
    do for i in $(seq 0 14) ;
	do if [ "$(( row + i ))" -eq "$1" ] ; then
		echo -n "X"
	    else echo -n "O"
	    fi
	    if [ "$i" -eq 6 -o "$i" -eq 12 ] ; then
		echo -n "|"
	    fi
	done
	echo # emit newline at end of row
    done
    echo "      FRONT"
}

echo "OSD $osd is on partition $part on disk $disk"

if [ -b "$disk" ]; then
    if smartctl -Hq silent "$disk"; then
	echo "drive $disk healthy according to SMART"
	if ! find_disk_in_kern_logs "$bnd" ; then
	    echo "No entries relating to $disk in kernel log either"
	    echo "Assuming this isn't a disk issue; quitting"
	    exit 1
	fi
    else
	echo "SMART status for $disk:"
	smartctl -Hq errorsonly "$disk" || true
    fi

    lun=$(lsscsi | sed -nre "/\/dev\/$bnd ?\$/s/\[0:0:([0-9]+):0].*\$/\1/p")
    if [ "$lun" -gt 30 ]; then
	bay=$(($lun - 1))
    else
	bay="$lun"
    fi

    echo -e "\nIf replacing drive ${disk}, note the following:"
    smartctl -i "$disk" | grep Serial || find_logged_serial "${osd}"
    # If LUN is over 60, this is a false value caused by the disk having been
    # unplugged and replugged; so instead look in lsscsi output to infer
    # which the faulty drive is
    if [ "$lun" -gt 60 ] ; then
	find_missing_disk_bay
    else
	echo "Drive is LUN ${lun}, corresponding to bay $bay"
    fi
    if ledctl "failure=${disk}" 2>/dev/null ; then
	echo "The red failure light should be illuminated on the drive bay."
    fi
    if readlink -e "/var/lib/ceph/osd/ceph-${osd}/journal" >/dev/null ; then
	echo -n "Journal is to be found on "
	readlink -e "/var/lib/ceph/osd/ceph-${osd}/journal"
    else
	find_logged_journal "${osd}"
    fi

else # block device $disk absent

    echo "Block device $disk absent, assume the drive has failed."
    if ! find_disk_in_kern_logs "$bnd" ; then
	echo "No recent kern.log activity, though, which is odd..."
    fi

    echo -e "\n If replacing drive ${disk}, note the following:"
    # /usr/local/sbin/log_osd_journals.sh logs which journal partition is used
    # by each osd nightly; use that to find the journal partition since we
    # can't inspect the osd directory because the drive is absent
    find_logged_journal "${osd}"

    # Work out which bay contains the failed disk; also output the relevant
    # serial number, extracted from syslog
    find_missing_disk_bay "${osd}"

fi # end of conditional for presence/absence of block device $disk

if [ $(lsscsi | grep -cE '\[0:0:((30)|(61)):0\]   enclosu') != "2" ] ; then
    echo -e "XXX WARNING XXX\nXXX LUN ARRANGEMENT SUSPECT XXX"
    echo "XXX DRIVE LOCATION IMPOSSIBLE TO PREDICT XXX"
    echo "XXX PLEASE REPORT TO ssg-isg@sanger.ac.uk XXX"
    echo "XXX DO NOT ATTEMPT TO HOT-SWAP DRIVE XXX"
    unset bay
fi

if [ -n "$bay" ] ;
    then show_bay "$bay"
fi

echo -e "\nThe following commands WHICH ARE IRREVERSIBLE remove this osd
and should be run on one of the ceph mon nodes, e.g. sto-1-1
ceph osd out osd.$osd
ceph osd crush remove osd.$osd
ceph auth del osd.$osd"

echo ""
echo "If hot-swapping this disk, on the affected host, you will then need to:"
echo "systemctl stop ceph-osd@${osd}.service"
echo "umount /var/lib/ceph/osd/ceph-${osd}"

echo -e "\nFinally, on one of the ceph mon nodes, e.g. sto-1-1
ceph osd rm osd.$osd
before physically removing the disk."
