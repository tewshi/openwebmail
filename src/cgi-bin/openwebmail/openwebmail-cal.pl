#!/usr/bin/perl -T
#############################################################################
# Open WebMail - Provides a web interface to user mailboxes                 #
#                                                                           #
# Copyright (C) 2001-2002                                                   #
# Chung-Kie Tung, Nai-Jung Kuo, Chao-Chiu Wang, Emir Litric, Thomas Chung   #
# Copyright (C) 1999                                                        #
# Michael Arndt  (original GPL project: Webcal)                             #
#                                                                           #
# This program is distributed under GNU General Public License              #
#############################################################################

use vars qw($SCRIPT_DIR);
if ( $ENV{'SCRIPT_FILENAME'} =~ m!^(.*?)/[\w\d\-]+\.pl! || $0 =~ m!^(.*?)/[\w\d\-]+\.pl! ) { $SCRIPT_DIR=$1; }
if (!$SCRIPT_DIR) { print "Content-type: text/html\n\n\$SCRIPT_DIR not set in CGI script!\n"; exit 0; }
push (@INC, $SCRIPT_DIR, ".");

$ENV{PATH} = ""; # no PATH should be needed
$ENV{BASH_ENV} = ""; # no startup script for bash
umask(0007); # make sure the openwebmail group can write

use strict;
use Fcntl qw(:DEFAULT :flock);
use Time::Local;
use CGI qw(-private_tempfiles :standard);
use CGI::Carp qw(fatalsToBrowser);
CGI::nph();   # Treat script as a non-parsed-header script

require "openwebmail-shared.pl";
require "filelock.pl";

use vars qw(%config %config_raw);
use vars qw($thissession);
use vars qw($loginname $domain $user $userrealname $uuid $ugid $homedir);
use vars qw(%prefs %style);
use vars qw($folderdir @validfolders $folderusage);
use vars qw($folder $printfolder $escapedfolder);

openwebmail_init();
verifysession();

use vars qw(%lang_folders %lang_text %lang_err);	# defined in lang/xy
use vars qw(%lang_calendar %lang_month %lang_wday_abbrev %lang_wday %lang_order); # defined in lang/xy
use vars qw(@wdaystr);			# defined in openwebmail-shared.opl

use vars qw($messageid $escapedmessageid);

########################## MAIN ##############################
$messageid = param("message_id");
$escapedmessageid = escapeURL($messageid);

my $action = param("action");

my $year=param('year')||'';
my $month=param('month')||'';
my $day=param('day')||'';
my $index=param('index')||'';

my $string=param('string')||'';
my $starthour=param('starthour')||0;
my $startmin=param('startmin')||0;
my $startampm=param('startampm')||'am';
my $endhour=param('endhour')||0;
my $endmin=param('endmin')||0;
my $endampm=param('endampm')||'am';
my $link=param('link')||'';

my $freq=param('freq')||'todayonly';
my $weekorder=param('weekorder')||'';
my $todayandnextndays=param('todayandnextndays')||0;
my $ndays=param('ndays')||0;
my $everymonth=param('everymonth')||0;
my $everyyear=param('everyyear')||0;

if ($action eq "calyear") {
   yearview($year);
} elsif ($action eq "calmonth") {
   monthview($year, $month);
} elsif ($action eq "calweek") {
   weekview($year, $month, $day);
} elsif ($action eq "calday") {
   dayview($year, $month, $day);
} elsif ($action eq "caledit") {
   edit_item($year, $month, $day, $index);
} elsif ($action eq "caladd") {
   add_item($year, $month, $day,
            $string,
            $starthour, $startmin, $startampm,
            $endhour, $endmin, $endampm,
            $freq, $weekorder,
            $todayandnextndays, $ndays, $everymonth, $everyyear,
            $link);
   dayview($year, $month, $day);
} elsif ($action eq "caldel") {
   del_item($index);
   dayview($year, $month, $day);
} elsif ($action eq "calupdate") {
   update_item($index, $string,
               $starthour, $startmin, $startampm,
               $endhour, $endmin, $endampm,
               $link );
   dayview($year, $month, $day);
} else {
   openwebmailerror("Action $lang_err{'has_illegal_chars'}");
}
########################## END MAIN ##########################

########################## YEARVIEW ##########################
sub yearview {
   my $year=$_[0];
   my $g2l=time()+timeoffset2seconds($prefs{'timeoffset'}); # trick makes gmtime($g2l) return localtime in timezone of timeoffsset
   my ($current_year, $current_month, $current_day)=(gmtime($g2l))[5,4,3];
   $current_year+=1900; $current_month++;

   my $day;
   $year = $current_year if (!$year);

   printheader();

   my $html = '';
   my $temphtml;
   open (YEARVIEW, "$config{'ow_etcdir'}/templates/$prefs{'language'}/yearview.template") or
      openwebmailerror("$lang_err{'couldnt_open'} $config{'ow_etcdir'}/templates/$prefs{'language'}/yearview.template!");
   while (<YEARVIEW>) {
      $html .= $_;
   }
   close (YEARVIEW);

   $html = applystyle($html);

   $temphtml = startform(-name=>"yearform",
			 -action=>"$config{'ow_cgiurl'}/openwebmail-cal.pl") .
               hidden(-name=>'action',
                      -default=>'calyear',
                      -override=>'1').
               hidden(-name=>'sessionid',
                      -default=>$thissession,
                      -override=>'1').
               hidden(-name=>'folder',
                      -default=>$folder,
                      -override=>'1').
               hidden(-name=>'message_id',
                      -default=>$messageid,
                      -override=>'1');
   $html =~ s/\@\@\@STARTFORM\@\@\@/$temphtml/g;

   $temphtml = textfield(-name=>'year',
                         -default=>$year,
                         -size=>'4',
                         -override=>'1');

   $html =~ s/\@\@\@YEARFIELD\@\@\@/$lang_text{'calfmt_year'}/g;
   $html =~ s/\@\@\@YEAR\@\@\@/ $temphtml /;

   $temphtml = end_form();
   $html =~ s/\@\@\@ENDFORM\@\@\@/$temphtml/g;

   $temphtml = formatted_date($year);
   $html =~ s/\@\@\@CALTITLE\@\@\@/$temphtml/g;

   my $cal_url=qq|$config{'ow_cgiurl'}/openwebmail-cal.pl?sessionid=$thissession&amp;folder=$escapedfolder&amp;message_id=$escapedmessageid&amp;|;

   $temphtml  = qq|<a href="|.$cal_url.
                qq|action=calyear&year=$year" title="$lang_calendar{'yearview'} |.formatted_date($year).qq|"><IMG SRC="$config{'ow_htmlurl'}/images/iconsets/$prefs{'iconset'}/yearview.gif" border="0" ALT="$lang_calendar{'yearview'} |.formatted_date($year).qq|"></a> \n|;
   $temphtml .= qq|<a href="|.$cal_url.
                qq|action=calmonth&year=$year&month=$current_month" title="$lang_calendar{'monthview'} |.formatted_date($year, $current_month).qq|"><IMG SRC="$config{'ow_htmlurl'}/images/iconsets/$prefs{'iconset'}/monthview.gif" border="0" ALT="$lang_calendar{'monthview'} |.formatted_date($year, $current_month).qq|"</a> \n|;
   $temphtml .= qq|<a href="|.$cal_url.
                qq|action=calweek&year=$year&month=$current_month&day=$current_day" title="$lang_calendar{'weekview'} |.formatted_date($year, $current_month, $current_day).qq|"><IMG SRC="$config{'ow_htmlurl'}/images/iconsets/$prefs{'iconset'}/weekview.gif" border="0" ALT="$lang_calendar{'weekview'} |.formatted_date($year, $current_month, $current_day).qq|"></a> \n|;
   $temphtml .= qq|<a href="|.$cal_url.
                qq|action=calday&year=$year&month=$current_month&day=$current_day" title="$lang_calendar{'dayview'} |.formatted_date($year, $current_month, $current_day).qq|"><IMG SRC="$config{'ow_htmlurl'}/images/iconsets/$prefs{'iconset'}/dayview.gif" border="0" ALT="$lang_calendar{'dayview'} |.formatted_date($year, $current_month, $current_day).qq|"></a> \n|;
   if ($year != $current_year) {
      $temphtml .= qq|<a href="|.$cal_url.
                   qq|action=calyear&year=$current_year" title="$lang_text{'backto'} |.formatted_date($current_year).qq|"><IMG SRC="$config{'ow_htmlurl'}/images/iconsets/$prefs{'iconset'}/refresh.gif" border="0" ALT="$lang_text{'backto'} |.formatted_date($current_year).qq|"></a> \n|;
   }
   $temphtml .= "&nbsp \n";
   if ($messageid eq "") {
      $temphtml .= qq|<a href="$config{'ow_cgiurl'}/openwebmail-main.pl?|.
                   qq|action=displayheaders&amp;sessionid=$thissession&amp;folder=$escapedfolder" title="$lang_text{'backto'} $printfolder"><IMG SRC="$config{'ow_htmlurl'}/images/iconsets/$prefs{'iconset'}/owm.gif" border="0" ALT="$lang_text{'backto'} $printfolder"></a> \n|;
   } else {
      $temphtml .= qq|<a href="$config{'ow_cgiurl'}/openwebmail-read.pl?|.
                   qq|action=readmessage&amp;sessionid=$thissession&amp;folder=$escapedfolder&amp;message_id=$escapedmessageid" title="$lang_text{'backto'} $printfolder"><IMG SRC="$config{'ow_htmlurl'}/images/iconsets/$prefs{'iconset'}/owm.gif" border="0" ALT="$lang_text{'backto'} $printfolder"></a> \n|;
   }
   $temphtml .= qq|<a href="$config{'ow_cgiurl'}/openwebmail-main.pl?sessionid=$thissession&amp;action=logout" title="$lang_text{'logout'} $prefs{'email'}"><IMG SRC="$config{'ow_htmlurl'}/images/iconsets/$prefs{'iconset'}/logout.gif" border="0" ALT="$lang_text{'logout'} $prefs{'email'}"></a> &nbsp; \n|;

   $html =~ s/\@\@\@MENUBARLINKS\@\@\@/$temphtml/g;

   my $prev_year = $year - 1;
   $temphtml=qq|<a href="|.$cal_url.
             qq|action=calyear&year=$prev_year" title="|.formatted_date($prev_year).qq|"><IMG SRC="$config{'ow_htmlurl'}/images/iconsets/$prefs{'iconset'}/left.gif" border="0" ALT="|.formatted_date($prev_year).qq|"></a> \n|;
   $html =~ s/\@\@\@PREV_LINK\@\@\@/$temphtml/g;

   my $next_year = $year + 1;
   $temphtml=qq|<a href="|.$cal_url.
             qq|action=calyear&year=$next_year" title="|.formatted_date($next_year).qq|"><IMG SRC="$config{'ow_htmlurl'}/images/iconsets/$prefs{'iconset'}/right.gif" border="0" ALT="|.formatted_date($next_year).qq|"></a> \n|;
   $html =~ s/\@\@\@NEXT_LINK\@\@\@/$temphtml/g;

   my $week=1;
   for my $month (1..12) {
      my @days = set_days_in_month($year, $month);
      my $bgcolor;

      if ($month==$current_month && $year == $current_year) {
         $bgcolor=qq|bgcolor=$style{'tablerow_light'}|;
      } else {
         $bgcolor=qq|bgcolor=$style{'tablerow_dark'}|;
      }

      $temphtml  = qq|<td valign=top align=center $bgcolor>\n|;

      $temphtml .= qq|<table border=0 width=100%><tr><td align=center>|.
                   qq|<a href=|.$cal_url.qq|action=calmonth&year=$year&month=$month>|.
                   qq|<B>$lang_month{$month}</B></a>|.
                   qq|</td></tr></table>\n|;

      $temphtml .= qq|<table border=0 cellpadding=1 cellspacing=0 width=100%>\n|;

      if ($prefs{'calendar_weekstart'} eq "S") {
         $temphtml .= qq|<tr align=center><td>$lang_wday_abbrev{'week'}</td>|.
                      qq|<td align=center>$lang_wday_abbrev{'0'}</td>|.
                      qq|<td align=center>$lang_wday_abbrev{'1'}</td>|.
                      qq|<td align=center>$lang_wday_abbrev{'2'}</td>|.
                      qq|<td align=center>$lang_wday_abbrev{'3'}</td>|.
                      qq|<td align=center>$lang_wday_abbrev{'4'}</td>|.
                      qq|<td align=center>$lang_wday_abbrev{'5'}</td>|.
                      qq|<td align=center>$lang_wday_abbrev{'6'}</td></tr>\n|;
      } else {
         $temphtml .= qq|<tr align=center><td>$lang_wday_abbrev{'week'}</td>|.
                      qq|<td align=center>$lang_wday_abbrev{'1'}</td>|.
                      qq|<td align=center>$lang_wday_abbrev{'2'}</td>|.
                      qq|<td align=center>$lang_wday_abbrev{'3'}</td>|.
                      qq|<td align=center>$lang_wday_abbrev{'4'}</td>|.
                      qq|<td align=center>$lang_wday_abbrev{'5'}</td>|.
                      qq|<td align=center>$lang_wday_abbrev{'6'}</td>|.
                      qq|<td align=center>$lang_wday_abbrev{'0'}</td></tr>\n|;
      }
      for my $x (0..5) {
         $temphtml .= qq|<tr align=center>|;
         if (($days[$x][0]) || ($days[$x][6])) {
            if ($days[$x][0]) {
               $day = $days[$x][0];
            } else {
               $day = $days[$x][6];
            }
            $temphtml .= qq|<td><a href=|.$cal_url.qq|action=calweek&year=$year&month=$month&day=$day>|.
                         qq|<font color=#c00000>$week</font></a></td>\n|;
         }
         for my $y (0..6) {
            if ($days[$x][$y]) {
               $day = $days[$x][$y];
               if ($day==$current_day && $month==$current_month && $year==$current_year) {
                  $bgcolor=qq|bgcolor=$style{'columnheader'}|;
               } else {
                  $bgcolor="";
               }
               $temphtml .= qq|<td $bgcolor><a href=|.$cal_url.qq|action=calday&year=$year&month=$month&day=$day>|.
                            qq|$days[$x][$y]</a></td>\n|;
               $week++ if ($y==6 && $week<52);
            } else {
               $temphtml .= qq|<td>&nbsp;</td>|;
            }
         }
         $temphtml .= qq|</tr>\n|;
      }
      $temphtml .= qq|</table></td>\n|;

      $html =~ s/\@\@\@MONTH$month\@\@\@/$temphtml/;
   }

   print $html;
   printfooter(2);
}
######################## END YEARVIEW ########################

########################## MONTHVIEW ##########################
sub monthview {
   my ($year, $month)=@_;
   my $g2l=time()+timeoffset2seconds($prefs{'timeoffset'}); # trick makes gmtime($g2l) return localtime in timezone of timeoffsset
   my ($current_year, $current_month, $current_day)=(gmtime($g2l))[5,4,3];
   $current_year+=1900; $current_month++;

   $year = $current_year if (!$year);
   $month = $current_month if (!$month);

   printheader();

   my $html = '';
   my $temphtml;
   open (MONTHVIEW, "$config{'ow_etcdir'}/templates/$prefs{'language'}/monthview.template") or
      openwebmailerror("$lang_err{'couldnt_open'} $config{'ow_etcdir'}/templates/$prefs{'language'}/monthview.template!");
   while (<MONTHVIEW>) {
      $html .= $_;
   }
   close (MONTHVIEW);

   $html = applystyle($html);

   $temphtml = startform(-name=>"yearform",
			 -action=>"$config{'ow_cgiurl'}/openwebmail-cal.pl") .
               hidden(-name=>'action',
                      -default=>'calmonth',
                      -override=>'1').
               hidden(-name=>'month',
                      -default=>$month,
                      -override=>'1').
               hidden(-name=>'sessionid',
                      -default=>$thissession,
                      -override=>'1').
               hidden(-name=>'folder',
                      -default=>$folder,
                      -override=>'1').
               hidden(-name=>'message_id',
                      -default=>$messageid,
                      -override=>'1');
   $html =~ s/\@\@\@STARTFORM\@\@\@/$temphtml/g;

   $temphtml = textfield(-name=>'year',
                         -default=>$year,
                         -size=>'4',
                         -override=>'1');

   $html =~ s/\@\@\@YEARFIELD\@\@\@/$lang_text{'calfmt_year'}/g;
   $html =~ s/\@\@\@YEAR\@\@\@/ $temphtml /;

   $temphtml = end_form();
   $html =~ s/\@\@\@ENDFORM\@\@\@/$temphtml/g;

   $temphtml = formatted_date($year, $month);
   $html =~ s/\@\@\@CALTITLE\@\@\@/$temphtml/g;

   my $cal_url=qq|$config{'ow_cgiurl'}/openwebmail-cal.pl?sessionid=$thissession&amp;folder=$escapedfolder&amp;message_id=$escapedmessageid&amp;|;

   $temphtml  = qq|<a href="|.$cal_url.
                qq|action=calyear&year=$year" title="$lang_calendar{'yearview'} |.formatted_date($year).qq|"><IMG SRC="$config{'ow_htmlurl'}/images/iconsets/$prefs{'iconset'}/yearview.gif" border="0" ALT="$lang_calendar{'yearview'} |.formatted_date($year).qq|"></a> \n|;
   $temphtml .= qq|<a href="|.$cal_url.
                qq|action=calmonth&year=$year&month=$month" title="$lang_calendar{'monthview'} |.formatted_date($year,$month).qq|"><IMG SRC="$config{'ow_htmlurl'}/images/iconsets/$prefs{'iconset'}/monthview.gif" border="0" ALT="$lang_calendar{'monthview'} |.formatted_date($year,$month).qq|"</a> \n|;
   $temphtml .= qq|<a href="|.$cal_url.
                qq|action=calweek&year=$year&month=$month&day=$current_day" title="$lang_calendar{'weekview'} |.formatted_date($year,$month,$current_day).qq|"><IMG SRC="$config{'ow_htmlurl'}/images/iconsets/$prefs{'iconset'}/weekview.gif" border="0" ALT="$lang_calendar{'weekview'} |.formatted_date($year,$month,$current_day).qq|"></a> \n|;
   $temphtml .= qq|<a href="|.$cal_url.
                qq|action=calday&year=$year&month=$month&day=$current_day" title="$lang_calendar{'dayview'} |.formatted_date($year,$month,$current_day).qq|"><IMG SRC="$config{'ow_htmlurl'}/images/iconsets/$prefs{'iconset'}/dayview.gif" border="0" ALT="$lang_calendar{'dayview'} |.formatted_date($year,$month,$current_day).qq|"></a> \n|;
   if ($year!=$current_year || $month!=$current_month) {
      $temphtml .= qq|<a href="|.$cal_url.
                   qq|action=calmonth&year=$current_year&month=$current_month" title="$lang_text{'backto'} |.formatted_date($current_year,$current_month).qq|"><IMG SRC="$config{'ow_htmlurl'}/images/iconsets/$prefs{'iconset'}/refresh.gif" border="0" ALT="$lang_text{'backto'} |.formatted_date($current_year,$current_month).qq|"></a> \n|;
   }
   $temphtml .= "&nbsp \n";
   if ($messageid eq "") {
      $temphtml .= qq|<a href="$config{'ow_cgiurl'}/openwebmail-main.pl?|.
                   qq|action=displayheaders&amp;sessionid=$thissession&amp;folder=$escapedfolder" title="$lang_text{'backto'} $printfolder"><IMG SRC="$config{'ow_htmlurl'}/images/iconsets/$prefs{'iconset'}/owm.gif" border="0" ALT="$lang_text{'backto'} $printfolder"></a> \n|;
   } else {
      $temphtml .= qq|<a href="$config{'ow_cgiurl'}/openwebmail-read.pl?|.
                   qq|action=readmessage&amp;sessionid=$thissession&amp;folder=$escapedfolder&amp;message_id=$escapedmessageid" title="$lang_text{'backto'} $printfolder"><IMG SRC="$config{'ow_htmlurl'}/images/iconsets/$prefs{'iconset'}/owm.gif" border="0" ALT="$lang_text{'backto'} $printfolder"></a> \n|;
   }
   $temphtml .= qq|<a href="$config{'ow_cgiurl'}/openwebmail-main.pl?sessionid=$thissession&amp;action=logout" title="$lang_text{'logout'} $prefs{'email'}"><IMG SRC="$config{'ow_htmlurl'}/images/iconsets/$prefs{'iconset'}/logout.gif" border="0" ALT="$lang_text{'logout'} $prefs{'email'}"></a> &nbsp; \n|;


   $html =~ s/\@\@\@MENUBARLINKS\@\@\@/$temphtml/g;

   my ($prev_year, $prev_month)= ($year, $month-1);
   if ($month == 1) {
      ($prev_year, $prev_month) = ($year-1, 12);
   }
   $temphtml=qq|<a href="|.$cal_url.
             qq|action=calmonth&year=$prev_year&month=$prev_month" title="|.formatted_date($prev_year,$prev_month).qq|"><IMG SRC="$config{'ow_htmlurl'}/images/iconsets/$prefs{'iconset'}/left.gif" border="0" ALT="|.formatted_date($prev_year,$prev_month).qq|"></a> \n|;
   $html =~ s/\@\@\@PREV_LINK\@\@\@/$temphtml/g;

   my ($next_year, $next_month)= ($year, $month+1);
   if ($month == 12) {
      ($next_year, $next_month) = ($year+1, 1);
   }
   $temphtml=qq|<a href="|.$cal_url.
             qq|action=calmonth&year=$next_year&month=$next_month" title="|.formatted_date($next_year,$next_month).qq|"><IMG SRC="$config{'ow_htmlurl'}/images/iconsets/$prefs{'iconset'}/right.gif" border="0" ALT="|.formatted_date($next_year,$next_month).qq|"></a> \n|;
   $html =~ s/\@\@\@NEXT_LINK\@\@\@/$temphtml/g;

   if ($prefs{'calendar_weekstart'} eq "S") {
      $html =~ s!\@\@\@WEEKDAY0\@\@\@!<font color=#cc0000>$lang_wday{'0'}</font>!;
      $html =~ s!\@\@\@WEEKDAY1\@\@\@!$lang_wday{'1'}!;
      $html =~ s!\@\@\@WEEKDAY2\@\@\@!$lang_wday{'2'}!;
      $html =~ s!\@\@\@WEEKDAY3\@\@\@!$lang_wday{'3'}!;
      $html =~ s!\@\@\@WEEKDAY4\@\@\@!$lang_wday{'4'}!;
      $html =~ s!\@\@\@WEEKDAY5\@\@\@!$lang_wday{'5'}!;
      $html =~ s!\@\@\@WEEKDAY6\@\@\@!<font color=#00aa00>$lang_wday{'6'}</font>!;
   } else {
      $html =~ s!\@\@\@WEEKDAY0\@\@\@!$lang_wday{'1'}!;
      $html =~ s!\@\@\@WEEKDAY1\@\@\@!$lang_wday{'2'}!;
      $html =~ s!\@\@\@WEEKDAY2\@\@\@!$lang_wday{'3'}!;
      $html =~ s!\@\@\@WEEKDAY3\@\@\@!$lang_wday{'4'}!;
      $html =~ s!\@\@\@WEEKDAY4\@\@\@!$lang_wday{'5'}!;
      $html =~ s!\@\@\@WEEKDAY5\@\@\@!<font color=#00aa00>$lang_wday{'6'}!;
      $html =~ s!\@\@\@WEEKDAY6\@\@\@!<font color=#cc0000>$lang_wday{'0'}</font>!;
   }

   my (%items, %indexes, $item_count);
   $item_count =readcalbook("$folderdir/.calendar.book", \%items, \%indexes, 0);
   $item_count+=readcalbook("$config{'global_calendarbook'}", \%items, \%indexes, 1E6) if (-f "$config{'global_calendarbook'}");
   my @days = set_days_in_month($year, $month);
   for my $x ( 0..5 ) {
      for my $y ( 0..6 ) {
         my $bgcolor;
         my $day = $days[$x][$y];
         if ($year==$current_year &&
             $month==$current_month &&
             $day==$current_day) {
            $bgcolor="bgcolor=$style{'tablerow_light'}";
         } elsif ($days[$x][$y]) {
            $bgcolor="bgcolor=$style{'tablerow_dark'}";
         } else {	# else cell is not unused
            $bgcolor="";
         }

         $temphtml = qq|<td valign=top $bgcolor>|.
                     qq|<table width="100%" cellpadding=0 cellspacing=0>\n|;

         if ($days[$x][$y] =~ /\d+/) {
            my $daystr=$days[$x][$y];
            $daystr=" ".$daystr if (length($daystr)<2);

            $temphtml .= start_form(-action=>"$config{'ow_cgiurl'}/openwebmail-cal.pl",
                                    -name=> "day$days[$x][$y]");
            $temphtml .= hidden(-name=>'sessionid',
                                -default=>$thissession,
                                -override=>'1');
            $temphtml .= hidden(-name=>'folder',
                                -value=>$folder,
                                -override=>'1');
            $temphtml .= hidden(-name=>'message_id',
                                -default=>$messageid,
                                -override=>'1');
            $temphtml .= hidden(-name=>'action',
                                -value=>'calday',
                                -override=>'1');
            $temphtml .= hidden(-name=>'year',
                                -value=>$year,
                                -override=>'1');
            $temphtml .= hidden(-name=>'month',
                                -value=>$month,
                                -override=>'1');
            $temphtml .= hidden(-name=>'day',
                                -value=>$day,
                                -override=>'1');
            $temphtml .= qq|<tr><td align=right>|.
                         lunar_str($year, $month, $day, $prefs{'charset'}).
                         submit("$daystr").
                         qq|</td></tr>|.
                         end_form();

            my $t=timelocal 1,1,1,$day,($month-1),($year-1900);
            my $dow=$wdaystr[(localtime($t))[6]];
            my $date=sprintf("%04d%02d%02d", $year, $month, $day);
            my $date2=sprintf("%04d,%02d,%02d,%s", $year,$month,$day,$dow);
            my $i=0;

            my @indexlist=();
            push(@indexlist, @{$indexes{$date}}) if (defined($indexes{$date}));
            push(@indexlist, @{$indexes{'*'}})   if (defined($indexes{'*'}));
            @indexlist=sort { ($items{$a}{'starthourmin'}||1E9)<=>($items{$b}{'starthourmin'}||1E9) } @indexlist;

            $temphtml .= qq|<tr><td align=left>|;
            for my $index (@indexlist) {
               if ($date=~/$items{$index}{'idate'}/ ||
                   $date2=~/$items{$index}{'idate'}/) {
                  if ($i<$prefs{'calendar_monthviewnumitems'}) {
                     $temphtml .= qq|<br>\n| if ( $i>0);
                     $temphtml .= month_week_item($items{$index}, $cal_url.qq|action=calday&year=$year&month=$month&day=$day|, ($index>=1E6))
                  }
                  $i++;
               }
            }
            if ($i>$prefs{'calendar_monthviewnumitems'}) {
               $temphtml .= qq|<br><br><font size=-1><a href=|.$cal_url.
                            qq|action=calday&year=$year&month=$month&day=$day>|.
                            qq|$lang_text{'moreitems'}</a></font>\n|;
            }
            $temphtml .= qq|&nbsp;<br>\n| if ($i==0);
            $temphtml .= qq|</td></tr></table></td>\n|;

         } else {
            $temphtml .= qq|<tr><td>$days[$x][$y]</td></tr>|.
                         qq|<tr><td></td></tr></table></td>\n|;
         }

         $html =~ s/\@\@\@DAY$x$y\@\@\@/$temphtml/;
      }
   }

   print $html;
   printfooter(2);
}
######################## END MONTHVIEW ########################

########################## WEEKVIEW ##########################
sub weekview {
   my ($year, $month, $day)=@_;
   my $g2l=time()+timeoffset2seconds($prefs{'timeoffset'}); # trick makes gmtime($g2l) return localtime in timezone of timeoffsset
   my ($current_year, $current_month, $current_day)=(gmtime($g2l))[5,4,3];
   $current_year+=1900; $current_month++;

   $year = $current_year if (!$year);
   $month = $current_month if (!$month);
   $day = $current_day if (!$day);

   printheader();

   my $html = '';
   my $temphtml;
   open (WEEKVIEW, "$config{'ow_etcdir'}/templates/$prefs{'language'}/weekview.template") or
      openwebmailerror("$lang_err{'couldnt_open'} $config{'ow_etcdir'}/templates/$prefs{'language'}/weekview.template!");
   while (<WEEKVIEW>) {
      $html .= $_;
   }
   close (WEEKVIEW);

   $html = applystyle($html);

   $temphtml = startform(-name=>"yearform",
			 -action=>"$config{'ow_cgiurl'}/openwebmail-cal.pl") .
               hidden(-name=>'action',
                      -default=>'calweek',
                      -override=>'1').
               hidden(-name=>'month',
                      -default=>$month,
                      -override=>'1').
               hidden(-name=>'day',
                      -default=>$day,
                      -override=>'1').
               hidden(-name=>'sessionid',
                      -default=>$thissession,
                      -override=>'1').
               hidden(-name=>'folder',
                      -default=>$folder,
                      -override=>'1').
               hidden(-name=>'message_id',
                      -default=>$messageid,
                      -override=>'1');
   $html =~ s/\@\@\@STARTFORM\@\@\@/$temphtml/g;

   $temphtml = textfield(-name=>'year',
                         -default=>$year,
                         -size=>'4',
                         -override=>'1');

   $html =~ s/\@\@\@YEARFIELD\@\@\@/$lang_text{'calfmt_year'}/g;
   $html =~ s/\@\@\@YEAR\@\@\@/ $temphtml /;

   $temphtml = end_form();
   $html =~ s/\@\@\@ENDFORM\@\@\@/$temphtml/g;

   $temphtml = formatted_date($year, $month, $day);
   $html =~ s/\@\@\@CALTITLE\@\@\@/$temphtml/g;

   my $cal_url=qq|$config{'ow_cgiurl'}/openwebmail-cal.pl?sessionid=$thissession&amp;folder=$escapedfolder&amp;message_id=$escapedmessageid&amp;|;

   $temphtml  = qq|<a href="|.$cal_url.
                qq|action=calyear&year=$year" title="$lang_calendar{'yearview'} |.formatted_date($year).qq|"><IMG SRC="$config{'ow_htmlurl'}/images/iconsets/$prefs{'iconset'}/yearview.gif" border="0" ALT="$lang_calendar{'yearview'} |.formatted_date($year).qq|"></a> \n|;
   $temphtml .= qq|<a href="|.$cal_url.
                qq|action=calmonth&year=$year&month=$month" title="$lang_calendar{'monthview'} |.formatted_date($year,$month).qq|"><IMG SRC="$config{'ow_htmlurl'}/images/iconsets/$prefs{'iconset'}/monthview.gif" border="0" ALT="$lang_calendar{'monthview'} |.formatted_date($year,$month).qq|"</a> \n|;
   $temphtml .= qq|<a href="|.$cal_url.
                qq|action=calweek&year=$year&month=$month&day=$day" title="$lang_calendar{'weekview'} |.formatted_date($year,$month,$day).qq|"><IMG SRC="$config{'ow_htmlurl'}/images/iconsets/$prefs{'iconset'}/weekview.gif" border="0" ALT="$lang_calendar{'weekview'} |.formatted_date($year,$month,$day).qq|"></a> \n|;
   $temphtml .= qq|<a href="|.$cal_url.
                qq|action=calday&year=$year&month=$month&day=$day" title="$lang_calendar{'dayview'} |.formatted_date($year,$month,$day).qq|"><IMG SRC="$config{'ow_htmlurl'}/images/iconsets/$prefs{'iconset'}/dayview.gif" border="0" ALT="$lang_calendar{'dayview'} |.formatted_date($year,$month,$day).qq|"></a> \n|;
   if ($year!=$current_year || $month!=$current_month || $day!=$current_day) {
      $temphtml .= qq|<a href="|.$cal_url.
                   qq|action=calweek&year=$current_year&month=$current_month&day=$current_day" title="$lang_text{'backto'} $lang_calendar{'weekview'} |.formatted_date($current_year,$current_month,$current_day).qq|"><IMG SRC="$config{'ow_htmlurl'}/images/iconsets/$prefs{'iconset'}/refresh.gif" border="0" ALT="$lang_text{'backto'} $lang_calendar{'weekview'} |.formatted_date($current_year,$current_month,$current_day).qq|"></a> \n|;
   }
   $temphtml .= "&nbsp \n";
   if ($messageid eq "") {
      $temphtml .= qq|<a href="$config{'ow_cgiurl'}/openwebmail-main.pl?|.
                   qq|action=displayheaders&amp;sessionid=$thissession&amp;folder=$escapedfolder" title="$lang_text{'backto'} $printfolder"><IMG SRC="$config{'ow_htmlurl'}/images/iconsets/$prefs{'iconset'}/owm.gif" border="0" ALT="$lang_text{'backto'} $printfolder"></a> \n|;
   } else {
      $temphtml .= qq|<a href="$config{'ow_cgiurl'}/openwebmail-read.pl?|.
                   qq|action=readmessage&amp;sessionid=$thissession&amp;folder=$escapedfolder&amp;message_id=$escapedmessageid" title="$lang_text{'backto'} $printfolder"><IMG SRC="$config{'ow_htmlurl'}/images/iconsets/$prefs{'iconset'}/owm.gif" border="0" ALT="$lang_text{'backto'} $printfolder"></a> \n|;
   }
   $temphtml .= qq|<a href="$config{'ow_cgiurl'}/openwebmail-main.pl?sessionid=$thissession&amp;action=logout" title="$lang_text{'logout'} $prefs{'email'}"><IMG SRC="$config{'ow_htmlurl'}/images/iconsets/$prefs{'iconset'}/logout.gif" border="0" ALT="$lang_text{'logout'} $prefs{'email'}"></a> &nbsp; \n|;

   $html =~ s/\@\@\@MENUBARLINKS\@\@\@/$temphtml/g;


   my $time = timelocal("0","0","12", $day, $month-1, $year-1900);

   my ($prev_year, $prev_month, $prev_day)=(localtime($time-86400*7))[5,4,3];
   $prev_year+=1900; $prev_month++;
   $temphtml=qq|<a href="|.$cal_url.
             qq|action=calweek&year=$prev_year&month=$prev_month&day=$prev_day" title="$lang_calendar{'weekview'} |.formatted_date($prev_year,$prev_month,$prev_day).qq|"><IMG SRC="$config{'ow_htmlurl'}/images/iconsets/$prefs{'iconset'}/left.gif" border="0" ALT="$lang_calendar{'weekview'} |.formatted_date($prev_year,$prev_month,$prev_day).qq|"></a> \n|;
   $html =~ s/\@\@\@PREV_LINK\@\@\@/$temphtml/g;

   my ($next_year, $next_month, $next_day)=(localtime($time+86400*7))[5,4,3];
   $next_year+=1900; $next_month++;
   $temphtml=qq|<a href="|.$cal_url.
             qq|action=calweek&year=$next_year&month=$next_month&day=$next_day" title="$lang_calendar{'weekview'} |.formatted_date($next_year,$next_month,$next_day).qq|"><IMG SRC="$config{'ow_htmlurl'}/images/iconsets/$prefs{'iconset'}/right.gif" border="0" ALT="$lang_calendar{'weekview'} |.formatted_date($next_year,$next_month,$next_day).qq|"></a> \n|;
   $html =~ s/\@\@\@NEXT_LINK\@\@\@/$temphtml/g;

   my $start_time;
   if ($prefs{'calendar_weekstart'} eq "S") {
      $html =~ s!\@\@\@WEEKDAY0\@\@\@!<font color=#cc0000>$lang_wday{'0'}</font>!;
      $html =~ s!\@\@\@WEEKDAY1\@\@\@!$lang_wday{'1'}!;
      $html =~ s!\@\@\@WEEKDAY2\@\@\@!$lang_wday{'2'}!;
      $html =~ s!\@\@\@WEEKDAY3\@\@\@!$lang_wday{'3'}!;
      $html =~ s!\@\@\@WEEKDAY4\@\@\@!$lang_wday{'4'}!;
      $html =~ s!\@\@\@WEEKDAY5\@\@\@!$lang_wday{'5'}!;
      $html =~ s!\@\@\@WEEKDAY6\@\@\@!<font color=#00aa00>$lang_wday{'6'}</font>!;
      my %wdaynum = qw (Sun 0 Mon 1 Tue 2 Wed 3 Thu 4 Fri 5 Sat 6);
      my $day = localtime($time); $day =~ s/^(\w+).*$/$1/;
      $start_time = $time - (86400 * $wdaynum{$day});
   } else {
      $html =~ s!\@\@\@WEEKDAY0\@\@\@!$lang_wday{'1'}!;
      $html =~ s!\@\@\@WEEKDAY1\@\@\@!$lang_wday{'2'}!;
      $html =~ s!\@\@\@WEEKDAY2\@\@\@!$lang_wday{'3'}!;
      $html =~ s!\@\@\@WEEKDAY3\@\@\@!$lang_wday{'4'}!;
      $html =~ s!\@\@\@WEEKDAY4\@\@\@!$lang_wday{'5'}!;
      $html =~ s!\@\@\@WEEKDAY5\@\@\@!<font color=#00aa00>$lang_wday{'6'}</font>!;
      $html =~ s!\@\@\@WEEKDAY6\@\@\@!<font color=#cc0000>$lang_wday{'0'}</font>!;
      my %wdaynum = qw (Mon 0 Tue 1 Wed 2 Thu 3 Fri 4 Sat 5 Sun 6);
      my $day = localtime($time); $day =~ s/^(\w+).*$/$1/;
      $start_time = $time - (86400 * $wdaynum{$day});
   }

   my (%items, %indexes, $item_count);
   $item_count =readcalbook("$folderdir/.calendar.book", \%items, \%indexes, 0);
   $item_count+=readcalbook("$config{'global_calendarbook'}", \%items, \%indexes, 1E6) if (-f "$config{'global_calendarbook'}");

   for my $x (0..6) {
      ($year, $month, $day)=(localtime($start_time+$x*86400))[5,4,3];
      $year+=1900; $month++;

      my $bgcolor;
      if ($year==$current_year &&
          $month==$current_month &&
          $day==$current_day) {
         $bgcolor="bgcolor=$style{'tablerow_light'}";
      } else {
         $bgcolor="bgcolor=$style{'tablerow_dark'}";
      }

      $temphtml = qq|<td valign=top $bgcolor>|.
                  qq|<table width="100%" cellpadding=0 cellspacing=0>\n|;

      my $daystr=$day;
      $daystr=" ".$daystr if (length($daystr)<2);

      $temphtml .= start_form(-action=>"$config{'ow_cgiurl'}/openwebmail-cal.pl",
                              -name=> "day$day");
      $temphtml .= hidden(-name=>'sessionid',
                          -default=>$thissession,
                          -override=>'1');
      $temphtml .= hidden(-name=>'folder',
                          -value=>$folder,
                          -override=>'1');
      $temphtml .= hidden(-name=>'message_id',
                          -default=>$messageid,
                          -override=>'1');
      $temphtml .= hidden(-name=>'action',
                          -value=>'calday',
                          -override=>'1');
      $temphtml .= hidden(-name=>'year',
                          -value=>$year,
                          -override=>'1');
      $temphtml .= hidden(-name=>'month',
                          -value=>$month,
                          -override=>'1');
      $temphtml .= hidden(-name=>'day',
                          -value=>$day,
                          -override=>'1');
      $temphtml .= qq|<tr><td align=right>|.
                   lunar_str($year, $month, $day, $prefs{'charset'}).
                   submit("$daystr").
                   qq|</td></tr>|.
                   end_form();

      my $t=timelocal 1,1,1,$day,($month-1),($year-1900);
      my $dow=$wdaystr[(localtime($t))[6]];
      my $date=sprintf("%04d%02d%02d", $year, $month, $day);
      my $date2=sprintf("%04d,%02d,%02d,%s", $year,$month,$day,$dow);
      my $i=0;

      my @indexlist=();
      push(@indexlist, @{$indexes{$date}}) if (defined($indexes{$date}));
      push(@indexlist, @{$indexes{'*'}})   if (defined($indexes{'*'}));
      @indexlist=sort { ($items{$a}{'starthourmin'}||1E9)<=>($items{$b}{'starthourmin'}||1E9) } @indexlist;

      $temphtml .= qq|<tr><td align=left valign=bottom>|;
      for my $index (@indexlist) {
         if ($date=~/$items{$index}{'idate'}/ ||
             $date2=~/$items{$index}{'idate'}/) {
            $temphtml .= qq|<br>\n| if ( $i>0);
            $temphtml .= month_week_item($items{$index}, $cal_url.qq|action=calday&year=$year&month=$month&day=$day|, ($index>=1E6));
            $i++;
         }
      }
      $temphtml .= qq|&nbsp;<br>\n| if ($i==0);
      $temphtml .= qq|</td></tr></table></td>\n|;

      $html =~ s/\@\@\@DAY$x\@\@\@/$temphtml/;
   }

   print $html;
   printfooter(2);
}

# print an item in the month or week view
sub month_week_item {
   my ($r_item, $daylink, $is_global) = @_;

   my $t='#';
   if (${$r_item}{'starthourmin'} ne "0") {
      $t = hourmin2str(${$r_item}{'starthourmin'}, $prefs{'calendar_hourformat'});
      if (${$r_item}{'endhourmin'} ne "0") {
         $t.= qq|-| . hourmin2str(${$r_item}{'endhourmin'}, $prefs{'calendar_hourformat'});
      }
   }

   my $s=${$r_item}{'string'};
   my $nohtml=$s; $nohtml=~ s/<.*?>//g;
   $s=substr($nohtml, 0, 36)."..." if (length($nohtml)>40);
   $s=qq|$s *| if ($is_global);

   my $temphtml=qq|<font color=#c00000>$t</font><br>|;
   $temphtml .= qq|<a href=${$r_item}{'link'}>| if (${$r_item}{'link'});
   $temphtml .= $s;
   $temphtml .= qq|</a>\n| if (${$r_item}{'link'});
   return($temphtml);
}
######################## END WEEKVIEW #########################

########################## DAYVIEW ###########################
sub dayview {
   my ($year, $month, $day)=@_;
   my $g2l=time()+timeoffset2seconds($prefs{'timeoffset'}); # trick makes gmtime($g2l) return localtime in timezone of timeoffsset
   my ($current_year, $current_month, $current_day)=(gmtime($g2l))[5,4,3];
   $current_year+=1900; $current_month++;

   $year = $current_year if (!$year);
   $month = $current_month if (!$month);
   $day = $current_day if (!$day);

   printheader();

   my $html = '';
   my $temphtml;
   open (DAYVIEW, "$config{'ow_etcdir'}/templates/$prefs{'language'}/dayview.template") or
      openwebmailerror("$lang_err{'couldnt_open'} $config{'ow_etcdir'}/templates/$prefs{'language'}/dayview.template!");
   while (<DAYVIEW>) {
      $html .= $_;
   }
   close (DAYVIEW);

   $html = applystyle($html);

   $temphtml = startform(-name=>"yearform",
			 -action=>"$config{'ow_cgiurl'}/openwebmail-cal.pl") .
               hidden(-name=>'action',
                      -default=>'calday',
                      -override=>'1').
               hidden(-name=>'month',
                      -default=>$month,
                      -override=>'1').
               hidden(-name=>'day',
                      -default=>$day,
                      -override=>'1').
               hidden(-name=>'sessionid',
                      -default=>$thissession,
                      -override=>'1').
               hidden(-name=>'folder',
                      -default=>$folder,
                      -override=>'1').
               hidden(-name=>'message_id',
                      -default=>$messageid,
                      -override=>'1');
   $html =~ s/\@\@\@STARTFORM\@\@\@/$temphtml/g;

   $temphtml = textfield(-name=>'year',
                         -default=>$year,
                         -size=>'4',
                         -override=>'1');

   $html =~ s/\@\@\@YEARFIELD\@\@\@/$lang_text{'calfmt_year'}/g;
   $html =~ s/\@\@\@YEAR\@\@\@/ $temphtml /;

   $temphtml = end_form();
   $html =~ s/\@\@\@ENDFORM\@\@\@/$temphtml/g;

   my $cal_url=qq|$config{'ow_cgiurl'}/openwebmail-cal.pl?sessionid=$thissession&amp;folder=$escapedfolder&amp;message_id=$escapedmessageid&amp;|;

   $temphtml  = qq|<a href="|.$cal_url.
                qq|action=calyear&year=$year" title="$lang_calendar{'yearview'} |.formatted_date($year).qq|"><IMG SRC="$config{'ow_htmlurl'}/images/iconsets/$prefs{'iconset'}/yearview.gif" border="0" ALT="$lang_calendar{'yearview'} |.formatted_date($year).qq|"></a> \n|;
   $temphtml .= qq|<a href="|.$cal_url.
                qq|action=calmonth&year=$year&month=$month" title="$lang_calendar{'monthview'} |.formatted_date($year,$month).qq|"><IMG SRC="$config{'ow_htmlurl'}/images/iconsets/$prefs{'iconset'}/monthview.gif" border="0" ALT="$lang_calendar{'monthview'} |.formatted_date($year,$month).qq|"</a> \n|;
   $temphtml .= qq|<a href="|.$cal_url.
                qq|action=calweek&year=$year&month=$month&day=$day" title="$lang_calendar{'weekview'} |.formatted_date($year,$month,$day).qq|"><IMG SRC="$config{'ow_htmlurl'}/images/iconsets/$prefs{'iconset'}/weekview.gif" border="0" ALT="$lang_calendar{'weekview'} |.formatted_date($year,$month,$day).qq|"></a> \n|;
   $temphtml .= qq|<a href="|.$cal_url.
                qq|action=calday&year=$year&month=$month&day=$day" title="$lang_calendar{'dayview'} |.formatted_date($year,$month,$day).qq|"><IMG SRC="$config{'ow_htmlurl'}/images/iconsets/$prefs{'iconset'}/dayview.gif" border="0" ALT="$lang_calendar{'dayview'} |.formatted_date($year,$month,$day).qq|"></a> \n|;
   if ($year!=$current_year || $month!=$current_month || $day!=$current_day) {
      $temphtml .= qq|<a href="|.$cal_url.
                   qq|action=calday&year=$current_year&month=$current_month&day=$current_day" title="$lang_text{'backto'} |.formatted_date($current_year,$current_month,$current_day).qq|"><IMG SRC="$config{'ow_htmlurl'}/images/iconsets/$prefs{'iconset'}/refresh.gif" border="0" ALT="$lang_text{'backto'} |.formatted_date($current_year,$current_month,$current_day).qq|"></a> \n|;
   }
   $temphtml .= "&nbsp \n";
   if ($messageid eq "") {
      $temphtml .= qq|<a href="$config{'ow_cgiurl'}/openwebmail-main.pl?|.
                   qq|action=displayheaders&amp;sessionid=$thissession&amp;folder=$escapedfolder" title="$lang_text{'backto'} $printfolder"><IMG SRC="$config{'ow_htmlurl'}/images/iconsets/$prefs{'iconset'}/owm.gif" border="0" ALT="$lang_text{'backto'} $printfolder"></a> \n|;
   } else {
      $temphtml .= qq|<a href="$config{'ow_cgiurl'}/openwebmail-read.pl?|.
                   qq|action=readmessage&amp;sessionid=$thissession&amp;folder=$escapedfolder&amp;message_id=$escapedmessageid" title="$lang_text{'backto'} $printfolder"><IMG SRC="$config{'ow_htmlurl'}/images/iconsets/$prefs{'iconset'}/owm.gif" border="0" ALT="$lang_text{'backto'} $printfolder"></a> \n|;
   }
   $temphtml .= qq|<a href="$config{'ow_cgiurl'}/openwebmail-main.pl?sessionid=$thissession&amp;action=logout" title="$lang_text{'logout'} $prefs{'email'}"><IMG SRC="$config{'ow_htmlurl'}/images/iconsets/$prefs{'iconset'}/logout.gif" border="0" ALT="$lang_text{'logout'} $prefs{'email'}"></a> &nbsp; \n|;

   $html =~ s/\@\@\@MENUBARLINKS\@\@\@/$temphtml/g;

   my $time = timelocal("0","0","12", $day, $month-1, $year-1900);

   my ($prev_year, $prev_month, $prev_day)=(localtime($time-86400))[5,4,3];
   $prev_year+=1900; $prev_month++;
   $temphtml=qq|<a href="|.$cal_url.
             qq|action=calday&year=$prev_year&month=$prev_month&day=$prev_day" title="|.formatted_date($prev_year,$prev_month,$prev_day).qq|"><IMG SRC="$config{'ow_htmlurl'}/images/iconsets/$prefs{'iconset'}/left.gif" border="0" ALT="|.formatted_date($prev_year,$prev_month,$prev_day).qq|"></a> \n|;
   $html =~ s/\@\@\@PREV_LINK\@\@\@/$temphtml/g;

   my ($next_year, $next_month, $next_day)=(localtime($time+86400))[5,4,3];
   $next_year+=1900; $next_month++;
   $temphtml=qq|<a href="|.$cal_url.
             qq|action=calday&year=$next_year&month=$next_month&day=$next_day" title="|.formatted_date($next_year,$next_month,$next_day).qq|"><IMG SRC="$config{'ow_htmlurl'}/images/iconsets/$prefs{'iconset'}/right.gif" border="0" ALT="|.formatted_date($next_year,$next_month,$next_day).qq|"></a> \n|;
   $html =~ s/\@\@\@NEXT_LINK\@\@\@/$temphtml/g;


   my (%items, %indexes, $item_count);
   $item_count =readcalbook("$folderdir/.calendar.book", \%items, \%indexes, 0);
   $item_count+=readcalbook("$config{'global_calendarbook'}", \%items, \%indexes, 1E6) if (-f "$config{'global_calendarbook'}");

   my $t=timelocal(1, 1, 1, $day, $month-1, $year-1900);
   my $wdaynum=(localtime($t))[6];

   $temphtml = formatted_date($year, $month, $day, $wdaynum);
   $temphtml .= qq| &nbsp; |.lunar_str($year, $month, $day, $prefs{'charset'});
   $html =~ s/\@\@\@CALTITLE\@\@\@/$temphtml/g;

   my $dow=$wdaystr[$wdaynum];
   my $date=sprintf("%04d%02d%02d", $year, $month, $day);
   my $date2=sprintf("%04d,%02d,%02d,%s", $year,$month,$day,$dow);
   my @indexlist=();
   push(@indexlist, @{$indexes{$date}}) if (defined($indexes{$date}));
   push(@indexlist, @{$indexes{'*'}})   if (defined($indexes{'*'}));
   @indexlist=sort { ($items{$a}{'starthourmin'}||1E9)<=>($items{$b}{'starthourmin'}||1E9) } @indexlist;

   my @bgcolor=($style{"tablerow_dark"}, $style{"tablerow_light"});
   my $colornum=0;
   my $itemcount=0;
   $temphtml='';
   for (my $t=0; $t<2400; $t+=100) {
      my $timestr=hourmin2str(sprintf("%04d",$t), $prefs{'calendar_hourformat'});
      my $y = 0;
      for my $index (@indexlist) {
         next if ($items{$index}{'starthourmin'} eq "0"|| !$index); # find timed items
         if ($date=~/$items{$index}{'idate'}/ ||
             $date2=~/$items{$index}{'idate'}/) {
            if ($items{$index}{'starthourmin'}>=$t && $items{$index}{'starthourmin'}< $t+100 ) {
               if (!$y) {
                  $colornum=($colornum+1)%2;
                  $temphtml .= qq|<tr>|.
                               qq|<td bgcolor=$bgcolor[$colornum] align=right nowrap>$timestr</td>|.
                               qq|<td bgcolor=$bgcolor[$colornum]>|.
                               qq|<table width=100% border=0 cellpadding=2>\n|;
               }
               $temphtml .= qq|<tr valign=top>|;
               $temphtml .= dayview_table_item($items{$index}, $cal_url, "&year=$year&month=$month&day=$day&index=$index", ($index>=1E6));
               $temphtml .= qq|</tr>|;
               $itemcount++;
               $y++;
            }
         }
      }
      $temphtml .= qq|</table></td></tr>\n| if $y;

      if (!$y && $prefs{'calendar_showemptyhours'} &&
          $t>=$prefs{'calendar_starthour'} && $t<=$prefs{'calendar_endhour'}) {
         $colornum=($colornum+1)%2;
         $temphtml .= qq|<tr><td bgcolor=$bgcolor[$colornum] align=right nowrap>$timestr</td>|.
                      qq|<td bgcolor=$bgcolor[$colornum]>&nbsp;</td></tr>\n|;
      }
   }

   my $y = 0;
   for my $index (@indexlist) {
      next if ($items{$index}{'starthourmin'} ne "0"|| !$index); # find non-timed items
      if ($date=~/$items{$index}{'idate'}/ ||
          $date2=~/$items{$index}{'idate'}/) {
         if (!$y) {
            $colornum=($colornum+1)%2;
            $temphtml .= qq|<tr>|.
                         qq|<td bgcolor=$bgcolor[$colornum]>&nbsp;</td>|.
                         qq|<td bgcolor=$bgcolor[$colornum]>|.
                         qq|<table width=100% border=0 cellpadding=2>\n|;
         }
         $temphtml .= qq|<tr valign=top>|;
         $temphtml .= dayview_table_item($items{$index}, $cal_url, "&year=$year&month=$month&day=$day&index=$index", ($index>=1E6));
         $temphtml .= qq|</tr>|;
         $itemcount++;
         $y++;
      }
   }
   $temphtml .= qq|</table></td></tr>\n| if $y;

   if ($itemcount==0) {
      $colornum=($colornum+1)%2;
      $temphtml .= qq|<tr><td bgcolor=$bgcolor[$colornum]>&nbsp;</td><td align=center bgcolor=$bgcolor[$colornum]>$lang_text{'noitemforthisday'}</td></tr>\n|;
   }
   $html =~ s/\@\@\@CALENDARITEMS\@\@\@/$temphtml/;

   $temphtml = startform(-action=>"$config{'ow_cgiurl'}/openwebmail-cal.pl",
                         -name=>'AddItemForm');
   $temphtml .= hidden(-name=>'sessionid',
                       -value=>$thissession,
                       -override=>'1');
   $temphtml .= hidden(-name=>'folder',
                       -value=>$folder,
                       -override=>'1');
   $temphtml .= hidden(-name=>'message_id',
                       -default=>$messageid,
                       -override=>'1');
   $temphtml .= hidden(-name=>'action',
                       -value=>'caladd',
                       -override=>'1');
   $temphtml .= hidden(-name=>'year',
                       -value=>$year,
                       -override=>'1');
   $temphtml .= hidden(-name=>'month',
                       -value=>$month,
                       -override=>'1');
   $temphtml .= hidden(-name=>'day',
                       -value=>$day,
                       -override=>'1');
   $html =~ s/\@\@\@STARTADDITEMFORM\@\@\@/$temphtml/;

   $temphtml = textfield(-name=>'string',
                         -default=>'',
                         -size=>'30',
                         -override=>'1');
   $html =~ s/\@\@\@STRINGFIELD\@\@\@/$temphtml/;

   my @hourlist;
   if ($prefs{'calendar_hourformat'}==12) {
      @hourlist=qw(none 1 2 3 4 5 6 7 8 9 10 11 12);
   } else {
      @hourlist=qw(none 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23);
   }
   my %numlabels=( none=>$lang_text{'none'},
                   0=>'00', 1=>'01', 2=>'02', 3=>'03', 4=>'04',
                   5=>'05', 6=>'06', 7=>'07', 8=>'08', 9=>'09');
   my $temphtml2;

   $temphtml = $lang_text{'calfmt_hourminampm'};
   $temphtml2 = popup_menu(-name=>'starthour',
                           -values=>\@hourlist,
                           -default=>'none',
                           -labels=>\%numlabels);
   $temphtml2 .= " <B>:</B> ";
   $temphtml2 .= popup_menu(-name=>'startmin',
                            -values=>[0,5,10,15,20,25,30,35,40,45,50,55],
                            -default=>0,
                            -labels=>\%numlabels);
   $temphtml =~ s/\@\@\@HOURMIN\@\@\@/$temphtml2/;
   if ($prefs{'calendar_hourformat'}==12) {
      $temphtml2 = popup_menu(-name=>'startampm',
                              -values=>['am','pm'],
                              -default=>'am',
                              -labels=>{ am=>$lang_text{'am'}, pm=>$lang_text{'pm'} } );
   } else {
      $temphtml2 ="";
   }
   $temphtml =~ s/\@\@\@AMPM\@\@\@/$temphtml2/;

   $html =~ s/\@\@\@STARTHOURMINMENU\@\@\@/$temphtml/;

   $temphtml = $lang_text{'calfmt_hourminampm'};
   $temphtml2 = popup_menu(-name=>'endhour',
                           -values=>\@hourlist,
                           -default=>'none',
                           -labels=>\%numlabels);
   $temphtml2 .= " <B>:</B> ";
   $temphtml2 .= popup_menu(-name=>'endmin',
                            -values=>[0,5,10,15,20,25,30,35,40,45,50,55],
                            -default=>0,
                            -labels=>\%numlabels);
   $temphtml =~ s/\@\@\@HOURMIN\@\@\@/$temphtml2/;
   if ($prefs{'calendar_hourformat'}==12) {
      $temphtml2 = popup_menu(-name=>'endampm',
                              -values=>['am','pm'],
                              -default=>'am',
                              -labels=>{ am=>$lang_text{'am'}, pm=>$lang_text{'pm'} } );
   } else {
      $temphtml2 ="";
   }
   $temphtml =~ s/\@\@\@AMPM\@\@\@/$temphtml2/;

   $html =~ s/\@\@\@ENDHOURMINMENU\@\@\@/$temphtml/;

   my %wdaynum = qw (Sun 0 Mon 1 Tue 2 Wed 3 Thu 4 Fri 5 Sat 6);
   my $weekorder=int(($day+6)/7);
   my %freqlabels = ('todayonly'           =>$lang_text{'today_only'},
                     'thewdayofthismonth'  =>"$lang_text{'the_wday_of_thismonth'} $lang_order{$weekorder} $lang_wday{$wdaynum{$dow}} $lang_text{'the_wday_of_thismonth2'}",
                     'everywdayofthismonth'=>"$lang_text{'every_wday_of_thismonth'} $lang_wday{$wdaynum{$dow}}  $lang_text{'every_wday_of_thismonth2'}" );
   if ($weekorder<=4) {
      $temphtml .= hidden(-name=>'weekorder',
                          -value=>$weekorder,
                          -override=>'1');
      $temphtml = popup_menu(-name=>'freq',
                             -values=>['todayonly', 'thewdayofthismonth', 'everywdayofthismonth'],
                             -labels=>\%freqlabels);
   } else {
      $temphtml = popup_menu(-name=>'freq',
                             -values=>['today', 'everywday'],
                             -labels=>\%freqlabels);
   }
   $html =~ s/\@\@\@FREQMENU\@\@\@/$temphtml/;

   $temphtml = checkbox(-name=>'todayandnextndays',
                        -value=>'1',
                        -checked=>0,
                        -label=>'');
   $html =~ s/\@\@\@TODAYANDNEXTNDAYSCHECKBOX\@\@\@/$temphtml/g;

   $temphtml = textfield(-name=>'ndays',
                         -default=>'',
                         -size=>'2',
                         -override=>'1');
   $html =~ s/\@\@\@NDAYSFIELD\@\@\@/$temphtml/;

   $temphtml = checkbox(-name=>'everymonth',
                        -value=>'1',
                        -checked=>0,
                        -label=>'');
   $html =~ s/\@\@\@EVERYMONTHCHECKBOX\@\@\@/$temphtml/g;

   $temphtml = checkbox(-name=>'everyyear',
                        -value=>'1',
                        -checked=>0,
                        -label=>'');
   $html =~ s/\@\@\@EVERYYEARCHECKBOX\@\@\@/$temphtml/g;

   $temphtml = textfield(-name=>'link',
                         -default=>'http://',
                         -size=>'30',
                         -override=>'1');
   $html =~ s/\@\@\@LINKFIELD\@\@\@/$temphtml/;

   $temphtml = submit("$lang_text{'save'}");
   $html =~ s/\@\@\@SUBMITBUTTON\@\@\@/$temphtml/;

   $temphtml = end_form();
   $html =~ s/\@\@\@ENDFORM\@\@\@/$temphtml/g;

   print $html;
   printfooter(2);
}

# print an item in the day view table
sub dayview_table_item {
   my ($r_item, $cal_url, $cgi_parm, $is_global) = @_;
   my $temphtml='';
   my $timestr='';
   if (${$r_item}{'starthourmin'} ne "0") {
      $timestr = hourmin2str(${$r_item}{'starthourmin'}, $prefs{'calendar_hourformat'});
      if (${$r_item}{'endhourmin'} ne "0") {
         $timestr .= qq|-| . hourmin2str(${$r_item}{'endhourmin'}, $prefs{'calendar_hourformat'});
      }
   }
   $timestr = "<font color=#c00000>$timestr</font>" if ($timestr ne "");

   if (${$r_item}{'string'}) {
      if (${$r_item}{'link'} eq "0") {
         $temphtml .= qq|<td>$timestr ${$r_item}{'string'}</td>\n|;
      } else {
         $temphtml .= qq|<td>$timestr <a href="${$r_item}{'link'}">${$r_item}{'string'}</a></td>\n|;
      }
   } else {
      $temphtml .= qq|<td>&nbsp;</td>\n|;
   }

   if ($is_global) {
      $temphtml .= "<td>&nbsp;</td>\n";
   } elsif (${$r_item}{'idate'} =~ /[^\d]/) {
      $temphtml .= qq|<td align=right nowrap>\n|.
                   qq|<a href=$cal_url|.qq|action=caledit$cgi_parm onclick=\"return confirm('$lang_text{'multieditconf'}')\">[$lang_text{'ed'}]</a>\n|.
                   qq|<a href=$cal_url|.qq|action=caldel$cgi_parm onclick=\"return confirm('$lang_text{'multidelconf'}')\">[$lang_text{'del'}]</a>\n|.
                   qq|</td>\n|;
   } else {
      $temphtml .= qq|<td align=right nowrap>\n|.
                   qq|<a href=$cal_url|.qq|action=caledit$cgi_parm>[$lang_text{'ed'}]</a>\n|.
                   qq|<a href=$cal_url|.qq|action=caldel$cgi_parm>[$lang_text{'del'}]</a>\n|.
                   qq|</td>\n|;
   }

   return $temphtml;
}
######################## END DAYVIEW #########################

######################## EDIT_ITEM #########################
# display the edit menu of an event
sub edit_item {
   my ($year, $month, $day, $index)=@_;

   printheader();

   my $html = '';
   my $temphtml;
   open (EDITCALENDAR, "$config{'ow_etcdir'}/templates/$prefs{'language'}/editcalendar.template") or
      openwebmailerror("$lang_err{'couldnt_open'} $config{'ow_etcdir'}/templates/$prefs{'language'}/editcalendar.template!");
   while (<EDITCALENDAR>) {
      $html .= $_;
   }
   close (EDITCALENDAR);

   $html = applystyle($html);

   my ($item_count, %items, %indexes);
   $item_count =readcalbook("$folderdir/.calendar.book", \%items, \%indexes, 0);

   if (! defined($items{$index}) ) {
      openwebmailerror("editcal - item missing");
   }

   $temphtml = formatted_date($year, $month, $day);
   $html =~ s/\@\@\@DATE\@\@\@/$temphtml/;

   $temphtml = startform(-action=>"$config{'ow_cgiurl'}/openwebmail-cal.pl",
                         -name=>'editcalendar');
   $temphtml .= hidden(-name=>'sessionid',
                       -value=>$thissession,
                       -override=>'1');
   $temphtml .= hidden(-name=>'folder',
                       -value=>$folder,
                       -override=>'1');
   $temphtml .= hidden(-name=>'message_id',
                       -default=>$messageid,
                       -override=>'1');
   $temphtml .= hidden(-name=>'action',
                       -value=>'calupdate',
                       -override=>'1');
   $temphtml .= hidden(-name=>'year',
                       -value=>$year,
                       -override=>'1');
   $temphtml .= hidden(-name=>'month',
                       -value=>$month,
                       -override=>'1');
   $temphtml .= hidden(-name=>'day',
                       -value=>$day,
                       -override=>'1');
   $temphtml .= hidden(-name=>'index',
                       -value=>$index,
                       -override=>'1');
   $html =~ s/\@\@\@STARTFORM\@\@\@/$temphtml/;

   $temphtml = textfield(-name=>'string',
                         -default=>$items{$index}{'string'},
                         -size=>'25',
                         -override=>'1');
   $html =~ s/\@\@\@STRINGFIELD\@\@\@/$temphtml/;

   my @hourlist;
   if ($prefs{'calendar_hourformat'}==12) {
      @hourlist=qw(none 1 2 3 4 5 6 7 8 9 10 11 12);
   } else {
      @hourlist=qw(none 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23);
   }
   my %numlabels=( none=>$lang_text{'none'},
                   0=>'00', 1=>'01', 2=>'02', 3=>'03', 4=>'04',
                   5=>'05', 6=>'06', 7=>'07', 8=>'08', 9=>'09');
   my $temphtml2;

   my ($starthour, $startmin, $startampm)=('none', 0, 'am');
   if ($items{$index}{'starthourmin'} =~ /0*(\d+)(\d{2})$/) {
      ($starthour, $startmin)=($1, $2);
      ($starthour, $startampm)=hour24to12($starthour) if ($prefs{'calendar_hourformat'}==12);
   }

   $temphtml = $lang_text{'calfmt_hourminampm'};
   $temphtml2 = popup_menu(-name=>'starthour',
                          -values=>\@hourlist,
                          -default=>$starthour,
                          -labels=>\%numlabels);
   $temphtml2 .= "<B>:</B>";
   $temphtml2 .= popup_menu(-name=>'startmin',
                           -values=>[0,5,10,15,20,25,30,35,40,45,50,55],
                           -default=>$startmin,
                           -labels=>\%numlabels);
   $temphtml =~ s/\@\@\@HOURMIN\@\@\@/$temphtml2/;
   if ($prefs{'calendar_hourformat'}==12) {
      $temphtml2 = popup_menu(-name=>'startampm',
                              -values=>['am','pm'],
                              -default=>$startampm,
                              -labels=>{ am=>$lang_text{'am'}, pm=>$lang_text{'pm'} } );
   }
   $temphtml =~ s/\@\@\@AMPM\@\@\@/$temphtml2/;
   $html =~ s/\@\@\@STARTHOURMINMENU\@\@\@/$temphtml/;

   my ($endhour, $endmin, $endampm)=('none', 0, 'am');
   if ($items{$index}{'endhourmin'} =~ /0*(\d+)(\d{2})$/) {
      ($endhour, $endmin)=($1, $2);
      ($endhour, $endampm)=hour24to12($endhour) if ($prefs{'calendar_hourformat'}==12);
   }

   $temphtml = $lang_text{'calfmt_hourminampm'};
   $temphtml2 = popup_menu(-name=>'endhour',
                           -values=>\@hourlist,
                           -default=>$endhour,
                           -labels=>\%numlabels);
   $temphtml2 .= "<B>:</B>";
   $temphtml2 .= popup_menu(-name=>'endmin',
                            -values=>[0,5,10,15,20,25,30,35,40,45,50,55],
                            -default=>$endmin,
                            -labels=>\%numlabels);
   $temphtml =~ s/\@\@\@HOURMIN\@\@\@/$temphtml2/;
   if ($prefs{'calendar_hourformat'}==12) {
      $temphtml2 = popup_menu(-name=>'endampm',
                              -values=>['am','pm'],
                              -default=>$endampm,
                              -labels=>{ am=>$lang_text{'am'}, pm=>$lang_text{'pm'} } );
   }
   $temphtml =~ s/\@\@\@AMPM\@\@\@/$temphtml2/;
   $html =~ s/\@\@\@ENDHOURMINMENU\@\@\@/$temphtml/;

   my $linkstr=$items{$index}{'link'};
   $linkstr="" if ($linkstr eq "0");
   $temphtml = textfield(-name=>'link',
                         -default=>$linkstr,
                         -size=>'25',
                         -override=>'1');
   $html =~ s/\@\@\@LINKFIELD\@\@\@/$temphtml/;

   $temphtml = submit("$lang_text{'save'}");
   $html =~ s/\@\@\@SUBMITBUTTON\@\@\@/$temphtml/;

   $temphtml = startform(-action=>"$config{'ow_cgiurl'}/openwebmail-cal.pl",
                         -name=>'editcalendar');
   $temphtml .= hidden(-name=>'sessionid',
                       -value=>$thissession,
                       -override=>'1');
   $temphtml .= hidden(-name=>'folder',
                       -value=>$folder,
                       -override=>'1');
   $temphtml .= hidden(-name=>'message_id',
                       -default=>$messageid,
                       -override=>'1');
   $temphtml .= hidden(-name=>'action',
                       -value=>'calday',
                       -override=>'1');
   $temphtml .= hidden(-name=>'year',
                       -value=>$year,
                       -override=>'1');
   $temphtml .= hidden(-name=>'month',
                       -value=>$month,
                       -override=>'1');
   $temphtml .= hidden(-name=>'day',
                       -value=>$day,
                       -override=>'1');
   $temphtml .= submit("$lang_text{'cancel'}");
   $html =~ s/\@\@\@CANCELBUTTON\@\@\@/$temphtml/;

   $temphtml = end_form();
   $html =~ s/\@\@\@ENDFORM\@\@\@/$temphtml/g;

   print $html;
   printfooter(2);
}
######################## END EDIT_ITEM #########################

######################## ADD_ITEM #########################
# add an item to user calendar
sub add_item {
   my ($year, $month, $day,
       $string,
       $starthour, $startmin, $startampm,
       $endhour, $endmin, $endampm,
       $freq, $weekorder,
       $todayandnextndays, $ndays,
       $everymonth,
       $everyyear,
       $link)=@_;
   my $line;
   return if ($string=~/^\s?$/);

   # check for bad input that would kill our database format
   if ($string =~ /\@\@\@/) {
      openwebmailerror("$lang_err{'pipe_char_not_allowed'}");
   }
   if ($link =~ /\@\@\@/) {
      openwebmailerror("$lang_err{'pipe_char_not_allowed'}");
   }
   # check for bad input that would confuse our database format
   if ($string =~ /\@$/) {
      $string=$string." ";
   } elsif ($string =~ /^\@/) {
      $string=" ".$string;
   }
   if ($link =~ /\@$/) {
      $link=$link." ";
   } elsif ($link =~ /^\@/) {
      $link=" ".$link;
   }
   $link=0 if ($link !~ m!://[^\s]+!);

   # translate time format to military time.
   my $starthourmin=0;
   my $endhourmin=0;
   if ($starthour =~ /\d+/) {
      if ($prefs{'calendar_hourformat'}==12) {
         $starthour+=12 if ($startampm eq "pm" && $starthour< 12);
         $starthour=0   if ($startampm eq "am" && $starthour==12);
      }
      $starthourmin = sprintf("%02d%02d", $starthour,$startmin);
   }
   if ($endhour =~ /\d+/) {
      if ($prefs{'calendar_hourformat'}==12) {
         $endhour+=12 if ($endampm eq "pm" && $endhour< 12);
         $endhour=0   if ($endampm eq "am" && $endhour==12);
      }
      $endhourmin = sprintf("%02d%02d", $endhour,$endmin);
   }

   my (%items, %indexes, $item_count);
   $item_count=readcalbook("$folderdir/.calendar.book", \%items, \%indexes, 0);

   my $index = $item_count+19690404;	# avoid collision with old records
   my $t = timelocal(1,1,1,$day, $month-1, $year-1900);
   my $dow = $wdaystr[(localtime($t))[6]];
   my $records = "";

   # construct the record.
   if (($freq eq 'todayonly') && (!$everymonth) && (!$everyyear)) {
      if ($todayandnextndays && $ndays) {
         if ($ndays !~ /\d+/) {
            openwebmailerror("$lang_err{'badnum_in_days'}: $ndays");
         }
         my $date_wild='(';
         for (my $i=0; $i<=$ndays; $i++) {
            my ($y, $m, $d)=(localtime($t+86400*$i))[5,4,3];
            my $date=sprintf("%04d%02d%02d", $y+1900, $m+1, $d);
            $date_wild.='|' if ($i>0);
            $date_wild.=sprintf("%04d%02d%02d", $y+1900, $m+1, $d);
         }
         $date_wild.=')';
         $items{$index}{'idate'}=$date_wild;
      } else {
         $items{$index}{'idate'}=sprintf("%04d%02d%02d", $year, $month, $day);
      }

   } elsif ($freq eq 'thewdayofthismonth') {
      my %weekorder_day_wild= ( 1 => "0[1-7]",
                                2 => "((0[8-9])|(1[0-4]))",
                                3 => "((1[5-9])|(2[0-1]))",
                                4 => "2[2-8]" );
      my $year_wild=sprintf("%04d", $year);
      my $month_wild=sprintf("%02d", $month);
      my $day_wild=sprintf("%02d", $day);
      $day_wild=$weekorder_day_wild{$weekorder} if ($weekorder_day_wild{$weekorder} ne "");
      $month_wild = ".*" if ($everymonth);
      $year_wild = ".*" if ($everyyear);
      $items{$index}{'idate'}="$year_wild,$month_wild,$day_wild,$dow";

   } else { # everywdayofthismonth and else...
      my $year_wild=sprintf("%04d", $year);
      my $month_wild=sprintf("%02d", $month);
      $month_wild = ".*" if ($everymonth);
      $year_wild = ".*" if ($everyyear);
      if ($freq eq 'everywdayofthismonth') {
         $items{$index}{'idate'}="$year_wild,$month_wild,.*,$dow";
      } else {
         my $daystr=sprintf("%02d", $day);
         $items{$index}{'idate'}="$year_wild,$month_wild,$daystr,.*";
      }
   }

   $items{$index}{'starthourmin'}="$starthourmin"; # " is required or "0000" will be treated as 0?
   $items{$index}{'endhourmin'}="$endhourmin";
   $items{$index}{'string'}=$string;
   $items{$index}{'link'}=$link;

   writecalbook("$folderdir/.calendar.book", \%items);

   my $msg="additem - start=$starthourmin, end=$endhourmin, str=$string";
   writelog($msg);
   writehistory($msg);
}
######################## END ADD_ITEM #########################

######################## DEL_ITEM #########################
# delete an item from user calendar
sub del_item {
   my $index=$_[0];
   my $msg;

   my (%items, %indexes, $item_count);
   $item_count=readcalbook("$folderdir/.calendar.book", \%items, \%indexes, 0);

   return if (! defined($items{$index}) );

   my $msg="delitem - index=$index, t=$items{$index}{'starthourmin'}, str=$items{$index}{'string'}";
   delete $items{$index};

   writecalbook("$folderdir/.calendar.book", \%items);

   writelog($msg);
   writehistory($msg);
}

######################## END DEL_ITEM #########################

######################## REPLACE_ITEM #########################
# update an item in user calendar
sub update_item {
   my ($index, $string,
       $starthour, $startmin, $startampm,
       $endhour, $endmin, $endampm,
       $link)=@_;
   my $line;

   return if ($string=~/^\s?$/);

   # check for valid input
   if ($string =~ /\@{3}/) {
      openwebmailerror("$lang_err{'at_char_not_allowed'}");
   }
   if ($link =~ /\@{3}/) {
      openwebmailerror("$lang_err{'at_char_not_allowed'}");
   }
   # check for bad input that would confuse our database format
   if ($string =~ /\@$/) {
      $string=$string." ";
   } elsif ($string =~ /^\@/) {
      $string=" ".$string;
   }
   if ($link =~ /\@$/) {
      $link=$link." ";
   } elsif ($link =~ /^\@/) {
      $link=" ".$link;
   }
   $link=0 if ($link !~ m!://[^\s]+!);

   # translate time format to military time.
   my $starthourmin=0;
   my $endhourmin=0;
   if ($starthour =~ /\d+/) {
      if ($prefs{'calendar_hourformat'}==12) {
         $starthour+=12 if ($startampm eq "pm" && $starthour< 12);
         $starthour=0   if ($startampm eq "am" && $starthour==12);
      }
      $starthourmin = sprintf("%02d%02d", $starthour,$startmin);
   }
   if ($endhour =~ /\d+/) {
      if ($prefs{'calendar_hourformat'}==12) {
         $endhour+=12 if ($endampm eq "pm" && $endhour< 12);
         $endhour=0   if ($endampm eq "am" && $endhour==12);
      }
      $endhourmin = sprintf("%02d%02d", $endhour,$endmin);
   }

   my (%items, %indexes, $item_count);
   $item_count=readcalbook("$folderdir/.calendar.book", \%items, \%indexes, 0);
   if (! defined($items{$index}) ) {
      openwebmailerror("updatecal - item missing");
   }

   $items{$index}{'starthourmin'}="$starthourmin"; # " is required or "0000" will be treated as 0?
   $items{$index}{'endhourmin'}="$endhourmin";
   $items{$index}{'string'}=$string;
   $items{$index}{'link'}=$link;

   writecalbook("$folderdir/.calendar.book", \%items);

   my $msg="updateitem - index=$index, start=$starthourmin, end=$endhourmin, str=$string";
   writelog($msg);
   writehistory($msg);
}

######################## END REPLACE_ITEM #########################

######################## SET_DAYS_IN_MONTH #########################
# set the day number of each cell in the month calendar
sub set_days_in_month {
   my ($year, $month) = @_;

   my @days_in_month = qw(0 31 28 31 30 31 30 31 31 30 31 30 31);
   if ((($year % 4) == 0) && ((($year % 100) != 0) || (($year % 400) == 0))) {
      $days_in_month[2]++;
   }

   my %wdaynum;
   if ($prefs{'calendar_weekstart'} eq "S") {
      %wdaynum=qw(Sun 0 Mon 1 Tue 2 Wed 3 Thu 4 Fri 5 Sat 6);
   } else {
      %wdaynum=qw(Mon 0 Tue 1 Wed 2 Thu 3 Fri 4 Sat 5 Sun 6);
   }

   my $time = timelocal("0","0","12","1",$month-1,$year-1900);
   my $weekday = localtime($time); $weekday =~ s/^(\w+).*$/$1/;

   my @days;
   my $day_counter = 1;
   for my $x (0..5) {
      for my $y (0..6) {
         if ( ($x>0 || $y>=$wdaynum{$weekday}) &&
              $day_counter<=$days_in_month[$month] ) {
            $days[$x][$y] = $day_counter;
            $day_counter++;
         }
      }
   }
   return @days;
}
######################## END SET_DAYS_IN_MONTH #########################

######################## HOURMIN2STR #########################
# convert military time (eg:1700) to timestr (eg:05:00 pm)
sub hourmin2str {
   my ($hourmin, $hourformat) = @_;
   if ($hourmin =~ /(\d+)(\d{2})$/) {
      my ($hour, $min) = ($1, $2);
      $hour =~ s/^0(.+)/$1/;
      if ($hourformat==12) {
         my $ampm;
         ($hour, $ampm)=hour24to12($hour);
         $hourmin = $lang_text{'calfmt_hourminampm'};
         $hourmin =~ s/\@\@\@HOURMIN\@\@\@/$hour:$min/;
         $hourmin =~ s/\@\@\@AMPM\@\@\@/$lang_text{$ampm}/;
      } else {
         $hourmin = "$hour:$min";
      }
   }
   return $hourmin;
}

sub hour24to12 {
   my $hour=$_[0];
   my $ampm="am";

   $hour =~ s/^0(.+)/$1/;
   if ($hour==24||$hour==0) {
      $hour = 12;
   } elsif ($hour > 12) {
      $hour = $hour - 12;
      $ampm = "pm";
   } elsif ($hour == 12) {
      $ampm = "pm";
   }
   return($hour, $ampm);
}
######################## END HOURMIN2STR #########################

######################## FORMATTED_DATE #########################
# convert date to language dependent str based on the format
sub formatted_date {
   my ($year, $month, $day, $wday)=@_;
   my $fmtstr;
   if ($wday) {
      $fmtstr=$lang_text{'calfmt_yearmonthdaywday'};
   } elsif ($day) {
      $fmtstr=$lang_text{'calfmt_yearmonthday'};
   } elsif ($month) {
      $fmtstr=$lang_text{'calfmt_yearmonth'};
   } elsif ($year) {
      $fmtstr=$lang_text{'calfmt_year'};
   } else {
      return("");
   }
   $fmtstr=~s/\@\@\@YEAR\@\@\@/$year/ if ($year);
   $fmtstr=~s/\@\@\@MONTH_STR\@\@\@/$lang_month{$month}/ if ($month);
   $fmtstr=~s/\@\@\@DAY\@\@\@/$day/ if ($day);

   if (defined($wday)) {
      my $wdaystr=$lang_wday{$wday};
      if ($wday==0) {
         $wdaystr=qq|<font color=#cc0000>$wdaystr</font>|; # sunday
      } elsif ($wday==6) {
         $wdaystr=qq|<font color=#00aa00>$wdaystr</font>|; #saturday
      }
      $fmtstr=~s/\@\@\@WEEKDAY_STR\@\@\@/&nbsp;$wdaystr&nbsp;/;
   }

   return($fmtstr);
}
######################## END FORMATTED_DATE #########################

########################## LUNAR_MONTHDAY #############################
# convert gregorian date to lunar str in big5
sub lunar_str {
   my ($year, $month, $day, $charset)=@_;
   my $str="";
   if ($charset eq "big5" || $charset eq "gb2312") {
      $str=(solar2lunar($year, $month, $day))[1];
      if ($str ne "") {
         my $color="";
         $color="color=#cc0000" if ($str=~/��@/ || $str=~/�Q��/);
         $str=b2g($str) if ($charset eq "gb2312");
         $str=qq|<font size=1 $color>$str</font>|;
      }
   }
   return($str);
}
######################## END LUNAR_MONTHDAY ###########################
