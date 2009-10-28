#!/usr/bin/perl
use FindBin;
use lib $FindBin::Bin.'/../lib';
use IGSP::GoogleAgent;
use Getopt::Std;

my $priority_page_name = 'Priority';

my %goal_page = (
                 rawsubmission => 'submission',
                 tafsubmission => 'submission',
                 validatetaf => 'submission',
                 combinedsubmission => 'submission',
                 submissionarchived => 'submission',
                 peaks => 'Final Peaks',
                 roc => 'Final Peaks'
                 );

my $usage = $0.' [-P priority_page_name] [-d] '."\npriority_page_name defaults to Priority\nSTDOUT and STDERR are suppressed and emailed unless -d is present\n";

my %opts;
getopts('dP:', \%opts);

my $debug = $opts{d};
$priority_page_name = $opts{P} if ($opts{P});

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

# run all goals in priority_page_name in the order they are encountered
# page must have all key_fields from config represented, although actual values for those not required can be null
foreach my $row ($encode_db->google_db->worksheet({ title => $priority_page_name })->rows()) {
    my $content = $row->content;
    my $args = { goal => $content->{goal} };
    map { $args->{$_} = $content->{$_} } keys %{$google_agent->config->{key_fields}};
    &run_runnable( $args );
}
exit;

sub run_runnable {
    my $args = shift;

    my $goal = $args->{goal};
    
    $goal =~ s/\_//g; # get rid of underscores
    print STDERR "CHECKING ".join(" ", map { join(':', $_, $args->{$_}) } keys %{$args})."\n" if ($debug);

    my $goal_agent = $pipeline_root.'/'.$goal.'_agent.pl';
    return unless (-x $goal_agent);

    my @cmd = ($goal_agent);

    foreach my $query_field (keys %{$google_agent->config->{key_fields}}) {
        next unless ($row_content->{$query_field});
        push @cmd, $row_content->{$query_field};
    }
    push @cmd, '-d' if ($debug);
    my $command = join(' ', @cmd).'&';
    print STDERR "plan_runner running $command\n" if ($debug);
    system($command);
    sleep 1;
    return;
}


