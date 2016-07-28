#!/usr/bin/perl -w

# July 2016, Thomas Schoebel-Theuer, 1&1 Internet AG

# Convert an ordinary natural load to a _ramped_ one.
# The spatial locality is not changed at all.
# Only the IOPS increases linearly over time.

# This yields some kind of intermediate between a natural load and
# an artificial one.

use English;
use strict;

my $inname = $ARGV[0];
my $speedup = 10; # delta IOPS / s
$speedup = $ARGV[1] if $ARGV[1];

die "bad name '$inname'" if !$inname;
my $outname = `basename $inname`;
$outname =~ s/\.load($|\..*)/.ramped-$speedup.load.gz/;
die "bad output filename '$outname'" if $outname eq $inname;

open IN, "zgrep ';' $inname |" or die "cannot read '$inname'\n";
open OUT, "| gzip -9 > $outname" or die "cannot create '$outname'\n";


my $copyright = `noecho=1; script_dir=\$(dirname $0); source \$script_dir/modules/lib.sh; echo_copyright`;

print OUT $copyright;
print OUT "Called as $0 @ARGV\n";
print OUT "start ; sector; length ; op ;  replay_delay ; replay_duration\n";

my $time = 0.0;

while (my $line = <IN>) {
  next if $line =~ m/^[a-z]/;
  my @values = split(/;/, $line);

  $values[0] = sprintf("%14.9f", $time);
  print OUT join(';', @values);

  my $speed = $speedup * $time;
  $speed = 1.0 if $speed < 1.0;
  my $time_plus = 1.0 / $speed;
  $time += $time_plus;
}

close IN;
close OUT;
