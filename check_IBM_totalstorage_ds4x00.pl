#!/usr/bin/perl -w

# author  : Thomas S. Iversen <zensonic@zensonic.dk>
# bugfixes: Philipp Höfliger <phoefliger@gmail.com>
#           Tests on ds4300 and ds4800. Ds4300 did not
#           have a "detected" keyword in the enclosure section to 
#           go after. 
# 
#           the ds4800 had other options in the enclosure section
#           than the ds4700 had. 
#          
# what:    monitor various aspects of an IBM ds4x00 storage enclosure
# license: GPL - http://www.fsf.org/licenses/gpl.txt
#
# 2009-04-09 - version 1.1 - bugfixes by Philipp Höfliger <phoefliger@gmail.com>
#                            See above.
#
#                          - addition of the -f,--file that reads the cabinet out
#                            from a file instead of contacting the controller
#
# 2009-04-08 - version 1.0 - initial version

use strict;
require 5.6.0;
use lib qw( /usr/lib/nagios );
use utils qw(%ERRORS $TIMEOUT &print_revision &support &usage);
use Getopt::Long;
use vars qw/$exit $opt_version $opt_timeout $opt_help $opt_command $opt_host $opt_verbose $res
$test_name $opt_sanname $opt_binary $PROGNAME $TIMEOUT $opt_file $opt_enclosure_name $opt_all $sudo/;

my @tests=();
$PROGNAME      = "check_IBM_dx4x00.pl";
$opt_binary    = '/opt/IBM_DS4000/client/SMcli';
$sudo          = '/usr/bin/sudo';
$opt_sanname   = 'ds4700';
$opt_verbose   = undef;
$opt_host      = undef;
$opt_file      = undef;
$TIMEOUT       = 100;
$res           = "OK";
$opt_all       = 1;

my $data;

# List of known tests that we can perform
my %known_tests=("system_status",  \&system_status, 
		 "array_status",   \&array_status,
		 "device_status",  \&device_status,
		 "logical_status", \&logical_status,
		 );

sub update_res {
    my $res_ref=shift;
    my $data_ref=shift;
    my $r=shift;
    my $l=shift;

    # Trim line before we return status
    $l=~s/^[\s]+//;
    $l=~s/[\s]+$//;
    $l=~s/[\s][\s]+/ /g;

    $$res_ref=$r if($ERRORS{$r}>$ERRORS{$$res_ref});
    if(defined($$data_ref)) {
	$$data_ref .= ", $l" if(defined($l));
    } else {
	$$data_ref .= $l if(defined($l));
    }
}

sub update_if_verbose {
    my $res_ref=shift;
    my $data_ref=shift;
    my $r=shift;
    my $l=shift;
    if(defined($opt_verbose)) {
	&update_res($res_ref, $data_ref, $r, $l);
    }
}

sub match_data {
    my $lines_ref=shift;
    my $match_start=shift;
    my $match_end=shift;
    my $skip=shift;
    my $collecting_data=0;
    
    my @m=();
    
  LINE: foreach (@$lines_ref) {
      unless($collecting_data) {
	  next LINE unless( m/$match_start/);
	  $collecting_data=1;
      } else {
	  last LINE if( m/$match_end/);
      }
      
      if(defined($skip)) {
	  next LINE if ( m/$skip/);
      }
      push(@m,$_);
     }
    return @m;
}

sub system_status_helper_method_a {
    my $input_ref=shift;
    my $test_name=shift;
    my $regexp=shift;
    my $gres_ref=shift;
    my $gres_data=shift;
    my @m=&match_data($input_ref,$regexp, "Detected",undef);

    # Skip test if we can not match anything.
    if(!@m) {
	print "Skipped test: $regexp, could not find regexp in output\n" if(defined($opt_verbose));
	return;
    }
    
    my $fline=$m[0];
    my $n;

    my $local_res="OK";
    my $local_data;
    $n=$1 if($fline=~/([0-9]*)\s*$regexp/i);

    if(!defined($n)) {
	&update_res(\$local_res,\$local_data, "WARNING", "Could not parse number of elements detected: $fline");
    }

    foreach my $line (@m) {
	if($line=~/status:/i && !($line=~/optimal/i)) {
	    &update_res(\$local_res, \$local_data, "CRITICAL", $line);
	}
    }

    if($local_res ne "OK") {
	&update_res($gres_ref, $gres_data, $local_res, $local_data);
    }
}

sub system_status_method_a {
    my $lines_ref=shift;
    my $test_name=shift;
    my $local_res_ref=shift;
    my $local_data_ref=shift;
    
    # Watch all these "sections". Cut them out and look for /status/i. If status is
    # not optimal or online, return error. If "section" not present in input
    # silently skip test.
    my @list=("Interconnect-Battery Canister Detected", "Batteries Detected", "SFPs Detected", "Power-Fan Canisters Detected","Power Supplies Detected", "Fans Detected", "Temperature Sensors Detected");
    
    foreach my $regexp (@list) {
	&system_status_helper_method_a($lines_ref, $test_name, $regexp, $local_res_ref, $local_data_ref);
    }
}

sub system_status_method_b {
    # Enclosure-method B
    my $lines_ref=shift;
    my $test_name=shift;
    my $local_res_ref=shift;
    my $local_data_ref=shift;

    my $item;
    foreach my $line (@$lines_ref) {
	chomp($line);
	if($line=~/Fan canister/i || $line=~/Power supply canister/i || $line=~/ESM card/i || $line=~/SFP/i) {
	    # Spans multiple lines
	    $item=$line;
	} elsif($line=~/Temperature:(.*)/i) {
	    my $status=$1;
	    &update_res($local_res_ref, $local_data_ref, "CRITICAL", $line) if(!($status=~/Optimal/i));
	} elsif($line=~/Enclosure path redundancy:(.*)/i) {
	    my $status=$1;
	    &update_res($local_res_ref, $local_data_ref, "CRITICAL", $line) if(!($status=~/ok/i));
	} elsif($line=~/Status:(.*)/) {
	    my $status=$1;
	    &update_res($local_res_ref, $local_data_ref, "CRITICAL", "$item: $status") if(!($status=~/optimal/i));
	} 
    }
}

sub system_status {
    my $input_ref=shift;
    my $test_name=shift;
    my $local_res="OK";
    my $local_data;

    my @m=&match_data($input_ref,"^ENCLOSURES-----", "--------","ENCLOSURES----");

    # Bugfix by Philipp (version 1.1)
    #
    # DS4300 (potentially other enclosures, maybe related to the firmware version instead
    #         of the model) has another way of presenting enclosure status. 
    # 
    # switch between the two by looking for the keyword "Detected" in the output. If it is present
    # use method A, if it isn't, use method B.
    
    my @l = grep(/Detected/i, @m);

    my $detect_method;
    if(scalar(@l) > 0) {
	$detect_method=\&system_status_method_a;
    } else {
	$detect_method=\&system_status_method_b;
    }	
    
    # Cut up the lines into sections for each enclosure/expansion unit.
    my @enclosure=();
    foreach my $line (@m) {
	if($line=~/Enclosure[0-9\s]*Overall Component Information/i) {
	    if(@enclosure) { &$detect_method(\@enclosure, $test_name, \$local_res, \$local_data); @enclosure=(); }
	}
	push(@enclosure,$line);
    }
    &$detect_method(\@enclosure, $test_name, \$local_res, \$local_data) if(@enclosure);


    if($local_res eq "OK") {
	&update_if_verbose(\$res, \$data, "OK", "$test_name: Optimal");
    } else {
	&update_res(\$res, \$data, $local_res, "$test_name: $local_res {$local_data}");
    }
}

sub array_status {
    my $input_ref=shift;
    my $test_name=shift;
    my $local_res="OK";
    my $local_data;

    my @m=&match_data($input_ref,"^ARRAYS-----", "--------",undef);

    # Find number of arrays.
    my $n;
    foreach my $line (@m) {
	$n=$1 if($line=~/Number of arrays:\s*([^\s]*)/i);
    }

    if(!defined($n)) {
	&update_res(\$local_res, \$local_data, "WARNING", "Could not find number of arrays in 'array_status'");
	return;
    }

    my $seen=0;
    my $array_status;
    foreach my $line (@m) {
	if($line=~/[Array ]?status:\s*([^\s]*)/i) {
	    $array_status=$1;
	    $seen++;
	    if(!defined($array_status) || !($array_status=~/online/i)) {
		&update_res(\$local_res, \$local_data, "CRITICAL", "One or more array(s) are not online");
	    }
	}
    }

    if($seen ne $n) {
	&update_res(\$local_res, \$local_data, "WARNING", "Could not account for all $n arrays");
    }

    if($local_res eq "OK") {
	&update_if_verbose(\$res, \$data, "OK", "$test_name: Optimal");
    } else {
	&update_res(\$res, \$data, $local_res, "$test_name: $local_res {$local_data}");
    }

}

sub device_status {
    my $input_ref=shift;
    my $test_name=shift;
    my $local_res="OK";
    my $local_data;

    my @m=&match_data($input_ref,"^DRIVES-----", "--------",undef);
    my @m1=&match_data(\@m,"SUMMARY", '^[\S]',undef);

    # Find number of logical.
    my $n;
    foreach my $line (@m1) {
	$n=$1 if($line=~/Number of drives:\s*([0-9]+)/i);
    }

    # This is tricky. Collect data only when we see a header we trust
    # and until we see an empty line.
    my @devices=();
    my $collecting=0;
    foreach my $line (@m1) {
	# Begin collecting from next line
	if(!$collecting && $line=~/TRAY/i && $line=~/CAPACITY/i && $line=~/STATUS/i) {
	    $collecting=1;
	    next;
	}
	
	# Turn off collection again. 
	$collecting=0 if($collecting && $line=~/^$/i);

	# Collect information
	push(@devices, $line) if($collecting);
    }

    if(scalar(@devices) ne $n) {
	&update_res(\$local_res, \$local_data, "WARNING", "Could not account for all $n devices");
    }

    foreach my $device (@devices) {
	if((!$device=~/optimal/i)) {
	    &update_res(\$local_res, \$local_data, "CRITICAL", "Device $device not optimal");
	}
    }

    if($local_res eq "OK") {
	&update_if_verbose(\$res, \$data, "OK", "$test_name: Optimal");
    } else {
	&update_res(\$res, \$data, $local_res, "$test_name: $local_res {$local_data}");
    }
}

sub logical_status {
    my $input_ref=shift;
    my $test_name=shift;
    my $local_res="OK";
    my $local_data;
    my @m=&match_data($input_ref,"STANDARD LOGICAL DRIVES-----", "--------",undef);

    # Find number of logical.
    my $n;
    foreach my $line (@m) {
	$n=$1 if($line=~/logical drives:\s*([0-9]+)/i);
    }

    # Cut out relevant summary block
    my @m1=&match_data(\@m,"SUMMARY", "DETAIL",undef);

    # This is tricky. Collect data only when we see a header we trust
    # and until we see an empty line.
    my @logicals=();
    my $collecting=0;
    foreach my $line (@m1) {
	# Begin collecting from next line
	if(!$collecting && $line=~/NAME/i && $line=~/ARRAY/i) {
	    $collecting=1;
	    next;
	}
	
	# Turn off collection again. 
	$collecting=0 if($collecting && $line=~/^$/i);

	# Collect information
	push(@logicals, $line) if($collecting);
    }

    if(scalar(@logicals) ne $n) {
	&update_res(\$local_res, \$local_data, "WARNING", "Could not account for all $n logical volumes");
    }

    foreach my $logical (@logicals) {
	if(!($logical=~/optimal/i)) {
	    &update_res(\$local_res, \$local_data, "CRITICAL", $logical);
	}
    }

    if($local_res eq "OK") {
	&update_if_verbose(\$res, \$data, "OK", "$test_name: Optimal");
    } else {
	&update_res(\$res, \$data, $local_res, "$test_name: $local_res {$local_data}");
    }

}

&process_options();


if (! -e $opt_binary) {
    my $res="CRITICAL";
    my $data="Could not execute $opt_binary\n";
    goto error_exit;
}


my @input;

if(defined($opt_file)) {
    # Read controller output from a file instead of 
    # executing an SMcli command. 
    if(! -f $opt_file) {
	$res="CRITICAL";
	$data="Could not open $opt_file";
	goto error_exit;
    }
    open(FILE, $opt_file);
    while(<FILE>) {
	push(@input, $_);
    }
    close(FILE)
} else {
    # Get controller output from SMcli command.
    
    alarm( $TIMEOUT ); # make sure we don't hang Nagios

    my $command="$sudo $opt_binary";
    $command .= " -n $opt_sanname" if(defined($opt_sanname));
    $command .= " -H $opt_host" if(defined($opt_host));
    $command .= " -c \"show storagesubsystem profile;\"";
    
    open(DATA,"$command|") || die "Could not execute $command";
    while(<DATA>) {
	chomp;
	push(@input,$_);
    }
    
    close(DATA);

    my $rc=$? >> 8;
    $|=1;
    
    if($rc > 0) {
	$res="WARNING";
	$data="Could not execute $command. Maybe you lack sudo permissions in the sudoers file. Ie append 'nagios      ALL=NOPASSWD: $command' to the sudoers file";
	goto error_exit;
    }

    alarm( 0 ); # we're not going to hang after this.
}

if(scalar(@input) <= 0) {
    $res="CRITICAL";
    $data="No input data to parse.";
    goto error_exit;
}

# Run the tests
my $test_name;
foreach my $tn (@tests) {
    &{$known_tests{$tn}}(\@input, $tn);
    $test_name .= ", $tn" if(!($test_name=~/all/i));
}
$test_name =~ s/^, //;


error_exit:

$data="" if(!defined($data));
$test_name="" if(!defined($test_name));
print "$res $test_name ($data)\n";

# Return total grand status.
exit $ERRORS{$res};


sub process_options {
    Getopt::Long::Configure( 'bundling' );
      GetOptions(
		 'V'     => \$opt_version,       'version'     => \$opt_version,
		 'v'     => \$opt_verbose,       'verbose'     => \$opt_verbose,
		 'h'     => \$opt_help,          'help'        => \$opt_help,
		 'H:s'   => \$opt_host,          'hostname:s'  => \$opt_host,
		 'f:s'   => \$opt_file,          'file:s'      => \$opt_file,
		 'n:s'   => \$opt_sanname,       'sanname:s'   => \$opt_sanname,
		 'o:i'   => \$TIMEOUT,           'timeout:i'   => \$TIMEOUT,
		 't:s'	 => \@tests,             'test:s'      => \@tests,
		 );
      
      if ( defined($opt_version) ) { local_print_revision(); }
      if ( defined($opt_help)) { &print_help(); }
      
      if(scalar(@tests) > 0) {
	  my $wrong;
	  foreach my $test (@tests) {
	      $wrong .= ", $test" if(!defined($known_tests{$test}));
	  }
	  if(defined($wrong)) {
	      $wrong=~s/^, //;
	      &print_help($wrong);
	      exit 1;
	  }
      }
      # If no tests are requested on the command line, run all tests
      if(scalar(@tests) <= 0) {
	  @tests=sort keys %known_tests;
	  $test_name = "all_known_tests";
      }
      
  }

sub local_print_revision { print_revision( $PROGNAME, '$Revision: 1.0 $ ' ); }

sub print_usage { print "Usage: $PROGNAME [-b <path_to_smcli>] [-H <host>] [-t <test_name>] [-n <san_name>] [-o <timeout>] [-v] [-h]\n"; }

sub print_help {
	local_print_revision();
	print "Copyright (c) 2009 Thomas S. Iversen <nagios-exchange\@zensonic.dk>\n\n",
	      "IBM DS4x00 storage enclosure plugin for Nagios\n\n";
	print_usage();
print <<EOT;
	-v, --verbose
		print extra debugging information
        -b, --binary=PATH
                path to SMCli binary.
        -f, --file=FILENAME
                filename containing output from the SMcli command against the storage cabinet.
	-h, --help
		print this help message
        -o, --timeout=TIMEOUT
                timout value in seconds to let SMcli command finish.
	-n, --sanname=SANNAME
	        name of the san controller.
	-H, --hostname=HOST
		name or IP address of enclosure to check if doing out-of-band monitoring
	-t, --test=TEST_NAME
		test to run, can be applied multiple times to run multiple tests

POSSIBLE TESTS:
EOT

foreach my $test (sort keys %known_tests) {
    print "	$test\n";
}
	
	print "\n\nDefault is to run all known tests unless specific tests are requested.\n";
	exit;
    }

