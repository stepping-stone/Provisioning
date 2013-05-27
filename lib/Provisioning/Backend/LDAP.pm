package Provisioning::Backend::LDAP;

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
use Net::LDAP;
use Net::LDAP::LDIF;
use Net::LDAP::Constant qw(
  LDAP_SYNC_REFRESH_AND_PERSIST
  LDAP_SUCCESS
  LDAP_SYNC_PRESENT
  LDAP_SYNC_ADD
  LDAP_SYNC_MODIFY
  LDAP_SYNC_DELETE
  LDAP_SYNC_REFRESH_REQUIRED
  LDAP_USER_CANCELED
);
use Switch;
use Net::LDAP::Control::SyncRequest;
use POSIX;
use File::Basename;

require Exporter;

=pod

=head1 Name

LDAP.pm

=head1 Synopsis

=head1 Description

This module is responsible everything concerning the communication with the backend (in this case LDAP). All the major tasks (e.g. connect, bind, queries ...) are handled in this module.

=head1 Uses

=over

=item Log

=item nformation

=item Module::Load

=item Net::LDAP

=item use Net::LDAP::Control::SyncRequest

=item Switch

=back

=head1 Methods

=over

=item connectToBackendServer 

This methode connects and binds to the given LDAP-Server::Port with given username and password. The only input parameter is $attempts (optional). It indicates the nubmers of connection-attempts already made. All other necessary information should be stored in a configuration file. If the connection was established successfully the Net::LDAP object is returned. Otherwise nothing is returned.

=item disconnectFromServer 

This void method simply disconnects from the server. You can specfiy the connection you want to disconnect by passing it as input parameter. If no connection is passed to the method it disconnects the main connection.

=item getValue 

This method returns the value from the given attribute. It simply performs the get_value method from the Net::LDAP library. As input parameters you have to specify the Net::LDAP::Entry object and the attribute.

=item simpleSearch

This method performs a simple LDAP search. There are three input parameters: subtree, filter and scope (optional, 'sub' is default). The search returns an array with the entries corresponding to the filter. 

=item startPersistantSearch

This method starts a persistant search. You can specify on which connection (optional), but if no connection is passed to the method it takes the default connection. All other necessary information should be stored in a configuration file.

=item modifyAttribute 

Modifies one attribute in a given entry. The input parameters are: entry, attribute, new_value and connection (optional, if not set takes default connection). The method returns nothing on success, 1 otherwise. 

=cut



our @ISA = qw(Exporter);

our %EXPORT_TAGS = ( 'all' => [ qw(exportEntryToFile getParentEntry ldap modifyAttribute connectToBackendServer simpleSearch getValue disconnectFromServer startPersistantSearch) ] );

our @EXPORT_OK = ( @{ $EXPORT_TAGS{'all'} } );

our @EXPORT = qw(exportEntryToFile getParentEntry modifyAttribute connectToBackendServer simpleSearch getValue disconnectFromServer startPersistantSearch);

our $VERSION = '0.01';



#TODO's

$|=1;


# general/default ldap-connection
my $ldap_connection;

# to test whether the methodes were successful
my $had_error;

# Set the configuration files, load them from the master script
my $cfg = $Provisioning::cfg;
my $global_cfg = $Provisioning::global_cfg;

# Read the configuration files and set some variables
my $modus= $cfg->val('Service','MODUS');
my $info= $global_cfg->val('Global','INFO');
my $debug= $global_cfg->val('Global','DEBUG') || $Proviosioning::opt_d;
my $service= $cfg->val('Service', 'SERVICE');
my $type= $cfg->val('Service', 'TYPE');
my $gateway=$Provisioning::TransportAPI;

my $update_cookie=0;

my $cookie;

# Load the service and transportAPI modules on runtime
my $service_module="Provisioning::$service\:\:$type";
our $TransportAPI="Provisioning::TransportAPI::$gateway";
load "$service_module", ':all';
load "$TransportAPI", ':all';

sub getValue{

  # this method returns the value from the selected attribute. It simply performs
  # the get_value method from the Net::LDAP library

  my ($entry, $attribute)=@_;

  # if the DN is asked, return the DN ...
  if($attribute=~/dn/i){
    return $entry->dn() if $entry->dn();
  }
  # otherwise return the asked attribute
  else{
    return $entry->get_value($attribute) if $entry->exists($attribute);
  }

  return undef;

}

  
sub getParentEntry
{
    my $entry = shift;
    
    # Split the dn
    my @parts = split( ",", getValue($entry,"dn") );
    # Remove the first part
    shift(@parts);
    # And put the rest together again
    my $parent_dn = join("," , @parts );

    # Get the parent entry
    my @parents = simpleSearch($parent_dn,"(objectclass=*)","base");

    return $parents[0];
}


sub exportEntryToFile
{

    my ( $entry, $ldif, $subtree ) = @_;

    # Create a new ldif object in write mode and the
    my $new_ldif = Net::LDAP::LDIF->new( $ldif, "a" );

    # Check for errors
    if ( ! $new_ldif )
    {
        logger("error","Cannot create ldif $ldif");
        return 1;
    }

    my $error = $new_ldif->error();
    if ( $error )
    {
        logger("error","Cannot open ldif $ldif: $error");
        return 1;
    }

    # If the user wants to save the whole subtree, get it and write it to the 
    # ldif
    if ( defined( $subtree ) && $subtree == 1 )
    {
        # Search for everything below the entry (get the whole sub tree) 
        my @subtree = simpleSearch($entry->dn() , "(objectclass=*)" , "sub");

        # Go through all results and write each entry to the ldif
        foreach my $tmp_entry ( @subtree )
        {
            # Write the content from the entry to the ldif
            $new_ldif->write_entry( $tmp_entry );
        }
    } else
    {
        # Write the content from the entry to the ldif
        $new_ldif->write_entry( $entry ); 
    }

    # Chek if there was an error
    $error = $new_ldif->error();

    # If there was an error log it and return
    if ( $error )
    {
        logger("error","Cannot write entry to ldif: $error");
        return 1;
    }

    # Terminate the process (close FH etc.)
    $new_ldif->done();

    return 0;


}

sub connectToBackendServer{

# This methode connects and binds to the given LDAP-Server::Port with given 
# username and password. If the connection was established successfully
# the Net::LDAP object is returned. Otherwise nothing is returned.

  my ($mode,$attempt)=@_;

  # If the attempt parameter was not passed, set attempts to 1 (it's the first
  # attempt).
  unless($attempt){
    $attempt=1;
  }

  # Up to now, we do not have errors, so set error to 0
  my $error=0;

  # Read the config fiel, get the information about the LDAP-Server
  my $ldap_server = $cfg->val('Database','SERVER');
  my $ldap_port = $cfg->val('Database','PORT');
  my $ROOTDN = $cfg->val('Database','ADMIN_USER');
  my $ROOTPW = $cfg->val('Database','ADMIN_PASSWORD');

  # Define two vars, they will be set later.

  # Seconds to sleep means how long we wait until we try to connect again after
  # a connection-attempt failed. 
  my $seconds_to_sleep;

  # attempts_before_exit means how many times we try to connect before we give
  # up in the case that we cannot connect to the LDAP-Server
  my $attempts_before_exit;

  # Now check which connection mode we have. "Connect" means the script just
  # started and we need to establish a connection to the LDAP-Server."Reconnect"
  # means that we lsot the connection to the LDAP-Server and need to reestablish
  # it.
  if ( $mode eq "connect" ) {

    # If the mode is connect, read the vars for the connect mode
    $seconds_to_sleep= $global_cfg->val('Global', 'SLEEP');
    $attempts_before_exit= $global_cfg->val('Global', 'ATTEMPTS');

  }
  elsif($mode eq "reconnect"){

    # If the mode is reconnect, read the vars for the reconnect mode
    $seconds_to_sleep= $global_cfg->val('Operation Mode', 'SLEEP');
    $attempts_before_exit= $global_cfg->val('Operation Mode', 'ATTEMPTS');

    # Log that we lost the connection and we will try to reconnect
    logger("warning","Lost connection to the LDAP-server ($ldap_server). Reconnect in $seconds_to_sleep seconds!");

    # Wait the specified time, it does not make sense to reconnect immediatly,
    # for example when the LDAP deamon is restarted or..
    sleep($seconds_to_sleep);
  }
  else{

    # If the mode is neither connect nor reconnect, take default values
    logger("warning","Unknown mode, setting default values sleep=30 and attempts=3");
    $seconds_to_sleep=30;
    $attempts_before_exit=3;
    
  }


  # try to establish the conncetion to the specified LDAP-Server
  $ldap_connection = Net::LDAP->new( $ldap_server,
                                  port => $ldap_port,
                                  async    => 0,
   				  #onerror => return,
                                  #debug    => 15,
			          #verify => 'require',
				  #cafile => '/etc/ssl/certs/Swiss_Certificate_Authority.cert.pem',
                                  );

  my $local_error=$!;

  # if something went wrong wait for some seconds (specified in the config file) and
  # then retry to connect to the server. If we reached the number of max. retries
  # (also specified in the config file) we abort and write a error-log-message

  # check whether the connection could be establisched
  if( !$ldap_connection ){

    # if the connection could not be established, check if the maximu attempts
    # is reached, if yes give up, otherwise try again to establish the
    # connection
    if( $attempt != $attempts_before_exit ){

      # Log what we are doing, to be able to track the process
      logger("warning","$attempt. attempt to establish LDAP-connection to ".
             "$ldap_server failed: $local_error. Retry in $seconds_to_sleep ".
             "seconds.");

      # Increase attempts
      $attempt++;

      # ...wait...
      sleep($seconds_to_sleep);

      # and try again to connect
      connectToBackendServer($mode,$attempt);
    }
    # if we tried enough we give up
    else{

      logger("error", "Last ($attempt.) attempt to establish LDAP-connection to $ldap_server failed: $local_error. Could not establish LDAP-connection.");
      $error=1;

    }# end if($attempt<$attempts_before_exit)
  }
  # if the connection could be established we can bind to the LDAP-Server
  else{

    logger("debug","LDAP-connection to $ldap_server established. Connection: $ldap_connection");

    # Bind to the LDAP-Server with the credetials from the config fiel
    my $bind = $ldap_connection->bind( $ROOTDN, password => $ROOTPW);

    # if binding was not successful we write a log message
    if( $bind->code() != LDAP_SUCCESS ){

      my $errorMessage="Could not bind to $ldap_server: ".$bind->error;
      logger("error",$errorMessage);
      $error=1;

    }
    # if binding was successful 
    else{

      logger("debug","Successful binded to $ldap_server");
      
    } #end if($bind>code() != LDAP_SUCCESS)
  } #end if(!$ldap_connection)


  # if there was an errror while connecting to the LDAP-Server we won't return
  # anything. If everything was ok, the connection is returned.
  if( $error == 1 )
  {

    return undef;

  }else
  {

    return $ldap_connection;

  } # end if($error==1)


}# end sub connectToBackendServer



=pod

=item disconnectFromServer

This methode disconnects from the given LDAP-Server.

=cut

sub disconnectFromServer{

  # simply disconnects from the server. if there's no connection specified
  # take the default

  my $connection = shift || $ldap_connection;

  logger("debug","taking down session: $connection");
  $connection->unbind;

}


=pod

=item simpleSearch



=cut


sub simpleSearch{

  # this method performs a simple LDAP search with the given filter in the
  # given subtree.

  my ($subtree,$filter,$scope)=@_;
  my @result;


  # create a seperate connection to not confuse to persistant search connection
  my $search_connection=connectToBackendServer("connect",1);

  # If no scope is given, take the default one (sub).
  unless($scope){
    $scope='sub';
  }  

  logger("debug","Searching for $filter in $subtree");


  # Search from the given base with the given scope and filter
  my $search_result = $search_connection->search(base	=> $subtree,
                           	 	  	scope	=> $scope,
                            			filter	=> $filter);

  # The search return an hash ref so parse it and extract the serach results and
  # put them in an array
  foreach my $entry ($search_result->entries) {
     push(@result,$entry); 
  }

  # Disconnect (search connection) from the server
  disconnectFromServer($search_connection);
  
  # return the results
  return @result;

}




sub startPersistantSearch{

  # Take the passed connection, if nothing is passed, take the default one.
  my $connection=shift || $ldap_connection;

  # Read the subtree specified in the config file
  my $subtree=$cfg->val('Database','SERVICE_SUBTREE');

  # Get the serach filter, take default one if nothing is defined
  my $search_filter = $cfg->val('Database','SEARCH_FILTER') || 
                      "(&(entryCSN>=%entryCSN%)(objectClass=*))";

  # get the cookie;
  $cookie=cookie();

  # create the search-control-object.
  # set the mode to persist means we search all the time -> while( TRUE )
  my $sync_request = Net::LDAP::Control::SyncRequest->new(mode => LDAP_SYNC_REFRESH_AND_PERSIST,
							  cookie => $cookie,  
							  reloadHint => 1,
							 );

  # Specify the attributes we use for the search
  my @attrs = qw(
    entryCSN
    entryUUID
    createTimestamp
    *
  );

  # get the entryCSN -> date of the last modification
  my $entryCSN = get_entryCSN($cookie);

  # Does the entryCSN appear in the serach filter? If yes replace it:
  $search_filter =~ s/%entryCSN%/$entryCSN/;

  # search the LDAP-directory for entries newer than the cookie in the given 
  # subtree and the above generated control-object and attributes. For each
  # result the persistantSearchCallback is called.
  my $LDAP_result=$connection->search(	base	 => $subtree,
                            		scope	 => 'sub',
                            		control	 => [ $sync_request ],
			    		callback => \&persistantSearchCallback,
                            		filter	 => $search_filter,
			    		attrs	 => \@attrs,
                           	       );

  # This is the forever loop, a persistant search will not have the done flag
  # set, so we will continue forever (execept there is an error).
  while(!$LDAP_result->done()) {

    # connection->process() means just continue searching
    $connection->process();

  }

  #if the following line is executed it means that the persistantSearchCallback
  #method recieved something unexpected, we retrun a special value to let the
  #main script know what happend!
  return 3;

} # end sub startPersistantSearch


sub persistantSearchCallback{

  # The first parameter passed is the the message from the search
  my $message = shift;

  # The second parameter passed may be "entry" or "intermediate" (if the search
  # foundsomething an entry object, otherwise an intermediate object is
  # returned).
  my $param2 = shift;

  # Get the controls passed form the search via the message
  my @controls = $message->control;

  # Define some vars, will be used later
  my @sync_controls;

  my $state;
  my $entryUUID;
  my $cookie;
  my $attrs;

  $update_cookie=0;

  # Now check if we got two parameters and if the second is an LDAP-Entry
  if ( $param2 && $param2->isa("Net::LDAP::Entry") ) {


    foreach my $ctrl (@controls) {
      if ($ctrl->isa('Net::LDAP::Control::SyncState')) {
	push(@sync_controls, $ctrl);
      } # End of if ($ctrl->isa('Net::LDAP::Control::SyncState'))	
    } # End of foreach my $ctrl (@controls)

    # Currently, we have certain states in which we want to die
    if(@sync_controls>1){
      logger("error", "Got search entry with multiple Sync State controls, script will stop here.");
      exitSearch();
    }
    if(!@sync_controls){
      logger("error", "Got search entry without Sync State control, script will stop here.");
      exitSearch();
    }
    if(!$sync_controls[0]->entryUUID){
      logger("error", "Got empty entryUUID, script will stop here.");
      exitSearch();
    }

    # set some useful vars
    $state = $sync_controls[0]->state();
    $entryUUID = unpack('H*',$sync_controls[0]->entryUUID());
    $cookie = (defined($sync_controls[0]->cookie()) ?  $sync_controls[0]->cookie() : 'UNDEF');

    # Check what kind of modus we have, if it is combined, we need to check if
    # the current change is selfcare or LDAP
    if($modus=~/combined/i)
    {
        # Check if the sstProvisioning* attributes exist, if yes, modus is
        # selfcare, if not, modus is LDAP
        if ( $param2->exists('sstProvisioningState') &&
             $param2->exists('sstProvisioningMode') &&
             $param2->exists('sstProvisioningExecutionDate')
           )
        {
            $modus = "selfcare";
        } else
        {
            $modus = "LDAP";
        }
    }

    # we have two modi, selfcare and ldap, if modus is selfcare ...
    if($modus=~/selfcare/i){

      # ... we have to check whether the value of 'sstProvisioningState' ...
      my $sstProvisioningState = $param2->get_value('sstProvisioningState');


      # ... is equal to 0. 0 means need provisioining, everything else means
      # no provisioning needed.
      #
      if( defined($sstProvisioningState) && $sstProvisioningState eq "0"){

        # Get the date
        my $date=`date +"%Y%m%d"`;

	# remove the breakline form the recieved date to be able to compare it
	$date=~s/\n//;

        # do we have to do it today? 0 or today's date means yes, something 
        # else means we don't have to do anything. 
        my $sstProvisioningExecutionDate = $param2->get_value('sstProvisioningExecutionDate');

        if(($sstProvisioningExecutionDate eq $date) or ($sstProvisioningExecutionDate eq "0")){

          my $sstProvisioningMode = $param2->get_value('sstProvisioningMode');

          # There are going to be some changes made in the LDAP directory, 
          # thats why we need to update the cookie file.
	  $update_cookie = 1;

          # check whether we have to add, modify or delete the entry. 
          switch($sstProvisioningMode){
            case "add"{
			logger("info","Adding ".$param2->dn());

			$had_error = processEntry($param2,"add",$state);

			if(!$had_error){
			  logger("info","Successfully added ".$param2->dn());
			}
			else{
			  logger("error","Could not add ".$param2->dn()." without errors, check your mailbox and syslog for further details.");
			} # end if(!$had_error)
	    } # end case "add"

	    case "modify"{
			  logger("info","Modifing ".$param2->dn());
			  $had_error=processEntry($param2,"modify",$state);
			  if(!$had_error){
			    logger("info","Successfully modified ".$param2->dn());
			  }
			  else{
			    logger("error","Could not modify ".$param2->dn()." without errors, check your mailbox and syslog for further details.");
			  } # end if(!$had_error)
	    } # end case modify

	    case "delete"{
			  logger("info","Deleting ".$param2->dn());
			  $had_error=processEntry($param2,"delete",$state);

			  if(!$had_error){
			    logger("info","Successfully deleted ".$param2->dn());
			  }
			  else {
			    logger("error","Could not delete ".$param2->dn()." without errors, check your mailbox and syslog for further details.");
			  } # end if(!$had_error)

	    } # end case delete

            case "snapshot" {
                                logger("info","Starting snapshot process for ".
                                       $param2->dn() );
                                # Start the process by calling the processEntry
                                # method
                                $had_error = processEntry($param2,"snapshot",$state);

                                # Test if the entry has been processed or not,
                                # if not -1 is returned and we can ignore this
                                # entry
                                return if ( $had_error == -1 );
                                
                                
                                if( $had_error == 0 )
                                {
                                    logger("info","Successfully snapshotted ".
                                           $param2->dn());
                                } else 
                                {
                                    logger("error","Could not snapshot ".
                                           $param2->dn()." without errors, ".
                                           "return code: $had_error" );
                                }

                                # We always want to write sstProvisioningState
                                # that's why we set had_error to 0
                                $had_error = 0;

                            } # End case snapshot

            case "merge"    {
                                logger("info","Starting merge process for ".
                                       $param2->dn() );
                                # Start the process by calling the processEntry
                                # method
                                $had_error = processEntry($param2,"merge",$state);
                                
                                # Test if the entry has been processed or not,
                                # if not -1 is returned and we can ignore this
                                # entry
                                return if ( $had_error == -1 );

                                if( $had_error == 0 )
                                {
                                    logger("info","Successfully merged ".
                                           $param2->dn());
                                } else 
                                {
                                    logger("error","Could not merge ".
                                           $param2->dn()." without errors, ".
                                           "return code: $had_error" );
                                }

                                # We always want to write sstProvisioningState
                                # that's why we set had_error to 0
                                $had_error = 0;

                            } # End case merge

            case "retain"   {
                                logger("info","Starting retain process for ".
                                       $param2->dn() );
                                # Start the process by calling the processEntry
                                # method
                                $had_error = processEntry($param2,"retain",$state);
                                
                                # Test if the entry has been processed or not,
                                # if not -1 is returned and we can ignore this
                                # entry
                                return if ( $had_error == -1 );

                                if( $had_error == 0 )
                                {
                                    logger("info","Successfully retained ".
                                           $param2->dn());
                                } else 
                                {
                                    logger("error","Could not retain ".
                                           $param2->dn()." without errors, ".
                                           "return code: $had_error" );
                                }

                                # We always want to write sstProvisioningState
                                # that's why we set had_error to 0
                                $had_error = 0;

                            } # End case retain

             case "delete"  {
                                logger("info","Starting delete process for ".
                                       $param2->dn() );
                                # Start the process by calling the processEntry
                                # method
                                $had_error = processEntry($param2,"delete",$state);
                                
                                # Test if the entry has been processed or not,
                                # if not -1 is returned and we can ignore this
                                # entry
                                return if ( $had_error == -1 );

                                if( $had_error == 0 )
                                {
                                    logger("info","Successfully deleted ".
                                           $param2->dn());
                                } else 
                                {
                                    logger("error","Could not delete ".
                                           $param2->dn()." without errors, ".
                                           "return code: $had_error" );
                                }

                                # We always want to write sstProvisioningState
                                # that's why we set had_error to 0
                                $had_error = 0;

                            } # End case delete

             case "restore" {
                                logger("info","Starting restore process for ".
                                       $param2->dn() );
                                # Start the process by calling the processEntry
                                # method
                                $had_error = processEntry($param2,"restore",$state);
                                
                                # Test if the entry has been processed or not,
                                # if not -1 is returned and we can ignore this
                                # entry
                                return if ( $had_error == -1 );

                                if( $had_error == 0 )
                                {
                                    logger("info","Successfully restored ".
                                           $param2->dn());
                                } else 
                                {
                                    logger("error","Could not restore ".
                                           $param2->dn()." without errors, ".
                                           "return code: $had_error" );
                                }

                                # We always want to write sstProvisioningState
                                # that's why we set had_error to 0
                                $had_error = 0;

                            } # End case restore

             case "unretainSmallFiles"{
                                logger("info","Starting unretain process for ".
                                       "the small files for ".$param2->dn() );
                                # Start the process by calling the processEntry
                                # method
                                $had_error = processEntry($param2,"unretainSmallFiles");
                                
                                # Test if the entry has been processed or not,
                                # if not -1 is returned and we can ignore this
                                # entry
                                return if ( $had_error == -1 );

                                if( $had_error == 0 )
                                {
                                    logger("info","Successfully unretained ".
                                           "the small files for ".$param2->dn());
                                } else 
                                {
                                    logger("error","Could not unretain the ".
                                           "small files for ".$param2->dn().
                                           ", return code: $had_error" );
                                }

                                # We always want to write sstProvisioningState
                                # that's why we set had_error to 0
                                $had_error = 0;

                            } # End case unretain
             case "unretainLargeFiles"{
                                logger("info","Starting unretain process for ".
                                       "the large files for ".$param2->dn() );
                                # Start the process by calling the processEntry
                                # method
                                $had_error = processEntry($param2,"unretainLargeFiles");
                                
                                # Test if the entry has been processed or not,
                                # if not -1 is returned and we can ignore this
                                # entry
                                return if ( $had_error == -1 );

                                if( $had_error == 0 )
                                {
                                    logger("info","Successfully unretained ".
                                           "the large files for ".$param2->dn());
                                } else 
                                {
                                    logger("error","Could not unretain the ".
                                           "large files for ".$param2->dn().
                                           ", return code: $had_error" );
                                }

                                # We always want to write sstProvisioningState
                                # that's why we set had_error to 0
                                $had_error = 0;

                            } # End case unretain

             case "cleanup"{
                                logger("info","Starting cleanup process for ".
                                       $param2->dn() );
                                # Start the process by calling the processEntry
                                # method
                                $had_error = processEntry($param2,"cleanup");
                                
                                # Test if the entry has been processed or not,
                                # if not -1 is returned and we can ignore this
                                # entry
                                return if ( $had_error == -1 );

                                if( $had_error == 0 )
                                {
                                    logger("info","Successfully cleaned up ".
                                           $param2->dn());
                                } else 
                                {
                                    logger("error","Could not cleanup ".
                                           $param2->dn()." without errors, ".
                                           "return code: $had_error" );
                                }

                                # We always want to write sstProvisioningState
                                # that's why we set had_error to 0
                                $had_error = 0;

                            } # End case cleanup


             else { # This is the default case if nothing above matched
                    # No changes made in the LDAP so set update cookie to 0 (we
                    # don't need to update the cookie)
                    $update_cookie = 0;
                  } # end else 

          } # end switch

          # If there were no errors, we can write the current date and time 
          # in the specified format to the entries sstProvisioningState
          # attribute to note that this entry has been processed
          if( !$had_error && $update_cookie )
          {
            # Establish a standalone write connection
            my $write_connection=connectToBackendServer("connect",1);

            if($write_connection)
            {
              my $timestamp = strftime "%Y%m%dT%H%M%SZ",gmtime();
              modifyAttribute($param2,'sstProvisioningState',$timestamp,$write_connection);
            }

            disconnectFromServer($write_connection);

          }# end if(!$had_error)

        } # end if($sstProvosioningExecutionDate)

      } # end if($sstProvisioningState)

    } # end if($modus=~/selfcare/i)


    # if modus is ldap...we simply check the entys state...
    elsif($modus=~/ldap/i){
      # we simply check the entys state and perform the aproppriate action. 
      switch($state) {
        case LDAP_SYNC_PRESENT  { print "present\n"; } #TODO
        case LDAP_SYNC_ADD      {
                                    # Call the process entry method and pass the
                                    # given entry and state "add"
                                    logger("info","Adding entry: ".
                                       $param2->dn() );

                                    # Start the process by calling the 
                                    # processEntry method
                                    $had_error = processEntry($param2,
                                                              "add",
                                                              $state);

                                    # Check if the entry could be added without
                                    # errors
                                    if( $had_error == 0 )
                                    {
                                        logger("info","Successfully added ".
                                               $param2->dn());
                                    } else 
                                    {
                                        logger("error","Could not add ".
                                               $param2->dn()." without errors,".
                                               " return code: $had_error" );
                                    }

                                }
        case LDAP_SYNC_MODIFY   {
                                    # Call the process entry method and pass the
                                    # given entry and state "modify"
                                    logger("info","Modifying entry: ".
                                       $param2->dn() );

                                    # Start the process by calling the 
                                    # processEntry method
                                    $had_error = processEntry($param2,
                                                              "modify",
                                                              $state);

                                    # Check if the entry could be added without
                                    # errors
                                    if( $had_error == 0 )
                                    {
                                        logger("info","Successfully modified ".
                                               $param2->dn());
                                    } else 
                                    {
                                        logger("error","Could not modify ".
                                               $param2->dn()." without errors,".
                                               " return code: $had_error" );
                                    }
                                }
        case LDAP_SYNC_DELETE   {
                                    # Call the process entry method and pass the
                                    # given entry and state "add"
                                    logger("info","Deleting entry: ".
                                       $param2->dn() );

                                    # Start the process by calling the 
                                    # processEntry method
                                    $had_error = processEntry($param2,
                                                              "delete",
                                                              $state);

                                    # Check if the entry could be added without
                                    # errors
                                    if( $had_error == 0 )
                                    {
                                        logger("info","Successfully deleted ".
                                               $param2->dn());
                                    } else 
                                    {
                                        logger("error","Could not delete ".
                                               $param2->dn()." without errors,".
                                               " return code: $had_error" );
                                    } 
                                }
        else                    {
                                    # We don't know this state so just log it
                                    logger("error","Received an entry ("
                                          .$param2->dn().") in LDAP mode and "
                                          ."state $state. This state is unknown"
                                          ." so we cannot process this entry"
                                          );
                                }

      } # End of switch($state)

    } # end elsif($modus=~/ldap/i)

    # We need to keep the cookie (if returned from the syncrepl provider)
    if(defined($sync_controls[0]->cookie)) {
      $cookie = $sync_controls[0]->cookie;
      # Display Cookie information
      logger("debug","Received new cookie: \$cookie=$cookie");
      cookie($cookie);
    } # end if(defined($sync_controls[0]->cookie))


  } # end if($param2 && $param2->isa("Net::LDAP::Entry"))

  elsif($param2 && $param2->isa("Net::LDAP::Reference")) {
    # The Net::LDAP::Reference object represents a reference (sometimes called a "referral") 
    # returned by the directory from a search.
    if ($info) {
      print "INFO:  Received Search Reference\n";
      return;
    } # End of if ($info)
  } # end elsif($param2 && $param2->isa("Net::LDAP::Reference"))

  elsif($param2 && $param2->isa("Net::LDAP::Intermediate::SyncInfo")) {
    # Net::LDAP::Intermediate::SyncInfo - LDAPv3 Sync Info Message object.
    if ($info) {
      print "INFO:  Received Intermediate SyncInfo Message\n";
    } # End of if ($info)
    my $attrs = $param2->{asn};

    if($attrs->{newcookie}) {
      $cookie = $attrs->{newcookie};
      if ($info) {
        print "INFO:  Received new cookie = $cookie\n";
      } # End of if ($info)
      cookie($cookie);
    } 
    elsif(my $refreshInfos = ($attrs->{refreshDelete} || $attrs->{refreshPresent})) {
      my $refreshState = ($attrs->{refreshDelete} ? 'refreshDelete' : 'refreshPresent');
      my $refreshDone = $refreshInfos->{refreshDone};

      if ($refreshInfos->{cookie}) {
        $cookie = $refreshInfos->{cookie};
        if ($info) {
          print "INFO:  Refresh State = $refreshState, Refresh Done = $refreshDone, Cookie = $cookie\n";
          # updating cookie file if it's different to the old one
	  print "cookie: $cookie\n";
          unless(cookie() eq $cookie){
	    cookie($cookie);
          }
        } # End of if ($info)
      } 
      else {
        if ($info) {
          print "INFO:  Refresh State = $refreshState, Refresh Done = $refreshDone, Cookie = none received\n";
        } # End of if ($info)
      } # End of if ($refreshInfos->{cookie})

    } # end elsif(my $refreshInfos = ($attrs->{refreshDelete} || $attrs->{refreshPresent}))
  

    elsif(my $syncIdSetInfos = $attrs->{syncIdSet}) {

    # Here we receive the information about deletions on the OpenLDAP server, that happend during the time
    # this script was offline.
    # Before the deletion of the entry with the uid = 3700000, we have the 
    # dn: uid=3700000,ou=people,ou=backup,ou=service,dc=tombstone,dc=ch
    # uid : 3700000
    # entryUUID : c3d1d414-1bd7-102f-88db-91a3755d6d2b
    # After the deletion (when this script was offline), we get the following Intermediate SyncInfo Messages:
    # entryUUID = c3d1d4141bd7102f88db91a3755d6d2b ("uid=3700000,ou=people,ou=backup,ou=service,dc=tombstone,dc=ch")
    # entryUUID = c3d2f48e1bd7102f88dc91a3755d6d2b ("cn=3700000,ou=group,ou=backup,ou=service,dc=tombstone,dc=ch")
    # This means, we lost the deletion information, because currently, it's impossible to make a connection 
    # from the entryUUID to the dn. To avoid this, we would need to keep a list of all the entryUUIDs.

    
      logger("warning","We lost a deletion.");
    
      my $refreshDeletes = $syncIdSetInfos->{refreshDeletes};
      if ($syncIdSetInfos->{cookie}) {
        $cookie = $syncIdSetInfos->{cookie};
        cookie($cookie);
        if ($info) {
          print "INFO:  Refresh Deletes = $refreshDeletes, Received cookie from syncIdSet = $cookie\nINFO:  setting cookie\n";
        } # End of if ($info)
      } 
      else {
        if ($info) {
          print "INFO:  Refresh Deletes = $refreshDeletes, No cookie received form syncIdSet\n";
        } # End of if ($info)
      } # End of if ($syncIdSetInfos->{cookie})

    # list operational attributes entryUUID (RFC-4530: http://www.rfc-editor.org/rfc/rfc4530.txt
      my @entryUUIDs;
      my $entryUUIDArrayLength = $#{$syncIdSetInfos->{syncUUIDs}};
      for(my $counter = 0; $counter <= $entryUUIDArrayLength; $counter++) {
        if($info){
          print "INFO:  entryUUID = ".unpack("H*",$syncIdSetInfos->{syncUUIDs}[$counter])."\n";
        }
        push(@entryUUIDs,unpack("H*",$syncIdSetInfos->{syncUUIDs}[$counter]));
      } # End of for(my $counter = 1; $counter <= $entryUUIDArrayLength; $counter++)
      my $UUIDs=join("\n",@entryUUIDs);
      my $mail_message="Deletion lost!!\nCannot contact the following entryUUID(s):\n$UUIDs\nEither remove the entry/entries manually or ignore this message.";
      my $log_message="Deletion lost! Cannot contact the following entryUUID(s): @entryUUIDs. Either remove the entry/entries manually or ignore this message.";
      logger("warning",$log_message);
      if($modus=~/ldap/i){
        sendMail($mail_message,"$service-$type","warning");
      }
    } # end elsif(my $syncIdSetInfos = $attrs->{syncIdSet})
  } # end elsif($controls[0] and $controls[0]->isa('Net::LDAP::Control::SyncDone'))

  elsif($message->code) {
    if ($message->code == 1) {

      my $new_connection=connectToBackendServer("reconnect",1);

      if($new_connection){
        logger("info","Established new connection to the server. Starting a new search now.", "$service-$type");
	startPersistantSearch($new_connection);
      }
      else{
        logger("error","Communication error, no connection to server (could not reconnect). Please restart the daemon for $service.");
	exitSearch();
      }
      
    } 
    elsif ($message->code == LDAP_USER_CANCELED) {
      logger("info","persistantSearchCallback() -> Exit code received, returning", "$service-$type");
      return;
    } 
    elsif ($message->code == LDAP_SYNC_REFRESH_REQUIRED) {
      logger("info", "Refresh required");
    } else {
        # We don't want to die.
        if ($info) {
          print "INFO: \$message->code = " . $message->code . "', \$message->error = `" . $message->error . "\n";
        } # End of if ($info)        
    }
  } else {
    logger("info","persistantSearchCallback method receieved something unexpected, script will now delete the cookie file and restart search (if not already done).");
  }


} # end sub persitantSearchCallback


sub exitSearch{

  # We have do stop the persistant search due to an error

  # Unlock the servince and disconnect all connections
  $Provisioning::lock->unlock("/var/run/provisioning_$service");
  gatewayDisconnect();
  disconnectFromServer();
  exit 1;

}


sub modifyAttribute{

  # TODO atomar replace for more than just one attribute!

  my ($entry, $attribute, $new_value, $connection)=@_;

  # If no connection is passed, take the default one
  unless($connection){
    $connection=$ldap_connection;
  }

  my $error=0;

  # get the entreis DN
  my $dn=getValue($entry,'DN');

  # modify the given attribute for the given DN
  my $modify = $connection->modify( $dn, replace => { $attribute => $new_value } );

  # Test whether the modification was successful, if not write an error message...
  if($modify->code() != LDAP_SUCCESS){
    my $errorMessage= "Cannot modify (set $attribute to $new_value): ".$dn.
                      " Error: ".$modify->error;
    logger("error",$errorMessage);
    $error=1;
  }
  # ... otherwise write an info message
  else{
    logger("debug","$attribute in Object \"$dn\" replaced with: $new_value");
  }

  return $error;
}










# calling without args means: get,
# giving an argument means: set
sub cookie {
  
  my ($cookie) = @_;
  #my $cfg=new Config::IniFiles( -file => '/home/pat/Documents/stepping-stone/provisioning/Testing/persistantSearch/persist.conf');
  
  my $cookie_file=$cfg->val('Database','COOKIE_FILE');

  # if $cookie is defined it means that we have to set the cookie
  if ($cookie){
    # TODO logger("$service-$type", $debug, "provision", "no-user", "info", "set cookie to $cookie"); 
    # write the cookie string to the cookie file
    unless($update_cookie){
      return
    }
    if(!open(COOKIE_FILE, ">$cookie_file")){
      # if we can't open the cookie file for writting, write an error-message ... 
      logger("error", "cannot open $cookie_file for writing $!");  
    }
    else{
      # .. otherwise write the cookie stirng to the cookie file
      print COOKIE_FILE $cookie;
      close(COOKIE_FILE);
      if($?!=0){
        logger("error","Could not update cookie file! Next search will produce same result as this one. You could update the cookie file manually:\n open the file: $cookie_file and replace the existing stirng with the following:\n$cookie");
      }
      else{
        logger("debug","cookie file successfully updated");
      }
      $update_cookie=0;
    }    
  }
  # if $cookie is not defined, it means that we have to get the cookie
  elsif(!$cookie){
    # TODO logger("$service-$type", $debug, "provision", "no-user", "info", "getting cookie");  
    # check whether the cookie_file exists and has a non-zero size (means there
    # is already something stored in the file)
    if(-e $cookie_file){
      if(-s $cookie_file>0){
        # if we have something in the cookie file, open it and read the cookie 
        # sting or wirte a error-message on failure.
        if (!open(COOKIEFILE, $cookie_file)){
          logger("warning", "cannot open cookie file for reading: $!");
        }
        else{
          $cookie=<COOKIEFILE>;
          close(COOKIEFILE);
        }
      }
      # if the cookie file does not exist or has a zero size, we have to 
      # initialize the cookie (normally this should only 
      else{
        logger("debug", "$cookie_file has a zero size and will now be set on default value (normal if the script (daemon) has just been started)");
        $cookie=$cfg->val('Database','DEFAULT_COOKIE');
      } # end if(-s $cookieFile>0) 
    }
    else{
      logger("debug", "$cookie_file does not exist, it will be created and set on default value (normal if the script (daemon) has just been started)");
      $cookie=$cfg->val('Database','DEFAULT_COOKIE');
    }
  } # end if($cookie)

  return $cookie;

  
} # End of sub cookie	






sub get_entryCSN{

  # extract the CSN from the cookie file

  my $CSN = shift;

  # the format of the entryCSN depends on the openLDAP version so we have to 
  # seperate here

  # version xxxx and older
  if($CSN && $CSN=~/csn=\d{14}Z#\d{6}#\d\d#\d{6},rid=\d{3}/){
    $CSN=~ /\d{14}Z#\d{6}#\d\d#\d{6}/;
    $CSN= $&;
  }
  # version xxx and newer
  elsif($CSN && $CSN=~/rid=\d{3},csn=\d{14}.\d{6}Z#\d{6}#\d{3}#\d{6}/){
    $CSN=~/\d{14}.\d{6}Z#\d{6}#\d{3}#\d{6}/;
    $CSN=$&;
  }
  # if the cookie file is empty, we have an undefined CSN
  else{
    # in selfcare mode we NEED a CSN so we set one to the 1. Januray 2000
    if($modus=~/selfcare/i || $modus=~/combined/i){
      $CSN="20000101000000.000000Z#000000#000#000000";
    }
    else{
      $CSN=undef;
    }# end if($modus=~/selfcare/i)
  }# end if($CSN && $CSN=~/csn=\d{14}Z#\d{6}#\d\d#\d{6},rid=\d{3}/)

  return $CSN;

}


1;

__END__

=back

=head1 Version

Created 2010-09-05 by Pat Kläy <pat.klaey@stepping-stone.ch>

=over

=item 2010-09-05 Pat Kläy created.

=item 2012-09-04 Pat Kläy modified

Added the 'started' case for the sstProvisioningMode in the selfcare mode

=back

=cut

