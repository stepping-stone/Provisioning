package Provisioning::Groupware::OX;

# Copyright (C) 2014 stepping stone GmbH
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

use Config::IniFiles;
use Net::LDAP;
use Net::LDAP::Util qw(ldap_explode_dn);
use Module::Load;

use Provisioning::Log;

require Exporter;

=pod

=head1 Name

OX.pm

=head1 Description

This module gets the information from the master script which entry had changed. It processes the given entry and will set up the necessary module with the appropriate method. 

=head1 Methods

=cut


our @ISA = qw(Exporter);

our %EXPORT_TAGS = ( 'all' => [ qw(processEntry) ] );

our @EXPORT_OK = ( @{ $EXPORT_TAGS{'all'} } );

our @EXPORT = qw(processEntry);

our $VERSION = '0.01';

#$|=1;

# get the service for ??
my $service=$Provisioning::cfg->val("Global","SERVICE");

# get the config-file from the master script.
our $service_cfg=$Provisioning::cfg;

# load the nessecary modules
load 'Provisioning::Groupware::OX::OXContext', ':all';
load 'Provisioning::Groupware::OX::OXAccount', ':all';
load 'Provisioning::Groupware::OX::OXPermission', ':all';
load "$Provisioning::server_module", ':all';



sub processEntry{

=pod

=over

=item processEntry($entry,$state)

This mehtod processes the given entry. It takes as input parameter the entry,
which should be processed, and it's state (add, modify or delete). First thing
done is to check what type the entry is, therefore the entrys DN is parsed. 
According to the entrys type and the state, all nessecary informations are 
collected using the Backend library specified in the configuration file. Then
the appropriate action (subroutine) is set up.

=back

=cut

  my ($entry,$state)=@_;

  my $error=0;
  my $DN=getValue($entry,'DN');
  my $context_ID;
  

  my $object_class=join(" ",getValue($entry,'objectClass'));


  # Test whether we have to process this entry, if the objectClass is not sstGroupwareOX
  # or sstGroupwareOXModule then return, otherwise process the entry
  unless(($object_class =~ /sstGroupwareOX/) or ($object_class =~ /sstGroupwareOXModule/)){
    logger("info","This entry ($DN) is not a OX entry, script will not process it!");
    return $error;
  }

  # if the entry is a sstMailDomainAlias then also return (no change is made in OX)
  if($object_class =~ /sstMailDomainAlias/){
    logger("info","Entry is a sstMailDomainAlias, script will not process it.");
    return $error
  }


  # get the contextid from the attribute sstGroupwareOXContextID
  if(getValue($entry,'sstGroupwareOXContextID')){
    $context_ID=getValue($entry,'sstGroupwareOXContextID');
  }
  else{
    logger("error","Could not get context-ID, attribute sstGroupwareOXContextID is not defined in $DN");
    $error=1;
    return $error;
  }

 

  # get the objectClass and perform the correspondig action:
 
  if($object_class =~ /sstMailDomain/){
    
    logger("info","Entry is a sstMailDomain");

    # if yes let's create the context
    $error=handleContext($context_ID,getValue($entry,'sstMailDomain'),'createcontext') if $state eq "add";
    $error=removeContext($context_ID,getValue($entry,'sstMailDomain')) if $state eq "delete";
    $error=handleContext($context_ID,getValue($entry,'sstMailDomain'),'changecontext') if $state eq "modify";
        
  } # end case sstMailDomain

  elsif($object_class=~/sstMailAlias/){
    logger("info","Entry is a sstMailAlias");

    # if its a sstMailAlias, add it... 
    my $hash_DN=ldap_explode_dn($DN);
    if($hash_DN->[1]{"SSTMAILDOMAIN"}){

      my $domain_name=$hash_DN->[1]{"SSTMAILDOMAIN"};
      $error=addMailAlias($entry,$domain_name,$context_ID) if $state eq "add"; #IMPLEMENTED
      $error=modifyMailAlias($entry,$domain_name,$context_ID) if $state eq "modify"; #IMPLEMENTED
      $error=deleteMailAlias($entry,$domain_name,$context_ID) if $state eq "delete"; #IMPLEMENTED
    }
    # if there's no sstMailDomain at second position we 
    # have a wrong DN.
    else{
      logger("error","Cannot extract domain_name ".
            "from DN: $DN.");
      $error=1;
      return $error;
    }  
  } # end case sstMailAlias

  elsif($object_class=~/sstMailAccount/){

    logger("info","Entry is a sstMailAccount");

    if(getValue($entry,'sstGroupwareOXAccountType')=~/user/i){
      logger("debug","sstMailAccount is a user");

      # ... a normal user ...

      $error=handleMailAccount($DN,$context_ID,
				getValue($entry,'givenName'),
				getValue($entry,'sn'),
				getValue($entry,'sstMail'),
				getValue($entry,'preferredLanguage'),
				getValue($entry,'sstMailAccountFolderDrafts'),
				getValue($entry,'sstMailAccountFolderSent'),
				getValue($entry,'sstMailAccountFolderSpam'),
				getValue($entry,'sstMailAccountFolderTrash')) 
				if $state eq "add";#IMPLEMENTED

      $error=handleMailAccount($DN,$context_ID,
				getValue($entry,'givenName'),
				getValue($entry,'sn'),
				getValue($entry,'sstMail'),
				getValue($entry,'preferredLanguage'),
				getValue($entry,'sstMailAccountFolderDrafts'),
				getValue($entry,'sstMailAccountFolderSent'),
				getValue($entry,'sstMailAccountFolderSpam'),
				getValue($entry,'sstMailAccountFolderTrash'),
				'change') if $state eq "modify";#IMPLEMENTED

      $error=deleteMailAccount($context_ID,getValue($entry,'sstMail'),$entry) if $state eq "delete";
	
    } # end (getValue($entry,'sstGroupwareOXAccountType')=~/user/i)
    elsif(getValue($entry,'sstGroupwareOXAccountType')=~/resource/i){

      logger("debug","sstMailAccount is a resource");

      # ... or a mail-resource
      $error=handleResourceAccount($context_ID,
				getValue($entry,'sstGroupwareOXResourceName'),
				getValue($entry,'sstGroupwareOXResourceDisplayName'),
				getValue($entry,'sstMail'),
				getValue($entry,'sstGroupwareOXResourceDescription')) 
				if $state eq "add"; #IMPLEMENTED

      $error=handleResourceAccount($context_ID,
				getValue($entry,'sstGroupwareOXResourceName'),
				getValue($entry,'sstGroupwareOXResourceDisplayName'),
				getValue($entry,'sstMail'),
				getValue($entry,'sstGroupwareOXResourceDescription'),
				'change') 
				if $state eq "modify"; #IMPLEMENTED

      $error=deleteResourceAccount($context_ID,getValue($entry,'sstGroupwareOXResourceName')) 
	     if $state eq "delete"; #IMPLEMENTED


    } # end elsif(getValue($entry,'sstGroupwareOXAccountType')=~/resource/i)
    else{

      # if it's not a 
      logger("error","Search returned an object where sstGroupwareOXAccountType is not User not resource. Script stops here.\n(users DN: $DN)");
      $error=1;
      return $error;
    } # end else

  }# end case sstMail
  elsif($object_class=~/sstGroupwareOXModule/){

    logger("info","Entry is a sstGroupwareOXModule");

    if(getValue($entry,'sstGroupwareOXModule') eq "BusinessMobility"){
      logger("debug","sstGroupwareOXModule is BusinessMobility");

      # extract the mail adress form the DN->value
      # of sstMail. Methode ldap_explode_dn writes
      # an array of hashes where each key-value
      # pair is one DN-Level. (Keys are upper-
      # case.)
      my $hash_DN=ldap_explode_dn($DN);
      if($hash_DN->[1]{"SSTMAIL"}){
        my $mailadress=$hash_DN->[1]{"SSTMAIL"};
	$error=Permission('BusinessMobility',$context_ID,$mailadress,'set') if $state eq "add"; #IMPLEMENTED
	$error=Permission('BusinessMobility',$context_ID,$mailadress,'deny') if $state eq "delete"; # IMPLEMENTED
      }

      # if theres no sstMail at second position we 
      # have a wrong DN.
      else{
        logger("error","Cannot extract mailadress ".
	       "from DN: $DN.");
        $error=1;
	return $error;
      }
    }
    elsif(getValue($entry,'sstGroupwareOXModule') eq "Webmail4Free"){

      logger("debug","sstGroupwareOXModule is Webmail4Free");

      my $hash_DN=ldap_explode_dn($DN);
      if($hash_DN->[1]{"SSTMAIL"}){

	my $mailadress=$hash_DN->[1]{"SSTMAIL"};
	$error=Permission('Webmail4Free',$context_ID,$mailadress,'set') if $state eq "add"; #IMPLEMENTED
	$error=Permission('Webmail4Free',$context_ID,$mailadress,'deny') if $state eq "delete"; # IMPLEMENTED
      }

      # if theres no sstMail at second position we 
      # have a wrong DN.
      else{
        logger("error","Cannot extract mailadress ".
	       "from DN: $DN.");
	$error=1;
	return $error;
      }
  
    }
    elsif(getValue($entry,'sstGroupwareOXModule') eq "Resource"){

      logger("debug","sstGroupwareOXModule is Resource");

      my $hash_DN=ldap_explode_dn($DN);
      if($hash_DN->[1]{"SSTMAIL"}){

	my $mailadress=$hash_DN->[1]{"SSTMAIL"};

        # extract resource name from mailadress
        $mailadress=~/@/;
        my $resource_name=$`;
	$error=Permission('Resource',$context_ID,undef,'set',$resource_name) if $state eq "add"; #IMPLEMENTED
	$error=Permission('Resource',$context_ID,undef,'deny',$resource_name) if $state eq "delete"; # IMPLEMENTED
      }

      # if theres no sstMail at second position we 
      # have a wrong DN.
      else{
        logger("error","Cannot extract mailadress ".
	       "from DN: $DN.");
	$error=1;
	return $error;
      }
  
    }
    else{
      logger("error","Search returned object sstGroupwareOXModule but attribute is not Webmail4Free, BusinessMobility or Resource. Script stops here. (users DN: $DN)");
      $error=1;
      return $error;
    }
  }# end case sstGroupwareOXModule
  else{
    logger("error","Search returned an undefined object. Object DN: $DN");
    $error=1;
    return $error;
  }# end else


  return $error;


} # end sub processEntry



1;

__END__

=pod

=head1 Version

=over

=item 2010-08-15 Pat Kläy created.

=item 2010-09-10 Pat Kläy modified.

The little methods put into seperate modules. The only method now is processEntry()

=back 

=cut
