package Provisioning::Groupware::OX::OXPermission;

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

require Exporter;

our @ISA = qw(Exporter);

our %EXPORT_TAGS = ( 'all' => [ qw(Permission) ] );

our @EXPORT_OK = ( @{ $EXPORT_TAGS{'all'} } );

our @EXPORT = qw(Permission);

our $VERSION = '0.01';

$|=1;


load "Provisioning::TransportAPI::$Provisioning::TransportAPI", ':all';
load "Provisioning::Log", ':all';
load "Provisioning::Groupware::OX::OXAccount", ':all';

my $service_cfg = $Provisioning::Groupware::OX::service_cfg;


my $OX_admin_pwd = $service_cfg->val('Service','ADMIN_PWD') || undef;
my $OX_admin_user = $service_cfg->val('Service','ADMIN_USER') || undef;

my $ox_connection = \$Provisioning::gateway_connection;


sub Permission{

  my ($permission,$context_ID,$mailadress,$state,$resource_name)=@_;

  my $error=0;
  my $username;

  if($mailadress){
    # get username from mailadress --> username is the mailadress without
    # @domain.tld
    $mailadress=~/@/;
    $username=$`;
  }


  # check if all the necessary parameters are defined
  if(!$permission || !$context_ID || (!$username && !$resource_name)){

    logger("error","Cannot continue and set :$permission: permission: not enough arguments:\ncontext-ID:$context_ID:\nusername:$username:\nresource_name:$resource_name:(empty for user)\n(for resource username is empty but not resource name!)\nValues should be between the \":\"");
    $error=1;
    return $error;

  }

  # if everything is ok, check if the user or resource is present in the given context...
  my $present;
  my $display_name;
  $present=checkOXUser($context_ID,$username) if $username;
  $display_name=$username if $username;
  $present=checkOXResource($context_ID,$resource_name) if $resource_name;
  $display_name=$resource_name if $resource_name;

  if($present){

      if($present eq "error"){
        logger("warning","Could not check the presence of $username".
               "$resource_name, error in the listuser command");
        return $error=1;
    }

    #.. if yes, set the permission either to ...
    if($permission=~/BusinessMobility/i){
      # .. BusinessMobility...
      logger("info","$state $permission permission for user $mailadress in context $context_ID");
      $error=setPermission($$ox_connection,'permissionBusinessMobility',$context_ID,$username,$OX_admin_user,$OX_admin_pwd,$state);
    } #end if ($permission=~/BusinessMobility/i)
    elsif($permission=~/Webmail4Free/i){
      logger("info","$state $permission permission for user $mailadress in context $context_ID");
      # ... or Webmail4Free ...
      $error=setPermission($$ox_connection,'permissionWebmail4Free',$context_ID,$username,$OX_admin_user,$OX_admin_pwd,$state);
    } # end elsif($permission=~/Webmail4Free/i
    elsif($permission=~/Resource/i){
      logger("info","$state $permission permission for resource $resource_name in context $context_ID");
      # ... or Webmail4Free ...
      $error=setPermission($$ox_connection,'permissionResource',$context_ID,$resource_name,$OX_admin_user,$OX_admin_pwd,$state);
    } # end elsif($permission=~/Resorce/i
    else{
      # ... or write an error-message if $permission is unknown
      logger("error","Unknown permission: $permission. Cannot set permission.");
      $error=1;
      return $error; 
    }# end else
  } # end if (checkUser($context_ID,$OX_admin_user,$OX_admin_pwd,$username)
  else{

    # ... if not, wirte an error-message.
    logger("error","user $username does not exist in context $context_ID. Cannot set $permission permission. Script will stop here.");
    $error=1;
  }

  return $error;

} # end sub Permission







1;

__END__
