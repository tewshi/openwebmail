#!/usr/bin/perl -T
#############################################################################
# Open WebMail - Provides a web interface to user mailboxes                 #
#                                                                           #
# Copyright (C) 2001                                                        #
# Chung-Kie Tung, Nai-Jung Kuo, Chao-Chiu Wang, Emir Litric                 #
# Copyright (C) 2000                                                        #
# Ernie Miller  (original GPL project: Neomail)                             #
#                                                                           #
# This program is distributed under GNU General Public License              #
#############################################################################

use strict;
no strict 'vars';
use Fcntl qw(:DEFAULT :flock);
use CGI qw(:standard);
use CGI::Carp qw(fatalsToBrowser);
CGI::nph();   # Treat script as a non-parsed-header script

$ENV{PATH} = ""; # no PATH should be needed
$ENV{BASH_ENV} = ""; # no startup sciprt for bash
umask(0007); # make sure the openwebmail group can write

push (@INC, '/usr/local/www/cgi-bin/openwebmail', ".");
require "openwebmail-shared.pl";
require "filelock.pl";
require "pop3mail.pl";

local %config;
readconf(\%config, "/usr/local/www/cgi-bin/openwebmail/etc/openwebmail.conf");
require $config{'auth_module'} or
   openwebmailerror("Can't open authentication module $config{'auth_module'}");

local $thissession;
local ($virtualuser, $user, $userrealname, $uuid, $ugid, $mailgid, $homedir);

local %prefs;
local %style;
local ($lang_charset, %lang_folders, %lang_sortlabels, %lang_text, %lang_err);

local $folderdir;
local (@validfolders, $folderusage);

local ($folder, $printfolder, $escapedfolder);
local $firstmessage;
local $sort;
local ($messageid, $escapedmessageid);

$mailgid=getgrnam('mail');

# setuid is required if mails is located in user's dir
if ( $config{'use_homedirspools'} || $config{'use_homedirfolders'} ) {
   if ( $> != 0 ) {
      my $suidperl=$^X;
      $suidperl=~s/perl/suidperl/;
      openwebmailerror("<b>$0 must setuid to root!</b><br>".
                       "<br>1. check if script is owned by root with mode 4755".
                       "<br>2. use '#!$suidperl' instead of '#!$^X' in script");
   }  
}

if ( defined(param("sessionid")) ) {
   $thissession = param("sessionid");

   my $loginname = $thissession || '';
   $loginname =~ s/\-session\-0.*$//; # Grab loginname from sessionid

   ($virtualuser, $user, $userrealname, $uuid, $ugid, $homedir)=get_virtualuser_user_userinfo($loginname);
   if ($user eq "") {
      openwebmailerror("User $loginname doesn't exist!");
   }

   if ( $config{'use_homedirspools'} || $config{'use_homedirfolders'} ) {
      set_euid_egid_umask($uuid, $mailgid, 0077);	
   } else {
      set_euid_egid_umask($>, $mailgid, 0077);	
   }
   # egid must be mail since this is a mail program...
   if ( $) != $mailgid) { 
      openwebmailerror("Set effective gid to mail($mailgid) failed!");
   }

   if ( $config{'use_homedirfolders'} ) {
      $folderdir = "$homedir/$config{'homedirfolderdirname'}";
   } else {
      $folderdir = "$config{'ow_etcdir'}/users/$user";
   }

   ($user =~ /^(.+)$/) && ($user = $1);  # untaint $user
   ($uuid =~ /^(.+)$/) && ($uuid = $1);
   ($ugid =~ /^(.+)$/) && ($ugid = $1);
   ($homedir =~ /^(.+)$/) && ($homedir = $1);  # untaint $homedir
   ($folderdir =~ /^(.+)$/) && ($folderdir = $1);  # untaint $folderdir

} else {
   sleep 10;	# delayed response
   openwebmailerror("No user specified!");
}

%prefs = %{&readprefs};
%style = %{&readstyle};

($prefs{'language'} =~ /^([\w\d\._]+)$/) && ($prefs{'language'} = $1);
require "etc/lang/$prefs{'language'}";
$lang_charset ||= 'iso-8859-1';

if ($user) {
   getfolders(\@validfolders, \$folderusage, 0);
   if (param("folder")) {
      my $isvalid = 0;
      $folder = param("folder");
      foreach my $checkfolder (@validfolders) {
         if ($folder eq $checkfolder) {
            $isvalid = 1;
            last;
         }
      }
      ($folder = 'INBOX') unless ( $isvalid );
   } else {
      $folder = "INBOX";
   }
   $printfolder = $lang_folders{$folder} || $folder || '';
   $escapedfolder = escapeURL($folder);

   $firstmessage = param("firstmessage") || 1;
   $sort = param("sort") || $prefs{"sort"} || 'date';

   $messageid=param("message_id") || '';
   $escapedmessageid=escapeURL($messageid);
}

########################## MAIN ##############################

verifysession();

if (defined(param("action"))) {      # an action has been chosen
   my $action = param("action");
   if ($action =~ /^(\w+)$/) {
      $action = $1;
      if ($action eq "saveprefs") {
         saveprefs();
      } elsif ($action eq "editpassword") {
         editpassword();
      } elsif ($action eq "changepassword" && $config{'enable_changepwd'} ) {
         changepassword();
      } elsif ($action eq "viewhistory") {
         viewhistory();
      } elsif ($action eq "editfolders") {
         editfolders();
      } elsif ($action eq "addfolder") {
         addfolder();
      } elsif ($action eq "deletefolder") {
         deletefolder();
      } elsif ($action eq "renamefolder") {
         renamefolder();
      } elsif ($action eq "downloadfolder") {
         downloadfolder();
      } elsif ($action eq "addressbook") {
         addressbook();
      } elsif ($action eq "editaddresses") {
         editaddresses();
      } elsif ($action eq "addaddress") {
         modaddress("add");
      } elsif ($action eq "deleteaddress") {
         modaddress("delete");
      } elsif ($action eq "clearaddress") {
         clearaddress();
      } elsif ($action eq "importabook") {
         importabook();
      } elsif ($action eq "exportabook") {
         exportabook();
      } elsif ($action eq "editfroms") {
         editfroms();
      } elsif ($action eq "addfrom") {
         modfrom("add");
      } elsif ($action eq "deletefrom") {
         modfrom("delete");
      } elsif ($action eq "editpop3" && $config{'enable_pop3'}) {
         editpop3();
      } elsif ($action eq "addpop3" && $config{'enable_pop3'}) {
         modpop3("add");
      } elsif ($action eq "deletepop3" && $config{'enable_pop3'}) {
         modpop3("delete");
      } elsif ($action eq "editfilter") {
         editfilter();
      } elsif ($action eq "addfilter") {
         modfilter("add");
      } elsif ($action eq "deletefilter") {
         modfilter("delete");
      } else {
         openwebmailerror("Action $lang_err{'has_illegal_chars'}");
      }
   } else {
      openwebmailerror("Action $lang_err{'has_illegal_chars'}");
   }
} else {            # no action has been taken, display prefs page
   editprefs();
}
###################### END MAIN ##############################

#################### EDITPREFS ###########################
sub editprefs {
   my $html = '';
   my $temphtml;

   open (PREFSTEMPLATE, "$config{'ow_etcdir'}/templates/$prefs{'language'}/prefs.template") or
      openwebmailerror("$lang_err{'couldnt_open'} $config{'ow_etcdir'}/templates/$prefs{'language'}/prefs.template");
   while (<PREFSTEMPLATE>) {
      $html .= $_;
   }
   close (PREFSTEMPLATE);

   $html = applystyle($html);

   printheader();

   $temphtml = start_form(-action=>"$config{'ow_cgiurl'}/openwebmail-prefs.pl",
                          -name=>'prefsform');
   $temphtml .= hidden(-name=>'action',
                       -default=>'saveprefs',
                       -override=>'1');
   $temphtml .= hidden(-name=>'sessionid',
                       -default=>$thissession,
                       -override=>'1');
   $temphtml .= hidden(-name=>'firstmessage',
                       -default=>$firstmessage,
                       -override=>'1');
   $temphtml .= hidden(-name=>'folder',
                       -default=>$folder,
                       -override=>'1');

   $html =~ s/\@\@\@STARTPREFSFORM\@\@\@/$temphtml/;

   my %userfrom=get_userfrom($virtualuser, $user, $userrealname, "$folderdir/.from.book");

   if ($userfrom{$prefs{'email'}}) {
      $temphtml = " $lang_text{'for'} " . $userfrom{$prefs{'email'}};
   } else {
      $temphtml = '';
   }
   $html =~ s/\@\@\@REALNAME\@\@\@/$temphtml/;

   my @availablelanguages = sort {
                                 $languagenames{$a} cmp $languagenames{$b}
                                 } keys(%languagenames);
   $temphtml = popup_menu(-name=>'language',
                          -"values"=>\@availablelanguages,
                          -default=>$prefs{"language"},
                          -labels=>\%languagenames,
                          -override=>'1');

   $html =~ s/\@\@\@LANGUAGEFIELD\@\@\@/$temphtml/;

   my @fromemails=sort keys (%userfrom);
   my %fromlabels;
   foreach (@fromemails) {
      if ($userfrom{$_}) {
         $fromlabels{$_}=qq|"$userfrom{$_}" <$_>|;
      } else {
         $fromlabels{$_}=qq|$_|;
      }
   }
   $temphtml = popup_menu(-name=>'email',
                                -"values"=>\@fromemails,
                                -labels=>\%fromlabels,
                                -default=>$prefs{'email'},
                                -override=>'1');

   $html =~ s/\@\@\@FROMEMAILMENU\@\@\@/$temphtml/;

   $temphtml = "<a href=\"$config{'ow_cgiurl'}/openwebmail-prefs.pl?action=editfroms&amp;sessionid=$thissession&amp;sort=$sort&amp;keyword=$escapedkeyword&amp;searchtype=$searchtype&amp;folder=$escapedfolder&amp;firstmessage=$firstmessage\"><IMG SRC=\"$config{'ow_htmlurl'}/images/iconsets/$prefs{'iconset'}/editfroms.gif\" border=\"0\" ALT=\"$lang_text{'editfroms'}\"></a> ";

   $html =~ s/\@\@\@EDITFROMSBUTTON\@\@\@/$temphtml/;

   $temphtml = textfield(-name=>'replyto',
                         -default=>$prefs{"replyto"} || '',
                         -size=>'40',
                         -override=>'1');

   $html =~ s/\@\@\@REPLYTOFIELD\@\@\@/$temphtml/;

   # Get a list of valid style files
   my @styles;
   opendir (STYLESDIR, "$config{'ow_etcdir'}/styles") or
      openwebmailerror("$lang_err{'couldnt_open'} $config{'ow_etcdir'}/styles directory for reading!");
   while (defined(my $currentstyle = readdir(STYLESDIR))) {
      unless ($currentstyle =~ /^\./) {
         push (@styles, $currentstyle);
      }
   }
   @styles = sort(@styles);
   closedir(STYLESDIR) or
      openwebmailerror("$lang_err{'couldnt_close'} $config{'ow_etcdir'}/styles!");

   $temphtml = popup_menu(-name=>'style',
                          -"values"=>\@styles,
                          -default=>$prefs{"style"},
                          -override=>'1');

   $html =~ s/\@\@\@STYLEMENU\@\@\@/$temphtml/;

   # Get a list of valid iconset
   my @iconsets;
   opendir (ICONSETSDIR, "$config{'ow_htmldir'}/images/iconsets") or
      openwebmailerror("$lang_err{'couldnt_open'} $config{'ow_htmldir'}/images/iconsets directory for reading!");
   while (defined(my $currentset = readdir(ICONSETSDIR))) {
      if (-d "$config{'ow_htmldir'}/images/iconsets/$currentset" && $currentset !~ /^\./) {
         push (@iconsets, $currentset);
      }
   }
   @iconsets = sort(@iconsets);
   closedir(ICONSETSDIR) or
      openwebmailerror("$lang_err{'couldnt_close'} $config{'ow_htmldir'}/images/iconsets!");

   $temphtml = popup_menu(-name=>'iconset',
                          -"values"=>\@iconsets,
                          -default=>$prefs{"iconset"},
                          -override=>'1');

   $html =~ s/\@\@\@ICONSETMENU\@\@\@/$temphtml/;


   # Get a list of valid background images
   my @backgrounds;
   my %bglabels=();
   opendir (BACKGROUNDSDIR, "$config{'ow_htmldir'}/images/backgrounds") or
      openwebmailerror("$lang_err{'couldnt_open'} $config{'ow_htmldir'}/images/backgrounds directory for reading!");
   while (defined(my $currentbackground = readdir(BACKGROUNDSDIR))) {
      unless ($currentbackground =~ /^\./) {
         push (@backgrounds, $currentbackground);
      }
   }
   closedir(BACKGROUNDSDIR) or
      openwebmailerror("$lang_err{'couldnt_close'} $config{'ow_htmldir'}/images/backgrounds!");
   @backgrounds = sort(@backgrounds);
   push(@backgrounds, "USERDEFINE");
   $bglabels{"USERDEFINE"}="--$lang_text{'userdef'}--";

   my ($background, $bgurl);
   if ( $prefs{'bgurl'}=~m!$config{'ow_htmlurl'}/images/backgrounds/([\w\d\._]+)! ) {
      $background=$1; $bgurl="";
   } else {
      $background="USERDEFINE"; $bgurl=$prefs{'bgurl'};
   }

   $temphtml = popup_menu(-name=>'background',
                          -"values"=>\@backgrounds,
                          -labels=>\%bglabels,
                          -default=>$background,
                          -onChange=>"JavaScript:document.prefsform.bgurl.value='';",
                          -override=>'1');

   $html =~ s/\@\@\@BACKGROUNDMENU\@\@\@/$temphtml/;

   $temphtml = textfield(-name=>'bgurl',
                         -default=>$bgurl,
                         -size=>'35',
                         -override=>'1');

   $html =~ s/\@\@\@BGURLFIELD\@\@\@/$temphtml/;

   $temphtml = popup_menu(-name=>'sort',
                          -"values"=>['date','date_rev','sender','sender_rev',
                                      'size','size_rev','subject','subject_rev',
                                      'status','thread','thread_rev'],
                          -default=>$prefs{"sort"},
                          -labels=>\%lang_sortlabels,
                          -override=>'1');

   $html =~ s/\@\@\@SORTMENU\@\@\@/$temphtml/;

   $temphtml = popup_menu(-name=>'headersperpage',
                          -"values"=>[8,10,12,14,16,18,20,22,24,26,28,30,32,34,36,38,40,50,100,500,1000],
                          -default=>$prefs{"headersperpage"},
                          -override=>'1');

   $html =~ s/\@\@\@HEADERSPERPAGE\@\@\@/$temphtml/;

   my %headerlabels = ('simple'=>$lang_text{'simplehead'},
                       'all'=>$lang_text{'allhead'}
                      );
   $temphtml = popup_menu(-name=>'headers',
                          -"values"=>['simple','all'],
                          -default=>$prefs{"headers"} || 'simple',
                          -labels=>\%headerlabels,
                          -override=>'1');

   $html =~ s/\@\@\@HEADERSMENU\@\@\@/$temphtml/;

   $temphtml = popup_menu(-name=>'defaultdestination',
                          -"values"=>['saved-messages','mail-trash', 'DELETE'],
                          -default=>$prefs{"defaultdestination"} || 'mail-trash',
                          -labels=>\%lang_folders,
                          -override=>'1');

   $html =~ s/\@\@\@DEFAULTDESTINATIONMENU\@\@\@/$temphtml/;

   $temphtml = checkbox(-name=>'confirmmsgmovecopy',
                        -value=>'1',
                        -checked=>$prefs{'confirmmsgmovecopy'},
                        -label=>'');

   $html =~ s/\@\@\@CONFIRMMSGMOVECOPY\@\@\@/$temphtml/;

   $temphtml = popup_menu(-name=>'editcolumns',
                          -"values"=>[60,62,64,66,68,70,72,74,76,78,80,82,84,86,88,90,100,110,120],
                          -default=>$prefs{"editcolumns"},
                          -override=>'1');

   $html =~ s/\@\@\@EDITCOLUMNSMENU\@\@\@/$temphtml/;

   $temphtml = popup_menu(-name=>'editrows',
                          -"values"=>[10,12,14,16,18,20,22,24,26,28,30,32,34,36,38,40,50,60,70,80],
                          -default=>$prefs{"editrows"},
                          -override=>'1');

   $html =~ s/\@\@\@EDITROWSMENU\@\@\@/$temphtml/;

   $temphtml = popup_menu(-name=>'dictionary',
                          -"values"=>$config{'spellcheck_dictionaries'},
                          -default=>$prefs{'dictionary'},
                          -override=>'1');

   $html =~ s/\@\@\@DICTIONARYMENU\@\@\@/$temphtml/;

   $temphtml = popup_menu(-name=>'filter_repeatlimit',
                          -"values"=>['0','5','10','20','30','40','50','100'],
                          -default=>$prefs{'filter_repeatlimit'},
                          -override=>'1');

   $html =~ s/\@\@\@FILTERREPEATLIMIT\@\@\@/$temphtml/;

   $temphtml = checkbox(-name=>'filter_fakedsmtp',
                        -value=>'1',
                        -checked=>$prefs{'filter_fakedsmtp'},
                        -label=>'');

   $html =~ s/\@\@\@FILTERFAKEDSMTP\@\@\@/$temphtml/g;

   $temphtml = checkbox(-name=>'filter_fakedexecontenttype',
                        -value=>'1',
                        -checked=>$prefs{'filter_fakedexecontenttype'},
                        -label=>'');

   $html =~ s/\@\@\@FILTERFAKEDEXECONTENTTYPE\@\@\@/$temphtml/g;

   $temphtml = checkbox(-name=>'disablejs',
                  -value=>'1',
                  -checked=>$prefs{'disablejs'},
                  -label=>'');

   $html =~ s/\@\@\@DISABLEJS\@\@\@/$temphtml/g;

   $temphtml = checkbox(-name=>'hideinternal',
                  -value=>'1',
                  -checked=>$prefs{'hideinternal'},
                  -label=>'');

   $html =~ s/\@\@\@HIDEINTERNAL\@\@\@/$temphtml/g;

   $temphtml = checkbox(-name=>'newmailsound',
                  -value=>'1',
                  -checked=>$prefs{'newmailsound'},
                  -label=>'');

   $html =~ s/\@\@\@NEWMAILSOUND\@\@\@/$temphtml/g;

   $temphtml = checkbox(-name=>'usesmileicon',
                  -value=>'1',
                  -checked=>$prefs{'usesmileicon'},
                  -label=>'');

   $html =~ s/\@\@\@USESMILEICON\@\@\@/$temphtml/g;

   if ($config{'enable_pop3'}) {
      $temphtml = checkbox(-name=>'autopop3',
                           -value=>'1',
                           -checked=>$prefs{'autopop3'},
                           -label=>'');
      $html =~ s/\@\@\@AUTOPOP3CHECKBOX\@\@\@/$temphtml/g;
      $html =~ s/\@\@\@AUTOPOP3START\@\@\@//g;
      $html =~ s/\@\@\@AUTOPOP3END\@\@\@//g;
   } else {
      $html =~ s/\@\@\@AUTOPOP3CHECKBOX\@\@\@/not available/g;
      $html =~ s/\@\@\@AUTOPOP3START\@\@\@/<!--/g;
      $html =~ s/\@\@\@AUTOPOP3END\@\@\@/-->/g;
   }

   my %dayslabels = ('0'=>$lang_text{'forever'});
   $temphtml = popup_menu(-name=>'trashreserveddays',
                          -"values"=>[0,1,2,3,4,5,6,7,14,21,30,60],
                          -default=>$prefs{'trashreserveddays'},
                          -labels=>\%dayslabels,
                          -override=>'1');

   $html =~ s/\@\@\@RESERVEDDAYSMENU\@\@\@/$temphtml/;

   $temphtml = textarea(-name=>'signature',
                        -default=>$prefs{"signature"},
                        -rows=>'5',
                        -columns=>'72',
                        -wrap=>'hard',
                        -override=>'1');

   $html =~ s/\@\@\@SIGAREA\@\@\@/$temphtml/;

   if ($config{'enable_autoreply'}) {
      # whether autoreply active or not is determined by
      # if .forward is set to call vacation program, not in .openwebmailrc
      my ($autoreply, $autoreplysubject, $autoreplytext)=getautoreply();

      $temphtml = checkbox(-name=>'autoreply',
                           -value=>'1',
                           -checked=>$autoreply,
                           -label=>'');

      $html =~ s/\@\@\@AUTOREPLYCHECKBOX\@\@\@/$temphtml/g;

      $temphtml = textfield(-name=>'autoreplysubject',
                            -default=>$autoreplysubject,
                            -size=>'40',
                            -override=>'1');

      $html =~ s/\@\@\@AUTOREPLYSUBJECT\@\@\@/$temphtml/;

      $temphtml = textarea(-name=>'autoreplytext',
                           -default=>$autoreplytext,
                           -rows=>'5',
                           -columns=>'72',
                           -wrap=>'hard',
                           -override=>'1');

      $html =~ s/\@\@\@AUTOREPLYTEXT\@\@\@/$temphtml/;

      $html =~ s/\@\@\@AUTOREPLYSTART\@\@\@//g;
      $html =~ s/\@\@\@AUTOREPLYEND\@\@\@//g;

   } else {
      $html =~ s/\@\@\@AUTOREPLYCHECKBOX\@\@\@/not available/g;
      $html =~ s/\@\@\@AUTOREPLYSUBJECT\@\@\@/not available/g;
      $html =~ s/\@\@\@AUTOREPLYTEXT\@\@\@/not available/g;

      $html =~ s/\@\@\@AUTOREPLYSTART\@\@\@/<!--/g;
      $html =~ s/\@\@\@AUTOREPLYEND\@\@\@/-->/g;
   }

   $temphtml = submit("$lang_text{'save'}") . end_form();

   # show cancel button if firsttimeuser not 'yes'
   my $firsttimeuser = param("firsttimeuser") || ''; 
   if ( $firsttimeuser ne 'yes' ) {
      $temphtml .= startform(-action=>"$config{'ow_cgiurl'}/openwebmail-main.pl");
      $temphtml .= hidden(-name=>'action',
                          -default=>'displayheaders',
                          -override=>'1');
      $temphtml .= hidden(-name=>'sessionid',
                          -default=>$thissession,
                          -override=>'1');
      $temphtml .= hidden(-name=>'sort',
                          -default=>$sort,
                          -override=>'1');
      $temphtml .= hidden(-name=>'firstmessage',
                          -default=>$firstmessage,
                          -override=>'1');
      $temphtml .= hidden(-name=>'folder',
                          -default=>$folder,
                          -override=>'1') .
                   '</td><td>' .
                   submit("$lang_text{'cancel'}") . end_form();

      $temphtml .= startform(-action=>"$config{'ow_cgiurl'}/openwebmail-prefs.pl");
      $temphtml .= hidden(-name=>'action',
                          -default=>'viewhistory',
                          -override=>'1');
      $temphtml .= hidden(-name=>'sessionid',
                          -default=>$thissession,
                          -override=>'1');
      $temphtml .= hidden(-name=>'sort',
                          -default=>$sort,
                          -override=>'1');
      $temphtml .= hidden(-name=>'firstmessage',
                          -default=>$firstmessage,
                          -override=>'1');
      $temphtml .= hidden(-name=>'folder',
                          -default=>$folder,
                          -override=>'1') .
                   '</td><td>' .
                   submit("$lang_text{'viewhistory'}") . end_form();

   }

   if ( $config{'enable_changepwd'}) {
      $temphtml .= startform(-action=>"$config{'ow_cgiurl'}/openwebmail-prefs.pl");
      $temphtml .= hidden(-name=>'action',
                          -default=>'editpassword',
                          -override=>'1');
      $temphtml .= hidden(-name=>'sessionid',
                          -default=>$thissession,
                          -override=>'1');
      $temphtml .= hidden(-name=>'sort',
                          -default=>$sort,
                          -override=>'1');
      $temphtml .= hidden(-name=>'firstmessage',
                          -default=>$firstmessage,
                          -override=>'1');
      $temphtml .= hidden(-name=>'folder',
                          -default=>$folder,
                          -override=>'1') .
                   '</td><td>' .
                   submit("$lang_text{'changepwd'}") . end_form();
   }

   $html =~ s/\@\@\@BUTTONS\@\@\@/$temphtml/;

   print $html;

   printfooter();
}

sub getautoreply {
   my $autoreply=0;
   my ($subject, $text)=("", "");

   if (open(FOR, "$homedir/.forward")) {
      my $forwardtext;
      while (<FOR>) {
         $forwardtext.=$_;
      }
      close(FOR);
      if ($forwardtext =~ /\|\s*$config{'vacationpipe'}\s+/) {
         $autoreply=1;
      }
   }

   if (open(MSG, "$homedir/.vacation.msg")) {
      my $inheader=1;
      while (<MSG>) {
         chomp($_);
         if ($inheader==0) {
            $text.="$_\n";
            next;
         }
         if (/^Subject:\s*(.*)/i) {
            $subject=$1;
         } elsif (/^[A-Za-z0-9\-]+: /i) {
            next;
         } else {
            $inheader=0;
            $text.="$_\n";
         }
      }
      close MSG;
   }

   $subject = $config{'default_autoreplysubject'} if ($subject eq "");
   $subject =~ s/\s/ /g;
   $subject =~ s/^\s+//;
   $subject =~ s/\s+$//;

   # remove signature 
   my $s=$prefs{'signature'};
   $s =~ s/\r\n/\n/g;
   my $i=rindex($text, $s);

   $text=substr($text, 0, $i) if ($i>0);

   $text= $config{'default_autoreplytext'} if ($text eq "");
   $text =~ s/\r\n/\n/g;
   $text =~ s/^\s+//s;
   $text =~ s/\s+$//s;

   return($autoreply, $subject, $text);
}

sub setautoreply {
   my ($autoreply, $from, $subject, $text, $signature)=@_;
   my @forwards=();
   my $email;
   my $selfforward=0;
   my $forwardtext;

   if (open(FOR, "$homedir/.forward")) {
      while (<FOR>) {
         $forwardtext.=$_;
      }
      close(FOR);
   } else {
      $selfforward=1;
   }

   # get forward list with selfemail and vacationpipe removed
   foreach $email ( split(/[,\n\r]+/, $forwardtext) ) {
      if ($email=~/$config{'vacationpipe'}/) {
         next;
      } elsif ( $email eq "\\$user" || $email eq "$user" ) {
         $selfforward=1;
         next;
      } elsif ( $email=~/$user\@(.+)/ ) {
         my $islocaldomain=0;
         my $domain=$1;
         foreach (@{$config{'domainnames'}}) {
            if ($domain eq $_) {
               $islocaldomain=1; 
               last;
            }
         }
         if ($islocaldomain) {
            $selfforward=1; 
            next;
         }
      }
      push(@forwards, $email);
   }

   if ($autoreply) {
      $|=1; 				# flush all output
      if ( fork() == 0 ) {		# child
         close(STDOUT);
         close(STDIN);
         # set enviro's for vacation program   
         $ENV{'USER'}=$user;
         $ENV{'LOGNAME'}=$user;
         $ENV{'HOME'}=$homedir;
         $<=$>;		# set uid = euid
         exec($config{'vacationinit'});
#         system("/bin/sh -c '$config{vacationinit} 2>>/tmp/err.log2  >>/tmp/err.log'" );
         exit 0;
      }
      push(@forwards, "\\$user") if ($selfforward);

      # if this user may be mapped from a virtual user
      # then use -j with vacation.pl to not checking the user in to: and cc:
      if ($virtualuser ne "") {
         push(@forwards, "\"|$config{'vacationpipe'} -a $virtualuser $user\"");
      } else {
         push(@forwards, "\"|$config{'vacationpipe'} $user\"");
      }

      open(FOR, ">$homedir/.forward") || return -1;
      print FOR join("\n", @forwards);
      close FOR;
      chown($uuid, $ugid, "$homedir/.forward");
   } else {
      if ($#forwards<0) {
         unlink("$homedir/.forward");
      } else {
         push(@forwards, "\\$user") if ($selfforward);
         open(FOR, ">$homedir/.forward") || return -1;
         print FOR join("\n", @forwards);
         close FOR;
         chown($uuid, $ugid, "$homedir/.forward");
      }
   }
      
   $subject =~ s/\s/ /g;
   $subject =~ s/^\s+//;
   $subject =~ s/\s+$//;
   $subject = $config{'default_autoreplysubject'} if ($subject eq "");

   $text =~ s/\r\n/\n/g;
   $text =~ s/^\s+//s;
   $text =~ s/\s+$//s;
   $text = $config{'default_autoreplytext'} if ($text eq "");

   if (length($text) > 500) {  # truncate to 500 chars
      $text = substr($text, 0, 500);
   }

   open(MSG, ">$homedir/.vacation.msg") || return -2;
   print MSG "From: $from\n".
             "Subject: $subject\n\n".
             "$text\n\n".
             $signature;		# append signature
   close MSG;
   chown($uuid, $ugid, "$homedir/.vacation.msg");
}
#################### END EDITPREFS ###########################

###################### SAVEPREFS #########################
sub saveprefs {
   if (! -d "$folderdir" ) {
      mkdir ("$folderdir", oct(700)) or
         openwebmailerror("$lang_err{'cant_create_dir'} $folderdir");
   }
   open (CONFIG,">$folderdir/.openwebmailrc") or
      openwebmailerror("$lang_err{'couldnt_open'} $folderdir/.openwebmailrc!");
   foreach my $key (qw(language email replyto 
                       style iconset bgurl 
                       sort headers headersperpage defaultdestination
                       confirmmsgmovecopy
                       editcolumns editrows dictionary
                       filter_repeatlimit filter_fakedsmtp 
                       filter_fakedexecontenttype 
                       disablejs hideinternal newmailsound usesmileicon autopop3 
                       trashreserveddays)) {
      my $value = param("$key");
      if ($key eq 'bgurl') {
         my $background=param("background");
         if ($value ne "" &&  $background eq "USERDEFINE") {
            print CONFIG "$key=$value\n";
         } else {
            print CONFIG "$key=$config{'ow_htmlurl'}/images/backgrounds/$background\n";
         }
         next;
      }

      $value =~ s/\.\.+//g;
      $value =~ s/[=\n\/\`\|\<\>;]//g; # remove dangerous char
      if ($key eq 'language') {
         my $validlanguage=0;
         my $currlanguage;
         my @availablelanguages = sort keys(%languagenames);
         foreach $currlanguage (@availablelanguages) {
            if ($value eq $currlanguage) {
               print CONFIG "$key=$value\n";
               last;
            }
         }
      } elsif ($key eq 'dictionary') {
         my $currdictionary;
         foreach $currdictionary (@{$config{'spellcheck_dictionaries'}}) {
            if ($value eq $currdictionary) {
               print CONFIG "$key=$value\n";
               last;
            }
         }
      } elsif ($key eq 'filter_repeatlimit') {
         # if repeatlimit changed, redo filtering may be needed
         if ( $value != $prefs{'filter_repeatlimit'} ) { 
            unlink("$folderdir/.filter.check");
         }
         print CONFIG "$key=$value\n";
      } elsif ( $key eq 'confirmmsgmovecopy' ||
                $key eq 'filter_fakedsmtp' ||
                $key eq 'filter_fakedexecontenttype' ||
                $key eq 'disablejs' ||
                $key eq 'hideinternal' ||
                $key eq 'newmailsound' ||
                $key eq 'usesmileicon' ||
                $key eq 'autopop3' ) {
         $value=0 if ($value eq '');
         print CONFIG "$key=$value\n";
      } else {
         print CONFIG "$key=$value\n";
      }
   }
   close (CONFIG) or openwebmailerror("$lang_err{'couldnt_close'} $folderdir/.openwebmailrc!");

   my $signaturefile="$folderdir/.signature";
   if ( -f "$folderdir/.signature" ) {
      $signaturefile="$folderdir/.signature";
   } elsif ( -f "$homedir/.signature" ) {
      $signaturefile="$homedir/.signature";
   }
   open (SIGNATURE,">$signaturefile") or
      openwebmailerror("$lang_err{'couldnt_open'} $signaturefile!");
   my $value = param("signature") || '';
   $value =~ s/\r\n/\n/g;
   if (length($value) > 500) {  # truncate signature to 500 chars
      $value = substr($value, 0, 500);
   }
   print SIGNATURE $value;
   close (SIGNATURE) or openwebmailerror("$lang_err{'couldnt_close'} $signaturefile!");
   chown($uuid, $ugid, $signaturefile) if ($signaturefile eq "$homedir/.signature");

   # reread preference & language file
   # since email and signature are used in .vacation.msg
   %prefs = %{&readprefs};
   ($prefs{'language'} =~ /^([\w\d\._]+)$/) && ($prefs{'language'} = $1);
   require "etc/lang/$prefs{'language'}";
   $lang_charset ||= 'iso-8859-1';

   if ($config{'enable_autoreply'}) {
      my $autoreply=param("autoreply")||0;
      my $autoreplysubject=param("autoreplysubject");
      my $autoreplytext=param("autoreplytext");
      my $from;
      if ($userfrom{$prefs{'email'}}) {
         $from=qq|"$userfrom{$prefs{'email'}}" <$prefs{'email'}>|;
      } else {
         $from=$prefs{'email'};
      }

      setautoreply($autoreply, $from, 
   		$autoreplysubject, $autoreplytext, $prefs{'signature'});
   }

   printheader();

   my $html = '';
   my $temphtml;

   open (PREFSSAVEDTEMPLATE, "$config{'ow_etcdir'}/templates/$prefs{'language'}/prefssaved.template") or
      openwebmailerror("$lang_err{'couldnt_open'} $config{'ow_etcdir'}/templates/$prefs{'language'}/prefssaved.template!");
   while (<PREFSSAVEDTEMPLATE>) {
      $html .= $_;
   }
   close (PREFSSAVEDTEMPLATE);

   $html = applystyle($html);

   $temphtml = startform(-action=>"$config{'ow_cgiurl'}/openwebmail-main.pl") .
               hidden(-name=>'action',
                      -default=>'displayheaders',
                      -override=>'1') .
               hidden(-name=>'sessionid',
                      -default=>$thissession,
                      -override=>'1') .
               hidden(-name=>'sort',
                      -default=>$sort,
                      -override=>'1') .
               hidden(-name=>'firstmessage',
                      -default=>$firstmessage,
                      -override=>'1') .
               hidden(-name=>'folder',
                      -default=>$folder,
                      -override=>'1') .
               submit("$lang_text{'continue'}") .
               end_form();

   $html =~ s/\@\@\@CONTINUEBUTTON\@\@\@/$temphtml/;

   print $html;

   printfooter();
}
##################### END SAVEPREFS ######################

##################### EDITPASSWORD #######################
sub editpassword {
   my $html = '';
   my $temphtml;

   open (CHANGEPASSWORDTEMPLATE, "$config{'ow_etcdir'}/templates/$prefs{'language'}/chpwd.template") or
      openwebmailerror("$lang_err{'couldnt_open'} $config{'ow_etcdir'}/templates/$prefs{'language'}/chpwd.template!");
   while (<CHANGEPASSWORDTEMPLATE>) {
      $html .= $_;
   }
   close (CHANGEPASSWORDTEMPLATE);

   $html = applystyle($html);

   printheader();

   $temphtml = startform(-name=>"passwordform",
			 -action=>"$config{'ow_cgiurl'}/openwebmail-prefs.pl") .
               hidden(-name=>'action',
                      -default=>'changepassword',
                      -override=>'1') .
               hidden(-name=>'sessionid',
                      -default=>$thissession,
                      -override=>'1') .
               hidden(-name=>'sort',
                      -default=>$sort,
                      -override=>'1') .
               hidden(-name=>'firstmessage',
                      -default=>$firstmessage,
                      -override=>'1') .
               hidden(-name=>'folder',
                      -default=>$folder,
                      -override=>'1');

   $html =~ s/\@\@\@STARTFORM\@\@\@/$temphtml/;

   # display virtual or user, but actually not used, chnagepassword grab user from sessionid
   $temphtml = textfield(-name=>'loginname',
                         -default=>$virtualuser||$user,
                         -size=>'10',
                         -disabled=>1,
                         -override=>'1');

   $html =~ s/\@\@\@USERIDFIELD\@\@\@/$temphtml/;

   $temphtml = password_field(-name=>'oldpassword',
                              -default=>'',
                              -size=>'10',
                              -override=>'1');
   $html =~ s/\@\@\@OLDPASSWORDFIELD\@\@\@/$temphtml/;
   
   $temphtml = password_field(-name=>'newpassword',
                              -default=>'',
                              -size=>'10',
                              -override=>'1');
   $html =~ s/\@\@\@NEWPASSWORDFIELD\@\@\@/$temphtml/;
   
   $temphtml = password_field(-name=>'confirmnewpassword',
                              -default=>'',
                              -size=>'10',
                              -override=>'1');
   $html =~ s/\@\@\@CONFIRMNEWPASSWORDFIELD\@\@\@/$temphtml/;
   
   $temphtml = submit(-name=> $lang_text{'changepwd'},
                      -onClick=>"return changecheck()");
   $html =~ s/\@\@\@CHANGEBUTTON\@\@\@/$temphtml/;

   $temphtml = end_form();
   $html =~ s/\@\@\@ENDFORM\@\@\@/$temphtml/;

   $temphtml = startform(-action=>"$config{'ow_cgiurl'}/openwebmail-prefs.pl") .
               hidden(-name=>'sessionid',
                      -default=>$thissession,
                      -override=>'1') .
               hidden(-name=>'sort',
                      -default=>$sort,
                      -override=>'1') .
               hidden(-name=>'firstmessage',
                      -default=>$firstmessage,
                      -override=>'1') .
               hidden(-name=>'folder',
                      -default=>$folder,
                      -override=>'1').
               submit("$lang_text{'cancel'}").
               end_form();

   $html =~ s/\@\@\@CANCELBUTTON\@\@\@/$temphtml/;

   print $html;

   printfooter();
}
##################### END EDITPASSWORD #######################

##################### CHANGEPASSWORD #######################
sub changepassword {
   my $oldpassword=param("oldpassword");
   my $newpassword=param("newpassword");
   my $confirmnewpassword=param("confirmnewpassword");

   my $html = '';
   my $temphtml;

   if ( $newpassword ne $confirmnewpassword ) {
      open (MISMATCH, "$config{'ow_etcdir'}/templates/$prefs{'language'}/chpwdconfirmmismatch.template") or
         openwebmailerror("$lang_err{'couldnt_open'} $config{'ow_etcdir'}/templates/$prefs{'language'}/chpwdconfirmmismatch.template!");
      while (<MISMATCH>) {
         $html .= $_;
      }
      close (MISMATCH);

   } else {
      my ($origruid, $origeuid)=($<, $>); 
      my $errorcode;
      
      $>=0; $<=$>;			# set ruid/euid to root before change passwd
      $errorcode=change_userpassword($user, $oldpassword, $newpassword);
      $<=$origruid; $>=$origeuid;	# fall back to original ruid/euid	

      if ($errorcode==0) {
         writelog("change passwd");
         writehistory("change passwd");
         open (CHANGED, "$config{'ow_etcdir'}/templates/$prefs{'language'}/chpwdok.template") or
            openwebmailerror("$lang_err{'couldnt_open'} $config{'ow_etcdir'}/templates/$prefs{'language'}/chpwdok.template!");
         while (<CHANGED>) {
            $html .= $_;
         }
         close (CHANGED);

      } else {
         my $errormsg;
         if ($errorcode==-1) {
            $errormsg=$lang_err{'func_notsupported'};
         } elsif ($errorcode==-2) {
            $errormsg=$lang_err{'param_fmterr'};
         } elsif ($errorcode==-3) {
            $errormsg=$lang_err{'auth_syserr'};
         } elsif ($errorcode==-4) {
            $errormsg=$lang_err{'pwd_incorrect'};
         } else {
            $errormsg="Unknow error code $errorcode";
         }
         writelog("change passwd error - $errorcode");
         writehistory("change passwd error - $errorcode");

#         sleep 10;	# delayed response

         open (INCORRECT, "$config{'ow_etcdir'}/templates/$prefs{'language'}/chpwdfailed.template") or
            openwebmailerror("$lang_err{'couldnt_open'} $config{'ow_etcdir'}/templates/$prefs{'language'}/chpwdfailed.template!");
         while (<INCORRECT>) {
            $html .= $_;
         }
         close (INCORRECT);
         $html =~ s/\@\@\@ERRORMSG\@\@\@/$errormsg/;
      }

   }

   $html = applystyle($html);

   printheader();

   $temphtml = startform(-action=>"$config{'ow_cgiurl'}/openwebmail-prefs.pl") .
               hidden(-name=>'sessionid',
                      -default=>$thissession,
                      -override=>'1') .
               hidden(-name=>'sort',
                      -default=>$sort,
                      -override=>'1') .
               hidden(-name=>'firstmessage',
                      -default=>$firstmessage,
                      -override=>'1') .
               hidden(-name=>'folder',
                      -default=>$folder,
                      -override=>'1').
               submit("$lang_text{'continue'}").
               end_form();

   $html =~ s/\@\@\@CONTINUEBUTTON\@\@\@/$temphtml/;

   print $html;

   printfooter();
}
##################### END CHANGEPASSWORD #######################

##################### LOGINHISTORY #######################
sub viewhistory {
   my $html = '';
   my $temphtml;

   open (HISTORY, "$config{'ow_etcdir'}/templates/$prefs{'language'}/history.template") or
      openwebmailerror("$lang_err{'couldnt_open'} $config{'ow_etcdir'}/templates/$prefs{'language'}/history.template!");
   while (<HISTORY>) {
      $html .= $_;
   }
   close (HISTORY);

   $html = applystyle($html);

   printheader();

   $temphtml="";

   open (HISTORYLOG, "$folderdir/.history.log");

   my $bgcolor = $style{"tablerow_dark"};
   while (<HISTORYLOG>) {
      chomp($_);
      $_=~/^(.*?) - \[(\d+)\] \((.*?)\) (.*)$/;

      my $record;
      my ($timestamp, $pid, $ip, $misc)=($1, $2, $3, $4);
      my ($u, $event, $desc, $desc2)=split(/ \- /, $misc, 4);
      if ($event !~ /error/i) {
         $record = qq|<tr>|.
                   qq|<td bgcolor=$bgcolor align="center">$timestamp</font></td>|.
                   qq|<td bgcolor=$bgcolor align="center">$ip</td>|.
                   qq|<td bgcolor=$bgcolor align="center">$u</td>|.
                   qq|<td bgcolor=$bgcolor align="center">$event</td>|.
                   qq|<td bgcolor=$bgcolor align="center">$desc</td>|.
                   qq|</tr>\n|;
      } else {
         $record = qq|<tr>|.
                   qq|<td bgcolor=$bgcolor align="center"><font color="#cc0000"><b>$timestamp</font></td>|.
                   qq|<td bgcolor=$bgcolor align="center"><font color="#cc0000"><b>$ip</font></td>|.
                   qq|<td bgcolor=$bgcolor align="center"><font color="#cc0000"><b>$u</font></td>|.
                   qq|<td bgcolor=$bgcolor align="center"><font color="#cc0000"><b>$event</b></font></td>|.
                   qq|<td bgcolor=$bgcolor align="center"><font color="#cc0000"><b>$desc</font></td>|.
                   qq|</tr>\n|;
      }
      $temphtml = $record . $temphtml;

      if ($bgcolor eq $style{"tablerow_dark"}) {
         $bgcolor = $style{"tablerow_light"};
      } else {
         $bgcolor = $style{"tablerow_dark"};
      }
   }

   close(HISTORYLOG);

   $html =~ s/\@\@\@LOGINHISTORY\@\@\@/$temphtml/;

   $temphtml = startform(-action=>"$config{'ow_cgiurl'}/openwebmail-prefs.pl") .
               hidden(-name=>'sessionid',
                      -default=>$thissession,
                      -override=>'1') .
               hidden(-name=>'sort',
                      -default=>$sort,
                      -override=>'1') .
               hidden(-name=>'firstmessage',
                      -default=>$firstmessage,
                      -override=>'1') .
               hidden(-name=>'folder',
                      -default=>$folder,
                      -override=>'1').
               submit("$lang_text{'continue'}").
               end_form();

   $html =~ s/\@\@\@CONTINUEBUTTON\@\@\@/$temphtml/;

   print $html;

   printfooter();
}
##################### END LOGINHISTORY #######################

#################### EDITFOLDERS ###########################
sub editfolders {
   my (@defaultfolders, @userfolders);
   local ($total_newmessages, $total_allmessages, $total_foldersize)=(0,0,0);

   push(@defaultfolders, 'INBOX', 
                         'saved-messages', 
                         'sent-mail', 
                         'saved-drafts', 
                         'mail-trash');

   foreach (@validfolders) {
      if ($_ ne 'INBOX' &&
          $_ ne 'saved-messages' &&
          $_ ne 'sent-mail' &&
          $_ ne 'saved-drafts' &&
          $_ ne 'mail-trash') {
         push (@userfolders, $_);
      }
   }

   my $html = '';
   my $temphtml;

   open (EDITFOLDERSTEMPLATE, "$config{'ow_etcdir'}/templates/$prefs{'language'}/editfolders.template") or
      openwebmailerror("$lang_err{'couldnt_open'} $config{'ow_etcdir'}/templates/$prefs{'language'}/editfolders.template!");
   while (<EDITFOLDERSTEMPLATE>) {
      $html .= $_;
   }
   close (EDITFOLDERSTEMPLATE);

   $html = applystyle($html);

   $html =~ s/\@\@\@FOLDERNAME_MAXLEN\@\@\@/$config{'foldername_maxlen'}/g;

   printheader();

   $temphtml = "<a href=\"$config{'ow_cgiurl'}/openwebmail-main.pl?action=displayheaders&amp;sessionid=$thissession&amp;sort=$sort&amp;firstmessage=$firstmessage&amp;folder=$escapedfolder\"><IMG SRC=\"$config{'ow_htmlurl'}/images/iconsets/$prefs{'iconset'}/backtofolder.gif\" border=\"0\" ALT=\"$lang_text{'backto'} $printfolder\"></a>";

   $html =~ s/\@\@\@MENUBARLINKS\@\@\@/$temphtml/g;

   $temphtml = start_form(-action=>"$config{'ow_cgiurl'}/openwebmail-prefs.pl") .
               hidden(-name=>'action',
                      -value=>'addfolder',
                      -override=>'1') .
               hidden(-name=>'sessionid',
                      -value=>$thissession,
                      -override=>'1') .
               hidden(-name=>'sort',
                      -default=>$sort,
                      -override=>'1') .
               hidden(-name=>'firstmessage',
                      -default=>$firstmessage,
                      -override=>'1') .
               hidden(-name=>'folder',
                      -default=>$folder,
                      -override=>'1');

   $html =~ s/\@\@\@STARTFOLDERFORM\@\@\@/$temphtml/;

   $temphtml = textfield(-name=>'foldername',
                         -default=>'',
                         -size=> $config{'foldername_maxlen'},
                         -maxlength=>$config{'foldername_maxlen'},
                         -override=>'1');

   $html =~ s/\@\@\@FOLDERNAMEFIELD\@\@\@/$temphtml/;

   $temphtml = submit(-name=>"$lang_text{'add'}",
                      -class=>"medtext");
   $html =~ s/\@\@\@ADDBUTTON\@\@\@/$temphtml/;

   $temphtml = end_form();
   $html =~ s/\@\@\@ENDFORM\@\@\@/$temphtml/;

   my $bgcolor = $style{"tablerow_dark"};
   my $currfolder;
   my $i=0;
   $temphtml='';
   foreach $currfolder (@userfolders) {
      $temphtml .= _folderline($currfolder, $i, $bgcolor);
      if ($bgcolor eq $style{"tablerow_dark"}) {
         $bgcolor = $style{"tablerow_light"};
      } else {
         $bgcolor = $style{"tablerow_dark"};
      }
      $i++;
   }
   $html =~ s/\@\@\@FOLDERS\@\@\@/$temphtml/;

   $bgcolor = $style{"tablerow_dark"};
   $temphtml='';
   foreach $currfolder (@defaultfolders) {
      $temphtml .= _folderline($currfolder, $i, $bgcolor);
      if ($bgcolor eq $style{"tablerow_dark"}) {
         $bgcolor = $style{"tablerow_light"};
      } else {
         $bgcolor = $style{"tablerow_dark"};
      }
      $i++;
   }
   $html =~ s/\@\@\@DEFAULTFOLDERS\@\@\@/$temphtml/;

   my $usagestr;
   if ($config{'folderquota'}) {
      if ($folderusage>=90) {
         $usagestr="<B><font color='#cc0000'>$folderusage %</font></B>";
      } else {
         $usagestr="<B>$folderusage %</B>";
      }
   } else {
      $usagestr="&nbsp;";
   }

   if ($total_foldersize > 1048575){
      $total_foldersize = int(($total_foldersize/1048576)+0.5) . "MB";
   } elsif ($total_foldersize > 1023) {
      $total_foldersize =  int(($total_foldersize/1024)+0.5) . "KB";
   }
   $temphtml = "<tr>".
               "<td align=\"center\" bgcolor=$bgcolor><B>$lang_text{'total'}</B></td>".
               "<td align=\"center\" bgcolor=$bgcolor><B>$total_newmessages</B></td>".
               "<td align=\"center\" bgcolor=$bgcolor><B>$total_allmessages</B></td>".
               "<td align=\"center\" bgcolor=$bgcolor><B>$total_foldersize</B></td>".
               "<td bgcolor=$bgcolor align=\"center\">$usagestr</td>";
               "</tr>";
   $html =~ s/\@\@\@TOTAL\@\@\@/$temphtml/;

   print $html;

   printfooter();
}

# this is inline function used by sub editfolders(), it changes
# $total_newmessages, $total_allmessages and $total_size in editfolders()
sub _folderline {
   my ($currfolder, $i, $bgcolor)=@_;
   my $temphtml='';
   my (%HDB, $newmessages, $allmessages, $foldersize);
   my ($folderfile,$headerdb)=get_folderfile_headerdb($user, $currfolder);

   if ( -f "$headerdb$config{'dbm_ext'}" ) {
      filelock("$headerdb$config{'dbm_ext'}", LOCK_SH);
      dbmopen (%HDB, $headerdb, undef);
      if ( defined($HDB{'ALLMESSAGES'}) ) {
         $allmessages=$HDB{'ALLMESSAGES'};
         $total_allmessages+=$allmessages;
      } else {
         $allmessages='&nbsp;';
      }
      if ( defined($HDB{'NEWMESSAGES'}) ) {
         $newmessages=$HDB{'NEWMESSAGES'};
         $total_newmessages+=$newmessages;
      } else {
         $newmessages='&nbsp;';
      }
      dbmclose(%HDB);
      filelock("$headerdb$config{'dbm_ext'}", LOCK_UN);
   } else {
      $allmessages='&nbsp;';
      $newmessages='&nbsp;';
   }

   # we count size for both folder file and related dbm
   $foldersize = (-s "$folderfile") + (-s "$headerdb$config{'dbm_ext'}");

   $total_foldersize+=$foldersize;
   # round foldersize and change to an appropriate unit for display
   if ($foldersize > 1048575){
      $foldersize = int(($foldersize/1048576)+0.5) . "MB";
   } elsif ($foldersize > 1023) {
      $foldersize =  int(($foldersize/1024)+0.5) . "KB";
   }

   my $escapedcurrfolder = escapeURL($currfolder);
   my $url = "$config{'ow_cgiurl'}/openwebmail-prefs.pl?sessionid=$thissession&amp;folder=$escapedcurrfolder&amp;action=downloadfolder";
   my $folderstr=$currfolder;
   $folderstr=$lang_folders{$currfolder} if defined($lang_folders{$currfolder});

   if ($currfolder eq 'INBOX') {
      $temphtml .= "<tr>".
                   "<td align=\"center\" bgcolor=$bgcolor>$folderstr".
                   "&nbsp;<a href=\"$url\"><IMG SRC=\"$config{'ow_htmlurl'}/images/iconsets/$prefs{'iconset'}/download.gif\" align=\"absmiddle\" border=\"0\" ALT=\"$lang_text{'download'} $folderstr\">".
                   "</a></td>".
                   "<td align=\"center\" bgcolor=$bgcolor>$newmessages</td>".
                   "<td align=\"center\" bgcolor=$bgcolor>$allmessages</td>".
                   "<td align=\"center\" bgcolor=$bgcolor>$foldersize</td>".
                   "<td bgcolor=$bgcolor align=\"center\">-----</td>";
                   "</tr>";
   } else {
      $temphtml .= "<tr>".
                   "<td align=\"center\" bgcolor=$bgcolor>$folderstr".
                   "&nbsp;<a href=\"$url\"><IMG SRC=\"$config{'ow_htmlurl'}/images/iconsets/$prefs{'iconset'}/download.gif\" align=\"absmiddle\" border=\"0\" ALT=\"$lang_text{'download'} $folderstr\">".
                   "</a></td>".
                   "<td align=\"center\" bgcolor=$bgcolor>$newmessages</td>".
                   "<td align=\"center\" bgcolor=$bgcolor>$allmessages</td>".
                   "<td align=\"center\" bgcolor=$bgcolor>$foldersize</td>";

      $temphtml .= start_form(-action=>"$config{'ow_cgiurl'}/openwebmail-prefs.pl",
                              -name=>"folderform$i");
      $temphtml .= hidden(-name=>'action',
                          -value=>'deletefolder',
                          -override=>'1');
      $temphtml .= hidden(-name=>'sessionid',
                          -value=>$thissession,
                          -override=>'1');
      $temphtml .= hidden(-name=>'sort',
                          -default=>$sort,
                          -override=>'1');
      $temphtml .= hidden(-name=>'firstmessage',
                          -default=>$firstmessage,
                          -override=>'1');
      $temphtml .= hidden(-name=>'folder',
                          -default=>$folder,
                          -override=>'1');
      $temphtml .= hidden(-name=>'foldername',
                          -value=>$currfolder,
                          -override=>'1');
      $temphtml .= hidden(-name=>'foldernewname',
                          -value=>$currfolder,
                          -override=>'1');

      $temphtml .= "<td bgcolor=$bgcolor align=\"center\">";

      $temphtml .= submit(-name=>"$lang_text{'rename'}", 
                          -class=>"medtext",
                          -onClick=>"return OpConfirm('folderform$i', 'renamefolder', $lang_text{'folderrenprop'}+' ( $currfolder )')");
      $temphtml .= submit(-name=>"$lang_text{'delete'}",
                          -class=>"medtext",
                          -onClick=>"return OpConfirm('folderform$i', 'deletefolder', $lang_text{'folderdelconf'}+' ( $currfolder )')");
      $temphtml .= '</td></tr>';
      $temphtml .= end_form();
   }

   return($temphtml);
}
################### END EDITFOLDERS ########################

################### ADDFOLDER ##############################
sub addfolder {
   my $foldertoadd = param('foldername') || '';
   $foldertoadd =~ s/\.\.+//g;
   $foldertoadd =~ s/[\s\/\`\|\<\>;]//g; # remove dangerous char
   ($foldertoadd =~ /^(.+)$/) && ($foldertoadd = $1);

   if (length($foldertoadd) > $config{'foldername_maxlen'}) {
      openwebmailerror("$lang_err{'foldername_long'}");
   }
   if ( is_defaultfolder($foldertoadd) ||
        $foldertoadd eq "$user" || $foldertoadd eq "" ) {
      openwebmailerror("$lang_err{'cant_create_folder'}");
   }

   my ($folderfile, $headerdb)=get_folderfile_headerdb($user, $foldertoadd);
   if ( -f $folderfile ) {
      openwebmailerror ("$lang_err{'folder_with_name'} $foldertoadd $lang_err{'already_exists'}");
   }

   open (FOLDERTOADD, ">$folderfile") or
      openwebmailerror("$lang_err{'cant_create_folder'} $foldertoadd!");
   close (FOLDERTOADD) or openwebmailerror("$lang_err{'couldnt_close'} $foldertoadd!");

   # create empty index dbm with mode 0600
   my %HDB;
   dbmopen(%HDB, $headerdb, 0600);
   dbmclose(%HDB);

   writelog("create folder - $foldertoadd");
   writehistory("create folder - $foldertoadd");

   getfolders(\@validfolders, \$folderusage, 0);
   editfolders();
}

sub is_defaultfolder {
   my $foldername=$_[0];
   if ($foldername eq 'INBOX' ||
       $foldername eq 'saved-messages' || 
       $foldername eq 'sent-mail' ||
       $foldername eq 'saved-drafts' ||
       $foldername eq 'mail-trash' ||
       $foldername eq 'DELETE' ||
       $foldername eq $lang_folders{'saved-messages'} ||
       $foldername eq $lang_folders{'sent-mail'} ||
       $foldername eq $lang_folders{'saved-drafts'} ||
       $foldername eq $lang_folders{'mail-trash'} ) {
      return(1);
   } else {
      return(0);
   }
}
################### END ADDFOLDER ##########################

################### DELETEFOLDER ##############################
sub deletefolder {
   my $foldertodel = param('foldername') || '';
   $foldertodel =~ s/\.\.+//g;
   $foldertodel =~ s/[\s\/\`\|\<\>;]//g; # remove dangerous char
   ($foldertodel =~ /^(.+)$/) && ($foldertodel = $1);

   # if is INBOX, return to editfolder immediately
   if ($foldertodel eq 'INBOX') {
      editfolders();
      return;
   }

   if ( -f "$folderdir/$foldertodel" ) {
      unlink ("$folderdir/$foldertodel",
              "$folderdir/.$foldertodel$config{'dbm_ext'}",
              "$folderdir/.$foldertodel.db",
	      "$folderdir/.$foldertodel.dir",
              "$folderdir/.$foldertodel.pag",
              "$folderdir/.$foldertodel.cache",
              "$folderdir/$foldertodel.lock",
              "$folderdir/$foldertodel.lock.lock");              

      writelog("delete folder - $foldertodel");
      writehistory("delete folder - $foldertodel");
   }

   getfolders(\@validfolders, \$folderusage, 0);
   editfolders();
}
################### END DELETEFOLDER ##########################

################### RENAMEFOLDER ##############################
sub renamefolder {
   my $oldname = param('foldername') || '';
   $oldname =~ s/\.\.+//g;
   $oldname =~ s/[\s\/\`\|\<\>;]//g; # remove dangerous char
   ($oldname =~ /^(.+)$/) && ($oldname = $1);

   if ($oldname eq 'INBOX') {
      editfolders();
      return;
   }

   my $newname = param('foldernewname');
   $newname =~ s/\.\.+//g;
   $newname =~ s/[\s\/\`\|\<\>;]//g; # remove dangerous char
   ($newname =~ /^(.+)$/) && ($newname = $1);

   if (length($newname) > $config{'foldername_maxlen'}) {
      openwebmailerror("$lang_err{'foldername_long'}");
   }
   if ( is_defaultfolder($newname) ||
        $newname eq "$user" || $newname eq "" ) {
      openwebmailerror("$lang_err{'cant_create_folder'}");
   }
   if ( -f "$folderdir/$newname" ) {
      openwebmailerror ("$lang_err{'folder_with_name'} $newname $lang_err{'already_exists'}");
   }

   if ( -f "$folderdir/$oldname" ) {
      rename("$folderdir/$oldname",          "$folderdir/$newname");
      rename("$folderdir/.$oldname$config{'dbm_ext'}", "$folderdir/.$newname$config{'dbm_ext'}");
      rename("$folderdir/.$oldname.db",      "$folderdir/.$newname.db");
      rename("$folderdir/.$oldname.dir",     "$folderdir/.$newname.dir");
      rename("$folderdir/.$oldname.pag",     "$folderdir/.$newname.pag");
      rename("$folderdir/.$oldname.cache",   "$folderdir/.$newname.cache");
      unlink("$folderdir/$oldname.lock", "$folderdir/$oldname.lock.lock");

      writelog("rename folder - rename $oldname to $newname");
      writehistory("rename folder - rename $oldname to $newname");
   }

#   print "Location: $config{'ow_cgiurl'}/openwebmail-prefs.pl?action=editfolders&sessionid=$thissession&sort=$sort&folder=$escapedfolder&firstmessage=$firstmessage\n\n";
   getfolders(\@validfolders, \$folderusage, 0);
   editfolders();
}
################### END RENAMEFOLDER ##########################

#################### DOWNLOAD FOLDER #######################
sub downloadfolder {
   my ($folderfile, $headerdb)=get_folderfile_headerdb($user, $folder);
   my ($cmd, $contenttype, $filename);
   my $buff;

   if ( -x '/usr/local/bin/zip' ) {
      $cmd="/usr/local/bin/zip -r - $folderfile |";
      $contenttype='application/x-zip-compressed';
      $filename="$folder.zip";

   } elsif ( -x '/usr/bin/zip' ) {
      $cmd="/usr/bin/zip -r - $folderfile |";
      $contenttype='application/x-zip-compressed';
      $filename="$folder.zip";

   } elsif ( -x '/usr/bin/gzip' ) {
      $cmd="/usr/bin/gzip -c $folderfile |";
      $contenttype='application/x-gzip-compressed';
      $filename="$folder.gz";

   } elsif ( -x '/usr/local/bin/gzip' ) {
      $cmd="/usr/local/bin/gzip -c $folderfile |";
      $contenttype='application/x-gzip-compressed';
      $filename="$folder.gz";

   } else {
      $cmd="$folderfile";
      $contenttype='text/plain';
      $filename="$folder";
   }

   $filename=~s/\s+/_/g;

   filelock($folderfile, LOCK_EX|LOCK_NB) or
      openwebmailerror("$lang_err{'couldnt_lock'} $folderfile");

   # disposition:attachment default to save
   print qq|Content-Transfer-Coding: binary\n|,
         qq|Connection: close\n|,
         qq|Content-Type: $contenttype; name="$filename"\n|;

   # ugly hack since ie5.5 is broken with disposition: attchment
   if ( $ENV{'HTTP_USER_AGENT'}!~/MSIE 5.5/ ) {
      print qq|Content-Disposition: attachment; filename="$filename"\n|;
   }
   print qq|\n|;

   ($cmd =~ /^(.+)$/) && ($cmd = $1);		# bypass taint check
   open (T, $cmd);
   while ( read(T, $buff,32768) ) {
     print $buff;
   }
   close(T);

   filelock($folderfile, LOCK_UN);

   writelog("download folder - $folder");
   writehistory("download folder - $folder");

   return;
}
################## END DOWNLOADFOLDER #####################

#################### ADDRESSBOOK #######################
sub addressbook {
   if ( $CGI::VERSION>=2.57) {
      print header(-pragma=>'no-cache',
                   -charset=>$lang_charset);
   } else {
      print header(-pragma=>'no-cache');
   }
   print start_html(-"title"=>"$lang_text{'abooktitle'}",
                    -BGCOLOR=>'#FFFFFF',
                    -BACKGROUND=>$prefs{'bgurl'});
   my %addresses=();
   my %globaladdresses=();
   my ($name, $email);
   my $form=param("form");
   my $field=param("field");
   my $preexisting = param("preexisting") || '';
   $preexisting =~ s/(\s+)?,(\s+)?/,/g;
   print startform(-action=>"javascript:Update('" . $field . "')",
                   -name=>'addressbook'
                  );
   print '<table border="0" align="center" width="90%" cellpadding="0" cellspacing="0">';

   if (defined($lang_text{$field})) {
      print '<tr><td colspan="2" bgcolor=',$style{"titlebar"},' align="left">',
      '<font color=',$style{"titlebar_text"},' face=',$style{"fontface"},' size="3"><b>',uc($lang_text{$field}),": $lang_text{'abook'}</b></font>",
      '</td></tr>';
   } else {
      print '<tr><td colspan="2" bgcolor=',$style{"titlebar"},' align="left">',
      '<font color=',$style{"titlebar_text"},' face=',$style{"fontface"},' size="3"><b>',uc($field),": $lang_text{'abook'}</b></font>",
      '</td></tr>';
   }
   my $bgcolor = $style{"tablerow_dark"};
   if ( -f "$folderdir/.address.book" ) {
      open (ABOOK,"$folderdir/.address.book") or
         openwebmailerror("$lang_err{'couldnt_open'} $folderdir/.address.book!");
      while (<ABOOK>) {
         ($name, $email) = (split(/\@\@\@/, $_, 3))[0,1];
         chomp($email);
         $addresses{"$name"} = $email;
      }
      close (ABOOK) or openwebmailerror("$lang_err{'couldnt_close'} $folderdir/.address.book!");

      foreach my $key (sort(keys %addresses)) {
         print "<tr><td bgcolor=$bgcolor width=\"20\"><input type=\"checkbox\" name=\"to\" value=\"",
         $addresses{"$key"}, '"';
         if ($preexisting =~ s/\Q$addresses{"$key"}\E,?//g) {
            print " checked";
         }
         print "></td><td width=\"100%\" bgcolor=$bgcolor>$key</td></tr>\n";
         if ($bgcolor eq $style{"tablerow_dark"}) {
            $bgcolor = $style{"tablerow_light"};
         } else {
            $bgcolor = $style{"tablerow_dark"};
         }
      }
   }

   if ( $config{'global_addressbook'} ne "" && -f "$config{'global_addressbook'}" ) {
      if (open (ABOOK,"$config{'global_addressbook'}")) {
         while (<ABOOK>) {
            ($name, $email) = (split(/\@\@\@/, $_, 3))[0,1];
            chomp($email);
            $globaladdresses{"$name"} = $email;
         }
         close (ABOOK);
      }
      foreach my $key (sort(keys %globaladdresses)) {
         print "<tr><td bgcolor=$bgcolor width=\"20\"><input type=\"checkbox\" name=\"to\" value=\"",
         $globaladdresses{"$key"}, '"';
         if ($preexisting =~ s/\Q$globaladdresses{"$key"}\E,?//g) {
            print " checked";
         }
         print "></td><td width=\"100%\" bgcolor=$bgcolor>$key</td></tr>\n";
         if ($bgcolor eq $style{"tablerow_dark"}) {
            $bgcolor = $style{"tablerow_light"};
         } else {
            $bgcolor = $style{"tablerow_dark"};
         }
      }
   }

   print '</td></tr><tr><td align="center" colspan="2" bgcolor=',$style{"tablerow_dark"},'>';
   print '<input type="hidden" name="remainingstr" value="', $preexisting, '">';
   print '<input type="submit" name="mailto.x" value="OK"> &nbsp;&nbsp;';
   print '<input type="button" value="Cancel" onClick="window.close();">';
   print '</td></tr></table>';
   print qq|<script language="JavaScript">
      <!--
      function Update(whichfield)
      {
         var e2 = document.addressbook.remainingstr.value;
         for (var i = 0; i < document.addressbook.elements.length; i++)
         {
            var e = document.addressbook.elements[i];
            if (e.name == "to" && e.checked)
            {
               if (e2)
                  e2 += ",";
               e2 += e.value;
            }
         }
         window.opener.document.$form.$field.value = e2;
         window.close();
      }
      //-->
      </script>|;
   print end_form();
   print end_html();
}
################## END ADDRESSBOOK #####################

##################### IMPORTABOOK ############################
sub importabook {
   my ($name, $email, $note);
   my (%addresses, %notes);
   my $abookupload = param("abook") || '';
   my $abooktowrite='';
   my $mua = param("mua") || '';
   if ($abookupload) {
      no strict 'refs';
      my $abookcontents = '';
      while (<$abookupload>) {
         $abookcontents .= $_;
      }
      close($abookupload);
#      if ($mua eq 'outlookexp5') {
#         unless ($abookcontents =~ /^Name,E-mail Address/) {
#            openwebmailerror("$lang_err{'abook_invalid'} <a href=\"$config{'ow_cgiurl'}/openwebmail-prefs.pl?action=importabook&amp;sessionid=$thissession&amp;sort=$sort&amp;folder=$escapedfolder&amp;firstmessage=$firstmessage&amp;message_id=$escapedmessageid\">$lang_err{'back'}</a> $lang_err{'tryagain'}");
#         }
#      }
      unless ( -f "$folderdir/.address.book" ) {
         open (ABOOK, ">>$folderdir/.address.book"); # Create if nonexistent
         close(ABOOK);
      }
      filelock("$folderdir/.address.book", LOCK_EX|LOCK_NB) or
         openwebmailerror("$lang_err{'couldnt_lock'} $folderdir/.address.book!");
      open (ABOOK,"+<$folderdir/.address.book") or
         openwebmailerror("$lang_err{'couldnt_open'} $folderdir/.address.book!");
      while (<ABOOK>) {
         ($name, $email, $note) = split(/\@\@\@/, $_, 3);
         chomp($email); chomp($note);
         $addresses{"$name"} = $email;
         $notes{"$name"}=$note;
      }
      my @fields;
      my $quotecount;
      my $tempstr;
      my @processed;

      foreach (split(/\r*\n/, $abookcontents)) {
 #        next if ( ($mua eq 'outlookexp5') && (/^Name,E-mail Address/) );
         next if ( $_ !~ (/\@/) );
         if (/,/) {
            @fields = split(/,/);
         } elsif (/;/) {
            @fields = split(/;/);
         } else {
            next;
         }
         $quotecount = 0;
         @processed = ();
         $tempstr = '';
         foreach my $str (@fields) {
            # remove a par of " 
            $str=~s/^\s*"(.*)"\s*$/$1/;
            # handle single "
            if ( ($str =~ /"/) && ($quotecount == 1) ) {
               $tempstr .= ',' . $str;
               $tempstr =~ s/"//g;
               push (@processed, $tempstr);
               $tempstr = '';
               $quotecount = 0;
            } elsif ($str =~ /"/) {
               $tempstr .= $str;
               $quotecount = 1;
            } elsif ($quotecount == 1) {
               $tempstr .= ',' . $str;
            } else {
               push (@processed, $str);
            }
         }

         if ( ($mua eq 'outlookexp5') && ($processed[0]) && ($processed[1]) ) {
            $processed[0] =~ s/^\s*//;
            $processed[0] =~ s/\s*$//;
            $processed[0] =~ s/://;
            $processed[0] =~ s/</&lt;/g;
            $processed[0] =~ s/>/&gt;/g;
            $processed[1] =~ s/</&lt;/g;
            $processed[1] =~ s/>/&gt;/g;
            $addresses{$processed[0]} = $processed[1];
            $note = join(",", @processed[2..9]);
            $note =~ s/,\s*,//g; 
            $note =~ s/^\s*,\s*//g;
            $note =~ s/\s*,\s*$//g;
            $notes{$processed[0]} = $note;
         } elsif ( ($mua eq 'nsmail') && ($processed[0]) && ($processed[6]) ) {
            $processed[0] =~ s/^\s*//;
            $processed[0] =~ s/\s*$//;
            $processed[0] =~ s/://;
            $processed[0] =~ s/</&lt;/g;
            $processed[0] =~ s/>/&gt;/g;
            $processed[6] =~ s/</&lt;/g;
            $processed[6] =~ s/>/&gt;/g;
            $addresses{"$processed[0]"} = $processed[6];
            $note = join(",", @processed[1..5,7..9]);
            $note =~ s/,\s*,//g; 
            $note =~ s/^\s*,\s*//g;
            $note =~ s/\s*,\s*$//g;
            $notes{$processed[0]} = $note;
         }
      }

      seek (ABOOK, 0, 0) or
         openwebmailerror("$lang_err{'couldnt_seek'} $folderdir/.address.book!");

      foreach $name (sort keys %addresses) {
         $abooktowrite .= "$name\@\@\@$addresses{$name}\@\@\@$notes{$name}\n";
      }

      if (length($abooktowrite) > ($config{'maxbooksize'} * 1024)) {
         openwebmailerror("$lang_err{'abook_toobig'}".
                          "<a href=\"$config{'ow_cgiurl'}/openwebmail-prefs.pl?action=importabook&amp;sessionid=$thissession&amp;sort=$sort&amp;folder=$escapedfolder&amp;firstmessage=$firstmessage&amp;message_id=$escapedmessageid\">$lang_err{'back'}</a>".
                          "$lang_err{'tryagain'}");
      }
      print ABOOK $abooktowrite;
      truncate(ABOOK, tell(ABOOK));

      close (ABOOK) or openwebmailerror("$lang_err{'couldnt_close'} $folderdir/.address.book!");
      filelock("$folderdir/.address.book", LOCK_UN);

      writelog("import addressbook");
      writehistory("import addressbook");

#      print "Location: $config{'ow_cgiurl'}/openwebmail-prefs.pl?action=editaddresses&sessionid=$thissession&sort=$sort&folder=$escapedfolder&firstmessage=$firstmessage&message_id=$escapedmessageid\n\n";
      editaddresses();

   } else {

      my $abooksize = ( -s "$folderdir/.address.book" ) || 0;
      my $freespace = int($config{'maxbooksize'} - ($abooksize/1024) + .5);

      my $html = '';
      my $temphtml;

      open (IMPORTTEMPLATE, "$config{'ow_etcdir'}/templates/$prefs{'language'}/importabook.template") or
         openwebmailerror("$lang_err{'couldnt_open'} $config{'ow_etcdir'}/templates/$prefs{'language'}/importabook.template");
      while (<IMPORTTEMPLATE>) {
         $html .= $_;
      }
      close (IMPORTTEMPLATE);

      $html = applystyle($html);

      printheader();

      $html =~ s/\@\@\@FREESPACE\@\@\@/$freespace/g;

      $temphtml = start_multipart_form();
      $temphtml .= hidden(-name=>'action',
                          -value=>'importabook',
                          -override=>'1') .
                   hidden(-name=>'sessionid',
                          -value=>$thissession,
                          -override=>'1') .
                   hidden(-name=>'sort',
                          -default=>$sort,
                          -override=>'1') .
                   hidden(-name=>'firstmessage',
                          -default=>$firstmessage,
                          -override=>'1') .
                   hidden(-name=>'folder',
                          -default=>$folder,
                          -override=>'1');
                   hidden(-name=>'message_id',
                          -default=>$messageid,
                          -override=>'1');
      $html =~ s/\@\@\@STARTIMPORTFORM\@\@\@/$temphtml/;


      my %mualabels =(outlookexp5 => 'Outlook Express 5',
                      nsmail      => 'Netscape Mail 4.x');
      $temphtml = radio_group(-name=>'mua',
                              -"values"=>['outlookexp5','nsmail'],
                              -default=>'outlookexp5',
                              -labels=>\%mualabels);
      $html =~ s/\@\@\@MUARADIOGROUP\@\@\@/$temphtml/;

      $temphtml = filefield(-name=>'abook',
                            -default=>'',
                            -size=>'30',
                            -override=>'1');
      $html =~ s/\@\@\@IMPORTFILEFIELD\@\@\@/$temphtml/;

      $temphtml = submit("$lang_text{'import'}");
      $html =~ s/\@\@\@IMPORTBUTTON\@\@\@/$temphtml/;

      $temphtml = end_form();
      $html =~ s/\@\@\@ENDFORM\@\@\@/$temphtml/g;

      $temphtml = start_form(-action=>"$config{'ow_cgiurl'}/openwebmail-prefs.pl") .
                  hidden(-name=>'action',
                         -value=>'editaddresses',
                         -override=>'1') .
                  hidden(-name=>'sessionid',
                         -value=>$thissession,
                         -override=>'1') .
                  hidden(-name=>'sort',
                         -default=>$sort,
                         -override=>'1') .
                  hidden(-name=>'folder',
                         -default=>$folder,
                         -override=>'1') .
                  hidden(-name=>'firstmessage',
                         -default=>$firstmessage,
                         -override=>'1');
                  hidden(-name=>'message_id',
                         -default=>$messageid,
                         -override=>'1') .
      $html =~ s/\@\@\@STARTCANCELFORM\@\@\@/$temphtml/;


      $temphtml = submit("$lang_text{'cancel'}");
      $html =~ s/\@\@\@CANCELBUTTON\@\@\@/$temphtml/;

      print $html;

      printfooter();
   }
}
#################### END IMPORTABOOK #########################

##################### EXPORTABOOK ############################
sub exportabook {
   filelock("$folderdir/.address.book", LOCK_EX|LOCK_NB) or
      openwebmailerror("$lang_err{'couldnt_lock'} $folderdir/.address.book!");
   open (ABOOK,"$folderdir/.address.book") or
      openwebmailerror("$lang_err{'couldnt_open'} $folderdir/.address.book!");

   # disposition:attachment default to save
   print qq|Content-Transfer-Coding: binary\n|,
         qq|Connection: close\n|,
         qq|Content-Type: text/plain; name="adbook.csv"\n|;

   # ugly hack since ie5.5 is broken with disposition: attchment
   if ( $ENV{'HTTP_USER_AGENT'}!~/MSIE 5.5/ ) {
      print qq|Content-Disposition: attachment; filename="adbook.csv"\n|,
   }
   print qq|\n|;

   print qq|Name,E-mail Address,Note\n|;

   while (<ABOOK>) {
      print join(",", split(/\@\@\@/,$_,3));
   }

   close(ABOOK);
   filelock("$folderdir/.address.book", LOCK_UN);

   writelog("export addressbook");
   writehistory("export addressbook");

   return;
}
#################### END EXPORTABOOK #########################

#################### EDITADDRESSES ###########################
sub editaddresses {
   my %addresses=();
   my %notes=();
   my %globaladdresses=();
   my %globalnotes=();
   my ($name, $email, $note);

   my $html = '';
   my $temphtml;

   open (EDITABOOKTEMPLATE, "$config{'ow_etcdir'}/templates/$prefs{'language'}/editaddresses.template") or
      openwebmailerror("$lang_err{'couldnt_open'} $config{'ow_etcdir'}/templates/$prefs{'language'}/editaddresses.template");
   while (<EDITABOOKTEMPLATE>) {
      $html .= $_;
   }
   close (EDITABOOKTEMPLATE);

   $html = applystyle($html);

   if ( -f "$folderdir/.address.book" ) {
      open (ABOOK,"$folderdir/.address.book") or
         openwebmailerror("$lang_err{'couldnt_open'} $folderdir/.address.book!");
      while (<ABOOK>) {
         ($name, $email, $note) = split(/\@\@\@/, $_, 3);
         chomp($email); chomp($note);
         $addresses{"$name"} = $email;
         $notes{"$name"}=$note;
      }
      close (ABOOK) or openwebmailerror("$lang_err{'couldnt_close'} $folderdir/.address.book!");
   }
   my $abooksize = ( -s "$folderdir/.address.book" ) || 0;
   my $freespace = int($config{'maxbooksize'} - ($abooksize/1024) + .5);

   if ( $config{'global_addressbook'} ne "" && -f "$config{'global_addressbook'}" ) {
      if (open (ABOOK,"$config{'global_addressbook'}") ) {
         while (<ABOOK>) {
            ($name, $email, $note) = split(/\@\@\@/, $_, 3);
            chomp($email);
            $globaladdresses{"$name"} = $email;
            $globalnotes{"$name"} = $note;
         }
         close (ABOOK);
      }
   }

   printheader();

   $html =~ s/\@\@\@FREESPACE\@\@\@/$freespace/g;

   if ( param("message_id") ) {
      $temphtml = "<a href=\"$config{'ow_cgiurl'}/openwebmail-main.pl?action=readmessage&amp;sessionid=$thissession&amp;sort=$sort&amp;firstmessage=$firstmessage&amp;folder=$folder&amp;message_id=$escapedmessageid\"><IMG SRC=\"$config{'ow_htmlurl'}/images/iconsets/$prefs{'iconset'}/backtofolder.gif\" border=\"0\" ALT=\"$lang_text{'backto'} $printfolder\"></a> &nbsp; &nbsp; ";
   } else {
      $temphtml = "<a href=\"$config{'ow_cgiurl'}/openwebmail-main.pl?action=displayheaders&amp;sessionid=$thissession&amp;sort=$sort&amp;firstmessage=$firstmessage&amp;folder=$folder\"><IMG SRC=\"$config{'ow_htmlurl'}/images/iconsets/$prefs{'iconset'}/backtofolder.gif\" border=\"0\" ALT=\"$lang_text{'backto'} $printfolder\"></a> &nbsp; &nbsp; ";
   }
   $temphtml .= "<a href=\"$config{'ow_cgiurl'}/openwebmail-prefs.pl?action=importabook&amp;sessionid=$thissession&amp;sort=$sort&amp;firstmessage=$firstmessage&amp;folder=$folder&amp;message_id=$escapedmessageid\"><IMG SRC=\"$config{'ow_htmlurl'}/images/iconsets/$prefs{'iconset'}/import.gif\" border=\"0\" ALT=\"$lang_text{'importadd'}\"></a>&nbsp;";
   $temphtml .= "<a href=\"$config{'ow_cgiurl'}/openwebmail-prefs.pl?action=exportabook&amp;sessionid=$thissession&amp;sort=$sort&amp;firstmessage=$firstmessage&amp;folder=$folder&amp;message_id=$escapedmessageid\"><IMG SRC=\"$config{'ow_htmlurl'}/images/iconsets/$prefs{'iconset'}/export.gif\" border=\"0\" ALT=\"$lang_text{'exportadd'}\"></a>&nbsp;";
   $temphtml .= "<a href=\"$config{'ow_cgiurl'}/openwebmail-prefs.pl?action=clearaddress&amp;sessionid=$thissession&amp;sort=$sort&amp;firstmessage=$firstmessage&amp;folder=$folder&amp;message_id=$escapedmessageid\" onclick=\"return confirm('$lang_text{'clearadd'}?')\"><IMG SRC=\"$config{'ow_htmlurl'}/images/iconsets/$prefs{'iconset'}/clearaddress.gif\" border=\"0\" ALT=\"$lang_text{'clearadd'}\"></a>";

   $html =~ s/\@\@\@MENUBARLINKS\@\@\@/$temphtml/g;

   $temphtml = startform(-action=>"$config{'ow_cgiurl'}/openwebmail-prefs.pl",
                         -name=>'newaddress') .
               hidden(-name=>'action',
                      -value=>'addaddress',
                      -override=>'1') .
               hidden(-name=>'sessionid',
                      -value=>$thissession,
                      -override=>'1') .
               hidden(-name=>'sort',
                      -default=>$sort,
                      -override=>'1') .
               hidden(-name=>'firstmessage',
                      -default=>$firstmessage,
                      -override=>'1') .
               hidden(-name=>'folder',
                      -default=>$folder,
                      -override=>'1');
               hidden(-name=>'message_id',
                      -default=>$messageid,
                      -override=>'1');

   $html =~ s/\@\@\@STARTADDRESSFORM\@\@\@/$temphtml/;

   $temphtml = textfield(-name=>'realname',
                         -default=>'',
                         -size=>'20',
                         -override=>'1');

   $html =~ s/\@\@\@REALNAMEFIELD\@\@\@/$temphtml/;

   $temphtml = textfield(-name=>'email',
                         -default=>'',
                         -size=>'30',
                         -override=>'1');
   $temphtml .= "<a href=\"Javascript:GoAddressWindow('email')\"><IMG SRC=\"$config{'ow_htmlurl'}/images/iconsets/$prefs{'iconset'}/group.gif\" border=\"0\" ALT=\"$lang_text{'group'}\"></a>";

   $html =~ s/\@\@\@EMAILFIELD\@\@\@/$temphtml/;

   $temphtml = textfield(-name=>'note',
                         -default=>'',
                         -size=>'25',
                         -override=>'1');
   $html =~ s/\@\@\@NOTEFIELD\@\@\@/$temphtml/;

   $temphtml = submit(-name=>"$lang_text{'addmod'}",
                      -class=>"medtext");
   $html =~ s/\@\@\@ADDBUTTON\@\@\@/$temphtml/;

   $temphtml = end_form();
   $html =~ s/\@\@\@ENDFORM\@\@\@/$temphtml/;

   $temphtml = '';
   my $bgcolor = $style{"tablerow_dark"};

   foreach my $key (sort { uc($a) cmp uc($b) } (keys %addresses)) {
      my ($namestr, $emailstr, $notestr)=($key, $addresses{$key}, $notes{$key});
      $namestr=substr($namestr, 0, 25)."..." if (length($namestr)>30);
      $emailstr=substr($emailstr, 0, 35)."..." if (length($emailstr)>40);
      $temphtml .= qq|<tr>|.
                   qq|<td bgcolor=$bgcolor width="150"><a href="Javascript:Update('$key','$addresses{$key}','$notes{$key}')">$namestr</a></td>|.
                   qq|<td bgcolor=$bgcolor width="250"><a href="$config{'ow_cgiurl'}/openwebmail-main.pl?action=composemessage&amp;firstmessage=$firstmessage&amp;sort=$sort&amp;folder=$escapedfolder&amp;sessionid=$thissession&amp;composetype=sendto&amp;to=$addresses{$key}">$emailstr</a></td>|.
                   qq|<td bgcolor=$bgcolor width="150">$notestr</td>|;

      $temphtml .= start_form(-action=>"$config{'ow_cgiurl'}/openwebmail-prefs.pl");
      $temphtml .= hidden(-name=>'action',
                          -value=>'deleteaddress',
                          -override=>'1');
      $temphtml .= hidden(-name=>'sessionid',
                          -value=>$thissession,
                          -override=>'1');
      $temphtml .= hidden(-name=>'sort',
                          -default=>$sort,
                          -override=>'1');
      $temphtml .= hidden(-name=>'firstmessage',
                          -default=>$firstmessage,
                          -override=>'1');
      $temphtml .= hidden(-name=>'folder',
                          -default=>$folder,
                          -override=>'1');
      $temphtml .= hidden(-name=>'message_id',
                          -default=>$messageid,
                          -override=>'1');
      $temphtml .= hidden(-name=>'realname',
                          -value=>$key,
                          -override=>'1');
      $temphtml .= "<td bgcolor=$bgcolor align=\"center\" width=\"80\">";
      $temphtml .= submit(-name=>"$lang_text{'delete'}",
                          -class=>"medtext");
      $temphtml .= '</td></tr>';
      $temphtml .= end_form();
      if ($bgcolor eq $style{"tablerow_dark"}) {
         $bgcolor = $style{"tablerow_light"};
      } else {
         $bgcolor = $style{"tablerow_dark"};
      }
   }

   my @sortkeys=sort { uc($a) cmp uc($b) } (keys %globaladdresses);
   if ($#sortkeys >= 0) {
      $temphtml .= "<tr><td colspan=\"4\">&nbsp;</td></tr>\n";
      $temphtml .= "<tr><td colspan=\"4\" bgcolor=$style{columnheader}><B>$lang_text{globaladdressbook}</B> ($lang_text{readonly})</td></tr>\n";
   }
   $bgcolor = $style{"tablerow_dark"};
   foreach my $key (@sortkeys) {
      my ($namestr, $emailstr, $notestr)=($key, $globaladdresses{$key}, $globalnotes{$key});
      $namestr=substr($namestr, 0, 25)."..." if (length($namestr)>30);
      $emailstr=substr($emailstr, 0, 35)."..." if (length($emailstr)>40);
      $temphtml .= qq|<tr>|.
                   qq|<td bgcolor=$bgcolor width="150"><a href="Javascript:Update('$key','$globaladdresses{$key}','$globalnotes{$key}')">$namestr</a></td>|.
                   qq|<td bgcolor=$bgcolor width="250"><a href="$config{'ow_cgiurl'}/openwebmail-main.pl?action=composemessage&amp;firstmessage=$firstmessage&amp;sort=$sort&amp;folder=$escapedfolder&amp;sessionid=$thissession&amp;composetype=sendto&amp;to=$globaladdresses{$key}">$emailstr</a></td>|.
                   qq|<td bgcolor=$bgcolor width="150">$notestr</td>|;

      $temphtml .= "<td bgcolor=$bgcolor align=\"center\" width=\"80\">";
      $temphtml .= "-----";
      $temphtml .= '</td></tr>';

      if ($bgcolor eq $style{"tablerow_dark"}) {
         $bgcolor = $style{"tablerow_light"};
      } else {
         $bgcolor = $style{"tablerow_dark"};
      }
   }

   $html =~ s/\@\@\@ADDRESSES\@\@\@/$temphtml/;

   $html =~ s/\@\@\@SESSIONID\@\@\@/$thissession/g;

   print $html;

   printfooter();
}
################### END EDITADDRESSES ########################

################### MODADDRESS ##############################
sub modaddress {
   my $mode = shift;
   my ($realname, $address, $ussrnote);
   $realname = param("realname") || '';
   $address = param("email") || '';
   $usernote = param("note") || '';
   $realname =~ s/://;
   $realname =~ s/^\s*//; # strip beginning and trailing spaces from hash key
   $realname =~ s/\s*$//;
   $address =~ s/[#&=\?]//g;
   $usernote =~ s/^\s*//; # strip beginning and trailing spaces
   $usernote =~ s/\s*$//;

   if (($realname && $address) || (($mode eq 'delete') && $realname) ) {
      my %addresses;
      my %notes;
      my ($name,$email,$note);
      if ( -f "$folderdir/.address.book" ) {
         my $abooksize = ( -s "$folderdir/.address.book" );
         if ( (($abooksize + length($realname) + length($address) + 2) >= ($config{'maxbooksize'} * 1024) ) && ($mode ne "delete") ) {
            openwebmailerror("$lang_err{'abook_toobig'} <a href=\"$config{'ow_cgiurl'}/openwebmail-prefs.pl?action=editaddresses&amp;sessionid=$thissession&amp;sort=$sort&amp;folder=$escapedfolder&amp;firstmessage=$firstmessage&amp;message_id=$escapedmessageid\">$lang_err{'back'}</a>
                          $lang_err{'tryagain'}");
         }
         filelock("$folderdir/.address.book", LOCK_EX|LOCK_NB) or
            openwebmailerror("$lang_err{'couldnt_lock'} $folderdir/.address.book!");
         open (ABOOK,"+<$folderdir/.address.book") or
            openwebmailerror("$lang_err{'couldnt_open'} $folderdir/.address.book!");
         while (<ABOOK>) {
            ($name, $email, $note) = split(/\@\@\@/, $_, 3);
            chomp($email); chomp($note);
            $addresses{"$name"} = $email;
            $notes{"$name"} = $note;
         }
         if ($mode eq 'delete') {
            delete $addresses{"$realname"};
         } else {
            $addresses{"$realname"} = $address;
            if ($usernote ne '') { # overwrite old note only if new one is not null
               $notes{"$realname"} = $usernote;
            }
         }
         seek (ABOOK, 0, 0) or
            openwebmailerror("$lang_err{'couldnt_seek'} $folderdir/.address.book!");

         foreach my $key (sort { uc($a) cmp uc($b) } (keys %addresses)) {
            print ABOOK "$key\@\@\@$addresses{$key}\@\@\@$notes{$key}\n";
         }
         truncate(ABOOK, tell(ABOOK));
         close (ABOOK) or openwebmailerror("$lang_err{'couldnt_close'} $folderdir/.address.book!");
         filelock("$folderdir/.address.book", LOCK_UN);
      } else {
         open (ABOOK, ">$folderdir/.address.book" ) or
            openwebmailerror("$lang_err{'couldnt_open'} $folderdir/.address.book!");
         print ABOOK "$realname\@\@\@$address\@\@\@$usernote\n";
         close (ABOOK) or openwebmailerror("$lang_err{'couldnt_close'} $folderdir/.address.book!");
      }
   }

#   print "Location: $config{'ow_cgiurl'}/openwebmail-prefs.pl?action=editaddresses&sessionid=$thissession&sort=$sort&folder=$escapedfolder&firstmessage=$firstmessage&amp;message_id=$escapedmessageid\n\n";
   editaddresses();
}
################## END MODADDRESS ###########################

################## CLEARADDRESS ###########################
sub clearaddress {
   if ( -f "$folderdir/.address.book" ) {
      open (ABOOK, ">$folderdir/.address.book") or
         openwebmailerror ("$lang_err{'couldnt_open'} $folderdir/.address.book!");
      close (ABOOK) or openwebmailerror("$lang_err{'couldnt_close'} $folderdir/.address.book!");
   }

   writelog("clear addressbook");
   writehistory("clear addressbook");

#   print "Location: $config{'ow_cgiurl'}/openwebmail-prefs.pl?action=editaddresses&sessionid=$thissession&sort=$sort&folder=$escapedfolder&firstmessage=$firstmessage&amp;message_id=$escapedmessageid\n\n";
   editaddresses();
}
################## END CLEARADDRESS ###########################

#################### EDITFROMS ###########################
sub editfroms {
   my $html = '';
   my $temphtml;

   open (EDITFROMBOOKTEMPLATE, "$config{'ow_etcdir'}/templates/$prefs{'language'}/editfroms.template") or
      openwebmailerror("$lang_err{'couldnt_open'} $config{'ow_etcdir'}/templates/$prefs{'language'}/editfroms.template");
   while (<EDITFROMBOOKTEMPLATE>) {
      $html .= $_;
   }
   close (EDITFROMBOOKTEMPLATE);

   $html = applystyle($html);

   my $frombooksize = ( -s "$folderdir/.from.book" ) || 0;
   my $freespace = int($config{'maxbooksize'} - ($frombooksize/1024) + .5);
   my %from=get_userfrom($virtualuser, $user, $userrealname, "$folderdir/.from.book");

   printheader();

   $html =~ s/\@\@\@FREESPACE\@\@\@/$freespace/g;

   $temphtml = startform(-action=>"$config{'ow_cgiurl'}/openwebmail-prefs.pl",
                         -name=>'newfrom') .
               hidden(-name=>'action',
                      -value=>'addfrom',
                      -override=>'1') .
               hidden(-name=>'sessionid',
                      -value=>$thissession,
                      -override=>'1') .
               hidden(-name=>'sort',
                      -default=>$sort,
                      -override=>'1') .
               hidden(-name=>'firstmessage',
                      -default=>$firstmessage,
                      -override=>'1') .
               hidden(-name=>'folder',
                      -default=>$folder,
                      -override=>'1');
               hidden(-name=>'message_id',
                      -default=>$messageid,
                      -override=>'1');
   $html =~ s/\@\@\@STARTFROMFORM\@\@\@/$temphtml/;

   $temphtml = textfield(-name=>'realname',
                         -default=>'',
                         -size=>'20',
                         -override=>'1');
   $html =~ s/\@\@\@REALNAMEFIELD\@\@\@/$temphtml/;

   $temphtml = textfield(-name=>'email',
                         -default=>'',
                         -size=>'30',
                         -override=>'1');

   $html =~ s/\@\@\@EMAILFIELD\@\@\@/$temphtml/;

   if ($config{'enable_setfromemail'}) {
      $temphtml = submit(-name=>"$lang_text{'addmod'}",
                         -class=>"medtext");
   } else {
      $temphtml = submit(-name=>"$lang_text{'modify'}",
                         -class=>"medtext");
   }

   $html =~ s/\@\@\@ADDBUTTON\@\@\@/$temphtml/;

   $temphtml = end_form();
   $html =~ s/\@\@\@ENDFORM\@\@\@/$temphtml/;


   my $bgcolor = $style{"tablerow_dark"};
   my ($email, $realname);

   $temphtml = '';
   foreach $email (sort { uc($a) cmp uc($b) } (keys %from)) {
      $realname=$from{$email};

      $temphtml .= qq|<tr>|.
                   qq|<td bgcolor=$bgcolor>$realname</td>|.
                   qq|<td bgcolor=$bgcolor><a href="Javascript:Update('$realname','$email')">$email</a></td>|;
                   qq|</tr>|;

      $temphtml .= start_form(-action=>"$config{'ow_cgiurl'}/openwebmail-prefs.pl");
      $temphtml .= hidden(-name=>'action',
                          -value=>'deletefrom',
                          -override=>'1');
      $temphtml .= hidden(-name=>'sessionid',
                          -value=>$thissession,
                          -override=>'1');
      $temphtml .= hidden(-name=>'sort',
                          -default=>$sort,
                          -override=>'1');
      $temphtml .= hidden(-name=>'firstmessage',
                          -default=>$firstmessage,
                          -override=>'1');
      $temphtml .= hidden(-name=>'folder',
                          -default=>$folder,
                          -override=>'1');
      $temphtml .= hidden(-name=>'message_id',
                          -default=>$messageid,
                          -override=>'1');
      $temphtml .= hidden(-name=>'email',
                          -value=>$email,
                          -override=>'1');
      $temphtml .= "<td bgcolor=$bgcolor align=\"center\" width=\"80\">";
      $temphtml .= submit(-name=>"$lang_text{'delete'}",
                          -class=>"medtext");
      $temphtml .= '</td></tr>';
      $temphtml .= end_form();
      if ($bgcolor eq $style{"tablerow_dark"}) {
         $bgcolor = $style{"tablerow_light"};
      } else {
         $bgcolor = $style{"tablerow_dark"};
      }
   }

   $html =~ s/\@\@\@FROMS\@\@\@/$temphtml/;

   $temphtml = startform(-action=>"$config{'ow_cgiurl'}/openwebmail-prefs.pl") .
               hidden(-name=>'sessionid',
                      -default=>$thissession,
                      -override=>'1') .
               hidden(-name=>'sort',
                      -default=>$sort,
                      -override=>'1') .
               hidden(-name=>'firstmessage',
                      -default=>$firstmessage,
                      -override=>'1') .
               hidden(-name=>'folder',
                      -default=>$folder,
                      -override=>'1') .
               submit("$lang_text{'backto'} $lang_text{'userprefs'}") .
               end_form();
   $html =~ s/\@\@\@CONTINUEBUTTON\@\@\@/$temphtml/;

   print $html;

   printfooter();
}
################### END EDITFROMS ########################

################### MODFROM ##############################
sub modfrom {
   my $mode = shift;
   my $realname = param("realname") || '';
   my $email = param("email") || '';

   $realname =~ s/://;
   $realname =~ s/^\s*//; # strip beginning and trailing spaces from hash key
   $realname =~ s/\s*$//;
   $email =~ s/[#&=\?]//g;

   if (($realname && $email) || (($mode eq 'delete') && $email) ) {
      my %from=get_userfrom($virtualuser, $user, $userrealname, "$folderdir/.from.book");
      my $frombooksize = ( -s "$folderdir/.from.book" ) || 0;
      if ( (($frombooksize + length($realname) + length($email) + 2) >= ($config{'maxbooksize'} * 1024) ) && ($mode ne "delete") ) {
         openwebmailerror("$lang_err{'abook_toobig'} <a href=\"$config{'ow_cgiurl'}/openwebmail-prefs.pl?action=editfroms&amp;sessionid=$thissession&amp;sort=$sort&amp;folder=$escapedfolder&amp;firstmessage=$firstmessage&amp;message_id=$escapedmessageid\">$lang_err{'back'}</a>
                          $lang_err{'tryagain'}");
      }

      if ($mode eq 'delete') {
         delete $from{$email};
      } else {
         if (defined($from{$email}) || $config{'enable_setfromemail'}) {
            $from{$email} = $realname;
         }
      }

      open (FROMBOOK, ">$folderdir/.from.book" ) or
         openwebmailerror("$lang_err{'couldnt_open'} $folderdir/.from.book!");
      foreach $email (sort { uc($a) cmp uc($b) } (keys %from)) {
         print FROMBOOK "$email\@\@\@$from{$email}\n";
      }
      close (FROMBOOK) or openwebmailerror("$lang_err{'couldnt_close'} $folderdir/.from.book!");
   }

#   print "Location: $config{'ow_cgiurl'}/openwebmail-prefs.pl?action=editfroms&sessionid=$thissession&sort=$sort&folder=$escapedfolder&firstmessage=$firstmessage&amp;message_id=$escapedmessageid\n\n";
   editfroms();
}
################## END MODFROM ###########################

#################### EDITPOP3 ###########################
sub editpop3 {
   my $html = '';
   my $temphtml;

   open (EDITPOP3BOOKTEMPLATE, "$config{'ow_etcdir'}/templates/$prefs{'language'}/editpop3.template") or
      openwebmailerror("$lang_err{'couldnt_open'} $config{'ow_etcdir'}/templates/$prefs{'language'}/editpop3.template");
   while (<EDITPOP3BOOKTEMPLATE>) {
      $html .= $_;
   }
   close (EDITPOP3BOOKTEMPLATE);

   $html = applystyle($html);

   my %accounts;
   my $pop3booksize = ( -s "$folderdir/.pop3.book" ) || 0;
   my $freespace = int($config{'maxbooksize'} - ($pop3booksize/1024) + .5);

   if (getpop3book("$folderdir/.pop3.book", \%accounts) <0) {
      openwebmailerror("$lang_err{'couldnt_open'} $folderdir/.pop3.book!");
   }

   printheader();

   $html =~ s/\@\@\@FREESPACE\@\@\@/$freespace/g;

   if ( param("message_id") ) {
      $temphtml = "<a href=\"$config{'ow_cgiurl'}/openwebmail-main.pl?action=readmessage&amp;sessionid=$thissession&amp;sort=$sort&amp;firstmessage=$firstmessage&amp;folder=$folder&amp;message_id=$escapedmessageid\"><IMG SRC=\"$config{'ow_htmlurl'}/images/iconsets/$prefs{'iconset'}/backtofolder.gif\" border=\"0\" ALT=\"$lang_text{'backto'} $printfolder\"></a> &nbsp; &nbsp; ";
   } else {
      $temphtml = "<a href=\"$config{'ow_cgiurl'}/openwebmail-main.pl?action=displayheaders&amp;sessionid=$thissession&amp;sort=$sort&amp;firstmessage=$firstmessage&amp;folder=$folder\"><IMG SRC=\"$config{'ow_htmlurl'}/images/iconsets/$prefs{'iconset'}/backtofolder.gif\" border=\"0\" ALT=\"$lang_text{'backto'} $printfolder\"></a> &nbsp; &nbsp; ";
   }
   $temphtml .= "<a href=\"$config{'ow_cgiurl'}/openwebmail-main.pl?action=retrpop3s&amp;sessionid=$thissession&amp;sort=$sort&amp;firstmessage=$firstmessage&amp;folder=$folder&amp;message_id=$escapedmessageid\"><IMG SRC=\"$config{'ow_htmlurl'}/images/iconsets/$prefs{'iconset'}/pop3.gif\" border=\"0\" ALT=\"$lang_text{'retr_pop3s'}\"></a>";

   $html =~ s/\@\@\@MENUBARLINKS\@\@\@/$temphtml/g;

   $temphtml = startform(-action=>"$config{'ow_cgiurl'}/openwebmail-prefs.pl",
                         -name=>'newpop3') .
               hidden(-name=>'action',
                      -value=>'addpop3',
                      -override=>'1') .
               hidden(-name=>'sessionid',
                      -value=>$thissession,
                      -override=>'1') .
               hidden(-name=>'sort',
                      -default=>$sort,
                      -override=>'1') .
               hidden(-name=>'firstmessage',
                      -default=>$firstmessage,
                      -override=>'1') .
               hidden(-name=>'folder',
                      -default=>$folder,
                      -override=>'1');
               hidden(-name=>'message_id',
                      -default=>$messageid,
                      -override=>'1');

   $html =~ s/\@\@\@STARTPOP3FORM\@\@\@/$temphtml/;

   $temphtml = textfield(-name=>'pop3host',
                         -default=>'',
                         -size=>'25',
                         -override=>'1');

   $html =~ s/\@\@\@HOSTFIELD\@\@\@/$temphtml/;

   $temphtml = textfield(-name=>'pop3user',
                         -default=>'',
                         -size=>'16',
                         -override=>'1');

   $html =~ s/\@\@\@REALNAMEFIELD\@\@\@/$temphtml/;

   $temphtml = password_field(-name=>'pop3pass',
                         -default=>'',
                         -size=>'8',
                         -override=>'1');

   $html =~ s/\@\@\@PASSFIELD\@\@\@/$temphtml/;

   $temphtml = checkbox(-name=>'pop3del',
                  -value=>'1',
                  -label=>'');

   $html =~ s/\@\@\@DELCHECKBOX\@\@\@/$temphtml/;

   $temphtml = checkbox(-name=>'enable',
                  -value=>'1',
                  -label=>'');

   $html =~ s/\@\@\@ENABLECHECKBOX\@\@\@/$temphtml/;

   $temphtml = submit(-name=>"$lang_text{'addmod'}",
                      -class=>"medtext");
   $html =~ s/\@\@\@ADDBUTTON\@\@\@/$temphtml/;

   $temphtml = end_form();
   $html =~ s/\@\@\@ENDFORM\@\@\@/$temphtml/;

   $temphtml = '';
   my $bgcolor = $style{"tablerow_dark"};
   foreach (sort values %accounts) {
      my ($pop3host, $pop3user, $pop3pass, $pop3lastid, $pop3del, $enable) = split(/\@\@\@/, $_);

      $temphtml .= qq|<tr>\n|.
      		   qq|<td bgcolor=$bgcolor><a href="Javascript:Update('$pop3host','$pop3user','$pop3pass','$pop3del','$enable')">$pop3host</a></td>\n|.
                   qq|<td align="center" bgcolor=$bgcolor><a href="$config{'ow_cgiurl'}/openwebmail-main.pl?action=retrpop3&pop3user=$pop3user&pop3host=$pop3host&amp;firstmessage=$firstmessage&amp;sort=$sort&amp;folder=$escapedfolder&amp;sessionid=$thissession&">$pop3user</a></td>\n|.
                   qq|<td align="center" bgcolor=$bgcolor>\*\*\*\*\*\*</td>\n|.
                   qq|<td align="center" bgcolor=$bgcolor>\n|;

      if ( $pop3del == 1) {
      	 $temphtml .= $lang_text{'delete'};
      }
      else {
      	 $temphtml .= $lang_text{'reserve'};
      }
      $temphtml .= qq|</td><td align="center" bgcolor=$bgcolor>\n|;
      if ( $enable == 1) {
      	 $temphtml .= $lang_text{'enable'};
      }
      else {
      	 $temphtml .= $lang_text{'disable'};
      }
      $temphtml .= "</td>";

      $temphtml .= start_form(-action=>"$config{'ow_cgiurl'}/openwebmail-prefs.pl");
      $temphtml .= hidden(-name=>'action',
                          -value=>'deletepop3',
                          -override=>'1');
      $temphtml .= hidden(-name=>'sessionid',
                          -value=>$thissession,
                          -override=>'1');
      $temphtml .= hidden(-name=>'sort',
                          -default=>$sort,
                          -override=>'1');
      $temphtml .= hidden(-name=>'firstmessage',
                          -default=>$firstmessage,
                          -override=>'1');
      $temphtml .= hidden(-name=>'folder',
                          -default=>$folder,
                          -override=>'1');
      $temphtml .= hidden(-name=>'message_id',
                          -default=>$messageid,
                          -override=>'1');
      $temphtml .= hidden(-name=>'pop3user',
                          -value=>$pop3user,
                          -override=>'1');
      $temphtml .= hidden(-name=>'pop3host',
                          -value=>$pop3host,
                          -override=>'1');
      $temphtml .= "<td bgcolor=$bgcolor align=\"center\" width=\"100\">";
      $temphtml .= submit(-name=>"$lang_text{'delete'}",
                          -class=>"medtext");
      $temphtml .= '</td></tr>';
      $temphtml .= end_form();
      if ($bgcolor eq $style{"tablerow_dark"}) {
         $bgcolor = $style{"tablerow_light"};
      } else {
         $bgcolor = $style{"tablerow_dark"};
      }
   }

   $html =~ s/\@\@\@ADDRESSES\@\@\@/$temphtml/;
   print $html;

   printfooter();
}
################### END EDITPOP3 ########################

################### MODPOP3 ##############################
sub modpop3 {
   my $mode = shift;
   my ($pop3host, $pop3user, $pop3pass, $pop3lastid, $pop3del, $enable);
   $pop3host = param("pop3host") || '';
   $pop3user = param("pop3user") || '';
   $pop3pass = param("pop3pass") || '';
   $pop3lastid = "none";
   $pop3del = param("pop3del") || 0;
   $enable = param("enable") || 0;
   
   # strip beginning and trailing spaces from hash key
   $pop3host =~ s/://;
   $pop3host =~ s/^\s*//; 
   $pop3host =~ s/\s*$//;
   $pop3host =~ s/[#&=\?]//g;
   
   $pop3user =~ s/://;
   $pop3user =~ s/^\s*//; 
   $pop3user =~ s/\s*$//;
   $pop3user =~ s/[#&=\?]//g;
   
   $pop3pass =~ s/://;
   $pop3pass =~ s/^\s*//; 
   $pop3pass =~ s/\s*$//;

   if ( ($pop3host && $pop3user && $pop3pass) 
     || (($mode eq 'delete') && $pop3host && $pop3user) ) {
      my %accounts;
      
      if ( -f "$folderdir/.pop3.book" ) {
         my $pop3booksize = ( -s "$folderdir/.pop3.book" );
         if ( (($pop3booksize + length("$pop3host\@\@\@$pop3user\@\@\@$pop3pass\@\@\@$pop3lastid\@\@\@$pop3del\@\@\@$enable")) >= ($config{'maxbooksize'} * 1024) ) && ($mode ne "delete") ) {
            openwebmailerror("$lang_err{'abook_toobig'} <a href=\"$config{'ow_cgiurl'}/openwebmail-prefs.pl?action=editpop3&amp;sessionid=$thissession&amp;sort=$sort&amp;folder=$escapedfolder&amp;firstmessage=$firstmessage&amp;message_id=$escapedmessageid\">$lang_err{'back'}</a> $lang_err{'tryagain'}");
         }
         if (getpop3book("$folderdir/.pop3.book", \%accounts) <0) {
            openwebmailerror("$lang_err{'couldnt_open'} $folderdir/.pop3.book!");
         }
         if ($mode eq 'delete') {
            delete $accounts{"$pop3host:$pop3user"};
         } else {
            foreach ( @{$config{'disallowed_pop3servers'}} ) {
               if ($pop3host eq $_) {
                  openwebmailerror("$lang_err{'disallowed_pop3'} $pop3host");
               }
            }
            $accounts{"$pop3host:$pop3user"}="$pop3host\@\@\@$pop3user\@\@\@$pop3pass\@\@\@$pop3lastid\@\@\@$pop3del\@\@\@$enable";
         }

         writebackpop3book("$folderdir/.pop3.book", \%accounts);

      } else {
         foreach ( @{$config{'disallowed_pop3servers'}} ) {
            if ($pop3host eq $_) {
               openwebmailerror("$lang_err{'disallowed_pop3'} $pop3host");
            }
         }
         open (POP3BOOK, ">$folderdir/.pop3.book" ) or
            openwebmailerror("$lang_err{'couldnt_open'} $folderdir/.pop3.book!");
         print POP3BOOK "$pop3host\@\@\@$pop3user\@\@\@$pop3pass\@\@\@$pop3lastid\@\@\@$pop3del\@\@\@$enable\n";
         close (POP3BOOK) or openwebmailerror("$lang_err{'couldnt_close'} $folderdir/.pop3.book!");
      }
   }

#   print "Location: $config{'ow_cgiurl'}/openwebmail-prefs.pl?action=editpop3&sessionid=$thissession&sort=$sort&folder=$escapedfolder&firstmessage=$firstmessage&amp;message_id=$escapedmessageid\n\n";
   editpop3();
}
################## END MODPOP3 ###########################

#################### EDITFILTER ###########################
sub editfilter {
   my $html = '';
   my $temphtml;
   my @filterrules=();
   my @globalfilterrules=();

   printheader();

   open (EDITFILTERTEMPLATE, "$config{'ow_etcdir'}/templates/$prefs{'language'}/editfilter.template") or
       openwebmailerror("$lang_err{'couldnt_open'} $config{'ow_etcdir'}/templates/$prefs{'language'}/editfilter.template");
   while (<EDITFILTERTEMPLATE>) {
       $html .= $_;
   }
   close (EDITFILTERTEMPLATE);

   $html = applystyle($html);
   
   ## replace @@@FREESPACE@@@ ##
   my $filterbooksize = ( -s "$folderdir/.filter.book" ) || 0;
   my $freespace = int($config{'maxbooksize'} - ($filterbooksize/1024) + .5);
   $html =~ s/\@\@\@FREESPACE\@\@\@/$freespace/g;
   
   ## replace @@@MENUBARLINKS@@@ ##
   if ( param("message_id") ) {
      $temphtml = "<a href=\"$config{'ow_cgiurl'}/openwebmail-main.pl?action=readmessage&amp;sessionid=$thissession&amp;sort=$sort&amp;firstmessage=$firstmessage&amp;folder=$folder&amp;message_id=$escapedmessageid\"><IMG SRC=\"$config{'ow_htmlurl'}/images/iconsets/$prefs{'iconset'}/backtofolder.gif\" border=\"0\" ALT=\"$lang_text{'backto'} $printfolder\"></a>";
   } else {
      $temphtml = "<a href=\"$config{'ow_cgiurl'}/openwebmail-main.pl?action=displayheaders&amp;sessionid=$thissession&amp;sort=$sort&amp;firstmessage=$firstmessage&amp;folder=$folder\"><IMG SRC=\"$config{'ow_htmlurl'}/images/iconsets/$prefs{'iconset'}/backtofolder.gif\" border=\"0\" ALT=\"$lang_text{'backto'} $printfolder\"></a>";
   }
   $html =~ s/\@\@\@MENUBARLINKS\@\@\@/$temphtml/g;

   ## replace @@@STARTFILTERFORM@@@ ##
   $temphtml = startform(-action=>"$config{'ow_cgiurl'}/openwebmail-prefs.pl",
                         -name=>'newfilter') .
                     hidden(-name=>'action',
                            -value=>'addfilter',
                            -override=>'1') .
                     hidden(-name=>'sessionid',
                            -value=>$thissession,
                            -override=>'1') .
                     hidden(-name=>'sort',
                            -default=>$sort,
                            -override=>'1') .
                     hidden(-name=>'firstmessage',
                            -default=>$firstmessage,
                            -override=>'1') .
                     hidden(-name=>'folder',
                            -default=>$folder,
                            -override=>'1');
                     hidden(-name=>'message_id',
                            -default=>$messageid,
                            -override=>'1');
   $html =~ s/\@\@\@STARTFILTERFORM\@\@\@/$temphtml/;

   ## replace @@@ENDFILTERFORM@@@ ##
   $temphtml = end_form();
   $html =~ s/\@\@\@ENDFILTERFORM\@\@\@/$temphtml/;

   ## replace @@@PRIORITYMENU@@@ ##
   $temphtml = popup_menu(-name=>'priority',
                          -values=>['01','02','03','04','05','06','07','08','09','10','11','12','13','14','15','16','17','18','19','20'],
                          -default=>'10');
   $html =~ s/\@\@\@PRIORITYMENU\@\@\@/$temphtml/;

   ## replace @@@RULEMENU@@@ ##
   %labels = ('from'=>$lang_text{'from'},
                        'to'=>$lang_text{'to'},
                        'subject'=>$lang_text{'subject'},
                        'smtprelay'=>$lang_text{'smtprelay'},
                        'header'=>$lang_text{'header'},
                        'textcontent'=>$lang_text{'textcontent'},
                        'attfilename'=>$lang_text{'attfilename'});
   $temphtml = popup_menu(-name=>'rules',
                          -values=>['from', 'to', 'subject', 'smtprelay', 'header', 'textcontent' ,'attfilename'],
                          -labels=>\%labels);
   $html =~ s/\@\@\@RULEMENU\@\@\@/$temphtml/;

   ## replace @@@INCLUDEMENU@@@ ##
   my %labels = ('include'=>$lang_text{'include'},
                        'exclude'=>$lang_text{'exclude'});
   $temphtml = popup_menu(-name=>'include',
                          -values=>['include', 'exclude'],
                          -labels=>\%labels);
   $html =~ s/\@\@\@INCLUDEMENU\@\@\@/$temphtml/;

   ## replace @@@TEXTFIELD@@@ ##
   $temphtml = textfield(-name=>'text',
                         -default=>'',
                         -size=>'26',
                         -override=>'1');
   $html =~ s/\@\@\@TEXTFIELD\@\@\@/$temphtml/;

   ## replace @@@OPMENU@@@ ##
   my %labels = ('move'=>$lang_text{'move'},
                 'copy'=>$lang_text{'copy'});
   $temphtml = popup_menu(-name=>'op',
                          -values=>['move', 'copy'],
                          -labels=>\%labels);
   $html =~ s/\@\@\@OPMENU\@\@\@/$temphtml/;

   ## replace @@@FOLDERMENU@@@ ##
   my @movefolders=@validfolders;
   push(@movefolders, 'DELETE');
   foreach (@movefolders) {
      if ( defined($lang_folders{$_}) ) {
          $labels{$_} = $lang_folders{$_};
      } else { 
         $labels{$_} = $_; 
      }
   }
   $temphtml = popup_menu(-name=>'destination',
                          -values=>[@movefolders],
                          -default=>'mail-trash',
                          -labels=>\%labels);
   $html =~ s/\@\@\@FOLDERMENU\@\@\@/$temphtml/;
   
   ## replace @@@ENABLECHECKBOX@@@ ##
   $temphtml = checkbox(-name=>'enable',
                        -value=>'1',
                        -checked=>"checked",
                        -label=>'');

   $html =~ s/\@\@\@ENABLECHECKBOX\@\@\@/$temphtml/;
   
   ## replace @@@ADDBUTTON@@@ ##
   $temphtml = submit(-name=>"$lang_text{'addmod'}",
                      -class=>"medtext");
   $html =~ s/\@\@\@ADDBUTTON\@\@\@/$temphtml/;

   ## replace @@@FILTERRULES@@@ ##
   if ( -f "$folderdir/.filter.book" ) {
      open (FILTER,"$folderdir/.filter.book") or
         openwebmailerror("$lang_err{'couldnt_open'} $folderdir/.filter.book!");
      while (<FILTER>) {
         chomp($_);
         push (@filterrules, $_);
      }
      close (FILTER) or openwebmailerror("$lang_err{'couldnt_close'} $folderdir/.filter.book!");
   }
   if ( $config{'global_filterbook'} ne "" && -f "$config{'global_filterbook'}" ) {
      if ( open (FILTER, "$config{'global_filterbook'}") ) { 
         while (<FILTER>) {
            chomp($_);
            push (@globalfilterrules, $_);
         }
         close (FILTER);
      }
   }

   $temphtml = '';
   my $bgcolor = $style{"tablerow_dark"};
   foreach my $line (@filterrules) {
      my ($priority, $rules, $include, $text, $op, $destination, $enable) = split(/\@\@\@/, $line);
      $temphtml .= "<tr>\n".
                   "<td bgcolor=$bgcolor align=center>$priority</td>\n".
                   "<td bgcolor=$bgcolor align=center>$lang_text{$rules}</td>\n".
                   "<td bgcolor=$bgcolor align=center>$lang_text{$include}</td>\n".
                   "<td bgcolor=$bgcolor align=center><a href=\"Javascript:Update('$priority','$rules','$include','$text','$op','$destination','$enable')\">$text</a></td>\n";
      if ($destination eq 'INBOX') {
         $temphtml .= "<td bgcolor=$bgcolor align=center>-----</td>\n";
      } else {
         $temphtml .= "<td bgcolor=$bgcolor align=center>$lang_text{$op}</td>\n";
      }
      if (defined($lang_folders{$destination})) {
         $temphtml .= "<td bgcolor=$bgcolor align=center>$lang_folders{$destination}</td>\n";
      } else {
         $temphtml .= "<td bgcolor=$bgcolor align=center>$destination</td>\n";
      }
      if ($enable == 1) {
         $temphtml .= "<td bgcolor=$bgcolor align=center>$lang_text{'enable'}</td>\n";
      } else {
         $temphtml .= "<td bgcolor=$bgcolor align=center>$lang_text{'disable'}</td>\n";
      }
      $temphtml .= start_form(-action=>"$config{'ow_cgiurl'}/openwebmail-prefs.pl");
      $temphtml .= "<td bgcolor=$bgcolor align=center>";
      $temphtml .= hidden(-name=>'action',
                          -value=>'deletefilter',
                          -override=>'1');
      $temphtml .= hidden(-name=>'sessionid',
                          -value=>$thissession,
                          -override=>'1');
      $temphtml .= hidden(-name=>'sort',
                          -default=>$sort,
                          -override=>'1');
      $temphtml .= hidden(-name=>'firstmessage',
                          -default=>$firstmessage,
                          -override=>'1');
      $temphtml .= hidden(-name=>'folder',
                          -default=>$folder,
                          -override=>'1');
      $temphtml .= hidden(-name=>'message_id',
                          -default=>$messageid,
                          -override=>'1');
      $temphtml .= hidden(-name=>'rules',
                          -value=>$rules,
                          -override=>'1');
      $temphtml .= hidden(-name=>'include',
                          -value=>$include,
                          -override=>'1');
      $temphtml .= hidden(-name=>'text',
                          -value=>$text,
                          -override=>'1');
      $temphtml .= hidden(-name=>'destination',
                          -value=>$destination,
                          -override=>'1');
      $temphtml .= submit(-name=>"$lang_text{'delete'}",
                          -class=>"medtext");
      $temphtml .= "</td>";
      $temphtml .= "</tr>";
      $temphtml .= end_form();
      if ($bgcolor eq $style{"tablerow_dark"}) {
         $bgcolor = $style{"tablerow_light"};
      } else {
         $bgcolor = $style{"tablerow_dark"};
      }
   }

   if ($#globalfilterrules >= 0) {
      $temphtml .= "<tr><td colspan=\"8\">&nbsp;</td></tr>\n";
      $temphtml .= "<tr><td colspan=\"8\" bgcolor=$style{columnheader}><B>$lang_text{globalfilterrule}</B> ($lang_text{readonly})</td></tr>\n";
   }
   $bgcolor = $style{"tablerow_dark"};
   foreach $line (@globalfilterrules) {
      my ($priority, $rules, $include, $text, $op, $destination, $enable) = split(/\@\@\@/, $line);
      $temphtml .= "<tr>\n".
                   "<td bgcolor=$bgcolor align=center>$priority</td>\n".
                   "<td bgcolor=$bgcolor align=center>$lang_text{$rules}</td>\n".
                   "<td bgcolor=$bgcolor align=center>$lang_text{$include}</td>\n".
                   "<td bgcolor=$bgcolor align=center><a href=\"Javascript:Update('$priority','$rules','$include','$text','$op','$destination','$enable')\">$text</a></td>\n".
                   "<td bgcolor=$bgcolor align=center>$lang_text{$op}</td>\n";
      if (defined($lang_folders{$destination})) {
         $temphtml .= "<td bgcolor=$bgcolor align=center>$lang_folders{$destination}</td>\n";
      } else {
         $temphtml .= "<td bgcolor=$bgcolor align=center>$destination</td>\n";
      }
      if ($enable == 1) {
         $temphtml .= "<td bgcolor=$bgcolor align=center>$lang_text{'enable'}</td>\n";
      } else {
         $temphtml .= "<td bgcolor=$bgcolor align=center>$lang_text{'disable'}</td>\n";
      }
      $temphtml .= "<td bgcolor=$bgcolor align=center>";
      $temphtml .= "-----";
      $temphtml .= "</td>";
      $temphtml .= "</tr>";
      if ($bgcolor eq $style{"tablerow_dark"}) {
         $bgcolor = $style{"tablerow_light"};
      } else {
         $bgcolor = $style{"tablerow_dark"};
      }
   }

   $html =~ s/\@\@\@FILTERRULES\@\@\@/$temphtml/;

   print $html;
   
   printfooter();
}
################### END EDITFILTER ########################

################### MODFILTER ##############################
sub modfilter {
   ## get parameters ##
   my $mode = shift;
   my ($priority, $rules, $include, $text, $op, $destination, $enable);
   $priority = param("priority") || '';
   $rules = param("rules") || '';
   $include = param("include") || '';
   $text = param("text") || '';
   $text =~ s/^[\s\@]+//;
   $text =~ s/[\@\s]+$//;
   $text =~ s/\@\@\@//g;
   $op = param("op") || 'move';
   $destination = param("destination") || '';
   $destination =~ s/\.\.+//g;
   $destination =~ s/[\s\/\`\|\<\>;]//g; # remove dangerous char
   $enable = param("enable") || 0;
   
   ## add mode -> can't have null $rules, null $text, null $destination ##
   ## delete mode -> can't have null $filter ##
   if( ($rules && $include && $text && $destination && $priority) || 
       (($mode eq 'delete') && ($rules && $include && $text && $destination)) ) {
      my %filterrules;
      if ( -f "$folderdir/.filter.book" ) {
         filelock("$folderdir/.filter.book", LOCK_EX|LOCK_NB) or
            openwebmailerror("$lang_err{'couldnt_lock'} $folderdir/.filter.book!");
         open (FILTER,"+<$folderdir/.filter.book") or
            openwebmailerror("$lang_err{'couldnt_open'} $folderdir/.filter.book!");
         while(<FILTER>) {
            my ($epriority,$erules,$einclude,$etext,$eop,$edestination,$eenable);
            my $line=$_; chomp($line);
            ($epriority,$erules,$einclude,$etext,$eop,$edestination,$eenable) = split(/\@\@\@/, $line);
            $filterrules{"$erules\@\@\@$einclude\@\@\@$etext\@\@\@$edestination"}="$epriority\@\@\@$erules\@\@\@$einclude\@\@\@$etext\@\@\@$eop\@\@\@$edestination\@\@\@$eenable";
         }
         if ($mode eq 'delete') {
            delete $filterrules{"$rules\@\@\@$include\@\@\@$text\@\@\@$destination"};
         } else {
            $filterrules{"$rules\@\@\@$include\@\@\@$text\@\@\@$destination"}="$priority\@\@\@$rules\@\@\@$include\@\@\@$text\@\@\@$op\@\@\@$destination\@\@\@$enable";
         }
         seek (FILTER, 0, 0) or
            openwebmailerror("$lang_err{'couldnt_seek'} $folderdir/.filter.book!");
   
         foreach (sort values %filterrules) {
            print FILTER "$_\n";
         }
         truncate(FILTER, tell(FILTER));
         close (FILTER) or openwebmailerror("$lang_err{'couldnt_close'} $folderdir/.filter.book!");         
         filelock("$folderdir/.filter.book", LOCK_UN);
      } else {
         open (FILTER, ">$folderdir/.filter.book" ) or
                  openwebmailerror("$lang_err{'couldnt_open'} $folderdir/.filter.book!");
         print FILTER "$priority\@\@\@$rules\@\@\@$include\@\@\@$text\@\@\@$op\@\@\@$destination\@\@\@$enable\n";
         close (FILTER) or openwebmailerror("$lang_err{'couldnt_close'} $folderdir/.filter.book!");
      }
      
      ## remove .filter.check ##
      unlink("$folderdir/.filter.check");
   }
#   print "Location: $config{'ow_cgiurl'}/openwebmail-prefs.pl?action=editfilter&sessionid=$thissession&sort=$sort&folder=$escapedfolder&firstmessage=$firstmessage&amp;message_id=$escapedmessageid\n\n";
    editfilter();
}
################## END MODFILTER ###########################
