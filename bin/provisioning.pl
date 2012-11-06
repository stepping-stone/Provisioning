#!/usr/bin/perl

package Provisioning;

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

use Config::IniFiles;
use Sys::Syslog;
use Getopt::Std;
use LockFile::Simple qw(lock trylock unlock);
use Module::Load;
use Cwd 'abs_path';
use File::Basename;

use warnings;
use strict;

use vars qw($opt_d $opt_h $opt_c $opt_r $opt_t $opt_g);

getopts('c:dhrtg:');

$SIG{INT}=\&Provisioning::shutdown;
$SIG{TERM}=\&Provisioning::shutdown;

$|++;


sub get_lib{

  # to include the current directory as a search path in perl we have to 
  # do it in compile time, so the method gets the current directory and
  # returns it

  my $location=dirname(abs_path($0));
  return $location."/../lib/";

}

# use the current directory as search path in perl
use lib get_lib();


############################################################################################
##  Start pod2text documentation
############################################################################################


=pod

=head1 Name

provisioning.pl

=head1 Usage
 
 provisioning.pl -c option_argument [-g option_argument] [-t] [-r] [-d] [-h]

=head1 Description

This script is the master for the whole provisioning. It locks the service,
creates a connection to the service-server and starts the persistant search.
All information is collected form the configuration file, so it can handle
several service, different connection to the service-server and different
database types.  

=head1 Options

=over

=item -c /path/to/your/configuration

The -c option is mandatory and specifies the backend (service) configuration
file.

=item -g /path/to/your/configuration

The -g option is optional and specifies the global configuration file. If this
value is not present, the default configuration is used.

=item -r

The -r option is optional and performs a dry-run, this means that no changes
will be made on the system. The script only prints out what it would do. 

=item -d

Enables debug mode. In debug mode everything that is logged will also be printed
to STDOUT.

=item -t 

Enables the test mode. There you can test whether all the functions still work
properly (e.g. after a system-update).

=item -h

Tells you where you can find some help:-)

=back

=head1 Version

=over 

=item 2010-07-01 Pat Kläy created.

=item 2010-07-05 Pat Kläy modified.

Cookie subroutine implemented.

=item 2010-09-05 Pat Kläy modified.

Removed the whole logic and put it into the modules.

=item 2010-10-08 Pat Kläy modified.

Implemented test mode.

=back

=cut


###############################################################################
##  End pod2text documentation
###############################################################################
# if the -h option is set the user wants help, tell him to use pod2text
if($opt_h){
  print "use pod2text $0 for help\n";
  exit;
}


# we have to know which service we have to provision, for this reason we need 
# a configuration file
our $opt_c;

openlog("provisioning.pl","ndelay,pid", "local0");

unless($opt_c){
  
  syslog("LOG_ERR","No config file specified for provisioning.pl. Script cannot continue without configuration file.");
  exit;

} # end unless(opt_c)

# get all the vars stored in the config file 
our $cfg=new Config::IniFiles( -file => $opt_c );

our $location=dirname(abs_path($0));

my $global_conf_file = $opt_g || "$location/../etc/Provisioning/Global.conf";


our $global_cfg = new Config::IniFiles( -file => $global_conf_file);

my $script_name         = $0;

our $debug 		= $opt_d;

my $info 		= $global_cfg->val('Global', 'INFO');

our $opt_R		= $opt_r;


my $backend		= $cfg->val('Database', 'BACKEND');
our $TransportAPI	= $cfg->val('Service','TRANSPORTAPI');

my $service		= $cfg->val('Service','SERVICE');
my $type		= $cfg->val('Service','TYPE');

my $subtree             = $cfg->val('Service', 'SERVICE_SUBTREE');
#my $attribute           = $cfg->val('Service', 'SERVICE_ATTRIBUTE');

our $syslog_name         = $cfg->val('Service', 'SYSLOG');

my $database_server	= $cfg->val('Database','SERVER');
my $database_port	= $cfg->val('Database','PORT');
my $database_user	= $cfg->val('Database','ADMIN_USER');
my $database_password	= $cfg->val('Database','ADMIN_PASSWORD');

my $gateway_host	= $cfg->val('Gateway','HOST') || undef;
my $gateway_user	= $cfg->val('Gateway','USER') || undef;
my $gateway_dsa_file	= $cfg->val('Gateway','DSA_FILE') || undef;


my $attempt     	= 1;

our $lock 		= LockFile::Simple->make(-hold=>0);



# load the necessary module
load "Provisioning::Log", ':all';
logger("info","Starting $service-$type provisioning script");

load "Provisioning::TransportAPI::$TransportAPI", ':all';

# immediatly establish gateway connection
our $gateway_connection=gatewayConnect("$gateway_host","$gateway_user","$gateway_dsa_file","connect",0);
unless($gateway_connection){
  logger("error","No gateway-connection. Connection to $gateway_host with user $gateway_user failed! Script stops here, cannot do anything without gateway-connection.",$service);
  exit; 
}

our $server_module="Provisioning::Backend::$backend";
load "$server_module", ':all';


#if($opt_t){
#  load "Test::Testscript", ':all';
#  testscript();
#  exit;
#}


unless($lock->trylock("/var/run/Provisioning-$service-$type")){

  logger("warning","$service-Deamon already running, program exits now");
  gatewayDisconnect($gateway_connection);
  exit;

}
else{
  logger("debug","file: /var/run/Provisioning-$service-$type locked");
}



# create the server connection. On success the connection is returned,
# otherwise undef. 
my $connection = connectToBackendServer("connect",$attempt);


if($connection){

  # only start the search if we are connected. 
  my $status=startPersistantSearch();
 
  #if the startPersistantSearch gets a return value ckeck if it's 
  #special. If it's 3 we know that callback method recieved something
  #unexpected. We assume it's the cookie file making this trouble. So we
  #delete it and start a new search if were in selfcare mode.
  my $modus=$cfg->val("Service","MODUS");  
  my $cookie=$cfg->val("Database","COOKIE_FILE");
  
  if($modus=~/selfcare/i){

    if($status==3){
      #delete the cookei file
      my @args=("rm",$cookie);
      system(@args);

      logger("info","Cookie file deleted, starting a new persistant search now");
      #and start a new search
      $status=startPersistantSearch();

      if($status==3){
        logger("error","Unknown error! The second time the persistantSearchCallback method recieved something unexpected. Cookie file has already been deleted.");
      }
    }
    
  }
  else{
    logger("error","persistantSearchCallback method recieved something unexpected. Delete the cookie file and restart the daemon could solve this problem (no guarantee!!). To do this log into the server that sent this mail and execute the following commands:\nrm $cookie\n/etc/init.d/sst-$service-$type start");
  }

  disconnectFromServer($connection);

}
else{
  logger("error","Could not start the persistant search, no connection. See syslog or your mailbox for further information.");
}

# take down all connection and clean up the locks
gatewayDisconnect($gateway_connection);
$lock->unlock("/var/run/Provisioning-$service-$type");
logger("info","Stopping $service provisioning script");


closelog();

sub shutdown(){

  # Unlock the service
  $lock->unlock("/var/run/Provisioning-$service-$type");

  # Disconnect the gateway and backend connection
  disconnectFromServer($connection) if $connection;
  gatewayDisconnect($gateway_connection) if $gateway_connection;

  # Stop the logging service
  logger("info","Stopping $service provisioning script");
  closelog();

  # Stop the script.
  exit 0;

}

# It meight be that the gateway connection breaks down, so we need to update it
# The check if the connection still works is done in the TransportAPI modules,
# which then call this method to update the global gateway connection
sub updateGatewayConnection{

    my $connection = shift;

    # Test whether we have a connection or not
    if ( defined( $connection ) )
    {
        # If the connection is defined, update it
        $gateway_connection = $connection;
    } else
    {
        # If the connection is not defined, stop the script and log it!
        logger("error","Cannot update connection becauase it is not defined ("
              ."not properly working). Stopping Script now!");
        Provisioning::shutdown();
    }

}
