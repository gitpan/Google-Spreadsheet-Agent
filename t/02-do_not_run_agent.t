use FindBin;
use Test::More;
use Google::Spreadsheet::Agent;

my $conf_file = $FindBin::Bin.'/../config/agent.conf.yml';
if (-e $conf_file) {
  plan( tests => 6 );
}
else {
  plan( 
    skip_all => 'You must create a valid test Google Spreadsheet and a valid '
                .$conf_file
                .' configuration file pointing to it to run the tests. See README.txt file for more information on how to run the tests.'
      );
}

my $agent_name = 'donotrun';
my $page_name = 'testing';
my $bind_key_fields = { 'testentry' => 'test' };

my $google_agent = Google::Spreadsheet::Agent->new(
                   agent_name => $agent_name,
                   debug => 1,
                   page_name => $page_name,
                   bind_key_fields => $bind_key_fields
                 );

my $entry = $google_agent->get_entry;
my $content = $entry->content;
$content->{ready} = undef;
$content->{$agent_name} = undef; # cleanup from a previous run as well
$entry->content($content); # this updates the spreadsheet with all rows defined

my $subroutine_ran;
my $return = $google_agent->run_my(sub { $subroutine_ran = 1; return; });
 
# this will actually return 1 since it is not runnable
is ($return, 1, 'run_my should return 1 when the entry is not ready');
ok (!$subroutine_ran, 'The subref should not have run at all when the entry is not ready');
$content->{ready} = 1;
$entry->content($content);

$google_agent->fail_entry;
$return = $google_agent->run_my(sub { $subroutine_ran = 1; return; });
 
# this will actually return 1 since it is not runnable
is ($return, 1, 'run_my should return 1 when the entry has failed');
ok (!$subroutine_ran, 'The subref should not have run at all when the entry has failed');

$google_agent->complete_entry;
$return = $google_agent->run_my(sub { $subroutine_ran = 1; return; });
 
# this will actually return 1 since it is not runnable
is ($return, 1, 'run_my should return 1 when the entry has already completed');
ok (!$subroutine_ran, 'The subref should not have run at all when the entry has already completed');

done_testing;
