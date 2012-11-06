package Provisioning::Util;

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

#use strict;
use warnings;

use Net::LDAP;

require Exporter;
use Net::LDAP::Constant qw(
  LDAP_SUCCESS
);

=pod

=head2 getHomeDir()

This method calculates form the userID the corresponding home directory. this would be /var/backup/%last-digit%/%three-last-digit%/%digit2-to-digit-4%/%userID/ where digit refers to the userID. So the home directory for the user 1234567 would be: /var/backup/7/567/234/1234567. This method returns the calculated home directory and takes as input-parameter the userID.

=cut


our @ISA = qw(Exporter);

our %EXPORT_TAGS = ( 'all' => [ qw(getHomeDir) ] );

our @EXPORT_OK = ( @{ $EXPORT_TAGS{'all'} } );

our @EXPORT = qw(getReseller getHomeDir);

our $VERSION = '0.01';

$|=1;


sub getHomeDir{

# This method calculates form the userID the corresponding home directory. this would be /var/backup/%last-digit%/%three-last-digit%/%digit2-to-digit-4%/%userID/ where digit refers to the userID. So the home directory for the user 1234567 would be: var/backup/7/567/234/1234567. This method returns the calculated home directory and takes as input-parameter the userID.

  my ($user,$service) = @_;

  $user=~ /\d{6}$/;
  my $string=$&;

  $string=~/\d$/;
  my $homedir="/var/$service/$&/";

  $string=~/\d{3}$/;
  $homedir.="$&/";

  $string=~/^\d{3}/;
  $homedir.="$&/";

  $homedir.="$user";

  return $homedir;

} #end sub getHomeDir


1;

__END__
