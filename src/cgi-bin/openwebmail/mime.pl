#
# encode_base64, decode_base64 and decode_qp are blatantly snatched
# from parts of the MIME-Base64 Perl modules.
#
# the encoding/decoding speed would be much faster if you install
# MIME-Base64 perl module (MIME-Base64-2.12.tar.gz) with XS support
#
use strict;

if (eval "require MIME::Base64") {
   import MIME::Base64;
   push @::Uses, "B$MIME::Base64::VERSION";
} else {
   eval q{

sub encode_base64
{
   my $str = shift;
   my $res = "";
   my $eol = "\n";

   pos($str) = 0;      # thanks, Andreas!

   while ($str =~ /(.{1,45})/gs) {
      $res .= substr(pack('u', $1), 1);
      chop($res);
   }
   $res =~ tr|` -_|AA-Za-z0-9+/|;

   # Fix padding at the end:
   my $padding = (3 - length($str) % 3) % 3;
   $res =~ s/.{$padding}$/'=' x $padding/e if $padding;

   # Break encoded string into lines of no more than 76 characters each:
   $res =~ s/(.{1,76})/$1$eol/g if (length $eol);
   return $res;
} # sub

sub decode_base64
{
    local($^W) = 0; # unpack("u",...) gives bogus warning in 5.00[123]

    my $str = shift;
    my $res = "";

    $str =~ tr|A-Za-z0-9+=/||cd;            # remove non-base64 chars
    $str =~ s/=+$//;                        # remove padding
    $str =~ tr|A-Za-z0-9+/| -_|;            # convert to uuencoded format
    while ($str =~ /(.{1,60})/gs) {
        my $len = chr(32 + length($1)*3/4); # compute length byte
        $res .= unpack("u", $len . $1 );    # uudecode
    }
    $res;
} # sub

  } # q
} #if


if (eval "require MIME::QuotedPrint") {
   import MIME::QuotedPrint qw(decode_qp);
   push @::Uses, "Q$MIME::QuotedPrint::VERSION";
} else {
   eval q{

sub decode_qp
{
    my $res = shift;
    $res =~ s/[ \t]+?(\r?\n)/$1/g;  # rule #3 (trailing space must be deleted)
    $res =~ s/=\r?\n//g;            # rule #5 (soft line breaks)
    $res =~ s/=([\da-fA-F]{2})/pack("C", hex($1))/ge;
    $res;
} # sub

  } # q
} #if


sub decode_mimewords {
    my $encstr = shift;
    my %params = @_;
    my @tokens;
    $@ = '';           # error-return

    # Collapse boundaries between adjacent encoded words:
    $encstr =~ s{(\?\=)[\r\n \t]*(\=\?)}{$1$2}gs;
    pos($encstr) = 0;
    ### print STDOUT "ENC = [", $encstr, "]\n";

    # Decode:
    my ($charset, $encoding, $enc, $dec);
    while (1) {
        last if (pos($encstr) >= length($encstr));
        my $pos = pos($encstr);               # save it

        # Case 1: are we looking at "=?..?..?="?
        if ($encstr =~    m{\G                # from where we left off..
                            =\?([^?]*)        # "=?" + charset +
                             \?([bq])         #  "?" + encoding +
                             \?([^?]+)        #  "?" + data maybe with spcs +
                             \?=              #  "?="
                            }xgi) {
            ($charset, $encoding, $enc) = ($1, lc($2), $3);
            $dec = (($encoding eq 'q') ? _decode_Q($enc) : decode_base64($enc));
            push @tokens, [$dec, $charset];
            next;
        }

        # Case 2: are we looking at a bad "=?..." prefix?
        # We need this to detect problems for case 3, which stops at "=?":
        pos($encstr) = $pos;               # reset the pointer.
        if ($encstr =~ m{\G=\?}xg) {
            $@ .= qq|unterminated "=?..?..?=" in "$encstr" (pos $pos)\n|;
            push @tokens, ['=?'];
            next;
        }

        # Case 3: are we looking at ordinary text?
        pos($encstr) = $pos;               # reset the pointer.
        if ($encstr =~ m{\G                # from where we left off...
                         ([\x00-\xFF]*?    #   shortest possible string,
                          \n*)             #   followed by 0 or more NLs,
                         (?=(\Z|=\?))      # terminated by "=?" or EOS
                        }xg) {
            length($1) or die "MIME::Words: internal logic err: empty token\n";
            push @tokens, [$1];
            next;
        }

        # Case 4: bug!
        die "MIME::Words: unexpected case:\n($encstr) pos $pos\n\t".
            "Please alert developer.\n";
    }
    return (wantarray ? @tokens : join('',map {$_->[0]} @tokens));
}

sub _decode_Q {
    my $str = shift;
    $str =~ s/=([\da-fA-F]{2})/pack("C", hex($1))/ge;  # RFC-1522, Q rule 1
    $str =~ s/_/\x20/g;                                # RFC-1522, Q rule 2
    $str;
}

# this is used to decode fileblock generated by uuencode program
sub uudecode ($)
{
    local($^W) = 0; # unpack("u",...) gives bogus warning in 5.00[123]

    my $str=shift;
    my $res = "";
    my $line;

    foreach $line ( split(/\n/, $str) ) {
       my $len = substr($line,0,1);
       $line=substr($line,1);
       $res .= unpack("u", $len . $line );    # uudecode
    }
    $res;
}

1;
