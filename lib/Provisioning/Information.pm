package Provisioning::Information;

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

use Net::SMTP::TLS;
use Config::IniFiles;
use strict;
use warnings;

use Provisioning::Log;

use POSIX; #LC_TIME setlocale
require Exporter;

our @ISA = qw(Exporter);

our %EXPORT_TAGS = ( 'all' => [ qw(sendMail) ] );

our @EXPORT_OK = ( @{ $EXPORT_TAGS{'all'} } );

our @EXPORT = qw(sendMail);

our $VERSION = '0.01';




sub sendMail{

  my ($message,$service,$facility,$force_send) = @_;

  my $mail_text;
  my $mail_subject;

  # get the environment for the mail header and the hostname for the message
  my $server = $Provisioning::cfg->val("Global","ENVIRONMENT");
  my $hostname = `hostname`;

  # remove the newline from hostname
  chomp($hostname);

  # get all vars stored in the config file. 
  my $mailcfg = $Provisioning::global_cfg;

  unless($mailcfg){
    logger("warning","No mailconfig defined, will not send any mail!");
    return;
  }

  # my $mailer=$mailcfg->val('Mail','mailer');
  my $host=$mailcfg->val('Mail','HOST');
  my $port=$mailcfg->val('Mail','PORT');
  my $username=$mailcfg->val('Mail','USERNAME');
  my $password=$mailcfg->val('Mail','PASSWORD');
#  my $from_address=$mailcfg->val('Mail','FROMADRESS');
  my $from_name=$mailcfg->val('Mail','FROMNAME');
  my $want_info_mail=$mailcfg->val('Mail','WANTINFOMAIL');

  my $to=$mailcfg->val('Mail','SENDTO');

  # Test if we have all information to send the mail
  if ( !$host || !$port || !$username || !$password || !$to )
  {
    # Log that we don't have enough information and return
    logger("warning","Should send a mail with the message: '$message'. But cannot"
          ." send the mail because it is not fully configure. To enable this "
          ."fauture please configure the section [Mail] in "
          .$mailcfg->GetFileName());
    return;
  }
  
  # if we want to send a mail whatever facility we have we need to set this 
  # var to TRUE
  if($force_send){
    $want_info_mail=1;
  }

  $mail_subject="[Provisioning] $service: $facility on $server";

  # if the facility is not defined we don't do anything so the subject and
  # message are passed to the mail-lib without any change.
  if(!$facility){
    $mail_text=$message;
  } # end if(!$facility)

  # if the facility is error we have a template
  elsif($facility=~/error/i){

    $mail_text="Error message from $service on $hostname:\n\n$message";

  } # end if ($facility)

  # if the facility is warning we have a template
  elsif($facility=~/warning/i){
    # if want info mail is TRUE we send a mail with the appropriate message
    if($want_info_mail){
      $mail_text="This is a warning mail.\n\nReport from the $service provisioining script on $hostname:\n\n$message";
    }
    # else we return without doing anything
    else{
      return 0
    }
  } # end elsif ($facility)

  # if the facility is info we have a template
  elsif($facility=~/info/i){

    # if want info mail is TRUE we send a mail with the appropriate message
    if($want_info_mail){
      $mail_text="This is an information mail.\n\nReport from the $service provisioining script on $hostname:\n\n$message";
    } 
    # else we return without doing anything
    else{
      return 0
    }
   
  } # end elsif($facility)

  # if the facility is debug we have a template
  elsif($facility=~/debug/i){
    # if want info mail is TRUE we send a mail with the appropriate message
    if($want_info_mail){
      $mail_text="This is a debug mail.\n\nReport from the $service provisioining script on $hostname:\n\n$message";
    }
    # else we return without doing anything
    else{
      return 0
    }
  } # end elsif ($facility)

  
  # set the LC_TIME to en_US.UTF-8 but first save the actual LC_TIME
  # to be able to restore it later
  my $oldLC=setlocale(LC_TIME);
  setlocale(LC_TIME,"en_US.UTF-8");
  # get the date string
  my $date=strftime("%d %b %Y %H:%M:%S %z",localtime());
  setlocale(LC_TIME,$oldLC);

   

  #create the mailer ...
  my $mailer = new Net::SMTP::TLS(
        $host,
        Port    =>      $port, 
        User    =>      $username,
        Password=>      $password);

  #.. and send the mail
  $mailer->mail($username);
  $mailer->to($to);
  $mailer->data;
  $mailer->datasend("From:$from_name<$username>\n");
  $mailer->datasend("To:$to\n");
  $mailer->datasend("Subject:$mail_subject\n");
  $mailer->datasend("Content-Type: text/plain; charset=UTF-8\n");
  $mailer->datasend("Date: $date\n");
  $mailer->datasend("$mail_text");
  $mailer->dataend;
  $mailer->quit;


} # end sub sendMail





1;

__END__
