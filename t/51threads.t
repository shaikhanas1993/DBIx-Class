use Config;
BEGIN {
  unless ($Config{useithreads}) {
    print "1..0 # SKIP your perl does not support ithreads\n";
    exit 0;
  }
}
use threads;

use strict;
use warnings;

use Test::More;
use Test::Exception;

plan skip_all => 'DBIC does not actively support threads before perl 5.8.5'
  if $] < '5.008005';

use DBIx::Class::Optional::Dependencies ();
use lib qw(t/lib);

plan skip_all => 'Test needs ' . DBIx::Class::Optional::Dependencies->req_missing_for ('rdbms_pg')
  unless DBIx::Class::Optional::Dependencies->req_ok_for ('rdbms_pg');

my ($dsn, $user, $pass) = @ENV{map { "DBICTEST_PG_${_}" } qw/DSN USER PASS/};
plan skip_all => 'Set $ENV{DBICTEST_PG_DSN}, _USER and _PASS to run this test'
      . ' (note: creates and drops a table named artist!)' unless ($dsn && $user);

# README: If you set the env var to a number greater than 10,
#   we will use that many children
my $num_children = $ENV{DBICTEST_THREAD_STRESS} || 1;
if($num_children !~ /^[0-9]+$/ || $num_children < 10) {
   $num_children = 10;
}

use_ok('DBICTest::Schema');

my $schema = DBICTest::Schema->connection($dsn, $user, $pass, { AutoCommit => 1, RaiseError => 1, PrintError => 0 });

my $parent_rs;

lives_ok (sub {
    my $dbh = $schema->storage->dbh;

    {
        local $SIG{__WARN__} = sub {};
        eval { $dbh->do("DROP TABLE cd") };
        $dbh->do("CREATE TABLE cd (cdid serial PRIMARY KEY, artist INTEGER NOT NULL UNIQUE, title VARCHAR(100) NOT NULL UNIQUE, year VARCHAR(100) NOT NULL, genreid INTEGER, single_track INTEGER);");
    }

    $schema->resultset('CD')->create({ title => 'vacation in antarctica', artist => 123, year => 1901 });
    $schema->resultset('CD')->create({ title => 'vacation in antarctica part 2', artist => 456, year => 1901 });

    $parent_rs = $schema->resultset('CD')->search({ year => 1901 });
    $parent_rs->next;
}, 'populate successfull');

my @children;
while(@children < $num_children) {

    my $newthread = async {
        my $tid = threads->tid;

        my $child_rs = $schema->resultset('CD')->search({ year => 1901 });
        my $row = $parent_rs->next;
        if($row && $row->get_column('artist') =~ /^(?:123|456)$/) {
            $schema->resultset('CD')->create({ title => "test success $tid", artist => $tid, year => scalar(@children) });
        }
        sleep(1); # tasty crashes without this
    };
    die "Thread creation failed: $! $@" if !defined $newthread;
    push(@children, $newthread);
}

ok(1, "past spawning");

{
    $_->join for(@children);
}

ok(1, "past joining");

while(@children) {
    my $child = pop(@children);
    my $tid = $child->tid;
    my $rs = $schema->resultset('CD')->search({ title => "test success $tid", artist => $tid, year => scalar(@children) });
    is($rs->next->get_column('artist'), $tid, "Child $tid successful");
}

ok(1, "Made it to the end");

$schema->storage->dbh->do("DROP TABLE cd");

done_testing;
