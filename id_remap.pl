#!/usr/bin/perl -w

use warnings;
use strict;
use autodie;

use File::Find;
use Getopt::Long;

# id_remap - a script to record UIDs and GIDs in a given range before a
# change to their numbering and reassign the contents of a directory path
# to the correct usernames and group names afterward.

# Written by Paul Wayper for Red Hat in August 2015.
# vim: set ts=4 ai :

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

sub pluralise {
	my ($number, $singular, $plural, $no_number) = @_;
	$plural = $singular . 's' if not $plural;
	my $desc = abs($number) != 1 ? $plural : $singular;
	if ($no_number) {
		return $desc;
	} else {
		return "$number $desc";
	}
}

sub time_stats {
	my ($before, $after, $ops, $opname) = @_;
	my $diff = $after - $before;
	my @int_names = qw{ second minute hour day };
	my @intervals = ( 60, 60, 24 );
	my $interval = 0;
	my $time_desc = '';
	do {
		if ($time_desc ne '') {
			$time_desc = ', ' . $time_desc;
		}
		$time_desc = pluralise($diff % $intervals[$interval], $int_names[$interval])
		 . $time_desc;
		$diff /= $intervals[$interval];
		$interval++;
	} while ($diff > $intervals[$interval]);
	printf "%s took %s, %.2f %s/sec\n", 
	 pluralise($ops, $opname), $time_desc, 
	 $diff/$ops, pluralise(int($diff/$ops), $opname, "$opname", "no number");
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
	# Read through the list of IDs and usernames in the file, remembering
	# those things that have changed ID.
	open my $fh, '<', $mapfile;
	my %user_remap_to;
	my %group_remap_to;
	
	my $start_time = time;
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
				$user_remap_to{$id} = $newuid;
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
				$group_remap_to{$id} = $newgid;
				}
			}
		} else {
			warn "Warning: unrecognised line '$_' in map file.\n";
		}
	}
	my $end_time = time;
	close $fh;
	my $user_remap_count = scalar keys %user_remap_to;
	my $group_remap_count = scalar keys %group_remap_to;
	print pluralise($user_remap_count, 'user'), " and ",
	      pluralise($group_remap_count, 'group'), " to convert.\n";
	time_stats($start_time, $end_time, $user_remap_count + $group_remap_count, 'id');
	print "Ready to search file system from '$base_path'...\n";
	
	# Now search the file system changing the owner and group of each object
	# that has changed.
	my $entities_checked = 0;
	my $entities_changed = 0;
	my $check_id_sub = sub {
		# Remember, we're now in $File::Find::dir, so stat and chown on $_
		my ($fuid, $fgid) = (stat($_))[4,5];
		$entities_checked++;
		unless (defined $fuid and defined $fgid) {
			warn "Warning: file '$File::Find::name' stat failed - maybe file is missing?\n";
			return;
		}
		return unless exists $user_remap_to{$fuid} or exists $group_remap_to{$fgid};
		my $newfuid = $user_remap_to{$fuid} || $fuid; 
		my $newfgid = $group_remap_to{$fgid} || $fgid;
		if ($dry_run) {
			print "Would have changed '$File::Find::name' to ($newfuid, $newfgid)\n";
		} else {
			print "Changing '$File::Find::name' to ($newfuid, $newfgid)\n"
			 if $verbose;
			# Optimise here: Perl's chown takes an array of files.  Batch
			# arguments up per directory?
			chown $newfuid, $newfgid, $_;
			$entities_changed++;
		}
	};
	
	$start_time = time;
	find($check_id_sub, $base_path);
	$end_time = time;
	print pluralise($entities_checked, 'file system object'), " checked, ",
		  pluralise($entities_changed, 'file system object'), " changed.\n";
	time_stats($start_time, $end_time, $entities_checked, 'check');
}

if ($mode eq 'before') {
	before();
} elsif ($mode eq 'after') {
	after();
}
