package Provisioning::TransportAPI::CLISSH;

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

use Config::IniFiles;
use Net::OpenSSH;
use Text::CSV::Encoded;
use IO::String;
use Provisioning::Log;

require Exporter;

our @ISA = qw(Exporter);

our %EXPORT_TAGS = ( 'all' => [ qw(checkPath gatewayConnect checkContext checkUser setPermission executeCommand getDomainUsers gatewayDisconnect) ] );

our @EXPORT_OK = ( @{ $EXPORT_TAGS{'all'} } );

our @EXPORT = qw(checkContext checkPath checkUser setPermission executeCommand getDomainUsers gatewayDisconnect);

our $VERSION = '0.01';



$|=1;



my @args;
my $output;


my $opt_r=$Provisioning::opt_R;
my $service=$Provisioning::cfg->val('Service','SERVICE')."-".$Provisioning::cfg->val('Service','TYPE');
my $service_cfg=$Provisioning::cfg;
my $global_cfg=$Provisioning::global_cfg;

###############################################################################
#####                                General                              #####
###############################################################################

sub gatewayConnect{

  # creates an ssh-connection for the given user on the given host with the given
  # dsa-key-file (no password). 

  my ($host,$user,$dsa_file,$mode,$attempt)=@_;

  my $error=0;

  unless($attempt){
    $attempt=1;
  }

  unless(-e $dsa_file){
    logger("error","dsa-file: $dsa_file does not exist, cannot create ssh-connection.");
    return undef;
  } # end unless


  my $seconds_to_sleep;
  my $attempts_before_exit;

  if($mode eq "connect"){
    $seconds_to_sleep= $global_cfg->val('Global', 'SLEEP');
    $attempts_before_exit= $global_cfg->val('Global', 'ATTEMPTS');
  }
  elsif($mode eq "reconnect"){
    $seconds_to_sleep= $global_cfg->val('Operation Mode', 'SLEEP');
    $attempts_before_exit= $global_cfg->val('Operation Mode', 'ATTEMPTS');
    logger("debug","$seconds_to_sleep seconds are over: trying to reconnect");
  }
  else{
    logger("warning","Unknown mode, setting default values sleep=30 and attempts=3");
    $seconds_to_sleep=30;
    $attempts_before_exit=3;
  }

  # establish connection
  my $connection = Net::OpenSSH->new($host,
                           user => $user,
                           master_opts => [-F => $dsa_file],
                          );

  # log if something went wrong
  if($connection->error){
    # check if we can try again
    if($attempt!=$attempts_before_exit){
      logger("warning","$attempt. attempt to establish ssh-connection to ".
             "$host failed: ".$connection->error." Retry in $seconds_to_sleep ".
             "seconds.");
      $attempt++;
      # ...wait...
      sleep($seconds_to_sleep);
      # try again
      $connection=gatewayConnect($host,$user,$dsa_file,$mode,$attempt);
    }
    # if we tried enough we give up
    else{
    
      my $message="Couldn't establish SSH connection to host $host: ". $connection->error;
      # use the Provisioning::Log::logger that will automatically send a mail to
      # the specified adress if an error occures
      logger("error",$message);
      $error=1;

    }# end if($attempt<$attempts_before_exit)

  }
  else{
    logger("debug","SSH-Connection to host $host established");
  }


  # finally, if everything was ok the connection can be returned, otherwise
  # nothing is returned.
  if($error==1){
    return undef;
  }
  else{
    return $connection;
  }

} # end sub makeSSHConenction



sub gatewayDisconnect(){

  my $ssh_connection=shift;

  my $error=0;

  if($ssh_connection){
    $error=$ssh_connection->capture({stderr_to_stdout=>1},"exit");
  }
  else{
    logger("waring","Should terminate ssh connection which does not exist.");
  }

  if($error){
    logger("warning","Could not terminate the ssh connection. It is still running.");
    print "\nError: $error\n";
  }
  else{
    logger("debug","ssh connection terminated.")
  }
  
}


sub checkSSHConnection{

    my $ssh_connection = shift;

    # Check if the ssh connection is still working properly.
    my $test = $ssh_connection->check_master();

    # If the test failed, we have to reconnect!
    unless($test){

        # Write a log message that the test failed!
        logger("warning","The master ssh connection test failed. Reconnecting!",1);
        # And reestablish the ssh connection
        $ssh_connection=gatewayConnect($service_cfg->val("Gateway","HOST"),
                                       $service_cfg->val("Gateway","USER"),
                                       $service_cfg->val("Gateway","DSA_FILE"),
                                       "reconnect",
                                       0,);

        # update the global ssh connection
        Provisioning::updateGatewayConnection($ssh_connection);
    }

    # return a working (!) ssh connection
    return $ssh_connection;
    
}

sub executeCommand{

  my ($ssh_connection,@args)=@_;

  my $error=0;

  my $command=join(" ",@args);

  if($opt_r){
    print "DRY-RUN:  $command\n\n";
    logger("debug","SSH-command: $command successfully executed");
  }
  else{

    $ssh_connection = checkSSHConnection($ssh_connection);

    $output=$ssh_connection->capture({stderr_to_stdout=>1},join(' ',@args));
    if($ssh_connection->error){
      logger("error", "ssh command: $command failed!!! Return-error-message: $output");
      $error=1;
    }
    else{
      logger("debug","SSH-command: $command successfully executed");
    }# end  unless($localerror==0)
  } # end if($opt_r)

  return $output, $error;

} # end sub executeCommand


sub checkPath{

  my ($ssh_connection,@args)=@_;

  my $output;

  if($opt_r){
    print join(" ",@args)."\n\n";
  }
  else{

    $ssh_connection=checkSSHConnection($ssh_connection);

    # execute the command which gets the user and return the output
    # if output is defined, the user exists, otherwise not
    $output=$ssh_connection->capture({stderr_to_stdout=>1},join(' ',@args));
    if($ssh_connection->error){
      if($output=~ /No such file or directory/){
	return undef;
      }
      else{
        logger("error","could not check user, command failed: $output");
        return "error";
      }# end if output

    }#end if ssh->error

  } # end if opt_r


  return $output;



}



sub checkUser{

  my ($ssh_connection,@args)=@_;

  my $output;
  
  if($opt_r){
    print join(" ",@args)."\n\n";
    return "asdf";
  }
  else{

    $ssh_connection=checkSSHConnection($ssh_connection);

    # execute the command which gets the user and return the output
    # if output is defined, the user exists, otherwise not
    $output=$ssh_connection->capture({stderr_to_stdout=>1},join(' ',@args));
    if($ssh_connection->error){
      if($output){
        logger("error","could not check user, command failed: $output");
        return "error";
      }
      else{
        return undef;
      }# end if output

    }#end if ssh->error

  } # end if opt_r


  return $output;

} # end sub checkUser




sub checkContext{

  my ($ssh_connection,@args)=@_;

  $args[3]=~/(-s )/;
  my $context_name=$'; #'

  logger("debug","Check context $context_name for presence");
   
  if($opt_r){
    print join(" ",@args)."\n\n";
    $output="asdf";
  }
  else{

    $ssh_connection=checkSSHConnection($ssh_connection);

    $output=$ssh_connection->capture({stderr_to_stdout=>1},join(' ',@args));
    if($ssh_connection->error){
      if($output){
        logger("error","could not check context, listcontext command failed: $output");
        return "error";
      }
      else{
        logger("debug","context is not present");
        return undef;
      }
    }
  }

  return $output;

} # end checkContext




sub createOXPermissionCommand{

  my ($ssh_connection,$section,$context_ID,$username,$OX_admin_user,$OX_admin_password,$state)=@_;

  my $param;



  # default command string
  my @command=("--adminuser '$OX_admin_user'", 
              "--adminpass '$OX_admin_password'",
              "--contextid '$context_ID'",
              );

  if($section eq "permissionResource"){
    unshift(@command,"/opt/open-xchange/sbin/changeresource");
    push(@command,"--name '$username'");
    logger("debug","generating permission commands for resource $username");
  }
  else{
    unshift(@command,"/opt/open-xchange/sbin/changeuser");
    push(@command,"--username '$username'");
    logger("debug","generating permission commands for user $username");
  }

  my $value;

  # read all parameters in the config-file for the given section
  my @parameters=$service_cfg->Parameters($section);

  # if we want to deny some permission...
  if($state eq 'deny'){

    # ... we simply set all parameters from the given section to off
    foreach $param (@parameters){
      if($service_cfg->val($section,$param) eq "on"){
        push(@command,"--$param off");
      }
      elsif($service_cfg->val($section,$param) eq "true"){
        push(@command,"--$param false");
      }
    }

  }
  # if we want to set permmision
  else{

    # for each parameter in the given section ...
    foreach $param (@parameters){

      #...  get it's value ... 
      $value=$service_cfg->val($section,$param);
      if($value){
        #...and add the key/value pair to the command string if value is defined
        push(@command,"--$param \"$value\"");
      }
      else{
        # if value is not defined write an error-message and quit the method
        logger("error","Value for parameter $param in section $section in ".
               "config-File $Provisioning::opt_c not defined. Can't generate".
               " permission command");
        return undef; 
      }

    } # end foreach

  } # end if($state eq 'deny'){

  logger("debug","permission commands successful generated");

  # if the command was successfully generated, return the command string 
  return @command;

}



###############################################################################
#####                              Permissions                            #####
###############################################################################

sub setPermission{

  my ($ssh_connection,$section,$context_ID,$username,$OX_admin_user,$OX_admin_password,$state)=@_;

  my $error=0;

  my @args=createOXPermissionCommand($ssh_connection,$section,$context_ID,$username,$OX_admin_user, $OX_admin_password,$state);

  unless(@args){
    # if the commands could not be generated, return here.
    $error=1;
    return $error;
  }

  $error=executeCommand($ssh_connection,@args);

  if($error){
    logger("error", "Could not $state $section permission for user $username.");
  }
  else{
    logger("info","$state $section permission in context $context_ID for ".
           "user $username successful");
  } # end if($error)

  return $error;


}


###############################################################################
#####                              Aliases                                #####
###############################################################################


sub getDomainUsers{

  my ($ssh_connection,$context_ID,$OX_admin_user,$OX_admin_password)=@_;

  my @data;

  # get all users form the domain
  
  # generating listuser command with it's options  
  my @args=("/opt/open-xchange/sbin/listuser",
            "--contextid '$context_ID'",
            "--adminuser '$OX_admin_user'",
            "--adminpass '$OX_admin_password'",
            "--csv"
            );

  # capture the output of the listuser command
  my @output = executeCommand($ssh_connection,@args);


  return undef if $output[1];

  # initialize the csv parser;
  my $csv= Text::CSV::Encoded->new({encoding  => "utf8"});

  # transform the string into a io stram
  #my $io=IO::String->new($output[0]);


  #parse the csv value
  my $i=0;

  while($output[0]=~ /\n/){ #something like getline 
    $output[0]=~ /\n/;
    $output[0]=$'; # new valie for output[0], it's all lines execpt the first
    
    # the first line is parsed for the username (username is first value)
    # so ina comma seperated list we search for a comma and take the string
    # before it as username
    $`=~/,/; 
 
    push(@data,$`); # add the username to the data array
  }

  # remove the header from the csv values
  shift(@data);

  # remove the " from the username
  foreach my $string (@data){
    while($string=~ /"/){
      $string=~ s/"//;
    }
  }

  return @data;


} # end sub getDomainUsers




#end module CLISSH.pm

1;

__END__
