#!/usr/bin/perl -- -*-mode:cperl; indent-tabs-mode: nil-*-

use strict;
use warnings;
use LWP::UserAgent;
use HTTP::Request;
use Data::Dumper;
use Getopt::Long qw/ GetOptions /;
use 5.8.0;

our $VERSION = '1.21';

my $USAGE = "$0 [--noindexcache] [--nocache] [--verbose]";

my $EOLURL = 'https://www.postgresql.org/support/versioning/';
my $EOL = '9.4';
my $EOLPLUS = '9.5';  ## EOL February 11, 2021

my %opt;
GetOptions(
    \%opt,
    'noindexcache',
    'nocache',
    'verbose',
    'help',
    'limitversions=s',
);
if ($opt{help}) {
    print "$USAGE\n";
    exit 0;
}

my $verbose = $opt{verbose} || 0;
my $cachedir = '/tmp/cache';
my $index = 'https://www.postgresql.org/docs/release/';
my $baseurl = 'http://www.postgresql.org/docs/current/static';

my $pagecache = {};

my $ua = LWP::UserAgent->new;
$ua->agent("GSM/$VERSION");

my $content = fetch_page($index);

my $total = 0;
my $bigpage = "$cachedir/postgres_all_versions.html";
open my $fh, '>', $bigpage or die qq{Could not open "$bigpage": $!\n}; ## no critic (InputOutput::RequireBriefOpen)
print {$fh} qq{<!DOCTYPE html>
<html lang='en'>

<head>
<meta http-equiv="Content-Type" content="text/html; charset=utf-8">
<style><!--
span.gsm_v { color: #990000; font-family: monospace;}
table.gsm { border-collapse: collapse; border-spacing: 15px }
table.gsm td { border: 1px solid #000; padding: 5px 7px 10px 7px; vertical-align: top; white-space: nowrap; }
table.gsm td.eol { color: #111111; font-size: smaller; }
table.gsm td.eol span { color: #dd0000 }
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

while ($content =~ m{a href="/docs/release/(\d[\d\.]+?)/"}gs) {
    my $version = $1;
    $verbose and warn "Found version $version\n";
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
    elsif ($pageinfo =~ m{Release [Dd]ate:\D+\d\d\d\d\-\?}) {
        $versiondate{$version} = 'future';
        $founddate = 1;
        $total--;
    }
    if (!$founddate) {
        die "No date found for version $version at page $pageurl!\n";
    }
}


my $date = qx{date +"%B %d, %Y"};
chomp $date;

my $oldselect = select $fh;
print qq{
<h1>Postgres Changelog - All Versions</h1>

<p>This is a complete, one-page listing of changes across all Postgres versions. All versions $EOL and older are EOL (<a href="$EOLURL">end of life</a>) and unsupported. This page was generated on $date by a script (version $VERSION) by Greg Sabino Mullane, and contains information for $total versions of Postgres.</p>

};


## Table of Contents
print "<table class='gsm'>\n";
my $COLS = 7;
my $startrow=1;
my $startcell=1;
my $oldmajor;
my $highversion = 1.0;
my $highrevision = 0;
my $revision = 0;
my $seeneol = 0;
my %version_is_eol;
my $current_column = 0;

for my $row (@pagelist) {
    my ($url,$version,$data) = @$row;
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
        $revision = 2;
    }
    ## Ancient stuff: X.Y where X <= 1
    elsif ($version =~ /^([01]\.\d\d?)$/) {
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
    $version_is_eol{$version} = $major <= $EOL ? 1 : 0;

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

    if ($startrow) {
        ## Close old row if needed
        if ($major != $highversion) {
            print "</tr>\n";
        }
        print "<tr>\n";
    }

    if ($startcell) {
        ## Close old cell if needed
        if ($major != $highversion and ! $startrow) {
            print "</td>\n";
        }
        my $showver = $major;
        my $span = 1;
        ## Last one before EOL
        if ($major eq $EOLPLUS) {
            $span = 2;
            $current_column++;
        }
        if ($major eq '6.0') {
            $showver = '6.0<br>and earlier...';
            $span = 2;
        }
        printf "<td%s%s><b>Postgres %s%s</b>\n",
            $span > 1 ? " colspan=$span" : '',
                $major <= $EOL ? ' class="eol"' : '',
                    $showver,
                        $major <= $EOL ? ' <br><span>(end of life)</span>' : '';
    }

    die "No version date found for $version!\n" if ! $versiondate{$version};
    printf qq{<br><a href="#version_%s">%s</a> (%s)\n},
        $version,
            ($revision>=1 ? $version : qq{<b>$version</b>}),
                $versiondate{$version} =~ /never/ ? "<em>never released!</em>" : "$versiondate{$version}";
    $oldmajor = $major;
}

print "</table>\n";
print STDOUT "Highest version: $highversion (revision $highrevision)\n";

my $names = 0;
my %namesmatch;
my %fail;

my $totalfail=0;

for my $row (@pagelist) {

    my ($url,$version,$data) = @$row;

    next if $opt{limitversions} and $version !~ /^$opt{limitversions}/;

    ## Old style:
    $data =~ s{.*?(<div class="SECT1")}{$1}s;
    $data =~ s{<div class="NAVFOOTER".+}{}s;

    ## New as of version 10:
    $data =~ s{.*(<p><strong>Release date)}{$1}s;
    $data =~ s{<div class="navfooter".+}{}s;

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
    $data =~ s{<h[56]}{<h4}sg;    $data =~ s{</h[56]>}{</h4>}sg;

    ## Remove all the not important "E-dot" stuff
    $data =~ s{>E\.[\d+\.]+\s*}{>}gsm;

    ## We are not using the existing CSS, so remove all classes
    $data =~ s{ class="\w+"}{}sg;

    ## Remove ids from the divs as we do not use those either
    $data =~ s{<div.+?>}{<div>}g;

    ## Add a header for quick jumping
    print qq{<a id="version_$version"></a>\n};

    ## Redirect internal version links
    ## <a href="release-9-3-5.html">Section E.4</a>
    $data =~ s{href=\s*"release-([\d\-]+)\.html">Section.*?</a>}{
        (my $ver = $1) =~ s/\-/./g;
        qq{href="#version_$ver">Version $ver</a>}
    }gmsex;

    ## Redirect simple links
    ## <a href="postgres-fdw.html"><span class=
    $data =~ s{href=\s*"(.+?)"}{href="$baseurl/$1"}g;

    ## LINK CVE notices
    my $mitre = 'https://cve.mitre.org/cgi-bin/cvename.cgi?name=';
    my $redhat = 'https://access.redhat.com/security/cve';

    $data =~ s{(CVE-[\d\-]+)}{<a href="$mitre$1">$1</a> or <a href="$redhat/$1">$1</a>}g;

    ## Put spaces before some parens
    $data =~ s{(...\w)\(([A-Z]...)}{$1 ($2}g;

    ## Strip final </div> if it exists
    $data =~ s{</div>\s*$}{};

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

    ## Remove "name" atribute if id already exists
    $data =~ s{ name=".+?" id=}{ id=}g;

    ## Replace acronym with abbr
    $data =~ s{<acronym .+?>}{<abbr>}gsm;
    $data =~ s{</acronym>}{</abbr>}g;

    ## Replace tt with kbd
    $data =~ s{<tt class=.+?">}{<kbd>}gsm;
    $data =~ s{</tt>}{</kbd>}g;

    ## Expand some names
my $namelist = q{
Adrian      : Adrian Hall
Aldrin      : Aldrin Leal
Alfred      : Alfred Perlstein
Alvaro      : Alvaro Herrera
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

};

    for (split /\n/ => $namelist) {
        next if ! /\w/;
        die "Invalid line: $_\n" if ! /^([A-Z][\w \?']+?)\s+:\s+([A-Z][\wé\.\-\' ]+?)(\s*:.+)?$/;
        my ($short,$long,$extra) = ($1,$2,$3||'');
        my $count = 0;
        $extra =~ s/^\s*:\s*//;
        if ($extra) {
            $extra = qr{$extra};
            $count += $data =~ s{($extra[\w\d\.\(\) ]+?\([\w ,]*)\Q$short\E([,\)])}{$1$long$2}g;
        }
        else {
            $count += $data =~ s{(\W)\Q$short\E([,\)])}{$1$long$2}g;
            ## Special case for Vadim &amp; Erich
            $count += $data =~ s{\(\Q$short\E &amp;}{($long &amp;}g;
            $count += $data =~ s{&amp; \Q$short\E\)}{(&amp; $long)}g;
        }
        $namesmatch{$short} += $count;
        $names += $count;
    }
    ## Gregs:
    for my $string ('8601 format', 'use pager', 'conforming', 'nonstandard ports') {
        $names += $data =~ s/\Q$string\E\s+\(Greg\)/$string (Greg Sabino Mullane)/;
    }
    for my $string ('for large values)', 'unnecessarily') {
        $names += $data =~ s/\Q$string\E\s+\(Greg([,\)])/$string (Greg Stark$1/;
    }

    while ($data =~ m{[\(,]([A-Z]\w+)[,\)]}g) {
        my $name = $1;
        next if $name =~ /^SQL|WARN|ERROR|MVCC|OID|NUL|ZONE|EPOCH|GEQO|WAL|WIN|Window|Alpha|Apple|BC|PITR|TIME|BUFFER|GBK|UHC/;
        next if $name =~ /^TM|PL|SSL|XID|V0|ANALYZE|CTE|CV|LRU|MAX|ORM|SJIS|CN|CSV|Czech|JOHAB|ISM|Also|BLOB/;
        next if $name =~ /^Taiwan|Mips|However|Japan|Ukrain|Venezuela|Altai|Kaliningrad/;
        next if $name eq 'MauMau' or $name eq 'Fiji' or $name eq 'ViSolve';
        next if $name eq 'Rumko' or $name eq 'Higepon' or $name eq 'Darwin';
        next if $name eq 'Simplified' or $name eq 'RLS' or $name eq 'OS';
        $fail{$name}++;
        $totalfail++;
    }

    my $fullversion = $version;

    if ($fullversion =~ /^\d+$/) {
        $fullversion = "$version.0";
    }
    my $eol = $version_is_eol{$version} ? qq{ <span class="eol"><a href="$EOLURL">(end of life)</a></span>} : '';
    print "<h2>Postgres version $fullversion$eol</h2>\n";
    print $data;

}

for my $short (sort keys %namesmatch) {
    next if $namesmatch{$short};
    next if $opt{limitversions};
    print STDOUT "NO MATCH FOR SHORTNAME $short!\n";
    exit;
}

for (sort keys %fail) {
    print STDOUT "$_: $fail{$_}\n";
}
warn "Total name misses: $totalfail\n";

print STDOUT "Names changed: $names\n";

print "</body></html>\n";
select $oldselect;
close $fh;
print "Total pages loaded: $total\n";
print "Rewrote $bigpage\n";

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
    if ($opt{nocache} or ($page =~ /release\.html/ and $opt{noindexcache})) {
        $skipcache = 1;
    }

    if (-e $file and ! $skipcache) {
        $verbose and print "Using cached file $file\n";
        open my $fh, '<', $file or die qq{Could not open "$file": $!\n};
        my $data; { local $/; $data = <$fh>; } ## no critic (Variables::RequireInitializationForLocalVars)
        close $fh;
        return $data;
    }

    $verbose and print "Fetching file $file\n";

    my $req = HTTP::Request->new(GET => $page);
    my $res = $ua->request($req);

    $res->is_success
        or die "FAILED to fetch $page: " . $res->status_line . "\n";

    open my $fh, '>', $file or die qq{Could not write "$file": $!\n};
    my $data = $res->content;
    print {$fh} $data;
    close $fh;

    $pagecache->{$page} = $file;

    return $data;

} ## end of fetch_page
