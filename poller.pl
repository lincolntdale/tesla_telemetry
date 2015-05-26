#!/usr/bin/perl

# script that polls Tesla REST interface in the cloud for telemetry
# this just prints it out on stdout
#   ltd@Interlink.com.au

# For personal use only. No guarantees on anything. Use at own risk.


use LWP::UserAgent;
use LWP::Protocol::https;
use HTTP::Cookies;
use HTTP::Request;
use Data::Dumper;
use POSIX::strptime;
use POSIX;
use MIME::Base64;
use JSON::XS;

#my $DEBUG = 1;
my $ua;
my $data;					# config data
my $now = time;
my $cfgfile = "/root/tesla/tesla_poller.cfg";	# where we store it
my $REFRESH_VEHICLE_INTERVAL = (24*60*60 * 4);	# every 4 days


#############################################################################
# set our defaults

sub setup {
	$Data::Dumper::Deepcopy = 1;
	&load_config;

	$ua = LWP::UserAgent->new(
		keep_alive => 1,
		agent => 'poller.pl 0.02',
		timeout => 10,
		cookie_jar => { },
		requests_redirectable => [],
		ssl_opts => { verify_hostname => 1 } );

	$ua->add_handler("request_send",
		sub { shift->dump; return }) if $DEBUG;
	$ua->add_handler("response_done",
		sub { shift->dump; return }) if $DEBUG;
}

#############################################################################
# load/save configuration files

sub load_config {
	if (-r $cfgfile) {
		local (@ARGV, $/) = ($cfgfile);
		no warnings 'all'; eval <>; die "$@" if $@;
		&add_password_dialog
			if ($data->{email} eq "INSERT_USERNAME_HERE");
	} else {
		$data->{email} = "INSERT_USERNAME_HERE";
		$data->{password} = "INSERT_PASSWORD_HERE";
		$data->{user_credentials} = "";
		$data->{user_credentials_expire} = "";
		&save_config;
		&add_password_dialog;
	}
}

sub save_config {
	die "could not write $cfgfile: $!\n" if (!(open(F,">$cfgfile")));
	print F Data::Dumper->Dump([$data], ["data"]);
	close F;
}

#############################################################################

sub add_password_dialog {
	printf STDERR "New configuration stored to %s\n",$cfgfile;
	printf STDERR "Please edit this file and set your email/password.\n\n";
	exit(0);
}

#############################################################################

#
# 1. get /login
#

sub login {
	my $response = $ua->get("https://portal.vn.teslamotors.com/login");
	die "login failure: ".$response->status_line."\n"
		if ($response->code != 200);
}

#############################################################################

#
# 2. post credentials to /login if we don't have a user credential
#

sub do_login {
	printf STDERR " - doing login ...\n" if $DEBUG;
	my $response = $ua->post("https://portal.vn.teslamotors.com/login",
		Content => {
		'user_session[email]' => $data->{email},
		'user_session[password]' => $data->{password} });
	die "did not get 302 in do_login: ".$response->status_line."\n"
		if ($response->code != 302);
}

#############################################################################

#
# 3. get list of vehicles (if we haven't done so for a while)
#

sub get_vehicle_list {
	my $force = shift;
	printf STDERR "get_vehicle_list ...\n" if $DEBUG;
	if ((!$force) &&
	    ($now <= ($data->{last_vehicle_refresh_time} + $REFRESH_VEHICLE_INTERVAL))) {
		printf STDERR "skipping get-vehicle-list, have a current list (last fetched %0.0f min ago)..\n",
			(($data->{last_vehicle_refresh_time} - $now) / 60);
		return;
	}

	printf STDERR "%srefreshing vehicle list (last fetched %s)\n",
		($force ? "forcing " : ""), scalar localtime $data->{last_vehicle_refresh_time};
	$data->{last_vehicle_refresh_time} = $now;

	my $response = $ua->get("https://portal.vn.teslamotors.com/vehicles");
	die "did not get 200 in get_vehicle_list: ".$response->status_line."\n" if ($response->code != 200);

	my $vehicle_list = decode_json($response->decoded_content);
	foreach my $vehicle (@{($vehicle_list)}) {
		my $vin = $vehicle->{vin};
		printf STDERR " - got id %s vin %s\n",$vehicle->{id},$vehicle->{vin};
		$data->{vehicles}->{$vin} = $vehicle;
	}
	&save_config;
}

#############################################################################

#
# 4. for each vehicle see if we can get mobile data
#

sub is_mobile_enabled {
	foreach my $vin (keys %{($data->{vehicles})}) {
		my $id = $data->{vehicles}->{$vin}->{id};
		printf STDERR "is_mobile_enabled for $vin ...\n" if $DEBUG;
		my $response = $ua->get("https://portal.vn.teslamotors.com/vehicles/".$id."/mobile_enabled");
		die "did not get 200 in is_mobile_enabled: ".$response->status_line."\n" if ($response->code != 200);

		my $json = decode_json($response->decoded_content);
		printf STDERR "mobile %s for vin %s (id %s)\n",($json->{result} == 1 ? "enabled" : "disabled"),$vin,$id;
		$data->{vehicles}->{$vin}->{mobile_is_enabled} = $json->{result};
	}
}

#############################################################################

#
# one-shot telemetry
#

sub get_vehicle_telemetry {
	my $what = shift;  # vehicle_state, drive_state, climate_state, charge_state

	foreach my $vin (keys %{($data->{vehicles})}) {
		if ($data->{vehicles}->{$vin}->{mobile_is_enabled}) {
			my $id = $data->{vehicles}->{$vin}->{id};
			printf STDERR "get_vehicle_telemetry: $what for $vin ...\n" if $DEBUG;
	
			my $response = $ua->get("https://portal.vn.teslamotors.com/vehicles/".$id."/command/".$what);
			die "did not get 200 in get_vehicle_telemetry: ".$response->status_line."\n" if ($response->code != 200);

			my $json = decode_json($response->decoded_content);
			printf "%s (id %s vin %s):\n",$what,$id,$vin;
			foreach my $k (keys $json) {
				printf "\t%s: %s\n",$k,$json->{$k};
			}
			printf "\n";
			# TODO: XXX do something with this...
		}
	}
}

#############################################################################

#
# streaming telemetry
#

sub stream_telemetry {
	my $vin_to_stream = shift;
	my $found_token = "";
	my $tries = 0;

	$vin_to_stream = (keys %{($data->{vehicles})})[0] if ($vin_to_stream eq ""); # get first

	while ($tries < 2) {
		$tries++;

		if ((defined $data->{vehicles}->{$vin_to_stream}) && ($data->{vehicles}->{$vin_to_stream}->{mobile_is_enabled})) {
			$found_token = $data->{vehicles}->{$vin_to_stream}->{tokens}->[0];

			if ($found_token eq "") {
				printf STDERR "forcing vehicle list to get token for vin %s\n",$vin_to_stream;
				&get_vehicle_list(1);
				$found_token = $data->{vehicles}->{$vin_to_stream}->{tokens}->[0];
			}
		}
		die "could not stream telemetry for VIN $vin_to_stream because not enabled or no vin or no token\n" if ($found_token eq "");

		printf STDERR "going to stream for vin %s vehicle_id %s email %s token %s (try %d)..\n",
			$vin_to_stream, $data->{vehicles}->{$vin_to_stream}->{vehicle_id}, $data->{email}, $found_token, $tries;

		my $response = $ua->get("https://streaming.vn.teslamotors.com/stream/".
			$data->{vehicles}->{$vin_to_stream}->{vehicle_id}.
			"/?values=speed,odometer,soc,elevation,est_heading,est_lat,est_lng,".
			"power,shift_state,range,est_range,heading",
			"Authorization" => "Basic ".MIME::Base64::encode($data->{email}.":".$found_token, ""),
			":content_cb" => \&streaming_callback);

		if (($response->code == 401) && ($response->status_line eq "401 provide valid authentication")) {
			printf STDERR "failed to stream: ".$response->status_line.": so refreshing...\n";
			$data->{vehicles}->{$vin_to_stream}->{tokens}->[0] = "";
			next;
		} elsif ($response->code != 200) {
			die "did not get 200 in stream_telemetry: ".$response->status_line."\n" if ($response->code != 200);
		}

		# we must have timed out, so just finish our loop here
		printf STDERR "finished streaming.\n";
		last;
	}
}

sub streaming_callback {
	my $chunk = shift;
	chop($chunk);
	my @t = split(',',$chunk);

	printf "time %s, %03dmsec speed %s odometer %s soc %s elevation %s est_heading %s est_lat %s est_long %s power %s shift_state %s range %s est_range %s heading %s\n",
		scalar localtime($t[0]/1000),($t[0]%1000),
		$t[1],$t[2],$t[3],$t[4],$t[5],$t[6],$t[7],$t[8],$t[9],$t[10],$t[11],$t[12];
}

#############################################################################

#############################################################################

#
# MAIN
#

&setup;

# &login;		# don't think this is necessary
&do_login;		# do our login, get cookies
&get_vehicle_list;	# get our list of vehicles
&is_mobile_enabled;	# check to see what vehicles have remote access enabled

&get_vehicle_telemetry("vehicle_state"); 	# get vehicle_state
&get_vehicle_telemetry("drive_state"); 		# get drive_state
&get_vehicle_telemetry("climate_state"); 	# get climate_state
&get_vehicle_telemetry("charge_state"); 	# get charge_state

# use &stream_telemetry("VIN") if you want to stream for a particular VIN,
# if none specified it will stream the first one
&stream_telemetry;
