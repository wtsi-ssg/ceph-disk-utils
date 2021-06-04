#!/bin/bash -e
# Script to light up the failure LED on a drive.
# Alternatively, to light up the LEDs on all the drives we can find
# - so leaving any failed drives that are missing from /dev unlit

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

usage()
{
    echo "Usage: ceph_drive_led.sh [device]"
    if [ "$1" ]; then exit "$1"; else exit 0; fi
}

# Try and light up all the drives we *do* have a device entry for (looking for
# host 0 and 12, since that's what the drives are on in our main and UKB
# ceph nodes )
light_all()
{
    if ledctl $( lsscsi | perl -ne 'next unless m{^\[(0|12):}; next unless m{ (/dev/\S+)}; push @o, $1; END { print "failure={ @o }" }' ) 2>/dev/null ; then
	echo "Every red light *except* on the failed drive(s) should be lit!"
    else
	echo "Attempting to light up the non-faulty drives failed"
    fi
}

light_single()
{
    if [ "$#" -ne 1 ]; then
	echo "Internal Error: light_single requires a single argument"
	exit 1
    fi
    if ledctl "failure=$1" 2>/dev/null ; then
	echo "The red failure light should be illuminated on the $1 drive bay."
    else
	echo "Failed to light up $1 drive bay."
    fi
}

if [ "$#" -eq 0 ]; then
    light_all
elif [ "$#" -eq 1 ]; then
    if [ -b "$1" ]; then
	light_single "$1"
    elif [ ! -e "$1" ]; then
	echo "Device $1 missing, will try to light up all the other drives"
	light_all
    else echo "Error: $1 exists but isn't a block device"
	 exit 1
    fi
else usage 1
fi
