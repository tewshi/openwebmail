#!/usr/bin/suidperl -T
#
# openwebmail-send.pl - mail composing and sending program
#

use vars qw($SCRIPT_DIR);
if ( $0 =~ m!^(.*?)/[\w\d\-\.]+\.pl! ) { $SCRIPT_DIR=$1; }
if (!$SCRIPT_DIR && open(F, '/etc/openwebmail_path.conf')) {
   $_=<F>; close(F); if ( $_=~/^([^\s]*)/) { $SCRIPT_DIR=$1; }
}
if (!$SCRIPT_DIR) { print "Content-type: text/html\n\nSCRIPT_DIR not set in /etc/openwebmail_path.conf !\n"; exit 0; }
push (@INC, $SCRIPT_DIR);

$ENV{PATH} = ""; # no PATH should be needed
$ENV{ENV} = "";      # no startup script for sh
$ENV{BASH_ENV} = ""; # no startup script for bash
umask(0002); # make sure the openwebmail group can write

use strict;
use Fcntl qw(:DEFAULT :flock);
use CGI qw(-private_tempfiles :standard);
use CGI::Carp qw(fatalsToBrowser carpout);
use Net::SMTP;

require "ow-shared.pl";
require "filelock.pl";
require "mime.pl";
require "iconv.pl";
require "maildb.pl";
require "htmlrender.pl";
require "htmltext.pl";

# common globals
use vars qw(%config %config_raw);
use vars qw($thissession);
use vars qw($loginname $logindomain $loginuser);
use vars qw($domain $user $userrealname $uuid $ugid $homedir);
use vars qw(%prefs %style %icontext);
use vars qw($quotausage $quotalimit);
use vars qw($folderdir @validfolders $folderusage);
use vars qw($folder $printfolder $escapedfolder);

# extern vars
use vars qw(%languagecharsets);	# defined in ow-shared.pl
use vars qw(%lang_folders %lang_sizes %lang_text %lang_err 
            %lang_prioritylabels %lang_msgformatlabels); # defined in lang/xy
use vars qw(%charset_convlist);	# defined in iconv.pl
use vars qw($_OFFSET $_FROM $_TO $_DATE $_SUBJECT $_CONTENT_TYPE 
            $_STATUS $_SIZE $_REFERENCES $_CHARSET);	# defined in maildb.pl

# local globals
use vars qw($messageid $escapedmessageid $mymessageid);
use vars qw($sort $page);
use vars qw($searchtype $keyword $escapedkeyword);

########################## MAIN ##############################
openwebmail_requestbegin();
$SIG{PIPE}=\&openwebmail_exit;	# for user stop
$SIG{TERM}=\&openwebmail_exit;	# for user stop

userenv_init();

$messageid = param("message_id");		# the orig message to reply/forward
$escapedmessageid = escapeURL($messageid);
$mymessageid = param("mymessageid");		# msg we are editing
$page = param("page") || 1;
$sort = param("sort") || $prefs{'sort'} || 'date';
$searchtype = param("searchtype") || 'subject';
$keyword = param("keyword") || '';
$escapedkeyword = escapeURL($keyword);

my $action = param("action");
if ($action eq "replyreceipt") {
   replyreceipt();
} elsif ($action eq "composemessage") {
   composemessage();
} elsif ($action eq "sendmessage") {
   sendmessage();
} else {
   openwebmailerror(__FILE__, __LINE__, "Action $lang_err{'has_illegal_chars'}");
}

openwebmail_requestend();
###################### END MAIN ##############################

################## REPLYRECEIPT ##################
sub replyreceipt {
   my $html='';
   my ($folderfile, $headerdb)=get_folderfile_headerdb($user, $folder);
   my @attr;
   my %HDB;

   if (!$config{'dbmopen_haslock'}) {
      filelock("$headerdb$config{'dbm_ext'}", LOCK_SH) or
         openwebmailerror(__FILE__, __LINE__, "$lang_err{'couldnt_locksh'} $headerdb$config{'dbm_ext'}");
   }
   dbmopen (%HDB, "$headerdb$config{'dbmopen_ext'}", undef);
   @attr=split(/@@@/, $HDB{$messageid});
   dbmclose(%HDB);
   filelock("$headerdb$config{'dbm_ext'}", LOCK_UN) if (!$config{'dbmopen_haslock'});

   if ($attr[$_SIZE]>0) {
      my $header;

      # get message header
      open (FOLDER, "+<$folderfile") or
          openwebmailerror(__FILE__, __LINE__, "$lang_err{'couldnt_open'} $folderfile! ($!)");
      seek (FOLDER, $attr[$_OFFSET], 0) or 
          openwebmailerror(__FILE__, __LINE__, "$lang_err{'couldnt_seek'} $folderfile! ($!)");
      $header="";
      while (<FOLDER>) {
         last if ($_ eq "\n" && $header=~/\n$/);
         $header.=$_;
      }
      close(FOLDER);

      # get notification-to
      if ($header=~/^Disposition-Notification-To:\s?(.*?)$/im ) {
         my $to=$1;
         my $from=$prefs{'email'};
         my $date=dateserial2datefield(gmtime2dateserial(), $prefs{'timeoffset'});

         my %userfrom=get_userfrom($logindomain, $loginuser, $user, $userrealname, "$folderdir/.from.book");
         foreach (keys %userfrom) {
            if ($header=~/$_/) {
               $from=$_; last;
            }
         }
         my $realname=$userfrom{$from};
         $realname =~ s/['"]/ /g;  # Get rid of shell escape attempts
         $from =~ s/['"]/ /g;  # Get rid of shell escape attempts

         my @recipients=();
         foreach (str2list($to,0)) {
            my $addr=(email2nameaddr($_))[1];
            next if ($addr eq "" || $addr=~/\s/);
            push (@recipients, $addr);
         }

         $mymessageid=fakemessageid($from) if (!$mymessageid);
         my $xmailer = $config{'name'};
         $xmailer .= " $config{'version'} $config{'releasedate'}" if ($config{'xmailer_has_version'});
         my $xoriginatingip = get_clientip();
         if ($config{'xoriginatingip_has_userid'}) {
            my $id=$loginuser; $id.="\@$logindomain" if ($config{'auth_withdomain'});
            $xoriginatingip .= " ($id)";
         }

         my $smtp;
         my $timeout=120; $timeout=180 if ($#recipients>=1); # more than 1 recipient
         $smtp=Net::SMTP->new($config{'smtpserver'},
                              Port => $config{'smtpport'},
                              Timeout => $timeout,
                              Hello => ${$config{'domainnames'}}[0]) or
            openwebmailerror(__FILE__, __LINE__, "$lang_err{'couldnt_open'} SMTP server $config{'smtpserver'}:$config{'smtpport'}!");

         # SMTP SASL authentication (PLAIN only)
         if ($config{'smtpauth'}) {
            my $auth = $smtp->supports("AUTH");
            $smtp->auth($config{'smtpauth_username'}, $config{'smtpauth_password'}) or
               openwebmailerror(__FILE__, __LINE__, "$lang_err{'network_server_error'}!<br>($config{'smtpserver'} - ".$smtp->message.")");
         }

         $smtp->mail($from);
         my @ok=$smtp->recipient(@recipients, { SkipBad => 1 });
         if ($#ok<0) {
            $smtp->close();
            openwebmailerror(__FILE__, __LINE__, "$lang_err{'sendmail_error'}!");
         }

         $smtp->data();

         my $s;

         if ($realname) {
            $s .= "From: ".encode_mimewords(qq|"$realname" <$from>|, ('Charset'=>$prefs{'charset'}))."\n";
         } else {
            $s .= "From: ".encode_mimewords(qq|$from|, ('Charset'=>$prefs{'charset'}))."\n";
         }
         $s .= "To: ".encode_mimewords($to, ('Charset'=>$prefs{'charset'}))."\n";
         $s .= "Reply-To: ".encode_mimewords($prefs{'replyto'}, ('Charset'=>$prefs{'charset'}))."\n" if ($prefs{'replyto'});

         # reply with english if sender has different charset than us
         my $is_samecharset=0;
         $is_samecharset=1 if ( $attr[$_CONTENT_TYPE]=~/charset="?\Q$prefs{'charset'}\E"?/i);

         if ($is_samecharset) {       
            $s .= "Subject: ".encode_mimewords("$lang_text{'read'} - $attr[$_SUBJECT]",('Charset'=>$prefs{'charset'}))."\n";
         } else {
            $s .= "Subject: ".encode_mimewords("Read - $attr[$_SUBJECT]", ('Charset'=>$prefs{'charset'}))."\n";
         }
         $s .= "Date: $date\n".
               "Message-Id: $mymessageid\n".
               "X-Mailer: $xmailer\n".
               "X-OriginatingIP: $xoriginatingip\n".
               "MIME-Version: 1.0\n";
         if ($is_samecharset) {       
            $s .= "Content-Type: text/plain; charset=$prefs{'charset'}\n\n".
                  "$lang_text{'yourmsg'}\n\n".
                  "  $lang_text{'to'}: $attr[$_TO]\n".
                  "  $lang_text{'subject'}: $attr[$_SUBJECT]\n".
                  "  $lang_text{'delivered'}: ".dateserial2str($attr[$_DATE], $prefs{'timeoffset'}, $prefs{'dateformat'})."\n\n".
                  "$lang_text{'wasreadon1'} ".dateserial2str(gmtime2dateserial(), $prefs{'timeoffset'}, $prefs{'dateformat'})." $lang_text{'wasreadon2'}\n\n";
         } else {
            $s .= "Content-Type: text/plain; charset=iso-8859-1\n\n".
                  "Your message\n\n".
                  "  To: $attr[$_TO]\n".
                  "  Subject: $attr[$_SUBJECT]\n".
                  "  Delivered: ".dateserial2str($attr[$_DATE], $prefs{'timeoffset'}, $prefs{'dateformat'})."\n\n".
                  "was read on".dateserial2str(gmtime2dateserial(), $prefs{'timeoffset'}, $prefs{'dateformat'}).".\n\n";
         }
         $s .= str2str($config{'mailfooter'}, "text")."\n" if ($config{'mailfooter'}=~/[^\s]/);

         $smtp->datasend($s);

         if (!$smtp->dataend()) {
            $smtp->close();
            openwebmailerror(__FILE__, __LINE__, "$lang_err{'sendmail_error'}!");
         }
         $smtp->quit();
      }

      # close the window that is processing confirm-reading-receipt
      $html=qq|<script language="JavaScript">\n|.
            qq|<!--\n|.
            qq|window.close();\n|.
            qq|//-->\n|.
            qq|</script>\n|;
   } else {
      my $msgidstr = str2html($messageid);
      $html="What the heck? Message $msgidstr seems to be gone!";
   }
   httpprint([], [htmlheader(), $html, htmlfooter(1)]);
}
################ END REPLYRECEIPT ################

############### COMPOSEMESSAGE ###################
# 9 composetype: reply, replyall, forward, editdraft,
#                forwardasorig (resent to another with exactly same msg),
#                forwardasatt (orig msg as an att),
#                continue(used after adding attachment),
#                sendto(newmail with dest user),
#                none(newmail)
use vars qw($_htmlarea_css_cache);
sub composemessage {
   my %message;
   my $attnumber;
   my $from ='';
   my $to = param("to") || '';
   my $cc = param("cc") || '';
   my $bcc = param("bcc") || '';
   my $replyto = param("replyto") || '';
   my $subject = param("subject") || '';
   my $body = param("body") || '';
   my $inreplyto = param("inreplyto") || '';
   my $references = param("references") || '';
   my $priority = param("priority") || 'normal';	# normal/urgent/non-urgent
   my $statname = param("statname") || '';

   my %userfrom=get_userfrom($logindomain, $loginuser, $user, $userrealname, "$folderdir/.from.book");
   if ( defined(param("from")) ) {
      $from=param("from");
   } elsif ($userfrom{$prefs{'email'}} ne "") {
      $from=qq|"$userfrom{$prefs{'email'}}" <$prefs{'email'}>|;
   } else {
      $from=qq|$prefs{'email'}|;
   }

   # charset is the charset choosed by user for current composing
   my $composecharset= $prefs{'charset'};
   foreach (values %languagecharsets) {
      if ($_ eq param("composecharset")) {
         $composecharset=$_; last;
      }
   }

   # msgformat is text, html or both
   my $msgformat = param("msgformat") || $prefs{'msgformat'} || 'text';
   my $newmsgformat = param("newmsgformat") || $msgformat;
   if (!htmlarea_compatible()) {
      $msgformat = $newmsgformat = 'text';
   }

   my ($attfiles_totalsize, $r_attfiles);
   if ( param("deleteattfile") ne '' ) { # user click 'del' link
      my $deleteattfile=param("deleteattfile");

      $deleteattfile =~ s/\///g;  # just in case someone gets tricky ...
      ($deleteattfile =~ /^(.+)$/) && ($deleteattfile = $1);   # untaint ...
      # only allow to delete attfiles belongs the $thissession
      if ($deleteattfile=~/^\Q$thissession\E/) {
         unlink ("$config{'ow_sessionsdir'}/$deleteattfile");
      }
      ($attfiles_totalsize, $r_attfiles) = getattfilesinfo();

   } elsif (defined(param('addbutton')) ||	# user press 'add' button
            param("webdisksel") ) { 		# file selected from webdisk
      ($attfiles_totalsize, $r_attfiles) = getattfilesinfo();

      no strict 'refs';	# for $attchment, which is fname and fhandle of the upload

      my $attachment = param("attachment");
      my $webdisksel = param("webdisksel");
      my ($attname, $attcontenttype);
      if ($webdisksel || $attachment) {
         if ($attachment) {
            # Convert :: back to the ' like it should be.
            $attname = $attachment;
            $attname =~ s/::/'/g;
            # Trim the path info from the filename
            if ($composecharset eq 'big5' || $composecharset eq 'gb2312') {
               $attname = zh_dospath2fname($attname);	# dos path
            } else {
               $attname =~ s|^.*\\||;		# dos path
            }
            $attname =~ s|^.*/||;	# unix path
            $attname =~ s|^.*:||;	# mac path and dos drive

            if (defined(uploadInfo($attachment))) {
#               my %info=%{uploadInfo($attachment)};
               $attcontenttype = ${uploadInfo($attachment)}{'Content-Type'} || 'application/octet-stream';
            } else {
               $attcontenttype = 'application/octet-stream';
            }

         } elsif ($webdisksel && $config{'enable_webdisk'}) {
            my $webdiskrootdir=$homedir.absolute_vpath("/", $config{'webdisk_rootpath'});
            ($webdiskrootdir =~ m!^(.+)/?$!) && ($webdiskrootdir = $1);  # untaint ...

            my $vpath=absolute_vpath('/', $webdisksel);
            my $err=verify_vpath($webdiskrootdir, $vpath);
            openwebmailerror(__FILE__, __LINE__, $err) if ($err);
            openwebmailerror(__FILE__, __LINE__, "$lang_text{'file'} $vpath $lang_err{'doesnt_exist'}") if (!-f "$webdiskrootdir/$vpath");

            $attachment=do { local *FH };
            open($attachment, "$webdiskrootdir/$vpath") or
               openwebmailerror(__FILE__, __LINE__, "$lang_err{'couldnt_open'} $lang_text{'webdisk'} $vpath! ($!)");
            $attname=$vpath; $attname=~s|/$||; $attname=~s|^.*/||;
            $attcontenttype=ext2contenttype($vpath);
         }

         if ($attachment) {
            if ( ($config{'attlimit'}) &&
                 ( ($attfiles_totalsize + (-s $attachment)) > ($config{'attlimit'}*1024) ) ) {
               close($attachment);
               openwebmailerror(__FILE__, __LINE__, "$lang_err{'att_overlimit'} $config{'attlimit'} $lang_sizes{'kb'}!");
            }
            my $attserial = time();
            open (ATTFILE, ">$config{'ow_sessionsdir'}/$thissession-att$attserial");
            print ATTFILE qq|Content-Type: $attcontenttype;\n|.
                          qq|\tname="|.encode_mimewords($attname, ('Charset'=>$composecharset)).qq|"\n|.
                          qq|Content-Id: <att$attserial>\n|.
                          qq|Content-Disposition: attachment; filename="|.encode_mimewords($attname, ('Charset'=>$composecharset)).qq|"\n|.
                          qq|Content-Transfer-Encoding: base64\n\n|;
            my ($buff, $attsize);
            while (read($attachment, $buff, 400*57)) {
               $buff=encode_base64($buff);
               $attsize += length($buff);
               print ATTFILE $buff;
            }
            close ATTFILE;
            close($attachment);	# close tmpfile created by CGI.pm

            my $attnum=$#{$r_attfiles}+1;
            ${${$r_attfiles}[$attnum]}{name}=$attname;
            ${${$r_attfiles}[$attnum]}{namecharset}=$composecharset;
            ${${$r_attfiles}[$attnum]}{id}="att$attserial";
            ${${$r_attfiles}[$attnum]}{file}="$thissession-att$attserial";
            ${${$r_attfiles}[$attnum]}{size}=$attsize;
            $attfiles_totalsize+=$attsize;
         }
      }

   # usr press 'send' button but no receiver, keep editing
   } elsif ( defined(param('sendbutton')) &&
             param("to") eq '' && param("cc") eq '' && param("bcc") eq '' ) {
      ($attfiles_totalsize, $r_attfiles) = getattfilesinfo();

   } elsif ($newmsgformat ne $msgformat) {	# chnage msg format between text & html
      ($attfiles_totalsize, $r_attfiles) = getattfilesinfo();

   } elsif (param('convto') ne "") {
      ($attfiles_totalsize, $r_attfiles) = getattfilesinfo();

   } else {	# this is new message, remove previous aged attachments
      deleteattachments();
   }

   my $composetype = param("composetype");
   if ($composetype eq "reply" || $composetype eq "replyall" ||
       $composetype eq "forward" || $composetype eq "forwardasorig" || 
       $composetype eq "editdraft" ) {
      if ($composetype eq "forward" || $composetype eq "forwardasorig" || 
          $composetype eq "editdraft") {
         %message = %{&getmessage($messageid, "all")};
      } else {
         %message = %{&getmessage($messageid, "")};
      }

      # make the $body(text version) $bodyhtml(html version) for new mesage 
      # from original mesage for different contenttype

      # we try to reserve the bdy in its original format so no info would be lost
      # if user browser is compatible with htmlarea for html msg composing
      my $bodyformat='text';	# text or html

      # handle the messages generated if sendmail is set up to send MIME error reports
      if ($message{contenttype} =~ /^multipart\/report/i) {
         foreach my $attnumber (0 .. $#{$message{attachment}}) {
            if (defined(${${$message{attachment}[$attnumber]}{r_content}})) {
               $body .= ${${$message{attachment}[$attnumber]}{r_content}};
               shift @{$message{attachment}};
            }
         }
      } elsif ($message{contenttype} =~ /^multipart/i) {
         # If the first attachment is text,
         # assume it's the body of a message in multi-part format
         if ( defined(%{$message{attachment}[0]}) && 
              ${$message{attachment}[0]}{contenttype} =~ /^text/i ) {
            if (${$message{attachment}[0]}{encoding} =~ /^quoted-printable/i) {
               $body = decode_qp(${${$message{attachment}[0]}{r_content}});
            } elsif (${$message{attachment}[0]}{encoding} =~ /^base64/i) {
               $body = decode_base64(${${$message{attachment}[0]}{r_content}});
            } elsif (${$message{attachment}[0]}{encoding} =~ /^x-uuencode/i) {
               $body = uudecode(${${$message{attachment}[0]}{r_content}});
            } else {
               $body = ${${$message{attachment}[0]}{r_content}};
            }
            if (${$message{attachment}[0]}{contenttype} =~ /^text\/html/i) {
               $bodyformat='html';
            }

            # handle mail with both text and html version
            # rename html to other name so if user in text compose mode,
            # the modified/forwarded text won't be overridden by html again
            if ( defined(%{$message{attachment}[1]}) &&
                 ${$message{attachment}[1]}{boundary} eq ${$message{attachment}[0]}{boundary} ) {
               # rename html attachment in the same alternative group
               if ( (${$message{attachment}[0]}{subtype}=~/alternative/i &&
                     ${$message{attachment}[1]}{subtype}=~/alternative/i &&
                     ${$message{attachment}[1]}{contenttype}=~/^text\/html/i  &&
                     ${$message{attachment}[1]}{filename}=~/^Unknown\./ ) ||
               # rename next if this=unknow.txt and next=unknow.html
                    (${$message{attachment}[0]}{contenttype}=~/^text\/plain/i &&
                     ${$message{attachment}[0]}{filename}=~/^Unknown\./       &&
                     ${$message{attachment}[1]}{contenttype}=~/^text\/html/i  &&
                     ${$message{attachment}[1]}{filename}=~/^Unknown\./ ) ) {
                  if ($msgformat ne 'text' && $bodyformat eq 'text' ) {
                     if (${$message{attachment}[1]}{encoding} =~ /^quoted-printable/i) {
                        $body = decode_qp(${${$message{attachment}[1]}{r_content}});
                     } elsif (${$message{attachment}[1]}{encoding} =~ /^base64/i) {
                        $body = decode_base64(${${$message{attachment}[1]}{r_content}});
                     } elsif (${$message{attachment}[0]}{encoding} =~ /^x-uuencode/i) {
                        $body = uudecode(${${$message{attachment}[1]}{r_content}});
                     } else {
                        $body = ${${$message{attachment}[1]}{r_content}};
                     }
                     $bodyformat='html';
                     # remove 1 attachment from the message's attachemnt list for html
                     shift @{$message{attachment}};
                  } else {
                     ${$message{attachment}[1]}{filename}=~s/^Unknown/Original/;
                     ${$message{attachment}[1]}{header}=~s!^Content-Type: \s*text/html;!Content-Type: text/html;\n   name="OriginalMsg.htm";!i;
                  }
               }
            }
            # remove 1 attachment from the message's attachemnt list for text
            shift @{$message{attachment}};
         } else {
            $body = '';
         }
      } else {
         $body = $message{'body'} || '';
         # handle mail programs that send the body encoded
         if ($message{contenttype} =~ /^text/i) {
            if ($message{encoding} =~ /^quoted-printable/i) {
               $body= decode_qp($body);
            } elsif ($message{encoding} =~ /^base64/i) {
               $body= decode_base64($body);
            } elsif ($message{encoding} =~ /^x-uuencode/i) {
               $body= uudecode($body);
            }
         }
         if ($message{contenttype} =~ /^text\/html/i) {
            $bodyformat='html';
         }
      }

      # carry attachments from old mesage to the new one
      if ($composetype eq "forward" ||  $composetype eq "forwardasorig" || 
          $composetype eq "editdraft") {
         if (defined(${$message{attachment}[0]}{header})) {
            my $attserial=time();
            ($attserial =~ /^(.+)$/) && ($attserial = $1);   # untaint ...
            foreach my $attnumber (0 .. $#{$message{attachment}}) {
               $attserial++;
               if (${$message{attachment}[$attnumber]}{header} ne "" &&
                   defined(${${$message{attachment}[$attnumber]}{r_content}}) ) {
                  open (ATTFILE, ">$config{'ow_sessionsdir'}/$thissession-att$attserial") or
                     openwebmailerror(__FILE__, __LINE__, "$lang_err{'couldnt_open'} $config{'ow_sessionsdir'}/$thissession-att$attserial! ($!)");
                  print ATTFILE ${$message{attachment}[$attnumber]}{header}, "\n\n";
                  print ATTFILE ${${$message{attachment}[$attnumber]}{r_content}};
                  close ATTFILE;
               }
            }
            ($attfiles_totalsize, $r_attfiles) = getattfilesinfo();
         }
      }

      if ($bodyformat eq 'html') {
         $body = html4nobase($body);
         if ($composetype ne "editdraft" && $composetype ne "forwardasorig") {
            $body = html4disablejs($body) if ($prefs{'disablejs'});
            $body = html4disableemblink($body, $prefs{'disableemblink'}) if ($prefs{'disableemblink'} ne 'none');
         }
         $body = html4attfiles($body, $r_attfiles, "$config{'ow_cgiurl'}/openwebmail-viewatt.pl", "action=viewattfile&amp;sessionid=$thissession");
         $body = html2block($body);
      }

      if ($msgformat eq 'auto') {
         $msgformat=$bodyformat;
         $msgformat='both' if ($msgformat eq 'html');
      }

      if ($bodyformat eq 'text' && $msgformat ne 'text')  {
         $body=text2html($body);
      } elsif ($bodyformat ne 'text' && $msgformat eq 'text')  {
         $body=html2text($body);
      }

      # convfrom is the charset choosed by user in last reading message
      my $convfrom=param('convfrom');
      if ($convfrom eq 'none.msgcharset') {
         foreach (values %languagecharsets) {
            if ($_ eq lc($message{'charset'})) {
               $composecharset=$_; last;
            }
         }
      }

      my $fromemail=$prefs{'email'};
      foreach (keys %userfrom) {
         if ($composetype eq "editdraft") {
            if ($message{'from'}=~/$_/) {
               $fromemail=$_; last;
            }
         } else { # reply/replyall/forward/forwardasatt/forwardasorig
            if ($message{'to'}=~/$_/ || $message{'cc'}=~/$_/ ) {
               $fromemail=$_; last;
            }
         }
      }
      if ($userfrom{$fromemail}) {
         $from=qq|"$userfrom{$fromemail}" <$fromemail>|;
      } else {
         $from=qq|$fromemail|;
      }


      if ($composetype eq "reply" || $composetype eq "replyall") {
         $subject = $message{'subject'} || '';
         $subject = "Re: " . $subject unless ($subject =~ /^re:/i);
         if (defined($message{'replyto'}) && $message{'replyto'}=~/[^\s]/) {
            $to = $message{'replyto'} || '';
         } else {
            $to = $message{'from'} || '';
         }

         if ($composetype eq "replyall") {
            my $toaddr=(email2nameaddr($to))[1];
            my @recv=();
            foreach my $email (str2list($message{'to'},0)) {
               my $addr=(email2nameaddr($email))[1];
               next if ($addr eq $fromemail || $addr eq $toaddr ||
                        $addr=~/undisclosed\-recipients:\s?;?/i );
               push(@recv, $email);
            }
            $to .= "," . join(',', @recv) if ($#recv>=0);

            @recv=();
            foreach my $email (str2list($message{'cc'},0)) {
               my $addr=(email2nameaddr($email))[1];
               next if ($addr eq $fromemail || $addr eq $toaddr ||
                        $addr=~/undisclosed\-recipients:\s?;?/i );
               push(@recv, $email);
            }
            $cc = join(',', @recv) if ($#recv>=0);
         }       

         if ($msgformat eq 'text') {
            # reparagraph orig msg for better look in compose window
            $body=reparagraph($body, $prefs{'editcolumns'}-8) if ($prefs{'reparagraphorigmsg'});
            # remove odds space or blank lines from body
            $body =~ s/(?: *\r?\n){2,}/\n\n/g;
            $body =~ s/^\s+//; $body =~ s/\s+$//;
            $body =~ s/\n/\n\> /g; $body = "> ".$body if ($body =~ /[^\s]/);
         } else {
            # remove all reference to inline attachments
            # because we don't carry them from original message when replying
            $body=~s/<[^\<\>]*?(?:background|src)\s*=[^\<\>]*?cid:[^\<\>]*?>//sig;

            # replace <p> with <br> to strip blank lines
            $body =~ s!<(?:p|p .*?)>!<br>!gi; $body =~ s!</p>!!gi;

            # replace <div> with <br> to strip layer and add blank lines
            $body =~ s!<(?:div|div .*?)>!<br>!gi; $body =~ s!</div>!!gi;

            $body =~ s!<br ?/?>(?:\s*<br ?/?>)+!<br><br>!gis;
            $body =~ s!^(?:\s*<br ?/?>)*!!gi; $body =~ s!(?:<br ?/?>\s*)*$!!gi;
            $body =~ s!(<br ?/?>|<div>|<div .*?>)!$1&gt; !gis; $body = '&gt; '.$body;
         }

         if ($prefs{replywithorigmsg} eq 'at_beginning') {
            my $h="On $message{'date'}, ".(email2nameaddr($message{'from'}))[0]." wrote";
            if ($msgformat eq 'text') {            
               $body = $h."\n".$body if ($body=~/[^\s]/);
            } else {
               $body = '<b>'.text2html($h).'</b><br>'.$body;
            }
         } elsif ($prefs{replywithorigmsg} eq 'at_end') {
            my $h="From: $message{'from'}\n".
                  "To: $message{'to'}\n";
            $h .= "Cc: $message{'cc'}\n" if ($message{'cc'} ne "");
            $h .= "Sent: $message{'date'}\n".
                  "Subject: $message{'subject'}\n";
            if ($msgformat eq 'text') {            
               $body = "---------- Original Message -----------\n".
                       "$h\n$body\n".
                       "------- End of Original Message -------\n";
            } else {
               $body = "<b>---------- Original Message -----------</b><br>\n".
                       text2html($h)."<br>$body<br>".
                       "<b>------- End of Original Message -------</b><br>\n";
            }
         }

         if (is_convertable($convfrom, $composecharset) ) {
            ($body, $subject, $to, $cc)=iconv($convfrom, $composecharset, $body,$subject,$to,$cc);
         }

         $replyto = $prefs{'replyto'} if (defined($prefs{'replyto'}));
         $inreplyto = $message{'messageid'};
         if ( $message{'references'} ne "" ) {
            $references = $message{'references'}." ".$message{'messageid'};
         } elsif ( $message{'inreplyto'} ne "" ) {
            $references = $message{'inreplyto'}." ".$message{'messageid'};
         } else {
            $references = $message{'messageid'};
         }

         my $origbody=$body;

         my $stationery;
         if ($config{'enable_stationery'} && $statname ne '') {
            my ($name,$content,%stationery);
            if ( -f "$folderdir/.stationery.book" ) {
               open (STATBOOK,"$folderdir/.stationery.book") or
                  openwebmailerror(__FILE__, __LINE__, "$lang_err{'couldnt_open'} $folderdir/.stationery.book! ($!)");
               while (<STATBOOK>) {
                  ($name, $content) = split(/\@\@\@/, $_, 2);
                  chomp($name); chomp($content);
                  $stationery{escapeURL($name)} = unescapeURL($content);
               }
               close (STATBOOK) or openwebmailerror(__FILE__, __LINE__, "$lang_err{'couldnt_close'} $folderdir/.stationery.book! ($!)");
            }
            $stationery = $stationery{$statname};
         }

         my $n="\n"; $n="<br>" if ($msgformat ne 'text');
         if ($stationery=~/[^\s]/) {
            $body = str2str($stationery, $msgformat).$n;
         } else {
            $body = $n.$n;
         }
         $body.= str2str($prefs{'signature'}, $msgformat).$n if ($prefs{'signature'}=~/[^\s]/);

         if ($prefs{replywithorigmsg} eq 'at_beginning') {
            $body = $origbody.$n.$body;
         } elsif ($prefs{replywithorigmsg} eq 'at_end') {
            $body = $body.$n.$origbody;
         }

      } elsif ($composetype eq "forward") {
         $subject = $message{'subject'} || '';
         $subject = "Fw: " . $subject unless ($subject =~ /^fw:/i);

         my $h="From: $message{'from'}\n".
               "To: $message{'to'}\n";
         $h .= "Cc: $message{'cc'}\n" if ($message{'cc'} ne "");
         $h .= "Sent: $message{'date'}\n".
               "Subject: $message{'subject'}\n";

         if ($msgformat eq 'text') {
            # remove odds space or blank lines from body
            $body =~ s/( *\r?\n){2,}/\n\n/g; $body =~ s/^\s+//; $body =~ s/\s+$//;
            $body = "\n".
                    "---------- Forwarded Message -----------\n".
                    "$h\n$body\n".
                    "------- End of Forwarded Message -------\n";
         } else {
            $body =~ s/<br>(\s*<br>)+/<br><br>/gis;
            $body = "<br>\n".
                    "<b>---------- Forwarded Message -----------</b><br>\n".
                    text2html($h)."<br>$body<br>".
                    "<b>------- End of Forwarded Message -------</b><br>\n";
         }

         if (is_convertable($convfrom, $composecharset) ) {
            ($body, $subject)=iconv($convfrom, $composecharset, $body,$subject);
         }

         my $n="\n"; $n="<br>" if ($msgformat ne 'text');
         $body .= $n.$n;
         $body .= str2str($prefs{'signature'}, $msgformat).$n if ($prefs{'signature'}=~/[^\s]/);

         $replyto = $prefs{'replyto'} if (defined($prefs{'replyto'}));
         $inreplyto = $message{'messageid'};
         if ( $message{'references'} ne "" ) {
            $references = $message{'references'}." ".$message{'messageid'};
         } elsif ( $message{'inreplyto'} ne "" ) {
            $references = $message{'inreplyto'}." ".$message{'messageid'};
         } else {
            $references = $message{'messageid'};
         }

      } elsif ($composetype eq "forwardasorig") {
         $subject = $message{'subject'} || '';
         $replyto = $message{'from'};
         if (is_convertable($convfrom, $composecharset) ) {
            ($body, $subject, $replyto)=iconv($convfrom, $composecharset, $body,$subject,$replyto);
         }

         $references = $message{'references'};
         $priority = $message{'priority'} if (defined($message{'priority'}));

         # remove odds space or blank lines from body
         if ($msgformat eq 'text') {
            $body =~ s/( *\r?\n){2,}/\n\n/g; $body =~ s/^\s+//; $body =~ s/\s+$//;
         } else {
            $body =~ s/<br>(\s*<br>)+/<br><br>/gis;
         }

      } elsif ($composetype eq "editdraft") {
         $subject = $message{'subject'} || '';
         $to = $message{'to'} if (defined($message{'to'}));
         $cc = $message{'cc'} if (defined($message{'cc'}));
         $bcc = $message{'bcc'} if (defined($message{'bcc'}));
         $replyto = $message{'replyto'} if (defined($message{'replyto'}));
         if (is_convertable($convfrom, $composecharset) ) {
            ($body, $subject, $to, $cc, $bcc, $replyto)=iconv($convfrom, $composecharset, $body,$subject,$to,$cc,$bcc,$replyto);
         }

         $inreplyto = $message{'inreplyto'};
         $references = $message{'references'};
         $priority = $message{'priority'} if (defined($message{'priority'}));
         $replyto = $prefs{'replyto'} if ($replyto eq '' && defined($prefs{'replyto'}));

         # we prefer to use the messageid in a draft message if available
         $mymessageid = $messageid if ($messageid);
      }

   } elsif ($composetype eq 'forwardasatt') {
      $msgformat='text' if ($msgformat eq 'auto');

      my ($folderfile, $headerdb)=get_folderfile_headerdb($user, $folder);
      filelock($folderfile, LOCK_SH|LOCK_NB) or
         openwebmailerror(__FILE__, __LINE__, "$lang_err{'couldnt_locksh'} $folderfile!");
      if (update_headerdb($headerdb, $folderfile)<0) {
         filelock($folderfile, LOCK_UN);
         openwebmailerror(__FILE__, __LINE__, "$lang_err{'couldnt_updatedb'} $headerdb$config{'dbm_ext'}");
      }

      my @attr=get_message_attributes($messageid, $headerdb);

      my $fromemail=$prefs{'email'};
      foreach (keys %userfrom) {
         if ($attr[$_TO]=~/$_/) {
            $fromemail=$_; last;
         }
      }
      if ($userfrom{$fromemail}) {
         $from=qq|"$userfrom{$fromemail}" <$fromemail>|;
      } else {
         $from=qq|$fromemail|;
      }

      open(FOLDER, "$folderfile");
      my $attserial=time();
      ($attserial =~ /^(.+)$/) && ($attserial = $1);   # untaint ...
      open (ATTFILE, ">$config{'ow_sessionsdir'}/$thissession-att$attserial") or
         openwebmailerror(__FILE__, __LINE__, "$lang_err{'couldnt_open'} $config{'ow_sessionsdir'}/$thissession-att$attserial! ($!)");
      print ATTFILE qq|Content-Type: message/rfc822;\n|,
                    qq|Content-Disposition: attachment; filename="Forward.msg"\n\n|;

      # copy message to be forwarded
      my $left=$attr[$_SIZE];
      seek(FOLDER, $attr[$_OFFSET], 0);

      # do not copy 1st line if it is the 'From ' delimiter
      $_ = <FOLDER>; $left-=length($_);
      if ( ! /^From / ) {
         print ATTFILE $_;
      }
      # copy other lines with the 'From ' delimiter escaped
      while ($left>0) {
         $_ = <FOLDER>; $left-=length($_);
         s/^From />From /;
         print ATTFILE $_;
      }

      close(ATTFILE);
      close(FOLDER);

      filelock($folderfile, LOCK_UN);

      ($attfiles_totalsize, $r_attfiles) = getattfilesinfo();

      $subject = $attr[$_SUBJECT];
      $subject = "Fw: " . $subject unless ($subject =~ /^fw:/i);
      if (is_convertable($attr[$_CHARSET], $composecharset) ) {
         ($subject)=iconv($attr[$_CHARSET], $composecharset, $subject);
      }

      $inreplyto = $message{'messageid'};
      if ( $message{'references'} ne "" ) {
         $references = $message{'references'}." ".$message{'messageid'};
      } elsif ( $message{'inreplyto'} ne "" ) {
         $references = $message{'inreplyto'}." ".$message{'messageid'};
      } else {
         $references = $message{'messageid'};
      }
      $replyto = $prefs{'replyto'} if (defined($prefs{'replyto'}));

      my $n="\n"; $n="<br>" if ($msgformat ne 'text');
      $body = $n."# Message forwarded as attachment".$n.$n;
      $body .= str2str($prefs{'signature'}, $msgformat).$n if ($prefs{'signature'}=~/[^\s]/);
 
   } elsif ($composetype eq 'continue') {
      $msgformat='text'    if ($msgformat eq 'auto');
      $newmsgformat='text' if ($newmsgformat eq 'auto');

      my $convto=param('convto');
      if ($composecharset ne $convto && is_convertable($composecharset, $convto) ) {
         ($body, $subject, $from, $to, $cc, $bcc, $replyto)=iconv($composecharset, $convto,
                                                     $body,$subject,$from,$to,$cc,$bcc,$replyto);
      }
      foreach (values %languagecharsets) {
         if ($_ eq $convto) {
            $composecharset=$_; last;
         }
      }

      if ( $msgformat eq 'text' && $newmsgformat ne 'text') {
         # default font size to 2 for html msg crecation
         $body=qq|<font size=2>|.text2html($body).qq|</font>|;
      } elsif ($msgformat ne 'text' && $newmsgformat eq 'text' ) {
         $body=html2text($body);
      }
      $msgformat=$newmsgformat;

   } else { # sendto or newmail
      $msgformat='text' if ($msgformat eq 'auto');
      $replyto = $prefs{'replyto'} if (defined($prefs{'replyto'}));

      my $n="\n"; $n="<br>" if ($msgformat ne 'text');
      $body=$n.$n.str2str($prefs{'signature'}, $msgformat).$n if ($prefs{'signature'}=~/[^\s]/);

   }

   # text area would eat leading \n, so we add it back here
   $body="\n".$body if ($msgformat eq 'text');
   # remove tail blank line and space
   $body=~s/\s+$/\n/s;

   # default font size to 2 for html msg crecation
   if ($msgformat ne 'text' && $composetype ne 'continue') {
      $body=qq|<font size=2>$body\n</font>|;
   }

   my ($html, $temphtml);

   my @tmp;
   if ($composecharset ne $prefs{'charset'}) {
      @tmp=($prefs{'language'}, $prefs{'charset'});
      ($prefs{'language'}, $prefs{'charset'})=('en', $composecharset);
      readlang($prefs{'language'});
      $printfolder = $lang_folders{$folder} || $folder || '';
   }
   $html = applystyle(readtemplate("composemessage.template"));
   if ($#tmp>=1) {
      ($prefs{'language'}, $prefs{'charset'})=@tmp;
   }

   my $compose_caller=param('compose_caller');
   my $urlparm="sessionid=$thissession&amp;folder=$escapedfolder&amp;page=$page&amp;sort=$sort&amp;keyword=$escapedkeyword&amp;searchtype=$searchtype";
   if ($compose_caller eq "read") {
      $temphtml = iconlink("backtofolder.gif", "$lang_text{'backto'} $printfolder", qq|accesskey="B" href="$config{'ow_cgiurl'}/openwebmail-read.pl?$urlparm&amp;action=readmessage&amp;message_id=$escapedmessageid&amp;headers=$prefs{'headers'}&amp;attmode=simple"|);
   } elsif ($compose_caller eq "abook") {
      $temphtml = iconlink("backtofolder.gif", "$lang_text{'backto'} $lang_text{'addressbook'}", qq|accesskey="B" href="$config{'ow_cgiurl'}/openwebmail-abook.pl?action=editaddresses&amp;$urlparm"|). qq|\n|;
   } else { # main
      $temphtml = iconlink("backtofolder.gif", "$lang_text{'backto'} $printfolder", qq|accesskey="B" href="$config{'ow_cgiurl'}/openwebmail-main.pl?action=listmessages&amp;$urlparm"|). qq|\n|;
   }

   $temphtml .= qq|&nbsp;\n|;

   # this refresh button is actually the same as add button,
   # because we need to post the request to keep user input data in the submission
   $temphtml .= iconlink("refresh.gif", $lang_text{'refresh'}, qq|accesskey="R" href="javascript:document.composeform.addbutton.click();"|);

   $html =~ s/\@\@\@BACKTOFOLDER\@\@\@/$temphtml/g;

   $temphtml = start_multipart_form(-name=>'composeform');
   $temphtml .= hidden(-name=>'action',
                       -default=>'sendmessage',
                       -override=>'1');
   $temphtml .= hidden(-name=>'sessionid',
                       -default=>$thissession,
                       -override=>'1');
   $temphtml .= hidden(-name=>'composetype',
                       -default=>'continue',
                       -override=>'1');
   $temphtml .= hidden(-name=>'deleteattfile',
                       -default=>'',
                       -override=>'1');
   $temphtml .= hidden(-name=>'inreplyto',
                       -default=>$inreplyto,
                       -override=>'1');
   $temphtml .= hidden(-name=>'references',
                       -default=>$references,
                       -override=>'1');
   $temphtml .= hidden(-name=>'composecharset',
                       -default=>$composecharset,
                       -override=>'1');
   $temphtml .= hidden(-name=>'compose_caller',
                       -default=>$compose_caller,
                       -override=>'1');

   $mymessageid=fakemessageid((email2nameaddr($from))[1]) if (!$mymessageid);
   $temphtml .= hidden(-name=>'mymessageid',
                       -default=>$mymessageid,
                       -override=>'1');

   $temphtml .= hidden(-name=>'folder',
                       -default=>$folder,
                       -override=>'1');
   if (param("message_id")) {
      $temphtml .= hidden(-name=>'message_id',
                          -default=>param("message_id"),
                          -override=>'1');
   }
   $temphtml .= hidden(-name=>'sort',
                       -default=>$sort,
                       -override=>'1');
   $temphtml .= hidden(-name=>'page',
                       -default=>$page,
                       -override=>'1');
   $temphtml .= hidden(-name=>'searchtype',
                       -default=>$searchtype,
                       -override=>'1');
   $temphtml .= hidden(-name=>'keyword',
                       -default=>$keyword,
                       -override=>'1');
   $temphtml .= hidden(-name=>'session_noupdate',
                       -default=>0,
                       -override=>'1');
   $html =~ s/\@\@\@STARTCOMPOSEFORM\@\@\@/$temphtml/g;

   my @fromlist=();
   foreach (sort_emails_by_domainnames($config{'domainnames'}, keys %userfrom)) {
      if ($userfrom{$_}) {
         push(@fromlist, qq|"$userfrom{$_}" <$_>|);
      } else {
         push(@fromlist, qq|$_|);
      }
   }
   $temphtml = popup_menu(-name=>'from',
                          -values=>\@fromlist,
                          -default=>$from,
                          -accesskey=>'F',
                          -override=>'1');
   $html =~ s/\@\@\@FROMMENU\@\@\@/$temphtml/;

   my @prioritylist=("urgent", "normal", "non-urgent");
   $temphtml = popup_menu(-name=>'priority',
                          -values=>\@prioritylist,
                          -default=>$priority || 'normal',
                          -labels=>\%lang_prioritylabels,
                          -override=>'1');
   $html =~ s/\@\@\@PRIORITYMENU\@\@\@/$temphtml/;

   # charset conversion menu
   my %ctlabels=( 'none' => "$composecharset *" );
   my @ctlist=('none');
   my %allsets;
   foreach (values %languagecharsets, keys %charset_convlist) {
      $allsets{$_}=1 if (!defined($allsets{$_}));
   }
   delete $allsets{$composecharset};
   
   if (defined($charset_convlist{$composecharset})) {
      foreach my $ct (sort @{$charset_convlist{$composecharset}}) {
         if (is_convertable($composecharset, $ct)) {
            $ctlabels{$ct}="$composecharset > $ct";
            push(@ctlist, $ct);
            delete $allsets{$ct};
         }
      }
   }
   push(@ctlist, sort keys %allsets);

   $temphtml = popup_menu(-name=>'convto',
                          -values=>\@ctlist,
                          -labels=>\%ctlabels,
                          -default=>'none',
                          -onChange=>'javascript:bodygethtml(); submit();',
                          -accesskey=>'I',
                          -override=>'1');
   $html =~ s/\@\@\@CONVTOMENU\@\@\@/$temphtml/g;

   $temphtml = textfield(-name=>'to',
                         -default=>$to,
                         -size=>'70',
                         -accesskey=>'T',
                         -override=>'1').
               qq|\n |.iconlink("addrbook.s.gif", $lang_text{'addressbook'}, qq|href="javascript:GoAddressWindow('to')"|);
   $html =~ s/\@\@\@TOFIELD\@\@\@/$temphtml/g;

   $temphtml = textfield(-name=>'cc',
                         -default=>$cc,
                         -size=>'70',
                         -accesskey=>'C',
                         -override=>'1').
               qq|\n |.iconlink("addrbook.s.gif", $lang_text{'addressbook'}, qq|href="javascript:GoAddressWindow('cc')"|);
   $html =~ s/\@\@\@CCFIELD\@\@\@/$temphtml/g;

   $temphtml = textfield(-name=>'bcc',
                         -default=>$bcc,
                         -size=>'70',
                         -override=>'1').
               qq|\n |.iconlink("addrbook.s.gif", $lang_text{'addressbook'}, qq|href="javascript:GoAddressWindow('bcc')"|);
   $html =~ s/\@\@\@BCCFIELD\@\@\@/$temphtml/g;

   $temphtml = textfield(-name=>'replyto',
                         -default=>$replyto,
                         -size=>'45',
                         -accesskey=>'R',
                         -override=>'1');
   $html =~ s/\@\@\@REPLYTOFIELD\@\@\@/$temphtml/g;

   $temphtml = checkbox(-name=>'confirmreading',
                        -value=>'1',
                        -label=>'');
   $html =~ s/\@\@\@CONFIRMREADINGCHECKBOX\@\@\@/$temphtml/;

   # table of attachment list
   my $htmlarea_attlist_js;

   if ($#{$r_attfiles}>=0) {
      $temphtml = "<table cellspacing='0' cellpadding='0' width='70%'><tr valign='bottom'>\n";

      $temphtml .= "<td><table cellspacing='0' cellpadding='0'>\n";
      for (my $i=0; $i<=$#{$r_attfiles}; $i++) {
         my $blank="";
         if (${${$r_attfiles}[$i]}{name}=~/\.(?:txt|jpg|jpeg|gif|png|bmp)$/i) {
            $blank="target=_blank";
         }
         if (${${$r_attfiles}[$i]}{namecharset} &&
             is_convertable(${${$r_attfiles}[$i]}{namecharset}, $composecharset) ) {
            (${${$r_attfiles}[$i]}{name})=iconv(${${$r_attfiles}[$i]}{namecharset}, $composecharset,
                                             ${${$r_attfiles}[$i]}{name});
         }
         my $attsize=${${$r_attfiles}[$i]}{size};
         if ($attsize > 1024) {
            $attsize=int($attsize/1024)."$lang_sizes{'kb'}";
         } else {
            $attsize= $attsize."$lang_sizes{'byte'}";
         }

         my $attlink=qq|$config{'ow_cgiurl'}/openwebmail-viewatt.pl/|.
                     escapeURL(${${$r_attfiles}[$i]}{name}).
                     qq|?sessionid=$thissession&amp;action=viewattfile&amp;|.
                     qq|attfile=|.escapeURL(${${$r_attfiles}[$i]}{file});
         $temphtml .= qq|<tr valign=top>|.
                      qq|<td><a href="$attlink" $blank><em>${${$r_attfiles}[$i]}{name}</em></a></td>|.
                      qq|<td nowrap align='right'>&nbsp; $attsize &nbsp;</td>|.
                      qq|<td nowrap>|.
                      qq|<a href="javascript:DeleteAttFile('${${$r_attfiles}[$i]}{file}')">[$lang_text{'delete'}]</a>|;
         if ($config{'enable_webdisk'} && !$config{'webdisk_readonly'}) {
            $temphtml .= qq|<a href=# title="$lang_text{'savefile_towd'}" onClick="window.open('$config{'ow_cgiurl'}/openwebmail-webdisk.pl?action=sel_saveattfile&amp;sessionid=$thissession&amp;attfile=${${$r_attfiles}[$i]}{file}&amp;attname=|.
                         escapeURL(${${$r_attfiles}[$i]}{name}).qq|', '_blank','width=500,height=330,scrollbars=yes,resizable=yes,location=no'); return false;">[$lang_text{'webdisk'}]</a>|;
         }
         $temphtml .= qq|</td></tr>\n|;

         if ($attlink !~ m!^https?://!) {
            if ($ENV{'HTTPS'}=~/on/i || $ENV{'SERVER_PORT'}==443) {
               $attlink="https://$ENV{'HTTP_HOST'}$attlink";
            } else {
               $attlink="http://$ENV{'HTTP_HOST'}$attlink"; 
            }
         }
         $htmlarea_attlist_js.=qq|,\n| if ($htmlarea_attlist_js);
         $htmlarea_attlist_js.=qq|"${${$r_attfiles}[$i]}{name}": "$attlink"|;
      }
      $temphtml .= "</table></td>\n";

      $temphtml .= "<td align='right' nowrap>\n";
      if ( $attfiles_totalsize ) {
         $temphtml .= "<em>" . int($attfiles_totalsize/1024) . $lang_sizes{'kb'};
         $temphtml .= " $lang_text{'of'} $config{'attlimit'} $lang_sizes{'kb'}" if ( $config{'attlimit'} );
         $temphtml .= "</em>";
      }
      $temphtml .= "</td>";

      $temphtml .= "</tr></table>\n";
   } else {
      $temphtml="";
   }

   $temphtml .= filefield(-name=>'attachment',
                         -default=>'',
                         -size=>'45',
                         -accesskey=>'A',
                         -override=>'1');
   $temphtml .= submit(-name=>"addbutton",
                       -OnClick=>'bodygethtml()',
                       -value=>"$lang_text{'add'}");
   $temphtml .= "&nbsp;";
   if ($config{'enable_webdisk'}) {
      $temphtml .= hidden(-name=>'webdisksel',
                          -value=>'',
                          -override=>'1');
      $temphtml .= submit(-name=>"webdisk",
                          -value=>"$lang_text{'webdisk'}",
                          -onClick=>qq|bodygethtml(); window.open('$config{ow_cgiurl}/openwebmail-webdisk.pl?sessionid=$thissession&amp;action=sel_addattachment', '_addatt','width=500,height=330,scrollbars=yes,resizable=yes,location=no'); return false;| );
   }
   $html =~ s/\@\@\@ATTACHMENTFIELD\@\@\@/$temphtml/g;

   $temphtml = textfield(-name=>'subject',
                         -default=>$subject,
                         -size=>'45',
                         -accesskey=>'S',
                         -override=>'1');
   $html =~ s/\@\@\@SUBJECTFIELD\@\@\@/$temphtml/g;

   my $backupsent=$prefs{'backupsentmsg'};
   if (defined(param("backupsent"))) {
      $backupsent=param("backupsent");
   }
   $temphtml = checkbox(-name=>'backupsentmsg',
                        -value=>'1',
                        -checked=>$backupsent,
                        -label=>'');
   $html =~ s/\@\@\@BACKUPSENTMSGCHECKBOX\@\@\@/$temphtml/;

   $temphtml = qq|<table width="100%" cellspacing="2" cellpadding="2" border="0"><tr><td>\n|;
   if ($msgformat eq 'text') {
      $temphtml .= textarea(-name=>'body',
                            -id=>'body',
                            -default=>$body,
                            -rows=>$prefs{'editrows'}||'20',
                            -columns=>$prefs{'editcolumns'}||'78',
                            -wrap=>'hard',	# incompatible with htmlarea
                            -accesskey=>'M',	# msg area
                            -override=>'1');
   } else {
      $temphtml .= textarea(-name=>'body',
                            -id=>'body',
                            -default=>$body,
                            -rows=>$prefs{'editrows'}||'20',
                            -columns=>$prefs{'editcolumns'}||'78',
                            -style=>'width:100%',
                            -accesskey=>'M',	# msg area
                            -override=>'1');
   }

   $temphtml .= qq|</td></tr></table>\n|;
   $html =~ s/\@\@\@BODYAREA\@\@\@/$temphtml/g;


   # 4 buttons: send, savedraft, spellcheck, cancel, 1 menu: msgformat

   $temphtml=qq|<table cellspacing="2" cellpadding="2" border="0"><tr>|;

   $temphtml.=qq|<td align="center">|.
              submit(-name=>"sendbutton",
                     -value=>"$lang_text{'send'}",
                     -onClick=>'bodygethtml(); return sendcheck();',
                     -accesskey=>'G',	# send, outGoing
                     -override=>'1').
              qq|</td>\n|;
   $temphtml.=qq|<td align="center">|.
              submit(-name=>"savedraftbutton",
                     -value=>"$lang_text{'savedraft'}",
                     -onClick=>'bodygethtml();',
                     -accesskey=>'W',	# savedraft, Write
                     -override=>'1').
              qq|</td>\n|;
   $temphtml.=qq|<td nowrap align="center">|.
              qq|<!--spellcheckstart-->\n|.
              popup_menu(-name=>'dictionary2',
                         -values=>$config{'spellcheck_dictionaries'},
                         -default=>$prefs{'dictionary'},
                         -onChange=>"JavaScript:document.spellcheckform.dictionary.value=this.value;",
                         -override=>'1').
              button(-name=>'spellcheckbutton',
                     -value=> $lang_text{'spellcheck'},
                     -onClick=>'spellcheck(); document.spellcheckform.submit();',
                     -override=>'1').
              qq|<!--spellcheckend-->\n|.
              qq|</td>\n|;
   $temphtml.=qq|<td align="center">|.
              button(-name=>'cancelbutton',
                      -value=> $lang_text{'cancel'},
                      -onClick=>'document.cancelform.submit();',
                      -override=>'1').
              qq|</td>\n|;

   $temphtml.=qq|<td align="center">\n|.
              qq|<!--newmsgformatstart-->\n|.
              qq|<table cellspacing="1" cellpadding="1" border="0"><tr>|.
              qq|<td nowrap align="right">&nbsp;$lang_text{'msgformat'}</td><td>|;

   if (htmlarea_compatible()) {
      $temphtml.=popup_menu(-name=>'newmsgformat',
                            -values=>['text', 'html', 'both'],
                            -default=>$msgformat,
                            -labels=>\%lang_msgformatlabels,
                            -onChange => "return msgfmtchangeconfirm();",
                            -override=>'1');
   } else {
      $temphtml.=popup_menu(-name=>'newmsgformat',
                            -values=>['text'],
                            -labels=>\%lang_msgformatlabels,
                            -onClick => "msgfmthelp();",
                            -override=>'1');
   }
   $temphtml.=hidden(-name=>'msgformat',
                     -value=>$msgformat,
                     -override=>'1').
              qq|</td></tr></table>\n|.
              qq|<!--newmsgformatend-->\n|.
              qq|</td>\n|;
        
   $temphtml.=qq|</tr></table>\n|;

   if ($prefs{'sendbuttonposition'} eq 'after') {
      $html =~ s/\@\@\@BUTTONSBEFORE\@\@\@//g;
      $html =~ s/\@\@\@BUTTONSAFTER\@\@\@/$temphtml/g;
   } elsif ($prefs{'sendbuttonposition'} eq 'both') {
      $html =~ s/\@\@\@BUTTONSBEFORE\@\@\@/$temphtml/g;
      $temphtml =~ s|<!--newmsgformatstart-->|<!--|;
      $temphtml =~ s|<!--newmsgformatend-->|-->|;
      $temphtml =~ s|<!--spellcheckstart-->|<!--|;
      $temphtml =~ s|<!--spellcheckend-->|-->|;
      $html =~ s/\@\@\@BUTTONSAFTER\@\@\@/$temphtml/g;
   } else {
      $html =~ s/\@\@\@BUTTONSBEFORE\@\@\@/$temphtml/g;
      $html =~ s/\@\@\@BUTTONSAFTER\@\@\@//g;
   }

   # spellcheck form
   $temphtml = start_form(-action=>"$config{'ow_cgiurl'}/openwebmail-spell.pl",
                          -name=>'spellcheckform',
                          -target=>'_spellcheck').
               hidden(-name=>'sessionid',
                      -default=>$thissession,
                      -override=>'1').
               hidden(-name=>'htmlmode',
                      -default=>($msgformat ne 'text'),
                      -override=>'1').
               hidden(-name=>'form',
                      -default=>'',
                      -override=>'1').
               hidden(-name=>'field',
                      -default=>'',
                      -override=>'1').
               hidden(-name=>'string',
                      -default=>'',
                      -override=>'1').
               hidden(-name=>'dictionary',
                      -default=>$prefs{'dictionary'},
                      -override=>'1');
   $html =~ s/\@\@\@STARTSPELLCHECKFORM\@\@\@/$temphtml/g;

   # cancel form
   if (param("message_id")) {
      $temphtml = start_form(-action=>"$config{'ow_cgiurl'}/openwebmail-read.pl",
                             -name=>'cancelform');
      $temphtml .= hidden(-name=>'action',
                          -default=>'readmessage',
                          -override=>'1');
      $temphtml .= hidden(-name=>'message_id',
                          -default=>param("message_id"),
                          -override=>'1');
      $temphtml .= hidden(-name=>'headers',
                          -default=>$prefs{'headers'} || 'simple',
                          -override=>'1');
   } else {
      $temphtml = start_form(-action=>"$config{'ow_cgiurl'}/openwebmail-main.pl",
                             -name=>'cancelform');
      $temphtml .= hidden(-name=>'action',
                          -default=>'listmessages',
                          -override=>'1');
   }
   $temphtml .= hidden(-name=>'sessionid',
                       -default=>$thissession,
                       -override=>'1');
   $temphtml .= hidden(-name=>'folder',
                       -default=>$folder,
                       -override=>'1');
   $temphtml .= hidden(-name=>'sort',
                       -default=>$sort,
                       -override=>'1');
   $temphtml .= hidden(-name=>'page',
                       -default=>$page,
                       -override=>'1');
   $temphtml .= hidden(-name=>'searchtype',
                       -default=>$searchtype,
                       -override=>'1');
   $temphtml .= hidden(-name=>'keyword',
                       -default=>$keyword,
                       -override=>'1');
   $html =~ s/\@\@\@STARTCANCELFORM\@\@\@/$temphtml/g;

   $temphtml = end_form();
   $html =~ s/\@\@\@ENDFORM\@\@\@/$temphtml/g;

   my $abook_width = $prefs{'abook_width'};
   $abook_width = 'screen.availWidth' if ($abook_width eq 'max');
   $html =~ s/\@\@\@ABOOKWIDTH\@\@\@/$abook_width/g;

   my $abook_height = $prefs{'abook_height'};
   $abook_height = 'screen.availHeight' if ($abook_height eq 'max');
   $html =~ s/\@\@\@ABOOKHEIGHT\@\@\@/$abook_height/g;

   my $abook_searchtype = $prefs{'abook_defaultfilter'}?escapeURL($prefs{'abook_defaultsearchtype'}):'';
   $html =~ s/\@\@\@ABOOKSEARCHTYPE\@\@\@/$abook_searchtype/g;

   my $abook_keyword = $prefs{'abook_defaultfilter'}?escapeURL($prefs{'abook_defaultkeyword'}):'';
   $html =~ s/\@\@\@ABOOKKEYWORD\@\@\@/$abook_keyword/g;

   # load css and js for html editor
   if ($msgformat ne 'text') {
      if (!$_htmlarea_css_cache) {
         open(F, "$config{'ow_htmldir'}/javascript/htmlarea.openwebmail/htmlarea.css") or
            openwebmailerror(__FILE__, __LINE__, "$lang_err{'couldnt_open'} $config{'ow_htmldir'}/javascript/htmlarea.openwebmail/htmlarea.css! ($!)");
         local $/; undef $/; $_htmlarea_css_cache=<F>; # read whole file in once
         close(F);
      }
      my $css=$_htmlarea_css_cache; $css=~s/\@\@\@BGCOLOR\@\@\@/$style{'window_light'}/g; $css=~s/"//g;
      my $lang=$prefs{'language'}; $lang='en' if ($composecharset ne $prefs{'charset'});
      my $direction="ltr"; $direction="rtl" if ($composecharset eq $prefs{'charset'} && is_RTLmode($prefs{'language'}));
      $html= qq|<script language="JavaScript" src="$config{'ow_htmlurl'}/javascript/htmlarea.openwebmail/htmlarea.js"></script>\n|.
             qq|<script language="JavaScript" src="$config{'ow_htmlurl'}/javascript/htmlarea.openwebmail/dialog.js"></script>\n|.
             qq|<script language="JavaScript" src="$config{'ow_htmlurl'}/javascript/htmlarea.openwebmail/popups/$lang/htmlarea-lang.js"></script>\n|.
             $html.
             qq|<style type="text/css">\n$css\n</style>\n|.
             qq|<script language="JavaScript">\n<!--\n|.
             qq|   var editor=new HTMLArea("body");\n|.
             qq|   editor.config.imgURL = "$config{'ow_htmlurl'}/javascript/htmlarea.openwebmail/images/";\n|.
             qq|   editor.config.popupURL = "$config{'ow_htmlurl'}/javascript/htmlarea.openwebmail/popups/$lang/";\n|.
             qq|   editor.config.bodyDirection = "$direction";\n|.
             qq|   editor.config.attlist = {\n$htmlarea_attlist_js};\n|.
             qq|   editor.generate();\n|.
             qq|//-->\n</script>\n|;
   }

   my @tmp;
   if ($composecharset ne $prefs{'charset'}) {
      @tmp=($prefs{'language'}, $prefs{'charset'});
      ($prefs{'language'}, $prefs{'charset'})=('en', $composecharset);
   }
   my $session_noupdate=param('session_noupdate');
   if (defined(param('savedraftbutton')) && !$session_noupdate) {
      # savedraft from user clicking, show show some msg for notifitcaiton
      my $msg=qq|<font size="-1">$lang_text{savedraft} |;
      $msg.= qq|($subject) | if ($subject);
      $msg.= qq|$lang_text{succeeded}</font>|;
      $html.= readtemplate('showmsg.js').
              qq|<script language="JavaScript">\n<!--\n|.
              qq|showmsg('$prefs{charset}', '$lang_text{savedraft}', '$msg', '$lang_text{"close"}', '_savedraft', 300, 100, 5);\n|.
              qq|//-->\n</script>\n|;
   }
   if (defined(param('savedraftbutton')) && $session_noupdate) {
      # this is auto savedraft triggered by timeoutwarning,
      # timeoutwarning js code is not required any more
      httpprint([], [htmlheader(), $html, htmlfooter(1)]);
   } else {
      # load timeoutchk.js and plugin jscode
      # which will be triggered when timeoutwarning shows up.
      my $jscode=qq|window.composeform.session_noupdate.value=1;|.
                 qq|window.composeform.savedraftbutton.click();|;
      httpprint([], [htmlheader(), $html, htmlfooter(2, $jscode)]);
   }
   if ($#tmp>=1) {
      ($prefs{'language'}, $prefs{'charset'})=@tmp;
   }
   return;
}
############# END COMPOSEMESSAGE #################

############### SENDMESSAGE ######################
sub sendmessage {
   no strict 'refs';	# for $attchment, which is fname and fhandle of the upload
   # goto composemessage if !savedraft && !send
   if ( !defined(param('savedraftbutton')) &&
        !(defined(param('sendbutton')) && (param("to")||param("cc")||param("bcc")))  ) {
      return(composemessage());
   }

   my %userfrom=get_userfrom($logindomain, $loginuser, $user, $userrealname, "$folderdir/.from.book");
   my ($realname, $from);
   if (param('from')) {
      ($realname, $from)=_email2nameaddr(param('from')); # use _email2nameaddr since it may return null name
   } else {
      ($realname, $from)=($userfrom{$prefs{'email'}}, $prefs{'email'});
   }
   $from =~ s/['"]/ /g;  # Get rid of shell escape attempts
   $realname =~ s/['"]/ /g;  # Get rid of shell escape attempts

   my $dateserial=gmtime2dateserial();
   my $date=dateserial2datefield($dateserial, $prefs{'timeoffset'});

   my $folder = param("folder");
   my $to = param("to");
   my $cc = param("cc");
   my $bcc = param("bcc");
   my $replyto = param("replyto");
   my $subject = param("subject") || 'N/A';
   my $inreplyto = param("inreplyto");
   my $references = param("references");
   my $composecharset = param("composecharset") || $prefs{'charset'};
   my $priority = param("priority");
   my $confirmreading = param("confirmreading");
   my $body = param("body");
   my $msgformat = param("msgformat");

   my $xmailer = $config{'name'};
   if ($config{'xmailer_has_version'}) {
      $xmailer .= " $config{'version'} $config{'releasedate'}";
   }
   my $xoriginatingip = get_clientip();
   if ($config{'xoriginatingip_has_userid'}) {
      $xoriginatingip .= " ($loginuser";
      $xoriginatingip .="\@$logindomain" if ($config{'auth_withdomain'});
      $xoriginatingip .= ")";
   }

   $mymessageid= fakemessageid($from) if (!$mymessageid);

   my ($attfiles_totalsize, $r_attfiles)=getattfilesinfo();

   $body =~ s/\r//g;		# strip ^M characters from message. How annoying!
   if ($msgformat ne 'text') {	# form html body to a complete html;
      $body=qq|<HTML>\n<HEAD>\n|.
            qq|<META content="text/html; charset=$composecharset" http-equiv=Content-Type>\n|.
            qq|<META content="$xmailer" name=GENERATOR>\n|.
            qq|</HEAD>\n<BODY bgColor=#ffffff>\n|.
            $body.
            qq|\n</BODY>\n</HTML>\n|;
      # replace links to attfiles with their cid
      $body = html4attfiles_link2cid($body, $r_attfiles, "$config{'ow_cgiurl'}/openwebmail-viewatt.pl");
   }

   my $attachment = param("attachment");
   my $attheader;
   if ( $attachment ) {
      if ( ($config{'attlimit'}) && ( ( $attfiles_totalsize + (-s $attachment) ) > ($config{'attlimit'} * 1024) ) ) {
         openwebmailerror(__FILE__, __LINE__, "$lang_err{'att_overlimit'} $config{'attlimit'} $lang_sizes{'kb'}!");
      }
      my $attcontenttype;
      if (defined(uploadInfo($attachment))) {
         $attcontenttype = ${uploadInfo($attachment)}{'Content-Type'} || 'application/octet-stream';
      } else {
         $attcontenttype = 'application/octet-stream';
      }
      my $attname = $attachment;
      # Convert :: back to the ' like it should be.
      $attname =~ s/::/'/g;
      # Trim the path info from the filename
      if ($composecharset eq 'big5' || $composecharset eq 'gb2312') {
         $attname = zh_dospath2fname($attname);	# dos path
      } else {
         $attname =~ s|^.*\\||;		# dos path
      }
      $attname =~ s|^.*/||;	# unix path
      $attname =~ s|^.*:||;	# mac path and dos drive

      $attheader = qq|Content-Type: $attcontenttype;\n|.
                   qq|\tname="|.encode_mimewords($attname, ('Charset'=>$composecharset)).qq|"\n|.
                   qq|Content-Disposition: attachment; filename="|.encode_mimewords($attname, ('Charset'=>$composecharset)).qq|"\n|.
                   qq|Content-Transfer-Encoding: base64\n|;
   }
   # convert message to prefs{'sendcharset'}
   if ($prefs{'sendcharset'} ne 'sameascomposing' &&
       is_convertable($composecharset, $prefs{'sendcharset'}) ) {
      ($from,$replyto,$to,$cc,$subject,$body)=iconv($composecharset, $prefs{'sendcharset'},
   						$from,$replyto,$to,$cc,$subject,$body);
      $composecharset=$prefs{'sendcharset'};
   }

   my $do_send=1;
   my $senderrstr="";
   my $senderr=0;

   my $do_save=1;
   my $saveerrstr="";
   my $saveerr=0;

   my $smtp;
   my $smtperrfile="/tmp/.openwebmail.smtperr.$$";
   local (*STDERR);	# localize stderr to a new global variable

   my ($savefolder, $savefile, $savedb);
   my $messagestart=0;
   my $messagesize=0;
   my $folderhandle=do { local *FH };

   if (defined(param('savedraftbutton'))) { # save msg to draft folder
      $savefolder = 'saved-drafts';
      $do_send=0;
      $do_save=0 if ($quotalimit>0 && $quotausage>=$quotalimit);
   } else {					     # save msg to sent folder && send
      $savefolder = 'sent-mail';
      $do_save=0 if (($quotalimit>0 && $quotausage>=$quotalimit) || param("backupsentmsg")==0 );
   }

   if ($do_send) {
      my @recipients=();
      foreach my $recv ($to, $cc, $bcc) {
         next if ($recv eq "");
         foreach (str2list($recv,0)) {
            my $addr=(email2nameaddr($_))[1];
            next if ($addr eq "" || $addr=~/\s/);
            push (@recipients, $addr);
         }
      }

      # validate receiver email
      if ($#{$config{'allowed_receiverdomain'}}>=0) {
         foreach my $email (@recipients) {
            my $allowed=0;
            foreach my $token (@{$config{'allowed_receiverdomain'}}) {
               if (lc($token) eq 'all' || $email=~/\Q$token\E$/i) {
                  $allowed=1; last;
               } elsif (lc($token) eq 'none') {
                  last;
               }
            }
            if (!$allowed) {
               openwebmailerror(__FILE__, __LINE__, $lang_err{'disallowed_receiverdomain'}." ( $email )");
            }
         }
      }

      # redirect stderr to smtperrfile
      ($smtperrfile =~ /^(.+)$/) && ($smtperrfile = $1);   # untaint ...
      open(STDERR, ">$smtperrfile");
      select(STDERR); local $| = 1; select(STDOUT);

      my $timeout=120; $timeout=180 if ($#recipients>=1); # more than 1 recipient
      if ( !($smtp=Net::SMTP->new($config{'smtpserver'},
                           Port => $config{'smtpport'},
                           Timeout => $timeout,
                           Hello => ${$config{'domainnames'}}[0],
                           Debug=>1)) ) {
         $senderr++;
         $senderrstr="$lang_err{'couldnt_open'} SMTP server $config{'smtpserver'}:$config{'smtpport'}!";
         writelog("send message error - couldn't open SMTP server $config{'smtpserver'}:$config{'smtpport'}");
         writehistory("send message error - couldn't open SMTP server $config{'smtpserver'}:$config{'smtpport'}");
      }

      # SMTP SASL authentication (PLAIN only)
      if ($config{'smtpauth'} && !$senderr) {
         my $auth = $smtp->supports("AUTH");
         if (! $smtp->auth($config{'smtpauth_username'}, $config{'smtpauth_password'}) ) {
            $senderr++;
            $senderrstr="$lang_err{'network_server_error'}!<br>($config{'smtpserver'} - ".$smtp->message.")";
            writelog("send message error - SMTP server $config{'smtpserver'} error - ".$smtp->message);
            writehistory("send message error - SMTP server $config{'smtpserver'} error - ".$smtp->message);
         }
      }

      $smtp->mail($from) or $senderr++ if (!$senderr);
      if (!$senderr) {
         my @ok=$smtp->recipient(@recipients, { SkipBad => 1 });
         $senderr++ if ($#ok<0);
      }
      $smtp->data()      or $senderr++ if (!$senderr);

      # save message to draft if smtp error, Dattola Filippo 06/20/2002
      if ($senderr && (!$quotalimit||$quotausage<$quotalimit)) {
         $do_save = 1;
         $savefolder = 'saved-drafts';
      }
   }

   if ($do_save) {
      ($savefile, $savedb)=get_folderfile_headerdb($user, $savefolder);

      if ( ! -f $savefile) {
         if (open ($folderhandle, ">$savefile")) {
            close ($folderhandle);
         } else {
            $saveerrstr="$lang_err{'couldnt_open'} $savefile!";
            $saveerr++;
            $do_save=0;
         }
      }

      if (!$saveerr && filelock($savefile, LOCK_EX|LOCK_NB)) {
         if (update_headerdb($savedb, $savefile)<0) {
            filelock($savefile, LOCK_UN);
            openwebmailerror(__FILE__, __LINE__, "$lang_err{'couldnt_updatedb'} $savedb$config{'dbm_ext'}");
         }

         my $oldmsgfound=0;
         my $oldsubject='';
         my %HDB;
         if (!$config{'dbmopen_haslock'}) {
            filelock("$savedb$config{'dbm_ext'}", LOCK_SH) or
               openwebmailerror(__FILE__, __LINE__, "$lang_err{'couldnt_locksh'} $savedb$config{'dbm_ext'}");
         }
         dbmopen(%HDB, "$savedb$config{'dbmopen_ext'}", undef);
         if (defined($HDB{$mymessageid})) {
            $oldmsgfound=1;
            $oldsubject=(split(/@@@/, $HDB{$mymessageid}))[$_SUBJECT];
         }
         dbmclose(%HDB);
         filelock("$savedb$config{'dbm_ext'}", LOCK_UN) if (!$config{'dbmopen_haslock'});

         if ($oldmsgfound) {
            if ($savefolder eq 'saved-drafts' && $subject eq $oldsubject) {
               # remove old draft if the subject is the same
               if (operate_message_with_ids("delete", [$mymessageid], $savefile, $savedb)<=0) {
                  $mymessageid=fakemessageid($from);	# use another id if remove failed
               }
            } else {
               # change mymessageid to ensure messageid is unique in one folder
               # note: this new mymessageid will be used by composemessage later
               $mymessageid=fakemessageid($from);
            }
         }

         if (open ($folderhandle, ">>$savefile") ) {
            seek($folderhandle, 0, 2);	# seek end manually to cover tell() bug in perl 5.8
            $messagestart=tell($folderhandle);
         } else {
            $saveerrstr="$lang_err{'couldnt_open'} $savefile!";
            $saveerr++;
            $do_save=0;
         }

      } else {
         $saveerrstr="$lang_err{'couldnt_lock'} $savefile!";
         $saveerr++;
         $do_save=0;
      }
   }

   # nothing to do, return error msg immediately
   if ($do_send==0 && $do_save==0) {
      if ($saveerr) {
         openwebmailerror(__FILE__, __LINE__, $saveerrstr);
      } else {
         print redirect(-location=>"$config{'ow_cgiurl'}/openwebmail-main.pl?action=listmessages&sessionid=$thissession&sort=$sort&folder=$escapedfolder&page=$page");
      }
   }

   my $s;

   # Add a 'From ' as delimeter for local saved msg
   if ($config{'delimiter_use_GMT'}) {
      $s = dateserial2delimiter(gmtime2dateserial(), "");
   } else {
      $s = dateserial2delimiter(gmtime2dateserial(), gettimeoffset()); # use server localtime for delimiter
   }
   print $folderhandle "From $user $s\n" or $saveerr++ if ($do_save && !$saveerr);

   if ($realname) {
      $s = "From: ".encode_mimewords(qq|"$realname" <$from>|, ('Charset'=>$composecharset))."\n";
   } else {
      $s = "From: ".encode_mimewords(qq|$from|, ('Charset'=>$composecharset))."\n";
   }
   dump_str($s, $smtp, $folderhandle, $do_send, $do_save, \$senderr, \$saveerr);

   if ($to) {
      $s = "To: ".encode_mimewords(folding($to), ('Charset'=>$composecharset))."\n";
      dump_str($s, $smtp, $folderhandle, $do_send, $do_save, \$senderr, \$saveerr);
   } elsif ($bcc && !$cc) { # recipients in Bcc only, To and Cc are null
      $s = "To: undisclosed-recipients: ;\n";
      print $folderhandle $s or $saveerr++ if ($do_save && !$saveerr);
   }

   if ($cc) {
      $s = "Cc: ".encode_mimewords(folding($cc), ('Charset'=>$composecharset))."\n";
      dump_str($s, $smtp, $folderhandle, $do_send, $do_save, \$senderr, \$saveerr);
   }
   if ($bcc) {	# put bcc header in folderfile only, not in outgoing msg
      $s = "Bcc: ".encode_mimewords(folding($bcc), ('Charset'=>$composecharset))."\n";
      print $folderhandle $s or $saveerr++ if ($do_save && !$saveerr);
   }

   $s  = "";
   $s .= "Reply-To: ".encode_mimewords($replyto, ('Charset'=>$composecharset))."\n" if ($replyto);
   $s .= "Subject: ".encode_mimewords($subject, ('Charset'=>$composecharset))."\n";
   $s .= "Date: $date\n";
   $s .= "Message-Id: $mymessageid\n";
   $s .= "In-Reply-To: $inreplyto\n" if ($inreplyto);
   $s .= "References: $references\n" if ($references);
   $s .= "Priority: $priority\n" if ($priority && $priority ne 'normal');
   $s .= "X-Mailer: $xmailer\n";
   $s .= "X-OriginatingIP: $xoriginatingip\n";
   if ($confirmreading) {
      if ($replyto) {
         $s .= "X-Confirm-Reading-To: ".encode_mimewords($replyto, ('Charset'=>$composecharset))."\n";
         $s .= "Disposition-Notification-To: ".encode_mimewords($replyto, ('Charset'=>$composecharset))."\n";
      } else {
         $s .= "X-Confirm-Reading-To: $from\n";
         $s .= "Disposition-Notification-To: $from\n";
      }
   }
   $s .= "MIME-Version: 1.0\n";
   dump_str($s, $smtp, $folderhandle, $do_send, $do_save, \$senderr, \$saveerr);

   my $contenttype;
   my $boundary = "----=OPENWEBMAIL_ATT_" . rand();
   my $boundary2 = "----=OPENWEBMAIL_ATT_" . rand();
   my $boundary3 = "----=OPENWEBMAIL_ATT_" . rand();

   my (@related, @mixed);
   foreach my $r_att (@{$r_attfiles}) {
      if (${$r_att}{'referencecount'}>0 && $msgformat ne "text") {
         push(@related, $r_att);
      } else {
         ${$r_att}{'referencecount'}=0;
         push(@mixed, $r_att);
      }
   }

   if ($attachment || $#mixed>=0 ) { # HAS MIXED ATT ##################################
      $contenttype="multipart/mixed;";

      dump_str(qq|Content-Type: multipart/mixed;\n|.
               qq|\tboundary="$boundary"\n|,
               $smtp, $folderhandle, $do_send, $do_save, \$senderr, \$saveerr);
      print $folderhandle "Status: R\n" or $saveerr++ if ($do_save && !$saveerr);
      dump_str(qq|\nThis is a multi-part message in MIME format.\n|,
               $smtp, $folderhandle, $do_send, $do_save, \$senderr, \$saveerr);

      if ($#related>=0) { # has related att, has mixed att
         if ($msgformat eq 'html') {
            dump_str(qq|\n--$boundary\n|.
                     qq|Content-Type: multipart/related;\n|.
                     qq|\ttype="text/html";\n|.
                     qq|\tboundary="$boundary2"\n|,
                     $smtp, $folderhandle, $do_send, $do_save, \$senderr, \$saveerr);
            
            dump_bodyhtml(\$body, $boundary2, $composecharset, $msgformat,
                              $smtp, $folderhandle, $do_send, $do_save, \$senderr, \$saveerr);
            dump_atts(\@related, $boundary2, $composecharset,
                      $smtp, $folderhandle, $do_send, $do_save, \$senderr, \$saveerr);

         } elsif ($msgformat eq "both") {
            $contenttype="multipart/related;";

            dump_str(qq|\n--$boundary\n|.
                     qq|Content-Type: multipart/related;\n|.
                     qq|\ttype="multipart/alternative";\n|.
                     qq|\tboundary="$boundary2"\n|,
                     $smtp, $folderhandle, $do_send, $do_save, \$senderr, \$saveerr);

            dump_str(qq|\n--$boundary2\n|.
                     qq|Content-Type: multipart/alternative;\n|.
                     qq|\tboundary="$boundary3"\n|,
                     $smtp, $folderhandle, $do_send, $do_save, \$senderr, \$saveerr);

            dump_bodytext(\$body, $boundary3, $composecharset, $msgformat,
                          $smtp, $folderhandle, $do_send, $do_save, \$senderr, \$saveerr);
            dump_bodyhtml(\$body, $boundary3, $composecharset, $msgformat,
                          $smtp, $folderhandle, $do_send, $do_save, \$senderr, \$saveerr);

            dump_str(qq|\n--$boundary3--\n|,
                     $smtp, $folderhandle, $do_send, $do_save, \$senderr, \$saveerr);

            dump_atts(\@related, $boundary2, $composecharset,
                      $smtp, $folderhandle, $do_send, $do_save, \$senderr, \$saveerr);
         }

         dump_str(qq|\n--$boundary2--\n|,
                  $smtp, $folderhandle, $do_send, $do_save, \$senderr, \$saveerr);

      } else {	# no related att, has mixed att
         if ($msgformat eq 'text') {
            dump_bodytext(\$body, $boundary, $composecharset,  $msgformat,
                          $smtp, $folderhandle, $do_send, $do_save, \$senderr, \$saveerr);
         
         } elsif ($msgformat eq 'html') {
            dump_bodyhtml(\$body, $boundary, $composecharset,  $msgformat,
                          $smtp, $folderhandle, $do_send, $do_save, \$senderr, \$saveerr);

         } elsif ($msgformat eq 'both') {
            dump_str(qq|\n--$boundary\n|.
                     qq|Content-Type: multipart/alternative;\n|.
                     qq|\tboundary="$boundary2"\n|,
                     $smtp, $folderhandle, $do_send, $do_save, \$senderr, \$saveerr);

            dump_bodytext(\$body, $boundary2, $composecharset, $msgformat,
                          $smtp, $folderhandle, $do_send, $do_save, \$senderr, \$saveerr);
            dump_bodyhtml(\$body, $boundary2, $composecharset, $msgformat,
                          $smtp, $folderhandle, $do_send, $do_save, \$senderr, \$saveerr);

            dump_str(qq|\n--$boundary2--\n|,
                     $smtp, $folderhandle, $do_send, $do_save, \$senderr, \$saveerr);
         }
      }

      dump_atts(\@mixed, $boundary, $composecharset,
                $smtp, $folderhandle, $do_send, $do_save, \$senderr, \$saveerr);

      if ($attachment) {
         dump_str(qq|\n--$boundary\n$attheader\n|,
                  $smtp, $folderhandle, $do_send, $do_save, \$senderr, \$saveerr);
         while (read($attachment, $s, 400*57)) { # attachmet fh to uploadfile stored by CGI.pm
            dump_str(encode_base64($s),
                     $smtp, $folderhandle, $do_send, $do_save, \$senderr, \$saveerr);
         }
         close($attachment);    # close tmpfile created by CGI.pm
      }

      dump_str(qq|\n--$boundary--\n|,
               $smtp, $folderhandle, $do_send, $do_save, \$senderr, \$saveerr);

   } else { # NO MIXED ATT ###################################################
      if ($#related>=0) { # has related att, no mixed att, !attachment param

         if ($msgformat eq 'html') {
            $contenttype="multipart/related;";

            dump_str(qq|Content-Type: multipart/related;\n|.
                     qq|\ttype="text/html";\n|.
                     qq|\tboundary="$boundary"\n|,
                     $smtp, $folderhandle, $do_send, $do_save, \$senderr, \$saveerr);
            print $folderhandle "Status: R\n" or $saveerr++ if ($do_save && !$saveerr);
            dump_str(qq|\nThis is a multi-part message in MIME format.\n|,
                     $smtp, $folderhandle, $do_send, $do_save, \$senderr, \$saveerr);
            
            dump_bodyhtml(\$body, $boundary, $composecharset, $msgformat,
                          $smtp, $folderhandle, $do_send, $do_save, \$senderr, \$saveerr);
            dump_atts(\@related, $boundary, $composecharset,
                      $smtp, $folderhandle, $do_send, $do_save, \$senderr, \$saveerr);

         } elsif ($msgformat eq "both") {
            $contenttype="multipart/related;";

            dump_str(qq|Content-Type: multipart/related;\n|.
                     qq|\ttype="multipart/alternative";\n|.
                     qq|\tboundary="$boundary"\n|,
                     $smtp, $folderhandle, $do_send, $do_save, \$senderr, \$saveerr);
            print $folderhandle "Status: R\n" or $saveerr++ if ($do_save && !$saveerr);
            dump_str(qq|\nThis is a multi-part message in MIME format.\n|,
                     $smtp, $folderhandle, $do_send, $do_save, \$senderr, \$saveerr);

            dump_str(qq|\n--$boundary\n|.
                     qq|Content-Type: multipart/alternative;\n|.
                     qq|\tboundary="$boundary2"\n|,
                     $smtp, $folderhandle, $do_send, $do_save, \$senderr, \$saveerr);

            dump_bodytext(\$body, $boundary2, $composecharset, $msgformat,
                          $smtp, $folderhandle, $do_send, $do_save, \$senderr, \$saveerr);
            dump_bodyhtml(\$body, $boundary2, $composecharset, $msgformat,
                          $smtp, $folderhandle, $do_send, $do_save, \$senderr, \$saveerr);

            dump_str(qq|\n--$boundary2--\n|,
                     $smtp, $folderhandle, $do_send, $do_save, \$senderr, \$saveerr);

            dump_atts(\@related, $boundary, $composecharset,
                      $smtp, $folderhandle, $do_send, $do_save, \$senderr, \$saveerr);
         }

         dump_str(qq|\n--$boundary--\n|,
                  $smtp, $folderhandle, $do_send, $do_save, \$senderr, \$saveerr);

      } else {	# no related att, no mixed att, !attachment param
         if ($msgformat eq 'text') {
            $contenttype="text/plain; charset=$composecharset";

            dump_str(qq|Content-Type: text/plain;\n|.
                     qq|\tcharset=$composecharset\n|,
                     $smtp, $folderhandle, $do_send, $do_save, \$senderr, \$saveerr);
            print $folderhandle "Status: R\n" or $saveerr++ if ($do_save && !$saveerr);

            $smtp->datasend("\n$body\n")    or $senderr++ if ($do_send && !$senderr);
            $body=~s/^From />From /gm;
            print $folderhandle "\n$body\n" or $saveerr++ if ($do_save && !$saveerr);
            if ( $config{'mailfooter'}=~/[^\s]/) {
               $s=str2str($config{'mailfooter'}, $msgformat)."\n";
               $smtp->datasend($s) or $senderr++ if ($do_send && !$senderr);
            }
         
         } elsif ($msgformat eq 'html') {
            $contenttype="text/html; charset=$composecharset";

            dump_str(qq|Content-Type: text/html;\n|.
                     qq|\tcharset=$composecharset\n|.
                     qq|Content-Transfer-Encoding: quoted-printable\n|,
                     $smtp, $folderhandle, $do_send, $do_save, \$senderr, \$saveerr);
            print $folderhandle "Status: R\n" or $saveerr++ if ($do_save && !$saveerr);

            $s = qq|\n|.encode_qp($body).qq|\n|;
            $smtp->datasend($s)    or $senderr++ if ($do_send && !$senderr);
            $s=~s/^From />From /gm;
            print $folderhandle $s or $saveerr++ if ($do_save && !$saveerr);
            if ( $config{'mailfooter'}=~/[^\s]/) {
               $s=encode_qp(str2str($config{'mailfooter'}, $msgformat))."\n";
               $smtp->datasend($s) or $senderr++ if ($do_send && !$senderr);
            }

         } elsif ($msgformat eq 'both') {
            $contenttype="multipart/alternative;";

            dump_str(qq|Content-Type: multipart/alternative;\n|.
                     qq|\tboundary="$boundary"\n|,
                     $smtp, $folderhandle, $do_send, $do_save, \$senderr, \$saveerr);
            print $folderhandle "Status: R\n" or $saveerr++ if ($do_save && !$saveerr);
            dump_str(qq|\nThis is a multi-part message in MIME format.\n|,
                     $smtp, $folderhandle, $do_send, $do_save, \$senderr, \$saveerr);

            dump_bodytext(\$body, $boundary, $composecharset, $msgformat,
                          $smtp, $folderhandle, $do_send, $do_save, \$senderr, \$saveerr);
            dump_bodyhtml(\$body, $boundary, $composecharset, $msgformat,
                          $smtp, $folderhandle, $do_send, $do_save, \$senderr, \$saveerr);

            dump_str(qq|\n--$boundary--\n|,
                     $smtp, $folderhandle, $do_send, $do_save, \$senderr, \$saveerr);
         }
      }
   }

   # ensure a blank line between messages for local saved msgs
   print $folderhandle "\n" or $saveerr++ if ($do_save && !$saveerr);

   if ($do_send) {
      if (!$senderr) {
         $smtp->dataend();
         $smtp->quit();
         close(STDERR);
         my @r;
         push(@r, "to=$to") if ($to); 
         push(@r, "cc=$cc") if ($cc); 
         push(@r, "bcc=$bcc") if ($bcc); 
         writelog("send message - subject=$subject - ".join(', ', @r));
         writehistory("send message - subject=$subject - ".join(', ', @r));
      } else {
         $smtp->close() if ($smtp); # close smtp if it was sucessfully opened
         if ($senderrstr eq "") {
            my $smtperr=readsmtperr($smtperrfile);
            $senderrstr=qq|$lang_err{'sendmail_error'}!|.
                         qq|<form>|.
                         textarea(-name=>'smtperror',
                                  -default=>$smtperr,
                                  -rows=>'5',
                                  -columns=>'72',
                                  -wrap=>'soft',
                                  -override=>'1').
                         qq|</form>|;
            $smtperr=~s/\n/\n /gs; $smtperr=~s/\s+$//;
            writelog("send message error - smtp error ...\n $smtperr");
            writehistory("send message error - smtp error");
         }
      }
      close(STDERR);
      unlink($smtperrfile);
   }

   if ($do_save) {
      if (!$saveerr) {
         $messagesize=tell($folderhandle)-$messagestart if ($do_save && !$saveerr);
         close($folderhandle);

         my @attr;
         $attr[$_OFFSET]=$messagestart;

         $attr[$_TO]=$to;
         $attr[$_TO]=$cc if ($attr[$_TO] eq '');
         $attr[$_TO]=$bcc if ($attr[$_TO] eq '');
         # some dbm(ex:ndbm on solaris) can only has value shorter than 1024 byte,
         # so we cut $_to to 256 byte to make dbm happy
         if (length($attr[$_TO]) >256) {
            $attr[$_TO]=substr($attr[$_TO], 0, 252)."...";
         }

         if ($realname) {
            $attr[$_FROM]=qq|"$realname" <$from>|;
         } else {
            $attr[$_FROM]=qq|$from|;
         }
         $attr[$_DATE]=$dateserial;
         $attr[$_SUBJECT]=$subject;
         $attr[$_CONTENT_TYPE]=$contenttype;
         $attr[$_STATUS]="R";
         $attr[$_STATUS].="I" if ($priority eq 'urgent');

         # flags used by openwebmail internally
         $attr[$_STATUS].="T" if ($attachment || $#{$r_attfiles}>=0 );

         $attr[$_SIZE]=$messagesize;
         $attr[$_REFERENCES]=$references;
         $attr[$_CHARSET]=$composecharset;

         # escape @@@
         foreach ($_FROM, $_TO, $_SUBJECT, $_CONTENT_TYPE, $_REFERENCES) {
            $attr[$_]=~s/\@\@/\@\@ /g; $attr[$_]=~s/\@$/\@ /;
         }

         my %HDB;
         if (!$config{'dbmopen_haslock'}) {
            filelock("$savedb$config{'dbm_ext'}", LOCK_EX) or
               openwebmailerror(__FILE__, __LINE__, "$lang_err{'couldnt_lock'} $savedb$config{'dbm_ext'}");
         }
         dbmopen(%HDB, "$savedb$config{'dbmopen_ext'}", 0600);
         $HDB{$mymessageid}=join('@@@', @attr);
         $HDB{'ALLMESSAGES'}++;
         $HDB{'METAINFO'}=metainfo($savefile);
         dbmclose(%HDB);
         filelock("$savedb$config{'dbm_ext'}", LOCK_UN) if (!$config{'dbmopen_haslock'});

      } else {
         seek($folderhandle, $messagestart, 0);
         truncate($folderhandle, tell($folderhandle));
         close($folderhandle);

         my %HDB;
         if (!$config{'dbmopen_haslock'}) {
            filelock("$savedb$config{'dbm_ext'}", LOCK_EX) or
               openwebmailerror(__FILE__, __LINE__, "$lang_err{'couldnt_lock'} $savedb$config{'dbm_ext'}");
         }
         dbmopen(%HDB, "$savedb$config{'dbmopen_ext'}", 0600);
         $HDB{'METAINFO'}=metainfo($savefile);
         dbmclose(%HDB);
         filelock("$savedb$config{'dbm_ext'}", LOCK_UN) if (!$config{'dbmopen_haslock'});
      }

      filelock($savefile, LOCK_UN);
   }

   # status update(mark referenced message as answered) and headerdb update
   #
   # this must be done AFTER the above do_savefolder block
   # since the start of the savemessage would be changed by status_update
   # if the savedmessage is on the same folder as the answered message
   if ($do_send && !$senderr && $inreplyto) {
      my @checkfolders=();

      # if current folder is sent/draft folder,
      # we try to find orig msg from other folders
      # Or we just check the current folder
      if ($folder eq "sent-mail" || $folder eq "saved-drafts" ) {
         foreach (@validfolders) {
            if ($_ ne "sent-mail" || $_ ne "saved-drafts" ) {
               push(@checkfolders, $_);
            }
         }
      } else {
         push(@checkfolders, $folder);
      }

      # identify where the original message is
      foreach my $foldername (@checkfolders) {
         my ($folderfile, $headerdb)=get_folderfile_headerdb($user, $foldername);
         my (%HDB, $oldstatus, $found);

         dbmopen(%HDB, "$headerdb$config{'dbmopen_ext'}", 0600);
         if (!$config{'dbmopen_haslock'}) {
            filelock("$headerdb$config{'dbm_ext'}", LOCK_EX) or
               openwebmailerror(__FILE__, __LINE__, "$lang_err{'couldnt_lock'} $headerdb$config{'dbm_ext'}");
         }
         if (defined($HDB{$inreplyto})) {
            $oldstatus = (split(/@@@/, $HDB{$inreplyto}))[$_STATUS];
            $found=1;
         }
         filelock("$headerdb$config{'dbm_ext'}", LOCK_UN) if (!$config{'dbmopen_haslock'});
         dbmclose(%HDB);

         if ( $found ) {
            if ($oldstatus !~ /a/i) {
               # try to mark answered if get filelock
               if (filelock($folderfile, LOCK_EX|LOCK_NB)) {
                  update_message_status($inreplyto, $oldstatus."A", $headerdb, $folderfile);
                  filelock("$folderfile", LOCK_UN);
               }
            }
            last;
         }
      }
   }

   if ($senderr) {
      openwebmailerror(__FILE__, __LINE__, $senderrstr);
   } elsif ($saveerr) {
      openwebmailerror(__FILE__, __LINE__, $saveerrstr);
   } else {
      if (defined(param('sendbutton'))) {
         # delete attachments only if no error,
         # in case user trys resend, attachments could be available
         deleteattachments();
         print redirect(-location=>"$config{'ow_cgiurl'}/openwebmail-main.pl?action=listmessages&sessionid=$thissession&sort=$sort&folder=$escapedfolder&page=$page");
      } else {
         # save draft, call getfolders to recalc used quota
         getfolders(\@validfolders, \$folderusage);
         if ($quotalimit>0 && $quotausage+$messagesize>$quotalimit) {
            $quotausage=(quota_get_usage_limit(\%config, $user, $homedir, 1))[2];
         }
         return(composemessage());
      }
   }
}

# convert filename in attheader to same charset as message itself when sending
sub _convert_attfilename {
   my ($prefix, $name, $postfix, $targetcharset)=@_;
   my $origcharset;
   $origcharset=$1 if ($name =~ m{=\?([^?]*)\?[bq]\?[^?]+\?=}xi);
   return($prefix.$name.$postfix)   if (!$origcharset || $origcharset eq $targetcharset);

   if (is_convertable($origcharset, $targetcharset)) {
      $name=decode_mimewords($name);
      ($name)=iconv($origcharset, $targetcharset, $name);
      $name=encode_mimewords($name, ('Charset'=>$targetcharset));
   }
   return($prefix.$name.$postfix);
}

sub dump_str {
   my ($s, $smtp, $folderhandle, $do_send, $do_save, $r_senderr, $r_saveerr)=@_;
   $smtp->datasend($s)    or ${$r_senderr}++ if ($do_send && !${$r_senderr});
   print $folderhandle $s or ${$r_saveerr}++ if ($do_save && !${$r_saveerr});
}

sub dump_bodytext {
   my ($r_body, $boundary, $composecharset, $msgformat,
       $smtp, $folderhandle, $do_send, $do_save, $r_senderr, $r_saveerr)=@_;

   my $s = qq|\n--$boundary\n|.
           qq|Content-Type: text/plain;\n|.
           qq|\tcharset=$composecharset\n\n|;
   if ($msgformat eq "text") {
      $s.=${$r_body}.qq|\n|;
   } else {
      $s.=html2text(${$r_body}).qq|\n|;
   }
   $smtp->datasend($s) or ${$r_senderr}++ if ($do_send && !${$r_senderr});

   $s=~s/^From / From/gm;
   print $folderhandle $s or ${$r_saveerr}++ if ($do_save && !${$r_saveerr});

   if ( $config{'mailfooter'}=~/[^\s]/) {
      $s=str2str($config{'mailfooter'}, $msgformat)."\n";
      $smtp->datasend($s) or ${$r_senderr}++ if ($do_send && !${$r_senderr});
   }
}

sub dump_bodyhtml {
   my ($r_body, $boundary, $composecharset, $msgformat,
       $smtp, $folderhandle, $do_send, $do_save, $r_senderr, $r_saveerr)=@_;

   my $s = qq|\n--$boundary\n|.
           qq|Content-Type: text/html;\n|.
           qq|\tcharset=$composecharset\n|.
           qq|Content-Transfer-Encoding: quoted-printable\n\n|;
   if ($msgformat eq "text") {
      $s.=encode_qp(text2html(${$r_body})).qq|\n|;
   } else {
      $s.=encode_qp(${$r_body}).qq|\n|;
   }
   $smtp->datasend($s) or ${$r_senderr}++ if ($do_send && !${$r_senderr});

   $s=~s/^From / From/gm;
   print $folderhandle $s or ${$r_saveerr}++ if ($do_save && !${$r_saveerr});

   if ( $config{'mailfooter'}=~/[^\s]/) {
      $s=encode_qp(str2str($config{'mailfooter'}, $msgformat))."\n";
      $smtp->datasend($s) or ${$r_senderr}++ if ($do_send && !${$r_senderr});
   }
}

sub dump_atts {
   my ($r_atts, $boundary, $composecharset, 
       $smtp, $folderhandle, $do_send, $do_save, $r_senderr, $r_saveerr)=@_;
   my $s;

   foreach my $r_att (@{$r_atts}) {
      $smtp->datasend("\n--$boundary\n")    or ${$r_senderr}++ if ($do_send && !${$r_senderr});
      print $folderhandle "\n--$boundary\n" or ${$r_saveerr}++ if ($do_save && !${$r_saveerr});

      my $attfile="$config{ow_sessionsdir}/${$r_att}{file}";
      my $referenced=${$r_att}{referencecount};

      open(ATTFILE, $attfile);
      # print attheader line by line
      while (defined($s = <ATTFILE>)) {
         if ($s =~ /^Content\-Id: <?att\d\d\d\d\d\d\d\d/ && !$referenced) {
            # remove contentid from attheader if it was set by openwebmail but not referenced, 
            # since outlook will treat an attachment as invalid 
            # if it has content-id but not been referenced
            next;
         }
         $s =~ s/^(.+name="?)([^"]+)("?.*)$/_convert_attfilename($1, $2, $3, $composecharset)/ige;
         $smtp->datasend($s)    or ${$r_senderr}++ if ($do_send && !${$r_senderr});
         print $folderhandle $s or ${$r_saveerr}++ if ($do_save && !${$r_saveerr});
         last if ($s =~ /^\s+$/ );
      }
      # print attbody block by block
      while (read(ATTFILE, $s, 32768)) {
         $smtp->datasend($s)    or ${$r_senderr}++ if ($do_send && !${$r_senderr});
         print $folderhandle $s or ${$r_saveerr}++ if ($do_save && !${$r_saveerr});
      }
      close(ATTFILE);
   }
   return;
}

############## END SENDMESSAGE ###################

######################## GET_TEXT_HTML #########################
sub str2str {
   my ($str, $format)=@_;
   my $is_html; $is_html=1 if ($str=~/(?:<br>|<p>|<a .*>|<font .*>|<table .*>)/is);
   if ($format eq 'text') {
      return html2text($str) if ($is_html)
   } else {
      return text2html($str) if (!$is_html);
   }
   return $str;
}
###################### END GET_TEXT_HTML #######################

##################### GETATTLISTINFO ###############################
sub getattfilesinfo {
   my @attfiles=();
   my $totalsize = 0;

   opendir (SESSIONSDIR, "$config{'ow_sessionsdir'}") or
      openwebmailerror(__FILE__, __LINE__, "$lang_err{'couldnt_open'} $config{'ow_sessionsdir'}! ($!)");
   my $attnum=-1;
   while (defined(my $currentfile = readdir(SESSIONSDIR))) {
      if ($currentfile =~ /^(\Q$thissession\E\-att\d+)$/) {
         $attnum++;
         $currentfile = $1;

         my ($attcontenttype, $attdisposition, $attid, $attlocation, $lastline);
         open (ATTFILE, "$config{'ow_sessionsdir'}/$currentfile");
         while (<ATTFILE>) {
            chomp;
            if (/^\s/) {
               s/^\s+//; # fields in attheader use ';' as delimiter, no space is ok
               if    ($lastline eq 'TYPE')     { $attcontenttype .= $_ }
               elsif ($lastline eq 'DISPOSITION') { $attdisposition .= $_ }
               elsif ($lastline eq 'LOCATION') { $attlocation .= $_ }
            } elsif (/^content-type:\s+(.+)$/ig) {
               $attcontenttype = $1;
               $lastline = 'TYPE';
            } elsif (/^content-disposition:\s+(.+)$/ig) {
               $attdisposition = $1;
               $lastline = 'DISPOSITION';
            } elsif (/^content-id:\s+(.+)$/ig) {
               $attid = $1;
               $attid =~ s/^\<(.+)\>$/$1/;
               $lastline = 'NONE';
            } elsif (/^content-location:\s+(.+)$/ig) {
               $attlocation = $1;
               $lastline = 'LOCATION';
            } elsif (/^\s+$/ ) {
               last;
            } else {
               $lastline = 'NONE';
            }
         }
         close (ATTFILE);

         (${$attfiles[$attnum]}{name}, ${$attfiles[$attnum]}{namecharset})
         	=get_filename_charset($attcontenttype, $attdisposition);
         ${$attfiles[$attnum]}{name}=~s/Unknown/attachment_$attnum/;
         ${$attfiles[$attnum]}{id}=$attid;
         ${$attfiles[$attnum]}{location}=$attlocation;
         ${$attfiles[$attnum]}{file}=$currentfile;
         ${$attfiles[$attnum]}{size}=(-s "$config{'ow_sessionsdir'}/$currentfile");

         $totalsize += ${$attfiles[$attnum]}{size};
      }
   }
   closedir (SESSIONSDIR);

   return ($totalsize, \@attfiles);
}
##################### END GETATTLISTINFO ###########################

##################### DELETEATTACHMENTS ############################
sub deleteattachments {
   my (@delfiles, $attfile);
   opendir (SESSIONSDIR, "$config{'ow_sessionsdir'}") or
      openwebmailerror(__FILE__, __LINE__, "$lang_err{'couldnt_open'} $config{'ow_sessionsdir'}! ($!)");
   while (defined($attfile = readdir(SESSIONSDIR))) {
      if ($attfile =~ /^(\Q$thissession\E\-att\d+)$/) {
         $attfile = $1;
         push(@delfiles, "$config{'ow_sessionsdir'}/$attfile");
      }
   }
   closedir (SESSIONSDIR);
   unlink(@delfiles) if ($#delfiles>=0);
}
#################### END DELETEATTACHMENTS #########################

###################### FOLDING ###########################
# folding the to, cc, bcc field in case it violates the 998 char limit
# defined in RFC 2822 2.2.3
sub folding {
   return($_[0]) if (length($_[0])<960);

   my ($folding, $line)=('', '');
   foreach my $token (str2list($_[0],0)) {
      if (length($line)+length($token) <960) {
         $line.=",$token";
      } else {
         $folding.="$line,\n   ";
         $line=$token;
      }
   }
   $folding.=$line;

   $folding=~s/^,//;
   return($folding);
}
###################### END FOLDING ########################

################### REPARAGRAPH #########################
sub reparagraph {
   my @lines=split(/\n/, $_[0]);
   my $maxlen=$_[1];
   my ($text,$left) = ('','');

   foreach my $line (@lines) {
      if ($left eq  "" && length($line) < $maxlen) {
         $text.="$line\n";
      } elsif ($line=~/^\s*$/ ||		# newline
               $line=~/^>/ || 		# previous orig
               $line=~/^#/ || 		# comment line
               $line=~/^\s*[\-=#]+\s*$/ || # dash line
               $line=~/^\s*[\-=#]{3,}/ ) { # dash line
         $text.= "$left\n" if ($left ne "");
         $text.= "$line\n";
         $left="";
      } else {
         if ($line=~/^\s*\(/ ||
               $line=~/^\s*\d\d?[\.:]/ ||
               $line=~/^\s*[A-Za-z][\.:]/ ||
               $line=~/\d\d:\d\d:\d\d/ ||
               $line=~/�G/) {
            $text.= "$left\n";
            $left=$line;
         } else {
            if ($left=~/ $/ || $line=~/^ / || $left eq "" || $line eq "") {
               $left.=$line;
            } else {
               $left.=" ".$line;
            }
         }

         while ( length($left)>$maxlen ) {
            my $furthersplit=0;
            for (my $len=$maxlen-2; $len>2; $len-=2) {
               if ($left =~ /^(.{$len}.*?[\s\,\)\-])(.*)$/) {
                  if (length($1) < $maxlen) {
                     $text.="$1\n"; $left=$2;
                     $furthersplit=1;
                     last;
                  }
               } else {
                  $text.="$left\n"; $left="";
                  last;
               }
            }
            last if ($furthersplit==0);
         }

      }
   }
   $text.="$left\n" if ($left ne "");
   return($text);
}
################### END REPARAGRAPH #########################

################## FAKEMESSGAEID ###########################
sub fakemessageid {
   my $postfix=$_[0];
   my $fakedid = gmtime2dateserial().'.M'.int(rand()*100000);
   if ($postfix =~ /@(.*)$/) {
      return("<$fakedid".'@'."$1>");
   } else {
      return("<$fakedid".'@'."$postfix>");
   }
}
################## END FAKEMESSGAEID ########################

################### READSMTPERR ##########################
sub readsmtperr {
   open(F, $_[0]);
   my $content;
   while (<F>) {
      s/\s*$//;
      $content.="$1\n" if (/(>>>.*$)/ || /(<<<.*$)/);
   }
   close(F);
   return($content);
}
################### END READSMTPERR ##########################

################### HTMLAREA_COMPATIBLE ######################
sub htmlarea_compatible {
   my $u=$ENV{'HTTP_USER_AGENT'};
   if ( $u=~m!Mozilla/4.0! &&
        $u=~m!compatible;! &&
        $u=~m!Windows! &&
        $u=~m!MSIE ([\d\.]+)! ) {
      return 1 if ($1>=5.5);	# MSIE>=5.5 on windows platform
   }
   if ( $u=~m!Mozilla/5.0! &&
        $u!~m!compatible;! &&
        $u!~m!(?:Phoenix|Galeon|Firebird)/! &&
        $u=~m!rv:([\d\.]+)! ) {
      return 1 if ($1>=1.3);	# full Mozilla>=1.3 on all plaform
   }
   return 0;
}
################### END HTMLAREA_COMPATIBLE ######################
