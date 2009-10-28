#!/usr/bin/perl
use FindBin;
use lib $FindBin::Bin.'/../lib';
use IGSP::GoogleAgent;
use Getopt::Std;

my $usage = $0.' [-d]'."\nSTDOUT and STDERR are suppressed and emailed unless -d is present\n";
my %opts;
getopts('d', \%opts);

my $debug = $opts{d};

unless ($debug) {
    open (STDOUT, '/dev/null');
    open (STDERR, '/dev/null');
}

my $google_agent = IGSP::GoogleAgent->new(
                                          agent_name => 'agent_runner',
                                          page_name => 'all',
                                          debug => $debug,
                                          bind_key_fields => {
                                              cell_line => 'all',
                                              technology => 'all',
                                              replicate => 'all'
                                          }
                                          );

# iterate through each page on the database, get runnable rows, and run each runnable on the row
foreach my $page_name (
                       map { $_->title }
                       $google_agent->google_db->worksheets
                       ) {
    foreach my $runnable_row (
                              grep { $_->content->{ready} && !$_->content->{complete} }
                              $google_agent->google_db->worksheet({ title => $page_name })->rows
                              ) {
        foreach my $goal (keys %{$runnable_row->content}) {
            next if ($runnable_row->content->{$goal}); # r,1,F cause it to skip
            &run_runnable(
                          $goal,
                          $runnable_row->content
                          );
        }
    }
}
exit;

sub run_runnable {
    my ($goal, $row_content) = @_;
    print STDERR "CHECKING ${goal} ".$row_content->{cellline}." ".$row_content->{technology}." ".$row_content->{replicate}."\n" if ($debug);

    # some of these will skip because they are goals without agents
    my $goal_agent = $FindBin::Bin.'../agent_bin/'.$goal.'_agent.pl';
    return unless (-x $goal_agent);

    my @cmd = ($goal_agent);

    foreach my $query_field (keys %{$google_agent->config->{key_fields}}) {
        next unless ($row_content->{$query_field});
        push @cmd, $row_content->{$query_field};
    }
    push @cmd, '-d' if ($debug);

    my $command = join(' ', @cmd).'&';
    print STDERR "$command\n" if ($debug);
    system($command);
    sleep 1;
    return;
}

