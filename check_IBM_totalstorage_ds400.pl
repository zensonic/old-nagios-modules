#!/usr/bin/perl -w

# author:  Thomas S. Iversen <zensonic@zensonic.dk>
# what:    monitor various aspects of an IBM ds300/400 totalstorage
# license: GPL - http://www.fsf.org/licenses/gpl.txt
#
# 2009-04-06 - Rev 1.0 - Initial reviesion.

use Net::Telnet ();
use lib "/usr/lib/nagios";
use utils qw(%ERRORS $TIMEOUT &print_revision &support &usage);
use Getopt::Long;
use strict;

my $PROGNAME = "check_IBM_totalstorage_ds400.pl";

# Globals, including standard options.
my $cabinet_type="ds400";
my $prompt='/DS400>/';

# opt_verbosity: 1..3
my ($opt_version, $opt_help, $host);
my $opt_verbosity=0;

my $res="OK";
my $data;
my $data_text;
my $test_name;

# List of known tests that we can perform
my %known_tests=("system_status",  \&system_status, 
		 "array_status",   \&array_status,
		 "device_status",  \&device_status,
		 "logical_status", \&logical_status,
		 );

# Default test to perform
my $default_test="system_status";

sub submit_synchronous_command {
    my $t=shift;
    my $init_cmd=shift;
    my $wait_prompt=shift;
    my $next_cmd=shift;
    my $exit_cmd=shift;
    my $iterations=shift;
    my @lines = $t->cmd(String => $init_cmd,
			Prompt => $wait_prompt);
    for(my $i=0;$i<$iterations;$i++) {
	push(@lines,$t->cmd(String => $next_cmd, Prompt => $wait_prompt));
    }
    
    push(@lines,$t->cmd($exit_cmd));
    return @lines;
}

sub open_telnet_session {
    my $opt_verbosity=shift;
    my $t;
    if($opt_verbosity > 2) {
	$t = new Net::Telnet
	    (Timeout => 40,
	     Prompt => $prompt,
	     Input_Log => 'i.log',
	     Dump_Log=> 'd.log');
    } else {
	$t = new Net::Telnet
	    (Timeout => 40,
	     Prompt => $prompt);
    }
    $t->open($host);
    $t->binmode(1);
    $t->cmd_remove_mode(0);
    return $t;
}

sub system_status {
    my $t=&open_telnet_session($opt_verbosity);
    
    # Execute command. As the command interperter in the ds400 is asynchronous
    # it will issue the command to the storage cabinet and return. 
    # So the output will just be something to discard.
    my @dummy = $t->cmd("show system");

    # The real output will be fetched here.
    my @lines = $t->cmd("show system");

    my ($system_status);
    foreach my $line (@lines) {
	chomp($line);
	if($line=~/System status:\s*([^\s]+)/i) {
	    $system_status=$1;
	}
    }
    if(!defined($system_status)) {
	$res="WARNING";
	$data="Could not parse System status";
    } else {
	if($system_status=~/normal/i) {
	    $res="OK";
	    $data=$system_status;
	} else {
	    $res="CRITICAL";
	    $data=$system_status;
	}
    }
}

sub check_all_online {
    my $line_ref=shift;
    my $regex=shift;
    my $item_desc=shift;

    my %items;
    my ($item_name, $item_status);
    foreach my $line (@$line_ref) {
	if($line=~/$regex/i) {
	    if(defined($item_name)) {
		# If item_name is defined, a new item marks
		# the ending of an old "record"
		$items{$item_name}=$item_status;
		undef($item_name);
		undef($item_status);
	    }
	    $item_name=$1;
	} elsif($line=~/Status:\s*(\w+)/i) {
	    $item_status=$1;
	}
    }
    
    # Loop through item. Problems arise if an item isnt online.
    
    foreach my $item (sort keys %items) {
	my $status=lc($items{$item});
	if((!($status=~/online/i)) && $res eq "OK") {
	    # If an item is not online and res still is ok, 
	    # update res
	    $res="CRITICAL";
	} 
	$data .= ", $item_desc '$item' is '$status'";
    }
    $data=~s/^, //;
}

sub array_status {
    my $t=&open_telnet_session($opt_verbosity);

    my @array_info=&submit_synchronous_command($t, "show array", '/Finish|More/', " ", "q", 10);
    &check_all_online(\@array_info, '\[\s*array \'([^\']*)\'\s*\]', "Array");
}

sub device_status {
    my $t=&open_telnet_session($opt_verbosity);

    my @device_info=&submit_synchronous_command($t, "show device", '/Finish|More/', " ", "q", 10);
    &check_all_online(\@device_info, '\[\s*Device ID\s*\'([^\']*)\'\s*\]', "Device");
}

sub logical_status {
    my $t=&open_telnet_session($opt_verbosity);

    my @logical_info=&submit_synchronous_command($t, "show logical", '/Finish|More/', " ", "q", 10);
    &check_all_online(\@logical_info, '\[\s*logical\s*\'([^\']*)\'\s*\]', "Logical Volume");
}
 
sub print_version { print_revision( $PROGNAME, '$Revision: 1.0 $ ' ); }

sub print_usage {
    my $err=shift;
    if($err) {
	print "Error in usage: $err\n";
    }
    print "Usage: $PROGNAME [options] -H <host>\n\n";
    print "   where options can be\n\n";
    print "      V|version     - return version of this script,\n";
    print "      v|verbosity   - 1..3, set verbosity when running script\n";
    print "      h|help        - returns this help screen\n";
    print "      H|hostname    - the hostname of the ds300/400 cabinet to check\n";
    print "      c|cabinettype - the type of the cabinet. Can be either 'ds300' or 'ds400'.\n";
    print "                      Default is 'ds400'\n";
    print "      t|test        - the test to perform on the cabinet. Can be one of\n";
    foreach my $test (sort keys %known_tests) {
	print "                          '$test'\n";
    }
    print "\n";
    print "                      Default test is '$default_test'\n";
    exit(1);
}

sub process_options {
    &Getopt::Long::Configure( 'bundling' );
    GetOptions(
	       'V'     => \$opt_version,       'version'        => \$opt_version,
	       'v'     => \$opt_verbosity,     'verbosity'      => \$opt_verbosity,
	       'h'     => \$opt_help,          'help'           => \$opt_help,
	       'H:s'   => \$host,              'hostname:s'     => \$host,
	       't:s'   => \$test_name,         'test:s'         => \$test_name,
	       'c:s'   => \$cabinet_type,      'cabinettype:s'  => \$cabinet_type,
	       
	       );

    if ( defined($opt_version) ) { &print_version(); }
    if ( defined($opt_help)) { &print_usage(); }
    if (!defined($host)) { &print_usage("You need to supply a hostname/ip address for the storage cabinet"); }
    if (!($cabinet_type=~/ds400/i || $cabinet_type=~/ds300/i)) { &print_usage("cabinettype has to be either ds300 or ds400");}
    if (!defined($test_name)) { $test_name=$default_test; }
    if (!defined($known_tests{$test_name})) { &print_usage("$test_name is an unknown test to perform");}
}

&process_options();

&{$known_tests{$test_name}};

print "$res $test_name ($data)\n";
exit $ERRORS{$res};



