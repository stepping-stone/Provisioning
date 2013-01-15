package Provisioning::Backend::File;

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

use strict;
use warnings;

use Provisioning::Log;
use Provisioning::Information;
use Module::Load;
use Config::IniFiles;

use Switch;
use POSIX;
use File::Basename;

require Exporter;

=pod

=head1 Name

File.pm

=head1 Synopsis

=head1 Description

This module is responsible everything concerning the communication with the 
backend (in this case a simple File). All the major tasks (e.g. connect, bind, 
queries ...) are handled in this module.

=head1 Uses

=over

=item Log

=item nformation

=item Module::Load

=item Switch

=back

=head1 Methods

=over

=item connectToBackendServer 


=item disconnectFromServer 


=item getValue 


=item simpleSearch


=item startPersistantSearch


=item modifyAttribute 


=cut



our @ISA = qw(Exporter);

our %EXPORT_TAGS = ( 'all' => [ qw(exportEntryToFile getParentEntry ldap modifyAttribute connectToBackendServer simpleSearch getValue disconnectFromServer startPersistantSearch) ] );

our @EXPORT_OK = ( @{ $EXPORT_TAGS{'all'} } );

our @EXPORT = qw(exportEntryToFile getParentEntry modifyAttribute connectToBackendServer simpleSearch getValue disconnectFromServer startPersistantSearch);

our $VERSION = '0.01';

$|=1;

# We need a configuration file which simulates the "server" and holds all the 
# information we usually get from the server
my $information_file = undef;

# to test whether the methodes were successful
my $had_error;

# Set the configuration files, load them from the master script
my $cfg = $Provisioning::cfg;
my $global_cfg = $Provisioning::global_cfg;

# Read the configuration files and set some variables
my $modus = $cfg->val('Service','MODUS');
my $info = $global_cfg->val('Global','INFO');
my $debug = $global_cfg->val('Global','DEBUG') || $Proviosioning::opt_d;
my $service = $cfg->val('Service', 'SERVICE');
my $type = $cfg->val('Service', 'TYPE');
my $gateway = $Provisioning::TransportAPI;

my $update_cookie=0;

my $cookie;

# Load the service and transportAPI modules on runtime
my $service_module = "Provisioning::$service\:\:$type";
our $TransportAPI = "Provisioning::TransportAPI::$gateway";
load "$service_module", ':all';
load "$TransportAPI", ':all';

sub getValue
{
    my ( $entry, $attribute ) = @_;

    # Since all attributes in the config file are upper case convert the
    # attribute to upper case
    $attribute = uc($attribute);

    # The value to return
    my @values;

    # Check if the specified section (entry) exists
    if ( $information_file->exists( $entry, $attribute ) )
    {
        # If yes return the value corresponding to the attribute in the section
        push ( @values, $information_file->val( $entry, $attribute ) );
    } else
    {
        # If not, we need to check the attribute in the general section
        push ( @values, $information_file->val( "General", $attribute ) );
    }

    return $values[0] if @values == 1;
    return @values if @values > 1;
    return undef;

}# end sub getValue

  
sub getParentEntry
{
    my $entry = shift;

    # Get the value for the parent entry
    my $parent = getValue( $entry, "parent" );

    # If it is "this" it means that the config file does not have a parent so 
    # we return the current config file
    if ( $parent eq "this" )
    {
        return $information_file;
    } else
    {
        # But if there is a file mentioned in the parent attribute, we need to
        # create a new config file with this file and return this one
        my $parent_conf = new Config::IniFiles( -file => $parent );
        return $parent_conf;
    }

}# end sub getParentEntry


sub exportEntryToFile
{
    my ( $section, $file ) = @_;

    # Open the specified file
    if ( !open(EXPORT,">$file") )
    {
        # Log that we cannot open the file
        logger("error","Cannot open file $file for writing!");
        return 1;
    }

    # Write the section name to the file
    print EXPORT "[$section]\n";

    # Read all the parameters of the given section and write it to the specified
    # file
    foreach my $param ( $information_file->Parameters( $section ) )
    {
        print EXPORT $param." = ".$information_file->val( $section, $param )."\n";
    }
    
    # Close the specified file
    close EXPORT;

    # Return that everything went fine
    return 0;

}# end sub exportEntryToFile

sub connectToBackendServer
{
    my ( $mode, $attempt ) = @_;

    # We actually don't need these two variables, we just need the Server value
    # from the configuration file which specifies an additional configuration
    # file which holds all the information we need to know

    # Check if the file is already defined, if yes just return it (we do not 
    # need/allow multiple open filehandler to a single file)
    return $information_file if defined($information_file); 


    my $additional_config_file = $cfg->val('Database','SERVER');

    # Test if this file exists
    unless ( -e $additional_config_file )
    {
        # Log it and return the error
       logger("error","The specified configuration file $additional_config_file"
              ." (specified in ".$cfg->GetFileName().") does not exist. Please "
              ."specify a valid configuration file and start the script again!");
        return undef;
    }

    # Test if the file is readable
    unless ( -r $additional_config_file )
    {
        # Log it and return the error
       logger("error","The specified configuration file $additional_config_file"
              ." is not readable. Please set correct ownership/permission and  "
              ." start the script again!");
        return undef;
    }

    # Create a new config::ini file object if it does not already exists
    $information_file = new Config::IniFiles( -file => $additional_config_file) if ( ! defined( $information_file ) );

    # return the file
    return $information_file;

}# end sub connectToBackendServer

sub disconnectFromServer
{

    # No disconnect method

}# end sub 

sub simpleSearch
{
    my ($subtree, $filter, $scope) = @_;

    # Parese the filter (attribute = value), first of all test if we have more
    # than just one condition: (&(attribute1 = value1)(attribute2 = value2))
    if ( $filter =~ m/^\(\&/ )
    {
        $filter =~ m/^\(\&\(([a-zA-Z]+)=(.*)\)\(.*$/;
        $filter = "(".$1."=".$2.")";
        logger("info","More than one condition, considering just the first "
              ."which is: $filter. (This will not affect the results in any "
              ."way.)");
    }

    $filter =~ m/^\(([a-zA-Z]+)=(.*)\)/;
    my $attribute = uc($1);
    my $value = $2;

    # Log what we are searching for
    logger("debug","Searching for $attribute = $value");

    # All results
    my @results = ();

    # Check if the section subtree exists
    foreach my $section ( $information_file->Sections() )
    {
        # Get the dn for the sections
        if ( ( getValue( $section, "dn" ) eq $subtree ) || ( $section eq $subtree ) )
        {
            # We are in the correct section, now get the attribute we are
            # looking for, if the value also matches, we can put this section
            # into the results
            if ( getValue( $section, $attribute ) eq $value )
            {
                push( @results, $section );
            }
        }

    }

    return @results;

}# end sub 

sub startPersistantSearch
{
    # TODO
    # Implement a persistant search and a persitant search callback
  
} # end sub startPersistantSearch

sub persistantSearchCallback
{

} # end subpersitantSearchCallback

sub exitSearch
{

} # end sub exitSearch


sub modifyAttribute
{
    my ($entry, $attribute, $new_value, $connection)=@_;

    # Get the log directory 
    my $log_dir = $information_file->val("General","LOGDIR");

    # Test if the log directory is writeable
    if ( -w $log_dir )
    {
        # Get the date for the log message: 
        my $date = strftime "%Y-%m-%d %H:%M:%S",localtime();

        if ( open(LOG,">>$log_dir/$entry.log") )
        {
            print LOG "\n$date:\n";

            # Test if the value is an array
            if ( ref($new_value) eq 'ARRAY')
            {
                foreach my $val (@$new_value)
                {
                    print LOG "$attribute: $val\n";
                }

            } else
            {
                print LOG $attribute.": ".$new_value."\n";
            }

            close LOG;
        } else
        {
            logger("warning","Cannot open file $log_dir/$entry.log for "
                  ."writing");
        }

    } else
    {
        logger("error","Log directory for virtual machines ($log_dir) is not "
              ."writable, please make sure it exists and has correct permission"
              );
        return 1;
    }

    return 0;   

} # end sub modifyAttribute

sub cookie 
{
  
} # end sub cookie


sub get_entryCSN
{ 

} # end sub get_entryCSN


1;

__END__

=back

=head1 Version

Created 2012-12-24 by Pat Kläy <pat.klaey@stepping-stone.ch>

=over

=item 2012-12-24 Pat Kläy created.

=back

=cut

