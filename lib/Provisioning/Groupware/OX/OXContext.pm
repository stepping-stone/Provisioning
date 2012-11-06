package Provisioning::Groupware::OX::OXContext;

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

use warnings;
use strict;

use Module::Load;

use Config::IniFiles;
use Text::CSV::Encoded;
use IO::String;

require Exporter;

our @ISA = qw(Exporter);

our %EXPORT_TAGS = ( 'all' => [ qw(handleContext removeContext checkOXContext) ] );

our @EXPORT_OK = ( @{ $EXPORT_TAGS{'all'} } );

our @EXPORT = qw(handleContext removeContext checkOXContext);

our $VERSION = '0.01';


load "Provisioning::TransportAPI::$Provisioning::TransportAPI", ':all';
load "Provisioning::Log", ':all';


my $service_cfg = $Provisioning::Groupware::OX::service_cfg;

my $OX_master_user = $service_cfg->val('Service','MASTER_USER') || undef;
my $OX_master_password = $service_cfg->val('Service','MASTER_PWD') || undef;
my $OX_admin_password = $service_cfg->val('Service','ADMIN_PWD') || undef;
my $OX_admin_user = $service_cfg->val('Service','ADMIN_USER') || undef;

my $ox_connection=\$Provisioning::gateway_connection;

my @args;

# initalize the CSV parser
my $csv= Text::CSV::Encoded->new();

sub checkOXContext{

  my ($context_name,$testscript)=@_;

  if(!$OX_master_user || !$OX_master_password || !$context_name){
    logger("error","Cannot check context: not enough arguments:\nOX-master:".
           "$OX_master_user:\nOX-master-password:$OX_master_password:\ncontext-name:".
           "$context_name:\nValues should be between the \":\"");
    return "error";
  }


  my @check_args=("/opt/open-xchange/sbin/listcontext",
	    "--adminuser $OX_master_user",
	    "--adminpass $OX_master_password",
	    "-s $context_name",
            "--csv");

  my $csv_string = checkContext($$ox_connection,@check_args);

  return "error" if $csv_string eq "error";
  return $csv_string if $testscript;

  # convert the captured output string into a IO stream 
  my $io=IO::String->new($csv_string);
  my $is_present;

  # parse the recieved CSV data
  while(my $row = $csv->getline ($io)){
    # and extract the 7th element -> name.
    $is_present=$row->[6];
  }


  if( defined($is_present) && $is_present =~ /$context_name/ ){
    return $is_present;
  }
  else{
    return undef;
  }
  

} # end sub checkOXContext









sub handleContext{
  # creates/modifies a (new) OX-Context with the above loaded Transport-API

  my ($context_ID, $context_name, $status)=@_;

  my $error=0;

  logger("info","Creating/modifing context $context_name");

  # check if all the necessary vars are defined. If yes we can create the
  # context, if not we have to write a log message and stop here.
  if(!$OX_master_user || !$OX_master_password || !$context_ID || !$context_name || !$OX_admin_password){
    logger("error","had not enough arguments to create context. The arguments are:\nox-master-user=:$OX_master_user:\nox-master-password=:$OX_master_password:\ncontext-ID=:$context_ID\ncontext-name=:$context_name:\nox-admin-password=:$OX_admin_password:\nox-admin-user=:$OX_admin_user:\nValues shoud be between the \":\"");
    $error=1;
  }
  else{
    unless(my $context_is_present=checkOXContext($context_name)){

      @args=("/opt/open-xchange/sbin/$status",
	     "--contextid $context_ID",
 	     "--contextname $context_name",
  	     "--adminuser $OX_master_user", 
  	     "--adminpass $OX_master_password",
  	     "--username $OX_admin_user",
  	     "--displayname \"Support stepping stone GmbH\"",
  	     "--givenname Support",
 	     "--surname \"stepping stone GmbH\"",
  	     "--password $OX_admin_password",
 	     "--email support\@stepping-stone.ch",
 	     "--language en_UK",
 	     "--timezone Europe/Zurich",
  	     "--quota 1024",
             "--nonl",);

      $error=executeCommand($$ox_connection,@args);

      if($error){
        logger("error", "Could not create/modify OX-Context $context_name. Script will stop here.");
      }
      else{
        logger("info","Context $context_name successfully created/modified.","send");
      } #end if($error)

    }
    else{
      
      if($context_is_present eq "error"){
        logger("error","Context could not be checked. View syslog or mailbox for further information");
        $error=1;
      }
      else{
        logger("warning","Context $context_name already exists");
      }# end if($context_is_present eq "error")

    } # end if(checkOXContext())
  }

  # if the context was successfully (!!) created 0 is returned, otherwise 1 is
  # returned. 
  return $error;
}






sub removeContext{

  my ($context_ID,$context_name)=@_;
  
  my $error=0;

  # check if all the necessary vars are defined. If yes we can create the
  # context, if not we have to write a log message and stop here.
  if(!$OX_master_user || !$OX_master_password || !$context_ID || !$context_name){
    
  logger("error","had not enough arguments to create context. The arguments are:\nox-master-user=:$OX_master_user:\nox-master-password=:$OX_master_password:\ncontext-ID=:$context_ID\ncontext-name:$context_name:\nValues shoud be between the \":\"");
    $error=1;
  }
  else{

    if(my $context_is_present=checkOXContext($context_name)){

      @args = ("/opt/open-xchange/sbin/deletecontext",
	       "--adminuser $OX_master_user",
	       "--adminpass $OX_master_password", 
	       "--contextid $context_ID",
               "--nonl",);


      $error=executeCommand($$ox_connection,@args);

      if($error){
        logger("error", "Could not delete OX-Context $context_name. Script will stop here.");
      }
      else{
        logger("info","Context $context_name successfully deleted.","send");
      } #end if($error)
    } 
    else{
     
      if($context_is_present eq "error"){
        logger("error","Context could not be checked. View syslog or mailbox for further information");
        $error=1;
      }
      else{
        logger("warning","Context $context_name does not exists, cannot delete a non-existing context.");
      }# end if($context_is_present eq "error")


    } # end if(checkOXContext)

  }

  return $error;


}# end sub removeContext



# end module OXContext



1;

__END__
