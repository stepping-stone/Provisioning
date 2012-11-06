package Provisioning::Log;

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

use Module::Load;
use Sys::Syslog;

require Exporter;

our @ISA = qw(Exporter);

our %EXPORT_TAGS = ( 'all' => [ qw(logger ) ] );

our @EXPORT_OK = ( @{ $EXPORT_TAGS{'all'} } );

our @EXPORT = qw(logger);

our $VERSION = '0.01';


# load the nessecary modules
load "Provisioning::Information", ':all';

my $service=$Provisioning::syslog_name;

sub logger{

  my($facility, $message, $send)=@_;

  my $opt_d = "$Provisioning::debug";
  my $log_debug = $Provisioning::cfg->val("Global", "LOG_DEBUG");
  my $log_info = $Provisioning::cfg->val("Global", "LOG_INFO");
  my $log_warning = $Provisioning::cfg->val("Global", "LOG_WARNING");
  my $log_error = $Provisioning::cfg->val("Global", "LOG_ERR");


  if(!$facility or !$message)
  {
    syslog("LOG_WARNING","Should log something but no message and/or facility defined. Cannot log.");
    return;
  }


  if($facility=~/debug/i && $log_debug){

    syslog("LOG_DEBUG","$service:  $message");
    # if debug mode is on, print the message to STDOUT
    if($opt_d){
      print "DEBUG:  $message\n\n";
    } # end if(opt_d)
    # if the user want to send the message, send it. 
    if($send){
      sendMail($message,$service,"info");
    }# end if(send)
  } # end if(facility)

  # if the facility is info, write a info-log-message
  elsif($facility=~/info/i && $log_info){

    syslog("LOG_INFO","$service:  $message");
    # if debug mode is on, print the message to STDOUT
    if($opt_d){
      print "INFO:  $message\n\n";
    } # end if(opt_d)
    # if the user want to send the message, send it. 
    if($send){
      sendMail($message,$service,"info");
    }# end if(send)
  } # end if(facility)

  # if the facility is warning, write a warning-log-message
  elsif($facility=~/warning/i && $log_warning){

    syslog("LOG_WARNING","$service:  $message");
    if($opt_d){
      print "WARNING:  $message\n\n";
    }
    if($send){
      sendMail($message,$service,"warning");
    }
  }

  # if the facility is error, write a error-log-message
  elsif($facility=~/error/i && $log_error){

    syslog("LOG_ERR","$service:  $message");
    sendMail($message,$service,"error");
    if($opt_d){
      print "ERROR:  $message\n\n";
    }
  } # end elsif($facility=error)

} # end sub logger()




1;

__END__
