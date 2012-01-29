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
# -h <history file>
my %cli_opts = ();
Getopt::Std::getopts('xvc:s:h:',\%cli_opts);

$options_file = $cli_opts{c} if ($cli_opts{c});
my $options = read_options("$options_file");
$$options{src_dir} = $cli_opts{s} if ($cli_opts{s});
$$options{verbose} = $cli_opts{v} if ($cli_opts{v});

my $min = 1;
my $max = 1;
# i don't usually do 'defined' but the value could be 0
$min = $$options{min} if (defined $$options{min});
$max = $$options{max} if (defined $$options{max});
# just in case max/min get switched or something, user error...?
if ($min > $max) {
    my $temp = $max;
    $max = $min;
    $min = $temp;
}
my $number = (int(rand($max-$min))+$min)-1;
my $ua = new LWP::UserAgent;



opendir DIR,"$$options{src_dir}";
my @files = grep { !/^\.\.?$/ } readdir DIR;
closedir DIR;

fisher_yates_shuffle(@files);
$number = $#files if ($number > $#files);
foreach my $file (@files[0 .. $number]) {
    if (upload_to_flickr($options,"$$options{src_dir}/$file",$ua)) {
        unlink "$$options{src_dir}/$file";
    }
}
exit;

sub upload_to_flickr {
    my $options     = shift;
    my $filename    = shift;
    my $ua          = shift;

    my $url = 'http://api.flickr.com/services/upload/';

    my $req = POST $url,
        Content_Type => 'form-data',
        Content => [
            is_public   => $$options{public},
            is_friend   => $$options{friends},
            is_family   => $$options{family},
            photo       => [ "$filename" ]
        ];

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
