#!/usr/bin/perl -w

use warnings;
use strict;
use autodie;

use Getopt::Long;

# id_remap - a script to record UIDs and GIDs in a given range before a
# change to their numbering and reassign the contents of a directory path
# to the correct usernames and group names afterward.

# Written by Paul Wayper for Red Hat in August 2015.

#  This program is free software; you can redistribute it and/or modify
#  it under the terms of the GNU General Public License as published by
#  the Free Software Foundation; either version 2 of the License, or
#  (at your option) any later version.
#  
#  This program is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU General Public License for more details.
#  
#  You should have received a copy of the GNU General Public License
#  along with this program; if not, write to the Free Software
#  Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston,
#  MA 02110-1301, USA.
#  

my %modes = map { $_ => 1 } qw{ before after };
my $mode = 'before';
my $mapfile = 'mapfile.txt';
my ($start_id, $end_id);
my ($start_uid, $end_uid);
my ($start_gid, $end_gid);
my $base_path;
my $dry_run = 0;
my $verbose = 0;

GetOptions(
	'mode|m=s'			=> \$mode,
	'file|f=s'			=> \$mapfile,
	'start-id|s=i'		=> \$start_id,
	'end-id|e=i'		=> \$end_id,
	'start-uid|su=i'	=> \$start_uid,
	'end-uid|eu=i'		=> \$end_uid,
	'start-gid|sg=i'	=> \$start_gid,
	'end-gid|eg=i'		=> \$end_gid,
	'base-path|p=s'		=> \$base_path,
	'dry-run|n'			=> \$dry_run,
	'verbose|v'			=> \$verbose,
);

unless (exists $modes{$mode}) {
	die "Error: mode must be one of: ", join(', ', reverse sort keys %modes), ".\n";
}
if ($mode eq 'before') {
	# Check before mode options
	if (defined $start_id and not defined $start_uid and not defined $start_gid) {
		$start_uid = $start_id;
		$start_gid = $start_id;
	}
	if (defined $end_id and not defined $end_uid and not defined $end_gid) {
		$end_uid = $end_id;
		$end_gid = $end_id;
	}
	unless (defined $start_uid) {
		die "Error: start UID must be set by -start-uid or -su (or -start-id | -s)\n";
	}
	unless (defined $end_uid) {
		die "Error: end UID must be set by -end-id or -eu (or -end-id | -e)\n";
	}
	unless (defined $start_gid) {
		die "Error: start GID must be set by -start-gid or -sg (or -start-id | -s)\n";
	}
	unless (defined $end_gid) {
		die "Error: end GID must be set by -end-gid or -eg (or -end-id | -e)\n";
	}
} elsif ($mode eq 'after') {
	unless (defined $base_path) {
		die "Error: base path must be set by -base-path or -p\n";
	}
}
if ($verbose) {
	$| = 1; # Flush stdout after every write
}

sub before {
	# Iterate through every ID in the range looking for valid IDs.  Remember
	# their username in the file;
	open my $fh, '>', $mapfile;
	# scan users:
	foreach my $uid ($start_uid .. $end_uid) {
		print "\rChecking user $uid..."
		 if $verbose;
		my $name = getpwuid($uid);
		if (defined $name) {
			print $fh "users:$uid:$name\n";
		}
	}
	# scan groups:
	foreach my $gid ($start_gid .. $end_gid) {
		print "\rChecking group $gid..."
		 if $verbose;
		my $name = getgrgid($gid);
		if (defined $name) {
			print $fh "groups:$gid:$name\n";
		}
	}
	close $fh;
	print "\n" if $verbose;
}

sub after {
	# Read through the list of IDs and usernames in the file.  Issue a find
	# and chown/chgrp by name for each user or group that has changed ID.
	open my $fh, '<', $mapfile;
	while (<$fh>) {
		chomp;
		my ($type, $id, $name) = split m{:};
		if      ($type eq 'users') {
			# Check uid of name
			my $newuid = getpwnam($name);
			if (not defined $newuid) {
				warn "Warning: user $name does not have an id now (old ID = $id).\n";
			} elsif ($newuid == $id) {
				print "Note: user $name has id $id before and after.\n"
				 if $verbose;
			} else {
				if ($dry_run) {
					print "Note: would have chown'ed files for $name from old id $id to new id $newuid\n";
				} else {
					my $command = "find '$base_path' -uid $id -print0 | xargs -0r chown $name";
					print "Running: $command\n"
					 if $verbose;
					system ($command);
				}
			}
		} elsif ($type eq 'groups') {
			# Check gid of name
			my $newgid = getgrnam($name);
			if (not defined $newgid) {
				warn "Warning: group $name does not have an id now (old ID = $id).\n";
			} elsif ($newgid == $id) {
				print "Note: group $name has id $id before and after.\n"
				 if $verbose;
			} else {
				if ($dry_run) {
					print "Note: would have chgrp'ed files for $name from old id $id to new id $newgid\n";
				} else {
					my $command = "find '$base_path' -gid $id -print0 | xargs -0r chgrp $name";
					print "Running: $command\n"
					 if $verbose;
					system ($command);
				}
			}
		} else {
			warn "Warning: unrecognised line '$_' in map file.\n";
		}
	}
	close $fh;
}

if ($mode eq 'before') {
	before();
} elsif ($mode eq 'after') {
	after();
}
