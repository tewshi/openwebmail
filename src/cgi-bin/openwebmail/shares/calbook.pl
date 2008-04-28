#
# calbook.pl - read/write calbook.pl
#

use strict;
use Fcntl qw(:DEFAULT :flock);

# read the user calendar and put the records into 2 hashes.
# %items:
# The keys are the index numbers of the items.
# The value of each key is a hashref of this item's fields.
# %indexes:
# The keys are an idate string, number, or regex.
# The value of each key is an arrayref of the indexes that belong to this idate.
# $indexshift:
# This is used to shift the index number so records in multiple calendars won't collide
sub readcalbook {
   my ($calbook, $r_items, $r_indexes, $indexshift) = @_;
   my $item_count = 0;

   return 0 if (! -f $calbook);

   sysopen(CALBOOK, $calbook, O_RDONLY) or return -1;

   while (<CALBOOK>) {
      next if (/^#/);
      chomp;

      my @a     = split(/\@{3}/, $_);
      my $index = $a[0] + $indexshift;

      $a[9] = 1 if ($a[9] eq '');

      $r_items->{$index} = {
                              idate         => $a[1],
                              starthourmin  => $a[2],
                              endhourmin    => $a[3],
                              string        => $a[4],
                              link          => $a[5],
                              email         => $a[6],
                              eventcolor    => $a[7] || 'none',
                              charset       => $a[8] || '',
                              eventreminder => $a[9],
                           };

      my $idate = $a[1];
      $idate= '*' if ($idate =~ m/[^\d]/); # use '*' for regex date

      $r_indexes->{$idate} = [] unless exists $r_indexes->{$idate};

      push(@{$r_indexes->{$idate}}, $index);

      $item_count++;
   }

   close(CALBOOK);

   return($item_count);
}

sub writecalbook {
   my ($calbook, $r_items) = @_;

   my @indexlist = sort { $r_items->{$a}{idate} <=> $r_items->{$b}{idate} } keys %{$r_items};

   $calbook = ow::tool::untaint($calbook);

   if (! -f "$calbook" ) {
      sysopen(CALBOOK, $calbook, O_WRONLY|O_TRUNC|O_CREAT) or return -1;
      close(CALBOOK);
   }

   ow::filelock::lock($calbook, LOCK_EX) or return -1;
   sysopen(CALBOOK, $calbook, O_WRONLY|O_TRUNC|O_CREAT) or return -1;
   my $newindex = 1;
   foreach (@indexlist) {
      print CALBOOK join('@@@',
                           $newindex,
                           $r_items->{$_}{idate},
                           $r_items->{$_}{starthourmin},
                           $r_items->{$_}{endhourmin},
                           $r_items->{$_}{string},
                           $r_items->{$_}{link},
                           $r_items->{$_}{email},
                           $r_items->{$_}{eventcolor} || 'none',
                           $r_items->{$_}{charset} || '',
                           $r_items->{$_}{eventreminder}
                        ) . "\n";
      $newindex++;
   }
   close(CALBOOK);
   ow::filelock::lock($calbook, LOCK_UN);

   return($newindex);
}

1;
