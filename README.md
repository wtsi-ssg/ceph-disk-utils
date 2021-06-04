# ceph-disk-utils
Shell utilities for managing disks within ceph clusters

These are scripts developed at the Wellcome Sanger Institute to handle
drive failures within our ceph storage nodes. The aim is to make it
easier to have failed drives handled by people who aren't ceph
experts. There are currently five scripts:

1. `ceph_failed_osd.sh` - pass this the id of a ceph osd with a failed
disk, and it will guide you as to which drive needs
replacing. Currently assumes you're using 4U Supermicro storage nodes,
but could be adapted to other systems.

2. `ceph_manage_failed_osd.sh` - a more intrusive version of the
previous, which does all the pre-removal work, leaving the failed
drive in a state where it is ready to be replaced.

3. `ceph_remove_failed_osd.sh` - script called (on an OSD host) from
the previous script (from a MON/MGR via ssh).

4. `log_osd_journals.sh` - run this out of cron to log which journal
device each OSD is using, and the serial number of each drive. The
previous script can use the log entries from this script to help in
the case that a disk has failed such that it is no longer reachable by
the OS.

5. `log_osd_journals.sh` - utility script to light up the failed light
on a particular disk (or, alternatively, all the available lights,
leaving only those on disk unavailable to the OS unlit).

Our storage nodes are Supermicro 4U servers, and these scripts make
certain assumptions about drive layout that won't be true for other
devices. These scripts understand ceph-disk and ceph-volume created
OSDs (and have been tested with Jewel, Luminous, and Octopus).
