#!/usr/bin/perl -w
# vim: set ts=4 ai :

use warnings;
use strict;
use autodie;

use File::Find;
use Getopt::Long;

# id_remap - a script to record UIDs and GIDs in a given range before a
# change to their numbering and reassign the contents of a directory path
# to the correct usernames and group names afterward.

# Written by Paul Wayper.  His employer doesn't have anything to do with it.
# No warranty expressed or implied.  Dry run and testing is your friend.

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

my $mode = 'scan';
my $scanfile = 'id_scan.txt';
my $mapfile = 'id_map.txt';
my ($start_id, $end_id);
my ($start_uid, $end_uid);
my ($start_gid, $end_gid);
my $base_path;
my $reverse = 0;
my $dry_run = 0;
my $verbose = 0;
my $help = 0;

GetOptions(
	'mode|m=s'			=> \$mode,
	'scan-file|sf=s'	=> \$scanfile,
	'map-file|mf=s'		=> \$mapfile,
	'start-id|s=i'		=> \$start_id,
	'end-id|e=i'		=> \$end_id,
	'start-uid|su=i'	=> \$start_uid,
	'end-uid|eu=i'		=> \$end_uid,
	'start-gid|sg=i'	=> \$start_gid,
	'end-gid|eg=i'		=> \$end_gid,
	'base-path|p=s'		=> \$base_path,
	'reverse|rollback|r' => \$reverse,
	'dry-run|n'			=> \$dry_run,
	'verbose|v'			=> \$verbose,
	'help|h'			=> \$help,
);

if ($help) {
	print "$0 - support bulk changes in UID / GID and update file system to suit.
Usage: $0 -mode (scan|map|file|after) ...
Options:
 -m(ode) scan|map|file|after	- mode to run in - see below.
 -scan-file|sf [id_scan.txt]	- file for ID scan results.
 -map-file|mf [id_map.txt]		- file for ID map results.
 -s(tart-id) (number)			- scan range start UID and GID.
 -e(nd-id) (number)				- scan range end UID and GID.
 -start-uid|su (number)			- scan range start UID.
 -end-uid|eu (number)			- scan range end UID.
 -start-gid|sg (number)			- scan range start GID.
 -end-gid|eg (number)			- scan range end GID.
 -base-path|p (path)			- path to scan for ID changes.
 -r(everse|rollback)			- reverse ID mapping in file changes.
 -d(ry-run)						- do not make changes to file system.
 -v(erbose)						- print extra timing and progress information.
 -h(elp)						- this help.
In 'scan' mode, scan the given ID ranges and remember the name for each ID.
In 'map' mode, read the scanned ranges and determine new ID for each change.
In 'file' mode, read map and change file system entities to new IDs if reqd.
'after' mode does 'map' and 'file' but writes no map file.
Normally, 1) scan, 2) change ID scheme, 3) map, 4) file.
Map file should remain constant across machines (saves processing time).
";
	exit 0;
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

sub time_desc {
	my ($diff) = @_;
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
	return $time_desc;
}

sub time_stats {
	# Time statistics while in a loop
	my ($before, $now, $op_num, $ops, $opname) = @_;
	my $diff = $now - $before;
	printf "\r%i/%i %s, %.2f %s/sec, completion in %s",
	 $op_num, $ops, pluralise($ops, $opname),
	 $diff/$ops, pluralise(int($diff/$ops), $opname, $opname, "no number"),
	 time_desc($diff);
}

sub completion_stats {
	# Time statistics for completion of loop
	my ($before, $after, $ops, $opname) = @_;
	my $diff = $after - $before;
	my $opspersec = ($diff < 0.0001) ? $ops : $ops / $diff;
	printf "%s took %s, %.2f %s/sec\n", 
	 pluralise($ops, $opname), time_desc($diff),
	 $opspersec, pluralise(int($opspersec), $opname, $opname, "no number");
}

sub scanner {
	# Iterate through every ID in the range looking for valid IDs.  Remember
	# their user name / group name in the file.  This happens before the
	# change to the IDs.
	if (-f $scanfile) {
		warn "Warning: Overwriting scan file '$scanfile'.\n";
	}
	open my $fh, '>', $scanfile unless $dry_run;

	# scan users:
	my $users_checked = 0; my $users_to_check = $end_uid - $start_uid + 1;
	my $users_found = 0;
	my $start_time = time;
	foreach my $uid ($start_uid .. $end_uid) {
		my $name = getpwuid($uid);
		$users_checked ++;
		if (defined $name) {
			print $fh "users:$uid:$name\n" unless $dry_run;
			$users_found ++;
		}
		if ($verbose) {
			time_stats($start_time, time, $users_checked, $users_to_check, 'user');
		}
	}
	my $end_time = time;
	completion_stats($start_time, $end_time, $users_found, 'user');

	# scan groups:
	my $groups_checked = 0; my $groups_to_check = $end_gid - $start_gid + 1;
	my $groups_found = 0;
	$start_time = time;
	foreach my $gid ($start_gid .. $end_gid) {
		$groups_checked ++;
		my $name = getgrgid($gid);
		if (defined $name) {
			print $fh "groups:$gid:$name\n" unless $dry_run;
			$groups_found ++;
		}
		if ($verbose) {
			time_stats($start_time, time, $groups_checked, $groups_to_check, 'group');
		}
	}
	$end_time = time;
	completion_stats($start_time, $end_time, $groups_found, 'group');

	close $fh unless $dry_run;
}

sub mapper {
	my ($no_map_file) = @_;
	# Read through the list of IDs and names in the file, and work out the
	# mapping to the new ID.
	open my $fh, '<', $scanfile;
	my @lines;
	while (<$fh>) {
		chomp; tr{\r}{}d;
		push @lines, $_
	}
	close $fh;
	my $line_count = scalar @lines;

	my %user_remap_to;
	my %group_remap_to;

	my $start_time = time;
	my $line_no = 0;
	for (@lines) {
		$line_no ++;
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
				$user_remap_to{$id} = { 'id' => $newuid, 'name' => $name };
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
				$group_remap_to{$id} = { 'id' => $newgid, 'name' => $name };
				}
			}
		} else {
			warn "Warning: unrecognised line '$_' in map file.\n";
		}
		if ($verbose) {
			time_stats($start_time, time, $line_no, $line_count, 'ID');
		}
	}

	my $end_time = time;
	completion_stats($start_time, $end_time, $line_count, 'ID');

	# Now write the mapping file if required
	unless ($no_map_file or $dry_run) {
		if (-f $mapfile) {
			warn "Warning: overwriting '$mapfile'\n";
		}
		print "Writing map file '$mapfile'..." if $verbose;
		open my $ofh, '>', $mapfile;
		# Note that we only write the users and groups that we've found to
		# differ in ID.  Therefore, the map file may not contain the same
		# number of lines as the scan file.
		foreach my $old_uid (sort {$a <=> $b} keys %user_remap_to) {
			print $ofh "users:$old_uid:$user_remap_to{$old_uid}{name}:$user_remap_to{$old_uid}{id}\n";
		}
		foreach my $old_gid (sort {$a <=> $b} keys %group_remap_to) {
			print $ofh "groups:$old_gid:$group_remap_to{$old_gid}{name}:$group_remap_to{$old_gid}{id}\n";
		}
		close $ofh;
		print "done.\n" if $verbose;
	}

	# Give the caller the chance to remember the user and group remappings
	return \%user_remap_to, \%group_remap_to;
}

sub filer {
	my ($no_map_file, $user_remap_href, $group_remap_href) = @_;
	my %user_remap_to;
	my %group_remap_to;
	if ($no_map_file) {
		# Get the mappings from the previous mapping process.
		%user_remap_to = %$user_remap_href;
		%group_remap_to = %$group_remap_href;
	} else {
		# Load the mapping from old IDs to new IDs.
		open my $fh, '<', $mapfile;
		while (<$fh>) {
			chomp; tr{\r}{}d;
			my ($type, $old_id, $name, $new_id) = split m{:};
			# Use the complete form of the hashes for compatibility with the
			# hashrefs from mapper.
			if ($type eq 'users') {
				$user_remap_to{$old_id}  = { 'id' => $new_id, 'name' => $name };
			} elsif ($type eq 'groups') {
				$group_remap_to{$old_id} = { 'id' => $new_id, 'name' => $name };
			} else {
				warn "Warning: unrecognised line '$_' in $mapfile.\n";
			}
		}
		close $fh;
	}

	if ($reverse) {
		print "Reversing mappings for -reverse mode..." if $verbose;
		my %new_user_remap;
		my %new_group_remap;
		# The reversal is complicated since the old user
		while (my ($id, $val) = each %user_remap_to) {
			$new_user_remap{$val->{'id'}} = { 'name' => $val->{'name'}, 'id' => $id };
		}
		while (my ($id, $val) = each %group_remap_to) {
			$new_group_remap{$val->{'id'}} = { 'name' => $val->{'name'}, 'id' => $id };
		}
		%user_remap_to = %new_user_remap;
		%group_remap_to = %new_group_remap;
		print "done\n" if $verbose;
	}

	my $user_remap_count = scalar keys %user_remap_to;
	my $group_remap_count = scalar keys %group_remap_to;
	print pluralise($user_remap_count, 'user'), " and ",
	      pluralise($group_remap_count, 'group'), " to convert.\n";
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
		my $newfuid = exists $user_remap_to{$fuid} ? $user_remap_to{$fuid}{'id'} : $fuid;
		my $newfgid = exists $group_remap_to{$fgid} ? $group_remap_to{$fgid}{'id'} : $fgid;
		die "Will not change UID 0!\n" if $fuid == 0 or $newfuid == 0;
		die "Will not change GID 0!\n" if $fgid == 0 or $newfgid == 0;
		# Assertion - due to previous mapping operation, only different IDs
		# are presented here.
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
	
	my $start_time = time;
	find($check_id_sub, $base_path);
	my $end_time = time;
	print pluralise($entities_checked, 'file system object'), " checked, ",
		  pluralise($entities_changed, 'file system object'), " changed.\n";
	completion_stats($start_time, $end_time, $entities_checked, 'check');
}

sub after {
	my ($u_r_h, $g_r_h) = mapper("no map file");
	filer("no map file", $u_r_h, $g_r_h);
}

my %mode_sub = (
	'scan'	=> \&scanner,
	'map'	=> \&mapper,
	'file'	=> \&filer,
	'after' => \&after,
);

unless (exists $mode_sub{$mode}) {
	die "Error: mode must be one of: ", join(', ', sort keys %mode_sub), ".\n";
}
if ($mode eq 'scan') {
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
	if ($reverse) {
		warn "Warning: -reverse mode has no effect when scanning for IDs.\n";
	}
} elsif ($mode eq 'map' or $mode eq 'after') {
	unless (-r $scanfile) {
		die "Error: cannot read scan file '$scanfile'.\n";
	}
} elsif ($mode eq 'files') {
	unless (defined $base_path) {
		die "Error: base path must be set by -base-path or -p\n";
	}
	unless (-r $mapfile) {
		die "Error: cannot read map file '$mapfile'.\n";
	}
}

if ($verbose) {
	$| = 1; # Flush stdout after every write
}

# Now execute via our hash dispatcher;
&{ $mode_sub{$mode} };
