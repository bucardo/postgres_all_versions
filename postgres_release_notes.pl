#!/usr/bin/perl -- -*-mode:cperl; indent-tabs-mode: nil-*-

use strict;
use warnings;
use LWP::UserAgent;
use HTTP::Request;
use Data::Dumper; $Data::Dumper::Sortkeys = 1;
use Getopt::Long qw/ GetOptions /;
use Encode 'decode';
use utf8; binmode(STDOUT, ":encoding(UTF-8)");
use open ':std', ':encoding(UTF-8)';
use 5.24.0;

our $VERSION = '1.41';

my $USAGE = "$0 [--noindexcache] [--nocache] [--verbose]";

## --limitversions X = Only do one or more versions
## --verbosenames = Show which names got changed
## --debug-tableonly = Just the top HTML TOC

my $RATELIMIT = 3;
my $RATELIMITSLEEP = 0.5;
my $PAGES_FETCHED = 0;

my $PG_DUMP_URL = 'https://www.postgresql.org/docs/current/app-pgdump.html';

my $GREG_URL = 'https://www.linkedin.com/in/abcde/';

my $BEST_VERSION_COLOR = '#000800';

my $COLS = 6;
my $EOLURL = 'https://www.postgresql.org/support/versioning/';
my $EOL = '13';
my $EOLSOON = '99';
my $CURRENT_VERSION = 18;
my $EOLDATES = q{
18 November 14, 2030
17 November 8, 2029
16 November 9, 2028
15 November 11, 2027
14 November 12, 2026
13 November 13, 2025
12 November 14, 2024
11 November 9, 2023
10 November 10, 2022
9.6 November 11, 2021
9.5 February 11, 2021
9.4 February 13, 2020
9.3 November 8, 2018
9.2 November 9, 2017
9.1 October 27, 2016
9.0 October 8, 2015
8.4 July 24, 2014
8.3 February 7, 2013
8.2 December 5, 2011
8.1 November 8, 2010
8.0 October 1, 2010
7.4 October 1, 2010
7.3 November 27, 2007
7.2 February 4, 2007
7.1 April 13, 2006
7.0 May 8, 2005
6.5 June 9, 2004
6.4 October 30, 2003
6.3 March 1, 2003
};
my %EOLDATE = map { /([0-9.]+) (.+)/; $1, $2 } grep { /[0-9]/ } split /\n/ => $EOLDATES;

my %opt;
GetOptions(
    \%opt,
    'noindexcache',
    'nocache',
    'verbose',
    'help',
    'limitversions|limitversion=s',
    'nameschanged',
    'debug-tableonly',
    'max-versions=i',
    'debug-name-diffs',
) or die "$USAGE\n";

if ($opt{help}) {
    print "$USAGE\n";
    exit 0;
}

my $maxversions = $opt{'max-versions'} || 0;
my $verbose = $opt{verbose} || 0;
my $cachedir = '/tmp/cache';
my $index = 'https://www.postgresql.org/docs/release/';
my $baseurl = 'https://www.postgresql.org/docs/current/static';


my $debug_names = 0;

my $pagecache = {};

my $ua = LWP::UserAgent->new;
$ua->agent("GSM/$VERSION");

my $content = fetch_page($index);

my $total = 0;
my $bigpage = "$cachedir/postgres_all_versions.html";
open my $fh, '>', $bigpage or die qq{Could not open "$bigpage": $!\n}; ## no critic (InputOutput::RequireBriefOpen)

my ($dfh1, $dfh2);
if ($opt{'debug-name-diffs'}) {
    my $diff1page = "$bigpage.original";
    open $dfh1, '>', $diff1page;
    my $diff2page = "$bigpage.new";
    open $dfh2, '>', $diff2page;
}

print {$fh} qq{<!DOCTYPE html>
<html lang='en'>

<head>
<meta http-equiv="Content-Type" content="text/html; charset=utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<style><!--
a { white-space: nowrap }
span.gsm_v { color: #990000; font-family: monospace }
table.gsm { border-collapse: collapse; border-spacing: 15px }
table.gsm td { border: 1px solid #000; padding: 5px 7px 10px 7px; vertical-align: top; white-space: nowrap }
table.gsm td.eol { font-size: x-small; font-family: monospace }
table.gsm td.eol span { color: #dd0000 }
table.gsm td.eolsoon { font-size: small; font-family: monospace }
table.gsm td.eolsoon span { color: #ff9900 }
table.gsm td.notdeadyet { font-size: small; }
table.gsm td.notdeadyet span { color: #339900 }
span.gsmt { font-family: serif !important; color: black !important; font-weight: bolder !important }
code { font-weight: bolder }
a.bv { color: $BEST_VERSION_COLOR; font-weight: bolder }
a.a { position: relative; }
a.a::after { visibility: hidden; position: absolute; opacity: 0; z-index: 5432;
font-family: monospace; background-color: #336791; color: #FFF9C4; content: attr(data-tooltip);
padding: 12px; border-radius: 14px; transition: opacity .3s; pointer-events: none; }
a.a:hover::after { opacity: 1; visibility: visible; }
a.c::after { top: 120%; transform: translateX(-42%) }
a.l::after { left: 130% } a.g { text-decoration: none }
--></style>
<title>Postgres Release Notes - All Versions</title>
</head>
<body>
};

my @pagelist;

## Each bulleted item may be in more than one version!
my %bullet;
## When it was released
my %versiondate;

## First run to gather version information

while ($content =~ m{a href="/docs/release/(\d+)([\d\.]+?)/"}gs) {
    my ($v1,$v2) = ($1,$2);
    my $version = "$v1$v2";
    $verbose and warn "Found version $version\n";
    next if $v1 > $CURRENT_VERSION;
    my $pageurl = "$index$version/";
	my $pageinfo = fetch_page($pageurl);
	$total++;

	push @pagelist => [$pageurl, $version, $pageinfo];

	while ($pageinfo =~ m{<li>\s*<p>(.+?)</li>}sg) {
		my $blurb = $1;
		push @{$bullet{$blurb}} => $version;
	}

	## Gather the release date for each version

    my $founddate = 0;
    if ($pageinfo =~ /Release [Dd]ate:\D+(\d\d\d\d\-\d\d\-\d\d)/) {
        $versiondate{$version} = $1;
        $verbose and warn "Found $version as $1\n";
        $founddate = 1;
    }
    elsif ($pageinfo =~ m{Release [Dd]ate:.+(never released)}) {
        $versiondate{$version} = $1;
        $verbose and warn "Version $version never released\n";
        $founddate = 1;
    }
    ## <p><strong>Release date:&nbsp;</strong>2020-XX-XX, CURRENT AS OF 2020-08-09</p>
    ## <p><strong>Release date:&nbsp;</strong>2021-??-?? (AS OF 2021-06-20)</p>
    elsif ($pageinfo =~ m{Release [Dd]ate:.+AS OF \d\d\d\d}) {
        $versiondate{$version} = 'future';
        $founddate = 1;
        $total--;
    }
    if (!$founddate) {
        die "No date found for version $version at page $pageurl: $pageinfo!\n";
    }
}


my $date = qx{date +"%B %d, %Y"};
chomp $date;

my $oldselect = select $fh;
print qq{
<h1>Postgres Changelog - All Versions</h1>

<p>Below is a complete, one-page listing of changes across all Postgres versions. All versions of PostgreSQL $EOL and older are EOL (<a href="$EOLURL">end of life</a>) and unsupported.<br> This page was generated on $date by a script (version $VERSION) by <a href="$GREG_URL">Greg Sabino Mullane</a>, and contains information for $total versions of Postgres.</p>

};


## Table of Contents
print "<table class='gsm'>\n";
my $oldmajor;
my $highversion = 1.0;
my $highrevision = 0;
my $revision = 0;
my %version_is_eol;
my $current_column = 0;

my $major_nowraps = '6.0 6.1 6.2 6.3 6.4 7.0';

my %major_nowrap = map { $_ => 1 } split /\s+/ => $major_nowraps;

my %in_left_column;

for my $row (@pagelist) {

    my $version = $row->[1];

    my $major = 0;

    $verbose > 2 and warn "Scanning version: $version\n";

    ## Three formats we support, from newest to oldest

    ## 10 and up: format is X.Z
    if ($version =~ /^(\d\d+)\.(\d+)$/) {
        $major = $1;
        $revision = $2;
    }
    ## 6.0.0 to 9.4.Z: X.Y.Z
    elsif ($version =~ /^(\d\.\d+)\.(\d+)$/) {
        $major = $1;
        $revision = $2;
    }
    ## Ancient stuff: X.Y where X <= 1
    elsif ($version =~ /^([01])\.\d\d?$/) {
        $major = $1;
        $revision = 0;
    }
    else {
        die "Could not parse version '$version'";
    }

    if ($major >= $highversion) {
        $highversion = $major;
        if ($revision > $highrevision) {
            $highrevision = $revision;
        }
    }

    ## Skip anything not yet released
    next if $versiondate{$version} eq 'future';

    ## Are we at the start of a row, or at the start of a cell?
    my ($startrow,$startcell) = (0,0);

    ## Store EOL flag for later
    $version_is_eol{$version} = $major <= $EOL ? (exists $EOLDATE{$major} ? " as of $EOLDATE{$major}" : '') : 0;

    $startrow = 1 if ! defined $oldmajor;

    if (! defined $oldmajor or $oldmajor != $major and $major >= 6) {
        $oldmajor = $major;
        $startcell = 1;
        if (++$current_column > $COLS) {
            $startrow = 1;
            $current_column = 1;
        }
        $verbose > 2 and warn "Switched to version $version, startrow is $startrow, current cols is $current_column\n";
    }

    if ($startrow and $major > 6.4) {
        ## Close old row if needed
        if ($major != $highversion) {
            print "</tr> <!-- $major -->\n";
        }
        print "<tr>\n";
        $in_left_column{$major} = 1;
    }

    if ($startcell) {
        ## Close old cell if needed
        if ($major != $highversion and ! $startrow and not exists $major_nowrap{$major}) {
            print "</td>\n";
        }
        my $showver = $major;
        my $span = 1;
        ## EOL
        if ($major eq $EOL) {
            $span = 1;
            $current_column += 0;
        }
        if ($major eq '6.0') {
            $showver = '6.0 and earlier...';
        }
        if ($major eq $CURRENT_VERSION) {
            $span = 1;
            $current_column += 0;
        }
        my $expdate = (exists $EOLDATE{$major}) ? ": $EOLDATE{$major}" : '';
        $expdate =~ s/([A-S]\w{2})\w+/$1/;
        if (exists $major_nowrap{$major}) {
            print '<br><br>';
            $current_column=0;
        }
        else {
            printf '<td%s%s>',
            $span > 1 ? " colspan=$span" : '',
              $major == $EOLSOON ? ' class="eolsoon" ' :
                $major <= $EOL ? ' class="eol"' : ' class="notdeadyet"';
        }
        printf "<span class='gsmt'>Postgres %s%s</span>\n",
          $showver,
          " <br><span>(end of life$expdate)</span>";
    }

    die "No version date found for $version!\n" if ! $versiondate{$version};
    my $tooltip = "Release notes for version $version";
    my $tooltip_class = exists $in_left_column{$major} ? 'a l' : 'a c';
    if ($revision < 1 and $major > 7) {
        $tooltip = "Release notes for major version $major";
    }

    printf qq{<br><a class='%s' data-tooltip='%s' %shref="#version_%s">%s</a> (%s)\n},
      $tooltip_class, $tooltip, ($major > $EOL and $startcell) ? 'class="bv" ' : '',
        $version,
            ( ($revision>=1 or $major <= 6) ? $version : qq{<b>$version</b>}),
                $versiondate{$version} =~ /never/ ? '<em>never released!</em>' : "$versiondate{$version}";
    $oldmajor = $major;
}

print "</table>\n";
print STDOUT "Highest version: $highversion (revision $highrevision)\n";

die "Rewrote $bigpage\n" if $opt{'debug-tableonly'};

my $names = 0;
my %namesmatch;
my %fail;

my $totalfail=0;

my $versions_done = 0;

for my $row (@pagelist) {

    my ($url,$version,$data) = @$row;

    next if $opt{limitversions} and $version !~ /^$opt{limitversions}/;

    ## Much of this changes from version to version

    ## Remove the new helper tags
    $data =~ s{ <a href="#(.+?)">#</a>}{}gsm;

    $data =~ s{.*(<p>(<strong>|<b>)Release date)}{$1}si
        or die "No release date found for $url\n";

    $data =~ s{<div[^>]+class="navfooter">.*}{}is;

    ## Allow and reformat the new v17+ code tags
    ## <a class="ulink" href="https://postgr.es/c/f347ec76e" target="_top">§</a>
    $data =~ s{<a class="ulink".*?href="(.+?)/([a-f0-9]+)".*?>.+?</a>}{<a class='a c g' href='$1/$2' target='_blank' data-tooltip='View git commit $2'>&#x1F4DC</a>}gsm;

    ## Add pretty version information for each bullet
    $data =~ s{<li>\s*<p>(.+?)</li>}{
        my $blurb = $1;
        die "Mismatch blurb!!" if ! exists $bullet{$blurb};
        my $pversion = join ',' => @{ $bullet{$blurb} };
        die "Another version mismatch!\n" if $pversion !~ /\b$version\b/;
        $pversion =~ s{(\b)$version,?}{$1};
        $pversion = sprintf '<b>%s</b>%s%s', $version, ($pversion =~ /\d/ ? ',' : ''), $pversion;
        $pversion =~ s/,$//;
        "<li><p><span class='gsm_v'>($pversion) </span>$blurb</li>"
    }sgex;

    ## Remove mailtos
    $data =~ s{<a href=\s*"mailto:.+?">(.+?)</a>}{$1}gs;

    ## Adjust the headers a good bit
    $data =~ s{<h2}{<h1}sg;    $data =~ s{</h2>}{</h1>}sg;
    $data =~ s{<h3}{<h2}sg;    $data =~ s{</h3>}{</h2>}sg;
    $data =~ s{<h4}{<h3}sg;    $data =~ s{</h4>}{</h3>}sg;
    $data =~ s{<h[56]}{<h4}sg; $data =~ s{</h[56]>}{</h4>}sg;

    ## Remove all the not important "E-dot" stuff
    $data =~ s{>E\.[\d+\.]+\s*}{>}gsm;

    ## We are not using the existing CSS, so remove all classes
    $data =~ s{ class="\w+"}{}sg;

    ## Lots of empty spans, so remove those too
    $data =~ s{<span>([^<]+)</span>}{$1}sg;
    ## Run again because of nested class="quote" things
    $data =~ s{<span>([^<]+)</span>}{$1}sg;

    ## Remove the not helpful titles as well
    $data =~ s{ title=".+?"}{}g;

    ## Spelling fixes
    $data =~ s{Jdbc}{JDBC}g;

    ## Special header handling for old versions
    $data =~ s{(\w[\w ]+)\n\-\-\-\-+}{
        "<h4>$1</h4>"
    }seg;
    $data =~ s{<pre>(<h4>(.+?)</h4>)}{$1\n<pre>}g;

    ## Special list handling for older Changes lists in 7x
    $data =~ s{<pre>\n?((?:Fix PL|Remove unused WAL|Fix for numeric|JDBC fixes|Fix many CLUSTER|Many multibyte|Prevent function calls|New CLI interface|Many array fixes|subselect\+|Add NT README|Fix text|Add pg_dump|Fix for a tiny|Configure detection|ecpg cleanup|Fix binary cursors|Allow TIME|Fix problems with pg_dump|fix for SET|packet length checking|ALTER TABLE bug).+?)</pre>}{
        my $innerlist = $1;
        $innerlist =~ s!^([\w/])!<li>$1!gsm;
        "<ul>$innerlist</ul>\n"
    }seg;

    ## Special inner lists
    $data =~ s{  +(\* Rules on relations.+?from view works)}{
        my $innerlist = $1;
        $innerlist =~ s/\*/<li>/g;
        "<ul> $innerlist </ul>"
    }se;

    ## Special handling for really, really old Changes
    $data =~ s{<pre>((?:Source code maintenance|Incompatib|Copyright change).+?)</pre>}{
        my $innerlist = $1;
        $innerlist =~ s!^([A-Z].+?) \*!<h4>$1</h4>\n\*!gsm;
        $innerlist =~ s/\* /<li>/g;
        $innerlist;
    }se;

    ## Add a header for quick jumping
    print qq{<a id="version_$version"></a>\n};

    ## Redirect internal version links
    ## <a href="release-9-3-5.html">Section E.4</a>
    $data =~ s{href=\s*"release-([\d\-]+)\.html">Section.*?</a>}{
        (my $ver = $1) =~ s/\-/./g;
        $ver .= '.0' if $ver =~ /^\d\d$/ or $ver =~ /^\d\.\d$/;
        qq{href="#version_$ver">Version $ver</a>}
    }gmsex;

    ## Redirect simple links
    ## <a href="queries-with.html">common table expressions</a>
    $data =~ s{href=\s*"([^#].+?)"}{href="$baseurl/$1" target="_blank"}g;

    ## LINK CVE notices
    my $mitre = 'https://cve.mitre.org/cgi-bin/cvename.cgi?name=';
    my $redhat = 'https://access.redhat.com/security/cve';

    $data =~ s{([^-])(CVE-[\d\-]+)}{$1<a href="$mitre$2">$2</a> or <a href="$redhat/$2">$2</a>}g;

    ## Put spaces before some parens
    $data =~ s{(...\w)\(([A-Z]...)}{$1 ($2}g;

    ## Simplify lists
    $data =~ s{<ul .+?>}{<ul>}gsm;
    $data =~ s{<li .+?>}{<li>}gsm;

    ## Make the list of names a simple list, not a table!
    $data =~ s{<table [^>]+summary=(.+?)</table>}{
        my $inside = $1;
        my $list = "<ul>\n";
        while ($inside =~ m{<td>(.+?)</td>}g) {
            $list .= "<li>$1\n";
        }
        "$list</ul>\n";
    }sex;

    ## Remove all divs
    $data =~ s{\s*</?div(.*?)>\s*}{}g;

    ## Remove "name" atribute if id already exists
    $data =~ s{ name=".+?" id=}{ id=}g;

    ## Replace acronym with abbr
    $data =~ s{<acronym .+?>}{<abbr>}gsm;
    $data =~ s{</acronym>}{</abbr>}g;

    ## Replace tt with kbd
    $data =~ s{<tt.*?>}{<kbd>}gsm;
    $data =~ s{</tt>}{</kbd>}g;

    ## Expand a few things
    $data =~ s{A dump/restore}{A <a href="$PG_DUMP_URL">dump/restore</a>}gsm;

    ## Expand some names
my $namelist = q{
Adrian      : Adrian Hall
Aldrin      : Aldrin Leal
Alfred      : Alfred Perlstein
Alvaro      : Álvaro Herrera
Anand       : Anand Surelia
Anders      : Anders Hammarquist
Andreas     : Andreas Zeugswetter
Andrew      : Andrew Dunstan
Barry       : Barry Lind
Billy       : Billy G. Allie
Brook       : Brook Milligan
Bruce       : Bruce Momjian
Bryan       : Bryan Henderson
Bryan?      : Bryan Henderson
Byron       : Byron Nikolaidis
Christof    : Christof Petig
Christopher : Christopher Kings-Lynne
Clark       : Clark C. Evans
Claudio     : Claudio Natoli
Constantin  : Constantin Teodorescu
Dan         : Dan McGuirk
Darcy       : D'Arcy J.M. Cain
D'Arcy      : D'Arcy J.M. Cain
Darren      : Darren King
Dave        : Dave Cramer
David       : David Hartwig
Edmund      : Edmund Mergl
Erich       : Erich Stamberger
Fabien      : Fabien Coelho
Frankpitt   : Bernard Frankpitt
Gavin       : Gavin Sherry
Giles       : Giles Lean
Goran       : Goran Thyni
Heikki      : Heikki Linnakangas
Heiko       : Heiko Lehmann
Henry       : Henry B. Hotz
Hiroshi     : Hiroshi Inoue
Igor        : Igor Natanzon
Jacek       : Jacek Lasecki
James       : James Hughes
Jan         : Jan Wieck
Jeroen      : Jeroen van Vianen
Joe         : Joe Conway
Jun         : Jun Kuwamura
Karel       : Karel Zak
Kataoka     : Hiroki Kataoka
Keith       : Keith Parks
Kurt        : Kurt Lidl
Leo         : Leo Shuster
Maarten     : Maarten Boekhold
Magnus      : Magnus Hagander
Marc        : Marc Fournier
Mark        : Mark Hollomon
Martin      : Martin Pitt
Massimo     : Massimo Dal Zotto
Matt        : Matt Maycock
Maurizio    : Maurizio Cauci
Michael     : Michael Meskes
Neil        : Neil Conway
Oleg        : Oleg Bartunov
Oliver      : Oliver Elphick
Pascal      : Pascal André
Patrice     : Patrice Hédé
Patrick     : Patrick van Kleef
Paul        : Paul M. Aoki
Peter E     : Peter Eisentraut
Peter       : Peter T. Mount
Philip      : Philip Warner
Phil        : Phil Thompson
Raymond     : Raymond Toy
Rod         : Rod Taylor
Ross        : Ross J. Reedstrom
Ryan        : Ryan Bradetich : view|varchar
Ryan        : Ryan Kirkpatrick : Solaris|Alpha
Simon       : Simon Riggs
Stan        : Stan Brown
Stefan      : Stefan Simkovics
Stephan     : Stephan Szabo
Sven        : Sven Verdoolaege
Tatsuo      : Tatsuo Ishii
Teodor      : Teodor Sigaev
Terry       : Terry Mackintosh
Thomas      : Thomas Lockhart
Todd        : Todd A. Brandys
TomH        : Tom I. Helbekkmo
TomS        : Tom Szybist
Tom         : Tom Lane
Travis      : Travis Melhiser
Vadim       : Vadim Mikheev
Vadmin      : Vadim Mikheev
Vince       : Vince Vielhaber
Zeugswetter : Andreas Zeugswetter

Zeugswetter Andres : Andreas Zeugswetter
Melnikov Maksim    : Maksim Melnikov
Hou Zhijie         : Zhijie Hou
Ilyasov Ian        : Ian Ilyasov
Darek Slusarczyk   : Darek Ślusarczyk
Kuntal Gosh        : Kuntal Ghosh
Paul Amonson       : Paul D. Amonson
Xudong Yang        : YANG Xudong
Kambam Vinay       : Vinay Kambam
Onder Kalaci       : Önder Kalaci
Przemyslaw Sztoch  : Przemysław Sztoch
Zongliang Quan     : Quan Zongliang
Gunnar Bluth       : Gunnar "Nick" Bluth
};

    ## Contextual hints
    $data =~ s{</h([3456])>}{ (PG $version)</h$1>}sg;

    ## Sanity check on all names
    if ($opt{nameschanged}) {

        my $contrib = all_contributors();

        my $changes = $data;
        $changes =~ s{.*Changes</h2><ul>}{GREGFOUND}s;
        $changes =~ s{\d+ contains a number of changes that may affect}{GREGFOUND}s;

        $changes =~ /GREGFOUND/ or die "Could not find Changes line in $version! $data\n";

        print STDOUT "Scanning version $version\n";
        my $failures = 0;

        if ($version =~ /\.0$/) {
            $changes =~ s{\)</p>}{) <a}gs;
        }

        while ($changes =~ /\(([^)]+?)\) <a/gs) {
            my $localnamelist = $1;
            $localnamelist =~ s/with hat tip to //;
            my $localfail = 0;
            for my $name (split /, / => $localnamelist) {
                if (!exists $contrib->{$name}) {
                    warn "Found unknown name in Changes v$version: $name\n";
                    $failures++;
                    $localfail++;
                }
                $contrib->{$name}++;
            }
            if ($localfail) {
                #print STDOUT "MATCH ($localnamelist)\n";
            }
        }

        if ($failures) {
            #die "Leaving due to name mismatch\n";
        }
    }

    my $original_data = $data;

    for (split /\n/ => $namelist) {
        next if ! /\w/;
        die "Invalid line: $_\n" if ! /^([A-Z][\w\x{00C3}© \?']+?)\s+:\s+([ÖÁA-Z][\wé\.\-\'\" ]+?)(\s*:.+)?$/;
        my ($short,$long,$extra) = ($1,$2,$3||'');
        my $count = 0;
        $extra =~ s/^\s*:\s*//;
        if ($extra) {
            $extra = qr{$extra};
            my $changed = $data =~ s{($extra[\w\d\.\(\) ]+?\([\w ,]*)\Q$short\E([,\)])}{$1$long$2}g;
            $count += $changed;
            debugname($data, $long, $changed) if $changed;
        }
        else {
            my $changed = $data =~ s{(\()\Q$short\E([,\)])}{$1$long$2}g;
            $count += $changed;
            debugname($data, $long, $changed) if $changed;

            ## Special case for Vadim &amp; Erich
            $changed = $data =~ s{\(\Q$short\E &amp;}{($long &amp;}g;
            $count += $changed;
            debugname($data, $long, $changed) if $changed;

            $changed = $data =~ s{&amp; \Q$short\E\)}{&amp; $long)}g;
            $count += $changed;
            debugname($data, $long, $changed) if $changed;

            $changed = $data =~ s{(, ?)\Q$short\E([\),])}{$1$long$2}g;
            $count += $changed;
            debugname($data, $long, $changed) if $changed;
        }
        $namesmatch{$short} += $count;
        $names += $count;

    }

    ## Gregs:
    for my $string ('8601 format', 'use pager', 'conforming', 'nonstandard ports') {
        my $search = $string =~ s/ /[ \n]/r;
        my $changed = $data =~ s/$search\s+\(Greg\)/$string (Greg Sabino Mullane)/;
        $names += $changed;
        debugname($data, 'Greg Sabino', $changed) if $changed;
    }

    for my $string ('for large values)', 'unnecessarily') {
        my $changed = $data =~ s/\Q$string\E\s+\(Greg([,\)])/$string (Greg Stark$1/;
        $names += $changed;
        debugname($data, 'Greg Stark', $changed) if $changed;
    }
    ## Álvaro:
    my $changed = $data =~ s/Alvaro Herrera/Álvaro Herrera/g;
    $names += $changed;
    debugname($data, 'Álvaro', $changed) if $changed;

    ## Hans:
    $changed = $data =~ s/Hans-Jurgen Schonig/Hans-Jürgen Schonig/g;
    $names += $changed;
    debugname($data, 'Hans-Jürgen', $changed) if $changed;

    $changed = $data =~ s/Hans-Juergen/Hans-Jürgen/g;
    $names += $changed;
    debugname($data, 'Hans-Jürgen', $changed) if $changed;

    while ($data =~ m{[\(,]([A-Z]\w+)[,\)]}g) {
        my $name = $1;
        next if $name =~ /^SQL|WARN|ERROR|MVCC|OID|NUL|ZONE|EPOCH|GEQO|WAL|WIN|Window|Alpha|Apple|BC|PITR|TIME|BUFFER|GBK|UHC/;
        next if $name =~ /^TM|PL|SSL|XID|V0|ANALYZE|CTE|CV|LRU|MAX|ORM|SJIS|CN|CSV|Czech|JOHAB|ISM|Also|BLOB|SIGKILL|JIT|NOT/;
        next if $name =~ /^Mojave|VERBOSE|AIO|Bokmål/;
        next if $name =~ /^Taiwan|Mips|However|Japan|Ukrain|Venezuela|Altai|Kaliningrad|Antarctica|Volgograd/;
        next if $name eq 'MauMau' or $name eq 'Fiji' or $name eq 'ViSolve';
        next if $name eq 'Rumko' or $name eq 'Higepon' or $name eq 'Darwin';
        next if $name eq 'Simplified' or $name eq 'RLS' or $name eq 'OS';
        next if $name eq 'Alternatively' or $name eq 'Kerberos';
        next if $name eq 'VaibhaveS';
        $fail{$name}++;
        if ($verbose) {
            print STDERR "Added $name for $version\n";
        }
        $totalfail++;
    }

    ## Special credit for the original authors
    if ('0.01' eq $version) {
        my $authors = original_authors();
        (my $namelist2) = join "\n" => map { "<li>$_</li>" } $authors->@*;

        $data .= "<h3>Berkeley students who (along with Larry Rowe) helped write the original version:</h3>\n$namelist2\n";
    }

    my $fullversion = $version;

    if ($fullversion =~ /^\d+$/) {
        $fullversion = "$version.0";
    }
    my $eol = '0' ne ($version_is_eol{$version} // 0) ? qq{ <span class="eol"><a href="$EOLURL">(end of life$version_is_eol{$version})</a></span>} : '';
    print "<h1>Postgres version $fullversion$eol</h1>\n";

    print $data;

    if ($opt{'debug-name-diffs'}) {
        print {$dfh1} $original_data;
        print {$dfh2} $data;
    }

    $versions_done++;

    last if $maxversions and $versions_done >= $maxversions;

}

for my $short (sort keys %namesmatch) {
    next if $namesmatch{$short};
    next if $opt{limitversions} or $maxversions;
    print STDOUT "NO MATCH FOR SHORTNAME $short!\n";
}

for (sort keys %fail) {
    print STDOUT "Failed to match $_: $fail{$_}\n";
}
warn "Total name misses: $totalfail\n";

print STDOUT "Names changed: $names\n";


if ($opt{nameschanged}) {
    print STDOUT "Debug names found: $debug_names\n";
    if ($names != $debug_names) {
        die "FAILED TO MATCH ALL NAMES!\n";
    }
}



print "</body></html>\n";
select $oldselect;
close $fh;
print "Total pages loaded: $total\n";
print "Total versions written: $versions_done\n";
print "Rewrote $bigpage\n";

if ($opt{'debug-name-diffs'}) {
    close $dfh1;
    my $diff1page = "$bigpage.original";
    warn "Write $diff1page\n";
    close $dfh2;
    my $diff2page = "$bigpage.new";
    warn "Write $diff2page\n";
}


sub debugname {

    my $string = shift;
    my $regex = shift;
    my $matches = shift;
    my $line= (caller)[2];

    return if ! $opt{nameschanged};

    my $NAMECONTEXT = 30;

    if ($string =~ /(.{$NAMECONTEXT}$regex.{$NAMECONTEXT})/s) {
        my $match = $1;
        $match =~ s/\n/ /g;
        print STDOUT "--> Name replace ($matches) for $regex: $match\n";
        $debug_names += $matches;
    }
    else {
        print STDOUT "Failed to find name change for $regex ($matches) line=$line\n";
    }
    return;
}


sub fetch_page {

    my $page = shift or die "Need a page!\n";

    if (! -d $cachedir) {
        mkdir $cachedir, 0700;
    }

    ## Special handling for Postgres website bug
    if ($page =~ q{docs/current/static/release-(\d\-\d\-\d+)}) {
        my $v = $1;
        if ($v eq '8-1-23' or $v eq '8-0-26' or $v eq '7-4-30' or $v eq '7-3-21' or $v eq '7-2-8') {
            ## 404 but it should not be, so we go to a known working version
            $page = "https://www.postgresql.org/docs/8.2/release-$v.html";
            $verbose and print "Replaced $v page with $page\n";
        }
    }

    (my $safename = $page) =~ s{/}{_}g;
    my $file = "$cachedir/$safename";

    my $skipcache = 0;
    if ($opt{nocache} or ($page =~ /release\W*$/ and $opt{noindexcache})) {
        $skipcache = 1;
    }

    if (-e $file and ! $skipcache) {
        $verbose and print "Using cached file $file\n";
        open my $fh, '<:encoding(UTF-8)', $file or die qq{Could not open "$file": $!\n};
        my $data; { local $/; $data = <$fh>; } ## no critic (Variables::RequireInitializationForLocalVars)
        close $fh;
        return $data;
    }

    $verbose and print "Fetching file $file via $page\n";

    if ($PAGES_FETCHED++ >= $RATELIMIT) {
        sleep $RATELIMITSLEEP;
    }

    my $req = HTTP::Request->new(GET => $page);
    my $res = $ua->request($req);

    $res->is_success
        or die "FAILED to fetch $page: " . $res->status_line . "\n";

    open my $fh, '>:encoding(UTF-8)', $file or die qq{Could not write "$file": $!\n};
    my $data = decode('UTF-8', $res->decoded_content(charset => 'none'));
    print {$fh} $data;
    close $fh;

    $pagecache->{$page} = $file;

    return $data;

} ## end of fetch_page


sub original_authors {

    ## Returns a list of the original authors, per https://momjian.us/main/blogs/pgblog/2020.html#September_21_2020

my $author_list = '
Jeff Alton
Paul Aoki
James Bell
Jennifer Caetta
Philip Chang
Jolly Chen
Ron Choi
Matt Dillon
Zelaine Fong
Adam Glass
Jeffrey Goh
Steven Grady
Serge Granik
Marti Hearst
Joey Hellerstein
Michael Hirohama
Chin-Heng Hong
Wei Hong
Anant Jhingran
Greg Kemnitz
Marcel Kornacker
Case Larsen
Boris Livshitz
Jeff Meredith
Ginger Ogle
Mike Olson
Nels Olson
Lay-Peng Ong
Carol Paxson
Avi Pfeffer
Spyros Potamianos
Sunita Surawagi
David Muir Sharnoff
Mark Sullivan
Cimarron Taylor
Marc Teitelbaum
Yongdong Wang
Kristen Wright
Andrew Yu
';

my @list;
push @list => $_ for (grep /\w/ => split /\n/ => $author_list);

return \@list;

} ## end of original_authors

sub all_contributors {

    ## A complete list of all contributor, used to help debug the name replacements

my $author_list = '
Tom Lane
';
## TODO: Put this back in


my %list = map{s/ +#.*//; $_, 0 } grep /\w/ => split /\n/ => $author_list;
return \%list;

} ## end of all_contributors
