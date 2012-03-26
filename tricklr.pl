#!/usr/bin/perl
# tricklr.pl - uploads photos to your flickr photo stream.
# Copyright (C) 2012 Christopher P. Bills (cpbills@fauxtographer.net)
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.
use strict;
use warnings;

# Flickr::Upload will basically do exactly what we need. but why download
# a script to use with something else you have to grab custom from CPAN when
# it's just a wrapper around LWP::UserAgent and HTTP::Request::Common?
use LWP::UserAgent;
use HTTP::Request;
use HTTP::Request::Common 'POST';
use XML::Simple;
use Getopt::Std;
use Digest::MD5 'md5_hex';

my $config_name = 'tricklr.conf';
my @config_path = ();
if ($^O =~ /mswin/i) {
    @config_path = ("./${config_name}");
} else {
    @config_path = ( "/etc/${config_name}",
                     "$ENV{HOME}/.${config_name}",
                     "$ENV{HOME}/.config/${config_name}",
                     "./${config_name}" );
}
my $options_file = '';
foreach my $config (@config_path) {
    $options_file = $config if (-e "$config" && -r "$config");
}

# command line options are:
# -v ; enable verbose output
# -c <config file>
# -s <source image directory>
# -1 : send only one image to flickr
# -h <history file>
my %cli_opts = ();
Getopt::Std::getopts('xvc:s:h:1',\%cli_opts);

$options_file = $cli_opts{c} if ($cli_opts{c});
my $options = read_options("$options_file");
$$options{src_dir} = $cli_opts{s} if ($cli_opts{s});
$$options{verbose} = $cli_opts{v} if ($cli_opts{v});

my $min = 1;
my $max = 1;
# i don't usually do 'defined', but the value /could/ be 0
$min = $$options{min} if (defined $$options{min});
$max = $$options{max} if (defined $$options{max});

if (defined $$options{1}) {
    $min = 1;
    $max = 1;
}

# just in case max/min get switched or something, user error...?
if ($min > $max) {
    my $temp = $max;
    $max = $min;
    $min = $temp;
}

# generate a random number from $min to $max to use
my $number = (int(rand($max-$min))+$min);
print "sending $number photos to flickr\n" if ($$options{verbose});

if ($$options{auth_token}) {
    # this may re-set the auth token if they are invalid;
    # so we can't do an 'else', as the test value may change
    verify_auth_token($options);
}

unless ($$options{auth_token}) {
    $$options{frob} = get_frob($options);
    print_auth_url($options);
    $$options{auth_token} = get_auth_token($options);
    print "please update your configuration with:\n\n";
    print "auth_token  $$options{auth_token}\n\n";
}

if (opendir DIR,"$$options{src_dir}") {
    my @files = grep { !/^\.\.?$/ } readdir DIR;
    closedir DIR;

    fisher_yates_shuffle(\@files);
    $number = $#files if ($number > $#files);
    foreach my $file (@files[0 .. $number]) {
        unless (upload_to_flickr($options,"$$options{src_dir}/$file")) {
            unlink "$$options{src_dir}/$file";
        }
    }
} else {
    print STDERR "unable to open $$options{src_dir}: $!\n";
    exit 1;
}

exit;

sub upload_to_flickr {
    my $options     = shift;
    my $filename    = shift;

    my $url = 'http://api.flickr.com/services/upload/';

    my $args = {
        api_key         => $$options{api_key},
        auth_token      => $$options{auth_token},
        is_public       => $$options{public},
        is_friend       => $$options{friends},
        is_family       => $$options{family}
    };

    my $sig = $$options{secret};
    foreach my $key (sort {$a cmp $b} keys %$args) {
        my $value = (defined($$args{$key})) ? $$args{$key} : "";
        $sig .= $key . $value;
    }
    $sig = md5_hex($sig);

    my $browser = new LWP::UserAgent;
       $browser->timeout(60);
       $browser->requests_redirectable(['POST','GET','HEAD']);
    my $request = POST $url,
        Content_Type => 'form-data',
        Content => [
            %{$args},
            api_sig => $sig,
            photo   => [ "$filename" ]
        ];
    my $response = $browser->request($request);
    if ($response->is_success) {
        my $xml = new XML::Simple;
        my $data = $xml->XMLin($response->content);
        if ($$data{stat} eq 'ok') {
            if ($$options{verbose}) {
                print "uploaded $filename - photoid $$data{photoid}\n";
            }
            return 0;
        } else {
            print STDERR "\'$$data{err}{msg}\' when uploading $filename\n";
            return 1;
        }
    } else {
        print STDERR "failed to upload image $filename\n";
        print STDERR $response->status_line, "\n";
        return 1;
    }
    # shouldn't make it here...
    return 1;
}

sub print_auth_url {
    # prints the URL a user needs to enter to authorize this script
    # for write permission to their flickr stream.
    my $options = shift;

    my $args = {
        api_key => $$options{api_key},
        frob    => $$options{frob},
        perms   => 'write'
    };

    my $sig = sign_request($options,$args);
    my $url = "http://flickr.com/services/auth/?$sig";

    print "please browse to: $url\n";
    print "then hit [enter]";
    my $dummy = <STDIN>;
}

sub verify_auth_token {
    # verify that the auth token is valid and grants write access
    # and delete the stored value if the key proves to be invalid
    my $options = shift;

    my $args = {
        api_key     => $$options{api_key},
        auth_token  => $$options{auth_token},
        method      => 'flickr.auth.checkToken'
    };

    my $sig = sign_request($options,$args);
    my $url = "http://api.flickr.com/services/rest/?$sig";

    my $content = http_get($url);
    if ($content) {
        my $xml = new XML::Simple;
        my $data = $xml->XMLin($content);
        if ($$data{stat} eq 'ok') {
            if ($$data{auth}{perms} ne 'write') {
                print STDERR "no write permission for provided auth_token\n";
                delete $$options{auth_token};
            }
            return;
        } else {
            if ($$data{err}{code} == 98) {
                print STDERR "$$data{err}{msg} - reset auth tokens\n";
                delete $$options{auth_token};
                return;
            } else {
                print STDERR "$$data{err}{msg}\n";
                exit $$data{err}{code};
            }
        }
    } else {
        # we don't really want to clobber the token if the page is simply
        # unreachable, or the request fails for some other reason...
        print STDERR "failed to verify token one way or another\n";
        exit 1;
    }
}

sub get_auth_token {
    # returns the auth key once an account has been authenticated via
    # the web browser and granting the app permission...
    my $options = shift;

    my $args = {
        api_key => $$options{api_key},
        frob    => $$options{frob},
        method  => 'flickr.auth.getToken'
    };

    my $sig = sign_request($options,$args);
    my $url = "http://api.flickr.com/services/rest/?$sig";

    my $content = http_get($url);
    if ($content) {
        my $xml = new XML::Simple;
        my $data = $xml->XMLin($content);
        if ($$data{stat} eq 'ok') {
            return $$data{auth}{token};
        } else {
            if ($$data{err}{code} == 108) {
                print STDERR "$$data{err}{msg}: did you browse to the url?\n";
            } else {
                print STDERR "$$data{err}{msg}\n";
            }
            exit $$data{err}{code};
        }
    } else {
        print STDERR "failed to get auth key\n";
        exit 1;
    }
}

sub get_frob {
    # gets the 'frob' (what the fuck is a frob?) from flickr which is part
    # of the authentication process and needed to upload images.
    my $options = shift;

    my $args = {
        api_key => $$options{api_key},
        method  => 'flickr.auth.getFrob'
    };

    my $sig = sign_request($options,$args);
    my $url = "http://api.flickr.com/services/rest/?$sig";

    my $content = http_get($url);
    if ($content) {
        my $xml = new XML::Simple;
        my $data = $xml->XMLin($content);
        if ($$data{stat} eq 'ok') {
            return $$data{frob};
        } else {
            print STDERR "$$data{err}{msg}\n";
            exit $$data{err}{code};
        }
    } else {
        print STDERR "failed to get frob\n";
        exit 1;
    }
}

sub http_get {
    my $url     = shift;

    my $browser = new LWP::UserAgent;
       $browser->timeout(10);
       $browser->requests_redirectable(['POST','GET','HEAD']);
    my $request = new HTTP::Request('GET',"$url");
    my $response = $browser->request($request);

    if ($response->is_success) {
        return $response->content;
    }
    return undef;
}

sub sign_request {
    my $options = shift;
    my $args    = shift;

    my @params = ();
    my $sig = $$options{secret};
    foreach my $key (sort {$a cmp $b} keys %$args) {
        my $value = (defined($$args{$key})) ? $$args{$key} : "";
        $sig .= $key . $value;
        push @params,"$key=$value";
    }
    return join('&',@params) . '&api_sig=' . md5_hex($sig);
}

sub fisher_yates_shuffle {
    my $array = shift;
    my $i;
    for ($i = @$array; --$i; ) {
        my $j = int rand ($i+1);
        next if $i == $j;
        @$array[$i,$j] = @$array[$j,$i];
    }
}

sub read_options {
    my $config  = shift;

    my %options = ();
    if (open FILE,'<',$config) {
        while (<FILE>) {
            my $line = $_;
            $line =~ s/^\s+//;
            $line =~ s/\s+$//;
            next if ($line =~ /^#/);
            next if ($line =~ /^$/);

            my ($option,$value) = split(/\s+/,$line,2);
            if ($options{$option}) {
                print "WARN: option $option previously defined in config\n";
            }
            $options{$option} = $value;
        }
        close FILE;
    } else {
        print STDERR "could not open file: $config: $!\n";
    }
    return \%options;
}
