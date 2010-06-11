#!/usr/bin/perl
#
# gallery2_filenames - Program to parse a Gallery2 'album' and improve file names
#
#

use vars qw($VERSION);

$VERSION='0.01';

use strict;
use Getopt::Long;
use Pod::Usage;
use Data::Dumper;
use File::Spec;
use File::Copy;
use DBI;


my %opts;
my $result = GetOptions(
	"help"       => \$opts{help},
	"dryrun"     => \$opts{dryrun},
	"verbose"    => \$opts{verbose},
	"rootdir=s"  => \$opts{rootdir},
	"database=s" => \$opts{database},
	"db_host=s"  => \$opts{db_host},
	"db_port=i"  => \$opts{db_port},
	"db_user=s"  => \$opts{db_user},
	"db_pass=s"  => \$opts{db_pass},
);

=head1 OPTIONS

	"help"       => print this message
	"dryrun"     => tell us what we're going to do, but don't do it
	"rootdir=s"  => root directory from which to start. e.g.
	                $yourgallerydata/albums/ to process your whole tree
					(default current directory)
	"database=s" => gallery database name
	"db_host=s"  => gallery database host
	"db_port=i"  => gallery database port (default 3306)
	"db_user=s"  => gallery database user
	"db_pass=s"  => gallery database password

=cut

pod2usage(-verbose => 1) && exit if
	($opts{help}) || (!$result);


#connect to db and build map
my $map = {};
$opts{db_port} ||= 3306;

my $dsn = "DBI:mysql:database=$opts{database};host=$opts{db_host}";
my $dbh = DBI->connect($dsn, $opts{db_user}, $opts{db_pass},
	{ RaiseError => 1, AutoCommit => 0 });


my $get_data = $dbh->prepare("
	SELECT fse.g_id, fse.g_pathComponent as filename, i.g_title, ce.g_id as album_id, pfse.g_pathComponent as dirname, p.g_title as albumtitle
	FROM g2_FileSystemEntity fse, g2_Item i, g2_ChildEntity ce,	g2_Item p, g2_FileSystemEntity pfse
	WHERE fse.g_id = i.g_id AND fse.g_id=ce.g_id AND ce.g_parentID = p.g_id AND ce.g_parentID = pfse.g_id AND ce.g_parentID != 7
");
$get_data->execute;

while (my ($id,$filename,$title,$album_id,$dirname,$albumtitle) = $get_data->fetchrow) {
	$map->{$dirname}->{id} = $album_id;
	$map->{$dirname}->{title} = $albumtitle;
	$map->{$dirname}->{items}->{$filename} = { id => $id, title => $title };
}
$get_data->finish;

my $update = $dbh->prepare("UPDATE g2_FileSystemEntity fse SET fse.g_pathComponent = ? WHERE fse.g_id = ?");

#warn Dumper $map; exit;

my $dir = File::Spec->canonpath($opts{rootdir} || '.');

&process_dir($dir,$map,$update,$dbh,\%opts);

print "\n\nDONE! -- now go 'Delete Database Cache' from your Admin:Maintenance menu\n\n";

$update->finish;
$dbh->disconnect;

exit;


sub process_dir {
	my ($dir,$map,$update,$dbh,$opts) = @_;
	print "processing $dir\n";

	my $dh;
	unless (opendir ($dh, $dir)) {
		warn "Can't open dir '$dir': $!\n";
		return;
	}

	my $topdir = pop( @{[ File::Spec->splitdir($dir) ]});

	my @files = grep { !/^\./ } readdir $dh;
	foreach my $curfile (@files) {

		if (-d "$dir/$curfile") {
			#go recursive
			&process_dir("$dir/$curfile",$map,$update,$dbh,$opts);
			print "going recursive on '$dir/$curfile'\n";
		}
		elsif ($curfile =~ /^(\d+)\.(\w+)$/) {
			my $newfile = $topdir.'-'.$curfile;
			print "want to rename $dir/$curfile to $dir/$newfile\n";

			if (my $slice = $map->{$topdir}->{items}->{$curfile}) {
				print "... and update id ".$slice->{id}."\n";

				unless ($opts->{dryrun}) {
					eval {
						$update->execute($newfile,$slice->{id});
						if (move("$dir/$curfile","$dir/$newfile")) {
							$dbh->commit;
							print "success!\n";
						}
						else {
							$dbh->rollback;
							print "file move failed: $!\n";
						}
					};
					if ($@) {
						$dbh->rollback;
						print "Failed: $@\n";
					}
				}
			}
			else {
				warn "Can't find slice!\n";
			}
		}
	}
}

