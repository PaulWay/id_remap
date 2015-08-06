#!/usr/bin/perl -w

use warnings;
use strict;
use autodie;

use Getopt::Long;

my %modes = map { $_ => 1 } qw{ before after };
my $mode = 'before';
my $mapfile = 'mapfile.txt';
my ($start_uid, $end_uid);
my ($start_gid, $end_gid);
my $base_path;
my $dry_run = 0;
my $verbose = 0;

GetOptions(
	'mode|m=s'			=> \$mode,
	'file|f=s'			=> \$mapfile,
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
	unless (defined $start_uid) {
		die "Error: start UID must be set by -start-uid or -su\n";
	}
	unless (defined $end_uid) {
		die "Error: end UID must be set by -end-id or -eu\n";
	}
	unless (defined $start_gid) {
		die "Error: start GID must be set by -start-gid or -sg\n";
	}
	unless (defined $end_gid) {
		die "Error: end GID must be set by -end-gid or -eg\n";
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
				print "Note: user $name has id $id before and after.\n";
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
				print "Note: group $name has id $id before and after.\n";
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
