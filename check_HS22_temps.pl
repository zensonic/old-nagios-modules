#!/usr/bin/perl

# author: Thomas S. Iversen

use strict;
require 5.6.0;
use utils qw(%ERRORS $TIMEOUT &print_revision &support &usage);
use Net::SNMP;

sub get_bladetemp {
    my $host=shift;
    my $community="public";
    my $port="161";

    alarm( $TIMEOUT ); # make sure we don't hang Nagios

    my $snmp_error;
    my ($snmp_session,$snmp_error) = Net::SNMP->session(
						     -version => 'snmpv1',
						     -hostname => $host,
						     -community => $community,
						     -port => $port,
		);
    
    my $oid;
    my $oid_prefix = ".1.3.6.1.4.1."; #Enterprises
    $oid_prefix .= "2.3.51.2."; #IBM Bladecenter
    $oid = "2.1.5.1.0";
    my $data = SNMP_getvalue($snmp_session,$oid_prefix.$oid);
    my $data_text=$data;
    $data_text =~ s/^\s*(.+?)\s*$/$1/;
    $data =~ s/^\s*(\d+)\.(\d+).*?$/$1$2/;
    
    $snmp_session->close;
    alarm( 0 ); # we're not going to hang after this.
    
    return $data;
}

sub SNMP_getvalue{
    my ($snmp_session,$oid) = @_;
    
    my $res = $snmp_session->get_request(
					 -varbindlist => [$oid]);
    
    if(!defined($res)){
	print "ERROR: ".$snmp_session->error."\n";
	exit;
    }
    
    return($res->{$oid});
}

sub get_ipmitemp {
    my $host=shift;

    my $cmd="/usr/bin/ipmitool -U USERID -P PASSW0RD -H $host -I lanplus sdr get \"Ambient Temp\"";
    my $result;
    open(FILE, "$cmd|") || die "Could not execute $cmd";
    while(<FILE>) {
	next if defined($result);
	if(/Sensor Reading/i) {
	    if(/:\s([0-9]*)/) {
		$result=$1;
	    }
	}
    }
    close(FILE);
    return $result;
}

print &get_bladetemp("bladecenter1mgn") . "\n";
print &get_bladetemp("bladecenter2mgn"). "\n";
print &get_ipmitemp("biomdcon"). "\n";
print &get_ipmitemp("biomd1con"). "\n";
print &get_ipmitemp("biomd2con"). "\n";
print &get_ipmitemp("biomd3con"). "\n";
print &get_ipmitemp("biomd4con"). "\n";
