#!/usr/bin/perl

# Copyright (C) 2012 stepping stone GmbH
#                    Switzerland
#                    http://www.stepping-stone.ch
#                    support@stepping-stone.ch
#
# Authors:
#  Pat Kläy <pat.klaey@stepping-stone.ch>
#  
# Licensed under the EUPL, Version 1.1.
#
# You may not use this work except in compliance with the
# Licence.
# You may obtain a copy of the Licence at:
#
# http://www.osor.eu/eupl
#
# Unless required by applicable law or agreed to in
# writing, software distributed under the Licence is
# distributed on an "AS IS" basis,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either
# express or implied.
# See the Licence for the specific language governing
# permissions and limitations under the Licence.
#

package Provisioning;

################################################################################
##  Start pod2text documentation
################################################################################
=pod

=head1 Name

BackupKVMWrapper.pl

=head1 Usage
 
 BackupKVMWrapper.pl -c option_argument[-d] [-h]

=head1 Description

=head1 Options

=over

=item -c /path/to/your/configuration

The -c option is mandatory and specifies the backend (service) configuration
file.

=cut

use Getopt::Long;
Getopt::Long::Configure("no_auto_abbrev");
use Config::IniFiles;
use Module::Load;
use Sys::Syslog;
use Cwd 'abs_path';
use File::Basename;
use LockFile::Simple qw(lock trylock unlock);
use POSIX;

# Flush the output
$|++;

sub get_lib{

  # to include the current directory as a search path in perl we have to 
  # do it in compile time, so the method gets the current directory and
  # returns it

  my $location=dirname(abs_path($0));
  return $location."/../../lib/";

}

# use the current directory as search path in perl
use lib get_lib();

# Open syslog
openlog("BackupKVMWrapper.pl","ndelay,pid", "local0");

# Write log message that the script was started
syslog("LOG_INFO","Starting Backup-KVM-Wrapper script");

# Get the options
my %opts;
GetOptions (
  \%opts,
  "help|h",             # Displays help text
  "debug|d",            # Enables debug mode
  "list|l:s",           # Comma seperated list or file which contains all machines
  "config|c:s",         # Specifys the configuration file
  "dryrun|r"            # Enables dry run mode
);

# Get the scripts location
my $location = dirname(abs_path($0));

our $debug;
our $opt_d = $debug;

checkCommandLineArguments();

## Read the configuration file: 
our $cfg = new Config::IniFiles( -file => $opts{'config'} );

my $backend = $cfg->val("Database","BACKEND");

our $server_module = "Provisioning::Backend::$backend";
our $TransportAPI = $cfg->val("Service","TRANSPORTAPI");

our $global_cfg = $cfg;
our $syslog_name = $cfg->val("Service","SYSLOG");
our $opt_R = $opts{'dryrun'};

our $gateway_connection = 1;

# Load necessary modules
load "Provisioning::Log", ":all";
load "Provisioning::Backup::KVM", ':all';
load "Provisioning::Backend::$backend", ":all";
load "Provisioning::Backup::KVM::KVMBackup",':all';
load "Provisioning::TransportAPI::$TransportAPI",':all';

# Try to lock the script
my $lock = LockFile::Simple->make( -hold => 0 );
my $lock_file = "/var/run/Provisioning-Backup-KVM-Wrapper";
unless( $lock->trylock( $lock_file ) ){

  logger("warning","$service-Deamon already running (file $lock_file already locked), program exits now");
  exit;

}
else{
  logger("debug","file: $lock_file locked");
}

# Nice look and feel in debug mode
print "\n\n" if ( $debug );

# Connect to the backend
my $backend_connection = connectToBackendServer("connect", 1);

# Test if the connection could be established
unless ( defined($backend_connection) ) 
{
    # Log and exit
    logger("error","Cannot connect to backend, stopping here");
    exit 1;
}

# Generate the array machines list according to the list parameter
my @machines_list = generateMachineList( $opts{'list'} );

# Log which machines are going to be backed up
logger("debug","Backing up the following machines: @machines_list");

# Write the backup date to the server
my $backup_date = strftime("%Y%m%d%H%M%S",localtime());
modifyAttribute( "General",
                 "Backup_date",
                 $backup_date,
                 $backend_connection);

# Backup the machines
backupMachines( @machines_list );
   
logger("info","Backup-KVM-Wrapper script finished");

# Unlock the service
$lock->unlock($lock_file);

closelog();

################################################################################
# checkCommandLineArguments
################################################################################
# Description:
#  Check the command line arguments
################################################################################
sub checkCommandLineArguments 
{
    # Check if the user needs some help
    if ( $opts{'help'} )
    {
        syslog("LOG_INFO","Printing help...");
        exec("pod2text $location/".basename(abs_path($0)));
    }

    # Test if the user wants debug mode
    if ( $opts{'debug'} )
    {
        $debug = 1;
    }

    # Check if we have all necessary parameters i.e. config and list
    unless( $opts{'config'} )
    {
        # Log and exit
        syslog("LOG_ERR","No configuration file specified! You need to pass "
              ."a configuration file with the --config/-c option");
        exit 1;
    }

    unless( $opts{'list'} )
    {
        # Log and exit
        syslog("LOG_ERR","No list specified! You need to pass a list (either "
              ."comma seperated or with file:///path/to/file) with the --list/"
              ."-l option");
        exit 1;
    }

} # end sub checkCommandLineArguments


################################################################################
# generateMachineList
################################################################################
# Description:
#  
################################################################################
sub generateMachineList
{
    my $list = shift;

    # The list we will return
    my @machines = ();

    # Check if the list is already a list (comma seperated) or a file
    if ( $list =~ m/^file\:\/\// )
    {
        # It is a file, open it and parse it: 
        # Remove the file:// in front
        $list =~ s/file\:\/\///;

        # Check if the file is readable
        unless ( -r $list )
        {
            logger("error","Cannot read file $list, please make sure it exists "
                  ."and has correct permission");
            return undef;
        } 

        # If the file is readable open and parse it
        open(FH,"$list");
        
        # Add all the lines / machine-names to the array
        while(<FH>)
        {
            chomp($_);
            push( @machines, $_ ) unless ($_ =~ m/^#/);
        }
        close FH;

    } else
    {
        # If the list is a comma seperated list, split it by comma
        @machines = split(",",$list);
    }

    # return the list / array of machine names
    return @machines;

} # end sub generateMachineList

################################################################################
# backupMachines
################################################################################
# Description:
#  
################################################################################
sub backupMachines
{
    my @machines = @_;

    # Check hash if machine could successfully be snapshotted
    my %snapshot_success = ();

    # Go through all machines in the list passed and execute the snapshot method
    foreach my $machine ( @machines ) 
    {
        # Log which machine we are processing
        logger("debug","Snapshotting machine $machine");

        # At start error is 0 for every machine 
        my $error = 0;

        $error = processEntry($machine,"snapshot");

        # Test if there was an error
        if ( $error )
        {
            logger("error","Snapshot process returned error code: $error"
                  ." Will not call merge and retain processes for machine "
                  ."$machine.") if $error != -1;
            $snapshot_success{$machine} = "no";
            next;
        }

        $snapshot_success{$machine} = "yes";
        logger("debug","Machine $machine successfully snapshotted");

    } # End of for each

    # After all machines have been snapshotted, we can merge and retain them
    foreach my $machine ( @machines )
    {
        
        # Check if the snapshot for this machine was successfull
        next if $snapshot_success{$machine} eq "no";

        logger("debug","Processing (merge and retain) machine $machine");

        # Do the merge and retain
        $error = processEntry($machine,"merge");

        # Test if there was an error
        if ( $error )
        {
            logger("error","Merge process returned error code: $error"
                  ." Will not call retain processes for machine "
                  ."$machine.");
            next;
        }

        $error = processEntry($machine,"retain");

        # Test if there was an error
        if ( $error )
        {
            logger("error","Retain process returned error code: $error"
                  ." No files have beed transfered to the backup location");
            next;
        }

        checkIterations($machine);

        logger("debug","Machine $machine processed");

    }

}

################################################################################
# checkIterations
################################################################################
# Description:
#  
################################################################################
sub checkIterations
{
    my $machine = shift;

    my @iterations;

    # Get the backup directory for the machine
    my $backup_directory = getValue($machine, "sstBackupRootDirectory");

    # Remove the file:// in front
    $backup_directory =~ s/file\:\/\///;

    # Add the intermediate path 
    $backup_directory .= "/".returnIntermediatePath()."/..";

    # Go through the hole directory and put all iterations in the iterations 
    # array
    while(<$backup_directory/*>)
    {
        push( @iterations, basename( $_ ) );
    }

    # As long as we have more iterations as we should have, delete the oldest:
    while ( @iterations > getValue( $machine, "SSTBACKUPNUMBEROFITERATIONS") )
    {
        # Set the oldest date to year 9000 to make sure that whatever date will
        # follow is older
        my $oldest = "90000101000000";
        my $oldest_index = 0;
        my $index;

        # Go through all iterations an check if the current iteration is older 
        # than the current oldest one. If yes, set the current iteration as the
        # oldest iteration.
        foreach my $iteration (@iterations)
        {
            if ( $iteration < $oldest )
            {
                $oldest = $iteration;
                $oldest_index = $index;
            } else
            {
                $index++;
            }
            
        }

        # Delete the oldest iteration from the array: 
        splice @iterations, $oldest_index, 1;

        # And delete it also from the filesystem: 
        my @args = ( "rm", "-rf", $backup_directory."/".$oldest);
        if ( executeCommand( undef, @args ) )
        {
            logger("error","Could not delete oldest iteration: "
                  .$backup_directory."/".$oldest.", try to delete it manually "
                  ."by executing the following command: @args");
            return 1;
        } else
        {
            logger("debug","Oldest iteration successfully deleted\n");
        }

    }


}