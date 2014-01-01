#!/usr/bin/perl
#
#
#
# TODO
#   - ensure data is UTF-8 (for JSON output)
#   - handle HEAD requests (at least for /)

use strict;
use warnings;

use threads;
use threads::shared;

use Net::UPnP::ControlPoint;
use LWP::UserAgent;
use HTTP::Daemon;
use HTTP::Status qw(:constants);
use XML::Simple;
use JSON;
use Text::Iconv;
use Time::HiRes qw/ gettimeofday /;
use POSIX qw/ strftime /;

use Data::Dumper;

my $log_level  = 'TRACE';
my $local_addr = '10.7.7.2';
my $local_port = '9999';
my $rediscover_timeout = 60;
my $target_server_name = shift @ARGV;

$SIG{PIPE} = 'IGNORE';

my %loglevels = (
        TRACE => 100,
        DEBUG => 75,
        INFO  => 50,
        WARN  => 10,
        ERROR => 1,
        NONE  => 0,
    );
my %rev_log = ();
foreach (keys %loglevels) {
    $rev_log{$loglevels{$_}} = $_;
}
$log_level = $loglevels{$log_level};

my %devices :shared;
my %subscriptions :shared;
my %states;

my $callback = HTTP::Daemon->new(
                    LocalAddr => $local_addr,
                    LocalPort => $local_port,
                    ReuseAddr => 1,
            ) or die "$0: Failed to start HTTPD: $!\n";
my $cb_url   = "http://$local_addr:".$callback->sockport()."/cb";
logmsg('DEBUG', "CallBack URL is $cb_url\n");

logmsg('INFO', 'starting first discovery...');
discover($target_server_name);
logmsg('INFO', 'subscribing...');
subscribe_all();

logmsg('INFO', 'starting rediscovery thread');
my $discover_thread = threads->create('rediscovery', $target_server_name);
$discover_thread->yield;

logmsg('INFO', 'waiting for requests on CB port...');
while (my $c = $callback->accept) {
    logmsg('DEBUG', "accept() ", $c->peerhost, ":", $c->peerport, "\n");
    my $r = $c->get_request;
    unless (defined $r) {
        logmsg('INFO', "HTTP::Request is undef: ", $c->peerhost, ":", $c->peerport, "\n");
        next;
    }
    logmsg('INFO', "Request: ", $r->method, " ", $r->uri->as_string);
    logmsg('DEBUG', "Headers: ", $r->headers->as_string('##'));
    my $charset = $r->headers->content_type_charset;
    logmsg('DEBUG', "Charset=", ($charset or ""));

    $c->force_last_request; # ignore any HTTP/1.1 'Connection: keep-alive'
    if ($r->method eq 'NOTIFY' and $r->uri->path eq '/cb') {
        handle_notify($c, $r);
    }
    elsif ($r->method eq 'GET') {
        if ($r->uri->path eq '/') {
            handle_get($c);
        }
        else {
            send_404($c, $r->uri->path);
        }
    }
    else {
        logmsg('WARN', "INVALID request: ",$r->method, " ", $r->uri->path, "\n");
        send_404($c, $r->uri->path); # FIXME
    }
    $c->close if $c;
    undef $c;
}

sub send_404 {
    my $client  = shift;
    my $path    = shift;

    logmsg('INFO', "send_404(): Not found: $path");
    my $data = <<__END;
<html>
<head><title>Not found</title></head>
<body><h1>Not found</h1>
The requested URL $path was not found on this server</body>
</html>
__END

    my $headers = HTTP::Headers->new();
    $headers->header('Content-Type', 'text/html');

    $client->send_response(
            HTTP::Response->new(HTTP_NOT_FOUND, "Not found", $headers, $data)
        );
}

sub send_412 {
    my $client  = shift;
    my $message = shift;

    logmsg('WARN', "Precondition failed: $message");
    my $data = <<__END;
<html>
<head><title>Precondition failed</title></head>
<body><h1>Precondition failed</h1>
Callback failed: $message</body>
</html>
__END

    my $headers = HTTP::Headers->new();
    $headers->header('Content-Type', 'text/html');

    $client->send_response(
            HTTP::Response->new(HTTP_NOT_FOUND, "Not found", $headers, $data)
        );
}

sub handle_get {
    my $client = shift;

    foreach (keys %states) {
        delete $states{$_}
            unless $subscriptions{$_};
    }

    logmsg('TRACE', Data::Dumper->Dump([\%states], ['states']));

    my %data = ();
    foreach my $sid (keys %states) {
        my $renderer = $states{$sid}->{name};
        $data{$renderer} = $states{$sid};
        $data{$renderer}->{sid} = $sid;
    }
    my $data = eval { JSON->new->pretty->encode(\%data); };
    if ($@) {
        logmsg('ERROR', "JSON encode failed: $@");
        $data = '{}';
    }

    my $headers = HTTP::Headers->new();
    $headers->header('Content-Type', 'application/json');
    $headers->header('Connection', 'close');

    $client->send_response(
            HTTP::Response->new(HTTP_OK, "OK", $headers, $data)
        );
}

sub handle_notify {
    my ($client, $request) = @_;

    my $sid = $request->header('sid');
    unless ($sid) {
        send_412($client, "no SID");
        return;
    }

    my $sub = $subscriptions{$sid};
    my $renderer = $sub->{name};
    unless ($renderer) {
        send_412($client, "invalid SID");
        return;
    }

    logmsg('INFO', "Callback from ", $client->peerhost, ":", $client->peerport,
            " => $renderer ($sid)\n");

    my $content = $request->content;
    logmsg('TRACE', "CONTENT=", $content);

    # we got the data, send OK to renderer
    $client->send_status_line;

    my $xml = XML::Simple->new();
    my $doc = $xml->XMLin($content);
    if ($doc->{'e:property'}->{'LastChange'}) {
        $doc = $xml->XMLin($doc->{'e:property'}->{'LastChange'});
        logmsg('TRACE', Data::Dumper->Dump([$doc]));
        my $cur_track = $doc->{InstanceID}->{CurrentTrackMetaData}->{val};
        if ($cur_track) {
            if ($cur_track eq 'NOT_IMPLEMENTED') {
                # print Data::Dumper->Dump([$doc]);
                # BubbleUPnP @ initial state sync
                $states{$sid} = {
                        name => $renderer,
                        last_changed => time,
                    };
            }
            else {
                my $cur = $xml->XMLin($cur_track);
                logmsg('TRACE', Data::Dumper->Dump([$cur], ['cur']));
                $cur = $cur->{item};
                my $data = {
                        name => $renderer,
                        last_changed => time,
                        artist => $cur->{'upnp:artist'},
                        title  => $cur->{'dc:title'},
                        album  => $cur->{'upnp:album'},
                        duration => $cur->{res}->{duration},
                    };
                $data->{original_track_number} = $cur->{'upnp:originalTrackNumber'}
                    if $cur->{'upnp:originalTrackNumber'};
                $data->{bitrate} = $cur->{res}->{bitrate}
                    if $cur->{res}->{bitrate};
                $data->{sample_freq} = $cur->{res}->{sampleFrequency}
                    if $cur->{res}->{sampleFrequency};
                $data->{channels} = $cur->{res}->{nrAudioChannels}
                    if $cur->{res}->{nrAudioChannels};
                $data->{size} = $cur->{res}->{size}
                    if $cur->{res}->{size};
                $data->{upnp_class} = $cur->{'upnp:class'}
                    if $cur->{'upnp:class'};

                $states{$sid} = $data;
            }
        }
        if ($doc->{InstanceID}->{TransportState}->{val}) {
            $states{$sid}->{state} = $doc->{InstanceID}->{TransportState}->{val};
        }
        logmsg('DEBUG', "DOC=", Data::Dumper->Dump([$doc], ['doc']));
    }
    else {
        logmsg('ERROR',  "NO LAST CHANGE: ", Data::Dumper->Dump([$doc], ['doc']));
    }
}

sub rediscovery {
    my $target = shift;
    sleep $rediscover_timeout;
    while (1) {
        logmsg('DEBUG', "starting discovery...\n");
        discover($target);
        subscribe_all();
        sleep $rediscover_timeout;
    }
}

sub subscribe_all {
    my $now = time();

    foreach my $sid (keys %subscriptions) {
        my $sub = $subscriptions{$sid};
        unless ($devices{$sub->{udn}}) {
            logmsg('INFO', "deleting subscription of vanished device: ",
                        $sub->{name}, ", sid = $sid\n");
            delete $subscriptions{$sid};
        }
        if ($now >= $sub->{start} + $sub->{timeout}) {
            logmsg('INFO', "deleting subscription after subscription timeout: ",
                        $sub->{name}, ", sid = $sid\n");
            delete $subscriptions{$sid};
        }
    }

    DEVICE:
    foreach my $udn (keys %devices) {
        my $dev = $devices{$udn};
        foreach my $sid (keys %subscriptions) {
            my $sub = $subscriptions{$sid};
            next unless ($sub->{udn} eq $udn);
            next DEVICE
                unless ($now >= $sub->{start} + $sub->{timeout} - $rediscover_timeout);
        }

        my ($sid, $timeout) = subscribe($dev->{url}, $cb_url);
        next unless defined $sid;
        $subscriptions{$sid} = shared_clone({
                    name    => $dev->{name},
                    url     => $dev->{url},
                    udn     => $udn,
                    timeout => $timeout,
                    start   => $now,
                });
    }
    logmsg('DEBUG', Data::Dumper->Dump([\%subscriptions], ['subscriptions']));
}

sub subscribe {
    my $sub_url = shift;
    my $cb_url = shift;
    my $req = HTTP::Request->new('SUBSCRIBE' => $sub_url);
    my $ua = LWP::UserAgent->new();
    $ua->default_header(
            CALLBACK => "<$cb_url>",
            NT       => 'upnp:event',
            TIMEOUT  => 'Second-1800',
        );

    my $res = eval { $ua->request($req); };
    if ($@) {
        logmsg('WARN', "subscribe(): $@");
        return;
    }

    unless ($res->is_success) {
        logmsg('WARN', "subscribe(): ", $res->status_line, "\n");
        return;
    }

    my $timeout = $res->header('timeout');
    $timeout =~ s/^\s*Second-(\d+)\s*$/$1/;
    logmsg('INFO', "subscribed to $sub_url with SID=",$res->header('sid'),"\n");
    return ($res->header('sid'), $timeout);
}

sub discover {
    my $target = shift;
    my $obj = Net::UPnP::ControlPoint->new();

    my %devs = ();

    my @dev_list = ();
    my $retry_cnt = 0;
    while (!@dev_list and $retry_cnt < 5) {
        @dev_list = $obj->search(st =>'upnp:rootdevice', mx => 3);
        $retry_cnt++;
    }

    my $devNum = 0;
    foreach my $dev (@dev_list) {
        my $device_type = $dev->getdevicetype();
        if  ($device_type ne 'urn:schemas-upnp-org:device:MediaRenderer:1') {
            next;
        }

        my $friendlyname = $dev->getfriendlyname();
        if ($target) {
            next unless $friendlyname =~ $target;
        }

        my $svc = $dev->getservicebyname('urn:schemas-upnp-org:service:AVTransport:1');
        next unless defined $svc;

        my $base = $dev->getdescription(name => 'URLBase'); # gmrender
        if (!$base) { # BubbleUPnP
            $base = $dev->getlocation();
            $base =~ s#^(http://.*?/).*$#$1#;
        }
        my $sub  = $svc->getdevicedescription(name => 'eventSubURL');
        if ($sub =~ m#^/#) {
            $base =~ s#/$##;
        }
        my $udn = $dev->getudn();
        logmsg('DEBUG', "SUB=$sub, BASE=$base");
        $devs{$udn} = {
                name => $friendlyname,
                url  => "$base$sub",
            };
    }

    foreach (keys %devs) {
        $devices{$_} = shared_clone($devs{$_});
    }
    logmsg('DEBUG', Data::Dumper->Dump([\%devices], ['devices']));
}

sub logmsg {
    my ($level, @msg) = @_;
    return if $loglevels{$level} > $log_level;
    my $msg = join "", @msg;
    chomp $msg;
    warn timestamp()," $level - $msg\n";
}

sub timestamp {
    my ($ts, $ys) = gettimeofday;
    my $secs = $ts % 60;
    return strftime('%Y-%m-%d %H:%M:', localtime($ts)).sprintf('%02.6f', "$secs.$ys");
}
