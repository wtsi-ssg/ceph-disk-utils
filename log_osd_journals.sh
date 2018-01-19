#!/bin/bash -e

# Script to log osd -> journal mappings and drive serial numbers.
# Most usefully run from cron.
#
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

set -o pipefail

# turn off a status light; this has the effect of turning them all off
# ledctl is chatty and always returns 0 :-(
ledctl off=/dev/sda 2>/dev/null

for osd in $( systemctl --no-pager --no-legend --state=running -t service list-units 'ceph-osd*' | sed -e 's/^[^@]*@\([0-9]*\)\..*$/\1/' ) ; do
	   
    echo -n "osd ${osd} has journal on "
    readlink -f "/var/lib/ceph/osd/ceph-${osd}/journal"

    if part=$(findmnt -n -o SOURCE "/var/lib/ceph/osd/ceph-${osd}") ; then
	echo -n "osd ${osd} is on partition ${part}, drive serial "
	/usr/sbin/smartctl -i "${part}" | sed -ne '/Serial/s/^.*: *//p'
    fi

done | logger -t osdtojour -ep daemon.info
