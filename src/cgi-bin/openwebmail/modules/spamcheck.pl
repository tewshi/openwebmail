package ow::spamcheck;
use strict;
#
# spamcheck.pl - routines to call external checker to detect spam
#
# 2004/07/01 tung.AT.turtle.ee.ncku.edu.tw
#
use IO::Socket;
require "modules/tool.pl";
require "modules/suid.pl";

# sub scanmsg(pipecmd, msg_reference)
# ret (spamlevel, '');
#     (-99999, runtime error);
# sub learnspam(pipecmd, msg_reference)
# ret (learned, exxamed);
#     (-99999, runtime error);
# sub larnham(pipecmd, msg_reference)
# ret (learned, exxamed);
#     (-99999, runtime error);

#
# The following routines assume the spamassassin is used for the spamcheck.
# To make this work, you have to start up the spamd first,
# then set 'enable_spamcheck yes' in the openwbemail.conf
# To speedup the spamcheck, it is recommended to use -L or --local options
# when you startup the spamd daemon, or user may encounter noticeable delay
# in message access
#

use vars qw (%spamcerr);
%spamcerr= (
   64 => "command line usage error",
   65 => "data format error",
   66 => "cannot open input",
   67 => "addressee unknown",
   68 => "host name unknown",
   69 => "service unavailable",
   70 => "internal software error",
   71 => "system error (e.g., can't fork)",
   72 => "critical OS file missing",
   73 => "can't create (user) output file",
   74 => "input/output error",
   75 => "temp failure; user is invited to retry",
   76 => "remote error in protocol",
   77 => "permission denied",
   78 => "configuration error",
);

# cmd:    /usr/local/bin/spamc -c -x -t60
# output: 212.8/5
sub scanmsg {
   my $ret=pipecmd_msg(@_);

   # spamc exit with spam level
   return ($1, '') if ($ret=~m!([\+\-]?[\d\.]+)/([\d+\.])! && $2!=0);

   # determine runtime error
   my $exit=$?&255;
   return(-99999, $spamcerr{$exit}) if (defined($spamcerr{$exit}));
   return(-99999, "spamd error, exit=$exit, ret=$ret");
}

# cmd:    /usr/local/bin/sa-learn --local --spam
# output: Learned from 1 message(s) (1 message(s) examined).
sub learnspam {
   my $ret=pipecmd_msg(@_);
   return (-99999, $ret) if ($ret!~/(\d+) message.*?(\d+) message/);
   return($1, $2);
}

# cmd:    /usr/local/bin/sa-learn --local --ham
# output: Learned from 1 message(s) (1 message(s) examined).
sub learnham {
   my $ret=pipecmd_msg(@_);
   return (-99999, $ret) if ($ret!~/(\d+) message.*?(\d+) message/);
   return($1, $2);
}

# common routine, ret pipe output #########################################
sub pipecmd_msg {
   my $username=getpwuid($>);	# username of euid
   my $pipecmd=ow::tool::untaint($_[0]); $pipecmd=~s/\@\@\@USERNAME\@\@\@/$username/g;
   my $r_message=$_[1]; # either sting ref or array ref may be used
   my $tmpfile=ow::tool::untaint("/tmp/.spamcheck.tmpfile.$$");

   # ensure tmpfile is owned by current euid but wll be writeable for forked pipe
   open(F, ">$tmpfile"); close(F); chmod(0666, $tmpfile);	

   # use fork to set ruid only if ruid!=euid && ruid !=0
   # ps: if caller is already a 'forked then die' process, it can set ruid=euid to avoid fork here
   if ($<!=$> && $<!=0) {
      local $SIG{CHLD}; undef $SIG{CHLD};  # disable $SIG{CHLD} temporarily for wait()
      local $|=1; # flush all output
      if (fork()==0) {
          close(STDIN); close(STDOUT); close(STDERR);
         # drop ruid/rgid to guarentee child ruid=euid=current euid, rgid=egid=current gid
         # thus dir/files created by child will be owned by current euid/egid
         ow::suid::drop_ruid_rgid();
         _pipecmd_msg($pipecmd, $r_message, $tmpfile);
         exit 0;
      }
      wait;
   } else {
      _pipecmd_msg($pipecmd, $r_message, $tmpfile);
   }

   open(F, $tmpfile); $_=<F>; close(F); $_=~s/[\r\n]//g;
   unlink $tmpfile;

   return $_;
}

# result/err in tmpfile since result may be used by different process
sub _pipecmd_msg {
   my ($pipecmd, $r_message, $tmpfile)=@_;
   my $errmsg;
   if (open(P, "|$pipecmd 2>/dev/null > $tmpfile")) {
      if (ref($r_message) eq 'ARRAY') {
         print P @{$r_message} or $errmsg=$!;
      } else {
         print P ${$r_message} or $errmsg=$!;
      }
      close(P);
   } else {
      $errmsg=$!;
   }
   if ($errmsg ne '') {
      open(F, ">$tmpfile"); print F $errmsg; close(F);
   }
}

1;