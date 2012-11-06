package Provisioning::Groupware::OX::OXAccount;

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
use Crypt::GeneratePassword qw(chars);

require Exporter;


=pod

=head1 Name

OXAccount.pm

=head1 Description

This module is set up, if the entry the OX.pm recieved is a mailaccount. All
methods to handle a mailaccount are implemented here.  

=head1 Methods

=cut


our @ISA = qw(Exporter);

our %EXPORT_TAGS = ( 'all' => [ qw(deleteResourceAccount handleResourceAccount checkOXUser checkOXResource handleMailAccount deleteMailAccount searchAliases addMailAlias modifyMailAlias deleteMailAlias) ] );

our @EXPORT_OK = ( @{ $EXPORT_TAGS{'all'} } );

our @EXPORT = qw(hanndleResourceAccount checkOXResource handleMailAccount deleteMailAccount searchAliases checkOXUser addMailAlias modifyMailAlias deleteMailAlias);

our $VERSION = '0.01';

$|=1;

my $TransportAPI = "Provisioning::TransportAPI::$Provisioning::TransportAPI";

# load the necessary modules
load "$Provisioning::server_module", ':all';
load "Provisioning::Log", ':all';
load "$TransportAPI", ':all';


 
# initialize the necessary vars.
our $service_cfg = $Provisioning::Groupware::OX::service_cfg;

my $OX_admin_password = $service_cfg->val('Service','ADMIN_PWD') || undef;
my $OX_admin_user = $service_cfg->val('Service','ADMIN_USER') || undef;

# Create a pointer to the global ox_connection
my $ox_connection = \$Provisioning::gateway_connection;

my @args;

# initalize the CSV parser
my $csv= Text::CSV::Encoded->new({encoding  => "utf8"});

###############################################################################
##############                      General                          ##########
###############################################################################



sub checkOXUser{

=pod

=over

=item checkOXUser

This method generates the necessary commands for the ox server to list a single
user. It then sets up the checkUser method from the TransportAPI module which
executes this command. From the return value the method can now calculate
whether the user already exist in the specified context.

=back

=cut

  my ($context_ID,$username,$testscript)=@_;

  my @check_args=("/opt/open-xchange/sbin/listuser",
           	  "--contextid '$context_ID'", 
           	  "--adminuser '$OX_admin_user'",
           	  "--adminpass '$OX_admin_password'",
           	  "-s '$username'",
           	  "--csv");


  my $csv_string=checkUser($$ox_connection,@check_args);

  return "error" if $csv_string eq "error";
  return $csv_string if $testscript;

  # convert the captured output string into a IO stream 
  my $io=IO::String->new($csv_string);
  my $is_present;

  # parse the recieved CSV data
  while(my $row = $csv->getline ($io)){
    # and extract the 1st element -> name.
    $is_present=$row->[0];
  }

  # if the name we get from the csv is the same as we were looking for, return
  # the value, otherwise return undef (actually return the result of the query)
  if($is_present=~/^$username$/i){
    logger("debug","user $username is present");
    return $is_present;
  }
  else{
    logger("debug","user $username is not present");
    return undef;
  }


} # end sub checkOXUser



sub checkOXResource{

=pod

=over

=item checkOXResource

This method generates the necessary commands for the ox server to list a single
resource. It then sets up the checkUser method from the TransportAPI module which
executes this command. From the return value the method can now calculate
whether the resource already exist in the specified context.

=back

=cut

  my ($context_ID,$resource_name,$testscript)=@_;

  # generating the necessary commands to list a single resource
  my @check_args=("/opt/open-xchange/sbin/listresource",
           	  "--contextid '$context_ID'", 
           	  "--adminuser '$OX_admin_user'",
           	  "--adminpass '$OX_admin_password'",
           	  "-s '$resource_name'",
           	  "--csv");

  my $csv_string=checkUser($$ox_connection,@check_args);

  return "error" if $csv_string eq "error";
  return $csv_string if $testscript;

  # convert the captured output string into a IO stream 
  my $io=IO::String->new($csv_string);
  my $is_present;

  # parse the recieved CSV data
  while(my $row = $csv->getline ($io)){
    # and extract the 1st element -> name.
    $is_present=$row->[1];
  }


  # if the name we get from the csv is the same as we were looking for, return
  # the value, otherwise return undef (actually return the result of the query)
  if($is_present=~/$resource_name/i){
    logger("debug","resource $resource_name is present");
    return $is_present;
  }
  else{
    logger("debug","resource $resource_name is not present");
    return undef;
  }


} # end sub checkOXResource



###############################################################################
##############                       User                            ##########
###############################################################################


sub handleMailAccount{

=pod

=over

=item handleMailAccount

This method checks first whether all necessary information is available and
then generates the commands according to whether a mail account should be added
or modified. Then the executeCommands form the TransportAPI module is called
with the generated commands as parameter. The return value of the
executeCommands indicates if the commands were successful or not. The method
returns then success of failure.

=back

=cut

  my ($DN,$context_ID,$givenname,$surname,$mailadress,$language,$drafts,$sent,$spam,$trash,$change)=@_;

  my $error=0;
  my $aliases;


  $language=~s/-/_/;
  $language=~s/CH/DE/;

  # test wether the user is added with intent or not
  unless($change){
    logger("info","Creating mailaccount for user $mailadress in context $context_ID");
  }
  else{
    logger("info","Changing mailaccount for user $mailadress in context $context_ID");
  }


  # generates a random password 8 characters long
  my $random_password=chars(8,8);

  # get username from mailadress --> username is the mailadress without
  # @domain.tld
  $mailadress=~/@/;
  my $username=$`;

  # check if all the necessary parameters are defined ...
  if(!$context_ID || !$givenname || !$surname || !$mailadress || !$language || !$random_password || !$username || !$OX_admin_password || !$OX_admin_user || !$drafts || !$sent || !$spam || !$trash){

    # .. if not write an error message where we can see which one is undef ...
    logger("error","had not enough arguments to create/modify a mailaccount.\nContext-ID :$context_ID:\ngivenname :$givenname:\nsurname :$surname:\nmailadress :$mailadress:\nlanguage :$language:\nrandom-password :$random_password:\nusername :$username:\nOX-admin-password :$OX_admin_password:\nOX-admin-user :$OX_admin_user\nDraft-folder name :$drafts:\nSent-folder name :$sent:\nSpam-folder name :$spam:\nTrash-folder name :$trash:\nThe values should be between the \":\"");
    $error=1;
  }

  else{

      # create default command for adding a user
      @args=("--contextid '$context_ID'",
      	     "--adminuser '$OX_admin_user'",
      	     "--adminpass '$OX_admin_password'",
      	     "--username '$username'",
      	     "--displayname '$givenname $surname'",
     	     "--givenname '$givenname'",
     	     "--surname '$surname'",
  	     "--language '$language'",
   	     "--timezone 'Europe/Zurich'",
   	     "--mail_folder_drafts_name '$drafts'",
   	     "--mail_folder_sent_name '$sent'",
   	     "--mail_folder_spam_name '$spam'",
   	     "--mail_folder_trash_name '$trash'",
             "--nonl",
	     );


    #...if everything is ok check if the user is already present in the context
    unless(my $user_is_present=checkOXUser($context_ID,$username)){ 

      # if he's not present, lets create the account...
      logger("debug","user $username is not present in context $context_ID");
      
      unshift(@args,"/opt/open-xchange/sbin/createuser");
      push(@args,"--password '$random_password'");
      push(@args,"--email $mailadress");

      # but check first if the user has aliases
      if($aliases=searchAliases($DN,$mailadress)){
        push(@args,"--aliases $aliases");
      }

      logger("debug","Creating OX-Mailaccount for user $mailadress"); 

      $error=executeCommand($$ox_connection,@args);

      if($error){
        logger("error","Could not create mailaccount for user $mailadress in context $context_ID.");
      }
      else{
        logger("info","Mailaccount for user $mailadress in context $context_ID successfully created.","send");
      } # end if($error)

    } # end unless()
    else{

      # check if there was an error while checking the user
      if($user_is_present eq "error"){
      
        logger("error","User could not be checked for presence, view syslog or mailbox for further information. Script stops here.");
        $error=1;
        return $error;
      }
      else{

        # otherwise log that he's already present. 
        logger("debug","user $username is present in context $context_ID");
      
        unless($change){
          logger("debug","user $username has already a mailaccount in context $context_ID. Script will update the user.");
        }
    
        # add the changeuser command to the standart commands
        unshift(@args,"/opt/open-xchange/sbin/changeuser");

        # search for aliases for the user. 
        $aliases=searchAliases($DN,$mailadress);

        # if aliases were found, add them to the commands to be executed. 
        if($aliases){
          push(@args,"--aliases $aliases");
        } # end if($aliases)

        $error=executeCommand($$ox_connection,@args);

        if($error){
          logger("error","Could not change mailaccount for user $mailadress in context $context_ID.");
        }
        else{
          logger("info","Mailaccount for user $mailadress in context $context_ID successfully changed.","send");
        } # end if($error)

      } # end if($user_is_present eq "error")

    } # end else-unless(checkUser(@check_args))

  } # end if(!$context_ID || !...)

  # if the account was successfully (!!) created/modified 0 is returned, otherwise 1.
  return $error;

} # end sub handleMailAccount





sub deleteMailAccount{

=pod

=over

=item deleteMailAccount

This method checks first whether all necessary information is available and
then generates the commands to delete a mail account. Then the executeCommands
form the TransportAPI module is called. The return value of this method
indicates if the commands were successful or not. If yes, the mailbox on the
filesystem is removed. Therefore a new connection is established, and the
rm -rf command will be executed. The method returns then success of failure.

=back

=cut


  my ($context_ID,$mailadress,$entry)=@_;

  my $error=0;


  # get username from mailadress --> username is the mailadress without
  # @domain.tld
  $mailadress=~/@/;
  my $username=$`;

  if(!$context_ID || !$mailadress || !$OX_admin_password || !$OX_admin_user || !$entry){

    # .. if not write an error message where we can see which one is undef ...
    logger("error","had not enough arguments to delete mailaccount.\nContext-ID:$context_ID:\nmailadress:$mailadress:\nOX-admin-password:$OX_admin_password:\nOX-admin-user:$OX_admin_user\nentry:$entry:\nThe values should be between the \":\"");
    $error=1;
  }

  else{

    if(my $user_is_present=checkOXUser($context_ID,$username)){ 

      logger("info","Deleting user $username in context $context_ID");

      # create commands to delete a user
      @args=("/opt/open-xchange/sbin/deleteuser",
	     "--contextid '$context_ID'",
             "--adminuser '$OX_admin_user'",
             "--adminpass '$OX_admin_password'",
             "--username '$username'",
             "--nonl",);

      $error=executeCommand($$ox_connection,@args);

      unless($error){

        my $imap_host=$service_cfg->val('IMAP','HOST');
        my $imap_user=$service_cfg->val('IMAP','USER');
	my $imap_dsa_file=$service_cfg->val('IMAP','DSA_FILE');

        my $imap_gateway_connection=gatewayConnect($imap_host,$imap_user,$imap_dsa_file,"connect",0);

	if($imap_gateway_connection){

	  # if we have a ssh connection get the users homedir
	  my $mail_homedir=getValue($entry,'sstMailMessageHomeDirectory');
          
	  # generate the commands to be executed
	  @args=("sudo","ls -la",$mail_homedir);

	  # capture the output from the above generated commands
	  my $output=$imap_gateway_connection->capture({stderr_to_stdout=>1},join(' ',@args));

	  # write log message whether the command was successful or not
	  my $command=join(' ',@args);
	  if($imap_gateway_connection->error){
	    logger("error", "ssh command: $command failed!!! Return-error-message: $output");
	    $error=1;
	  }
	  else{
	    logger("debug","SSH-command: $command successfully executed");
	  }

          # Log out from the imap-server
          $imap_gateway_connection->system("exit");

	}
	else{
	  # if no ssh connection to the imap server could be established
	  # write an error message and return with error status
	  logger("error","Cannot establish SSH-connection to the imap-server! Cannot delete the Mailbox on the filesystem!"
                ." Please rerun the script or remove the users mailbox manually on "
                .$service_cfg->val('IMAP','HOST')." by executing the following"
                ." command: rm -rf ".getValue($entry,'sstMailMessageHomeDirectory'));
                
	  $error=1;

	}

	# if no error occured while deleting the user, write success message...
        unless($error){
	  logger("info","User $username in context $context_ID successfully deleted","send");
	}
	# ... otherwise wirte failure message
	else{
	  logger("error","User has been deleted from the OX but could not delete the mailbox on the imap-server!");
	}

      }
      # if an error occured already while deleting the user form the OX
      # write an error message
      else{
	logger("error","Could not delete user $username in context $context_ID");
      }

    }
    # if the user is not present in the OX context ...
    else{
      
      # ... write error message if user could not be checked ...
      if($user_is_present eq "error"){
        logger("error","User could not be checked for presence, view syslog or mailbox for further information. Script stops here.");
        $error=1;
        return $error;
      }
      # ... or write a message if the user is not present
      else{
        logger("info","User $username is not present in context $context_ID, cannot delete a non-existing user");
      }

    }# end if(checkOXUser)

  }# end if (!context_ID || !...)

  return $error;

} # end sub deleteMailAccount






sub searchAliases{

=pod

=over

=item searchAliases

The searchAliases method searches in the database if the specified user has
aliases or not. If yes, the aliases will be returned as a comma seperated list.
Otherwise nothing will be returned.

=back

=cut


  my ($DN,$mailadress)=@_;

  my @aliases;

  # get one DN-Level up, (DN-level shoud then normally be sstMailDomain=...)
  $DN=~/(,)/;
  my $search_base=$'; #'

  # start a search (normally on DN-level sstMailDomain) and look for
  # objectClass=sstMailAlias and sstMailForward= the given mail adress.
  my @results=simpleSearch($search_base,"(&(objectClass=sstMailAlias)(objectClass=sstGroupwareOX)(sstMailForward=$mailadress))");

  # if the search returned a result ...
  if(@results){
    logger("debug","aliases found for user $mailadress in $search_base");

    #... go through each result ... 
    foreach my $entry (@results){

      if(getValue($entry,'sstMail')){
        my $alias=getValue($entry,'sstMail');
        # ... and add the attribute-value of sstMail to an array if sstMail is
        # defined
        push(@aliases,$alias);
      }
      else{
        logger("error","Alias search returned an object with objectClass=sstMailAlias and sstMailForward=$mailadress. But the attribute 'sstMail' is not defined! Script will continue but NOT add any aliases for user $mailadress\n(DN: $DN)");
        return undef;
      } # end if(getValue($entry,'sstMail')

    } # end foreach

    # add the mailadress to the aliases (important for changeuser)
    push(@aliases,$mailadress);

    # convert the array to a comma seperated sting and return it
    my $aliases=join(",",@aliases);
    return $aliases;

  } # end if(@results)
  else{
    logger("debug","no aliases found for user $mailadress in $search_base");
    return undef;
  } # end else if(@results)



} # end sub searchAliases





###############################################################################
##############                      Aliases                          ##########
###############################################################################


sub deleteMailAlias{

=pod

=over

=item deleteMailAlias

The deleteMailAlias method collects all users that had this entry as an alias.
Then it goes through each of this users and gets its aliases, deletes this alias
and updates the users aliases.

=back

=cut


  my ($entry,$domain_name,$context_ID)=@_;

  my $error=0;
  my $alias;


  # read the attribute sstMailForward from the given entry
  my @mail_forward=getValue($entry,'sstMailForward');
  my $to_delete=getValue($entry,'sstMail'); 

  # for each value (mailadress) in sstMailForward ...
  foreach my $field (@mail_forward){

    # ... check if the mailadress is in this domain ...
    if($field=~/$domain_name/i){

	# ... if yes, extract the username form email (string before '@')
      $field=~/@/;
      my $user=$`;

      # get the list of the users aliases
      my @aliases = getUserAliases($user,$context_ID);

      my @new_aliases;

	# remove the alias we deleted (push all others to a new array)
      foreach $alias (@aliases){
        if($alias ne $to_delete){
          push(@new_aliases,$alias);
        }
      }

      # Finally add the users mailadress itself
      unshift(@new_aliases,"$user\@$domain_name");

      # generate commands to update the useres aliases
      my @args=("/opt/open-xchange/sbin/changeuser",
		"--contextid '$context_ID'",
		"--adminuser '$OX_admin_user'", 
		"--adminpass '$OX_admin_password'",
		"--username '$user'",
		"--aliases '".join(",",@new_aliases)."'",
                "--nonl",
		);

     $error=executeCommand($$ox_connection,@args);

    }
  }

  return $error;


}



sub addMailAlias{


=pod

=over

=item addMailAlias

This method adds handles a mail alias if it's added. The method checks which
user(s) has this alias, get the other aliases of the user(s) and updates the 
user(s) alias field with the old and this alias.

=back

=cut

  my ($entry,$domain_name,$context_ID)=@_;

  my $error=0;


  # read the attribute sstMailForward from the given entry
  my @mail_forward=getValue($entry,'sstMailForward');  

  # for each value (mailadress) in sstMailForward ...
  foreach my $field (@mail_forward){

    # ... check if the mailadress is in this domain ...
    if($field=~/$domain_name/i){

      # ... if yes, search the corresponding user
      my @users=simpleSearch("sstMailDomain=$domain_name,ou=mail,ou=services,o=stepping-stone,c=ch","(&(objectClass=sstMailAccount)(sstMail=$field)(objectClass=sstGroupwareOX)(sstGroupwareOXAccountType=User))");

      # if the user is found ...
      if(@users){

        # ... search his aliases and update the user. 
        my $new_aliases=searchAliases(getValue($users[0],'dn'),$field);

        # only conitnue if you found aliases for the user, but this test should
        # always be true
        if($new_aliases){

          # get the username form the mailadress
          $field=~/@/;
          my $username=$`;
	
          # check if the user is persent in the given context (also this test
          # should normally be true).
          if(checkOXUser($context_ID,$username)){

            @args=("/opt/open-xchange/sbin/changeuser",
    		   "--contextid '$context_ID'",
		   "--adminuser '$OX_admin_user'",
 		   "--adminpass '$OX_admin_password'",
 		   "--username '$username'",
 		   "--aliases '$new_aliases'",
                   "--nonl",);

            $error=executeCommand($$ox_connection,@args);

  	    if($error){
    		logger("error", "Could not update aliases for user $username in context $context_ID.");
  	    }
  	    else{
   	 	logger("info","aliases for user $username in context $context_ID for successfully updated");
            } # end if($error)

          }
          else{
            logger("error","Could not update aliases for user $field -> user is not present in context $context_ID.");
            $error=1;
            return $error;
          }# end if(checkUser)

        }
        else{
          logger("error","Could not find aliases for mailadress $field. ".
                 "This message should never appear. If it does, there's ".
                 "something really corrupt in the code. Please double check ".
                 "the methods addMail alias and searchAlias in ".
                 "Provisioning::Groupware::OX::OXAccount.");
          $error=1;
          return $error;
        } #end if($new_aliases)

      }
      # if the user is not found, he will be added soon and the aliases will
      # be added then. So it's not a big deal. 
      else{
        logger("warning","User with mailadress $field does not exist.");
      }# end if(@users)

    }
    # if the alias is not in this domain we ignore it. 
    else{
      logger("debug","Found an alias for user $field which is not in this domain. The script ignores this alias.");
    }#end if($field=~/$domain_name/i)

  }#end foreach

  return $error;

} # end sub addMailAlias



sub modifyMailAlias{

=pod

=over

=item modifyMailAlias

The modifyMailAlias method first adds this alias. Like that we handle if a new
user was added to this alias. Then it calls the updateMailAliases method which
handles the rest. 

=back

=cut

  my ($entry,$domain_name,$context_ID)=@_;

  my $error=0;
  my $localerror=0;
  my @new_aliases;

  # add all aliases to the corresponding mailaccount (if a new alias was 
  # added we make sure that he is now active).
  $error=addMailAlias($entry,$domain_name,$context_ID);

  # get all users of the given domain
  my @users=getDomainUsers($$ox_connection,$context_ID,$OX_admin_user,$OX_admin_password);


  # for each user in the domain, check whether the aliases are up-to-date.
  # (make sure that we delete an alias if it was deleted in the database).
  foreach my $user (@users){

    # ckeck if aliases for the specified user are up-to-date.
    if(my @aliases=getUserAliases($user,$context_ID)){
      @new_aliases=updateAliases(@aliases,$user);
    }
    else{
      $error=1;
      return $error;
    }

    # generate commands to update the useres aliases
    my @args=("/opt/open-xchange/sbin/changeuser",
	   "--contextid '$context_ID'",
           "--adminuser '$OX_admin_user'",
           "--adminpass '$OX_admin_password'",
	   "--username '$user'",
	   "--aliases '".join(",",@new_aliases)."'",
           "--nonl",
	   );

    $error=executeCommand($$ox_connection,@args);


  }

  return $error;

} # end sub modifyMailAlias





sub getUserAliases{

=pod

=over

=item getUserAliases

This method gets all aliases of a specified user. It parses the csv value
returned from the ox-server command listuser. It reads the alias fields and
converts this string into an array which then is returned. 

=back

=cut


  my ($user,$context_ID)=@_;

  my @data;
  my @aliases;
  my $alias;

  # get the aliases from the given user.

  # generating listuser command with it's options
  my @args=("/opt/open-xchange/sbin/listuser",
            "--contextid '$context_ID'", 
            "--adminuser '$OX_admin_user'",
            "--adminpass '$OX_admin_password'",
            "-s '$user'",
            "--csv",
            );

  # capture the output (CSV) from the listuser command
  my @users=executeCommand($$ox_connection,@args);

  # if no error occured during the listuser command...
  if($users[1] == 0){

    # convert the captured output string into a IO stream 
    my $io=IO::String->new($users[0]);

    # parse the recieved CSV data
    while(my $row = $csv->getline ($io)){
      # and extract the 107th element -> aliases.
      push(@data,$row->[107]);
    }
  }
  # ... otherwise log the error.
  else{
    logger("error","Could not get useres data, error: $users[0]");
    return undef;
  }

  # transfer the aliases string to the var. $aliases
  my $aliases=$data[1];

  # convert the string into an array
  while($aliases=~/, /){
    push(@aliases,$`);
    $aliases=$'; #'
  }
  
  # add the last element of the string to the array
  push(@aliases,$aliases);

  

  return @aliases;

}


sub updateAliases{

=pod

=over

=item updateAliases

This method checks if the aliases revieved form the ox-server are still 
up-to-date, means they are also in the database. So the method simply goes
through each alias getting form the modifyMailAlias method and checks whether
it is also in the database. If not the alias is deleted from the alias list and
the user is updated. 

=back

=cut

  my (@aliases)=@_;

  my $error=0;
  my @new_aliases;
  my $alias;
  my $change;
  my @entry;
  my $index=0;

  # the last parameter passed to this method is the username and not an alias
  # so save it and delete it from the alias-list.
  my $user=$aliases[@aliases-1];
  pop(@aliases);


  # go through each alias and check if it's still actual. 
  foreach $alias (@aliases){

    # search the alias object
    @entry=simpleSearch("ou=mail,ou=services,o=stepping-stone,c=ch","(&(objectClass=sstMailAlias)(sstMail=$alias))");
    if($entry[0]){

      # check whether the aliases recieved from the OX is also in the ldap and
      # if not ...
      unless(join(" ",getValue($entry[0],'sstMailForward'))=~/$user/){

        # delete this alias form the list and note that we changed the list
	logger("info","$aliases[$index] is no longer an alias of $user. Script will remove it.");
        delete $aliases[$index];
        $change=1;

      } # end unless

    } # end if
    $index++;
    
  } # end foreach

  # if the list changed
  if($change){  

    # go through the list and transfer the still existing (up-to-date) aliases
    # into a new list. This is necessary cause the alias is still part of the 
    # array, it is just 'undef'. But we want to return a proper array.
    foreach $alias (@aliases){
      if($alias){
        push(@new_aliases,$alias)
      }
    } # end for each

    return @new_aliases;

  }# end if

  return @aliases;

} # end sub updateAliases




###############################################################################
##############                      Resource                         ##########
###############################################################################



sub handleResourceAccount{

=pod

=over

=item handleResourceAccount

This method checks first whether all necessary information is available and
then generates the commands according to wheter a resource account should be
added or modified. Then the executeCommands form the TransportAPI module is
called with this commands. The return value of the executeCommands indicates
if the commands were successful or not. The method returns then success of
failure.

=back

=cut

  my ($context_ID,$resource_name,$display_name,$mailadress,$description,$change)=@_;

  my $error=0;

  # check if all the nessesary vars are defined ...
  if(!$context_ID || !$resource_name || !$mailadress || !$description || !$display_name){
    
    # if not write an error message ...
    logger("error","Could not create/modify resource :$resource_name:, not enough arguments:context-ID:$context_ID:\nemail:$mailadress:\ndescription:$description:\ndisplay-name:$display_name:\nValues should be between the \":\"");
    $error=1;
    return $error;

  }
  # otherwise continue with the code
  else{

    # generating default command
    @args=("--adminuser '$OX_admin_user'",
           "--adminpass '$OX_admin_password'",
	   "--contextid '$context_ID'",
	   "--name '$resource_name'",
	   "--displayname '$display_name'",
	   "--description '$description'",
	   "--email '$mailadress'",
           "--nonl",);

    # check if the resource already exists
    unless(my $resource_is_present=checkOXResource($context_ID,$resource_name)){

      logger("debug","Resource $resource_name is not present in context $context_ID");

      unless($change){
        logger("info","Creating resource $resource_name in context $context_ID");
        unshift(@args,"/opt/open-xchange/sbin/createresource");
      }
      else{
        logger("info","Modifing resource $resource_name in context $context_ID");
        unshift(@args,"/opt/open-xchange/sbin/changeresource");
      }

      $error=executeCommand($$ox_connection,@args);

      if($error){
        logger("error","Could not create/modify resource $resource_name in context $context_ID");
        $error=1;
        return $error;
      }
      else{
        logger("info","Resource $resource_name in context $context_ID successfully created/modified","send");
      }#end if ($error)

    }
    else{

      # check if there was an error while checking the resource
      if($resource_is_present eq "error"){
      
        logger("error","Resource could not be checked for presence, view syslog or mailbox for further information. Script stops here.");
        $error=1;
        return $error;
      }


      logger("debug","Resource $resource_name is already present in context $context_ID");
      logger("info","Changing resource $resource_name in context $context_ID");

      unshift(@args,"/opt/open-xchange/sbin/changeresource");

      $error=executeCommand($$ox_connection,@args);

      if($error){
        logger("error","Could not modify resource $resource_name in context $context_ID");
        $error=1;
        return $error;
      }
      else{
        logger("info","Resource $resource_name in context $context_ID successfully modified","send");
      }#end if ($error)

    } # end unless(checkResource())

  } # end if(!context_ID || !...)




} # end sub handleResourceAccount


sub deleteResourceAccount{

=pod

=over

=item deleteResourceAccount

This method checks first whether all necessary information is available and
then generates the commands to delete a resource account. Then the executeCommands
form the TransportAPI module is called. The return value of this method
indicates if the commands were successful or not. If yes, the mailbox on the
filesystem is removed. Therefore a new connection is established, and the
rm -rf command will be executed. The method returns then success of failure.

=back

=cut

  my($context_ID, $resource)=@_;
  my @args;
  my $error=0;
  my $is_present;

  # check if we have all nessecary vars. If not write a error-message and quit
  if(!$context_ID || !$resource){
    logger("error","Not enough arguments for deleteResourceAccount:\nContext-ID:$context_ID:\nResource name:$resource:\nValues should be between \":\"");
    return $error=1;
  }

  # check if the resource we want to delete is present in the given context
  if($is_present=checkOXResource($context_ID, $resource)){
  
    # test if the checkResource methode returned an error
    unless($is_present eq "error"){

      # generating commands to delete the resource
      @args=("/opt/open-xchange/sbin/deleteresource",
  	     "--adminuser '$OX_admin_user'",
  	     "--adminpass '$OX_admin_password'",
  	     "--contextid $context_ID",
  	     "--name '$resource'",
             "--nonl",
	     );

      # execute the commands
      $error=executeCommand($$ox_connection,@args);

    }
    # if the checkResource method returned error, write a error-message and quit
    else{
      logger("error","Could not check resource $resource for presence.");
      return $error=1;
    }
  # if the resource does not exist do nothing but write a log-message.
  }
  else{
    logger("warning","Rescource $resource does not exist. Cannot delete a non-existing resource.");
  }

  return $error;


} # end sub deleteResourceAccount



 
# end module OXAccount.pm

1;

__END__

=pod 

=head1 Version

=over

=item 2010-09-10 Pat Kläy created.

=item 2010-26-10 Pat Kläy modified.

Alias methods implemented.

=item 2011-02-11 Pat Kläy modified

ox_connection passed to all TransportAPI functions to be able to deal with more than one gateway connections

=back

=cut
