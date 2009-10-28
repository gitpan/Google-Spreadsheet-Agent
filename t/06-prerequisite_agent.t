use FindBin;
use Test::More;
use Google::Spreadsheet::Agent;
use Sys::Hostname;

my $conf_file = $FindBin::Bin.'/../config/agent.conf.yml';
if (-e $conf_file) {
  plan( tests => 9 );
}
else {
  plan( 
    skip_all => 'You must create a valid test Google Spreadsheet and a valid '
                .$conf_file
                .' configuration file pointing to it to run the tests. See README.txt file for more information on how to run the tests.'
      );
}

my $agent_name = 'prerequisite';
my $prerequisite_cell_name = 'prerequisitecell';
my $page_name = 'testing';
my $bind_key_fields = { 'testentry' => 'test' };

my $google_agent = Google::Spreadsheet::Agent->new(
                   agent_name => $agent_name,
                   debug => 1,
                   page_name => $page_name,
                   bind_key_fields => $bind_key_fields,
                   prerequisites => [ $prerequisite_cell_name ],
                 );

# cleanup from a previous run
my $entry = $google_agent->get_entry;
my $content = $entry->content;
$content->{$agent_name} = undef;
$content->{ready} = 1; # just in case
$content->{$prerequisite_cell_name} = undef;
$entry->content($content);

my $subroutine_ran;
my $return = $google_agent->run_my(sub { $subroutine_ran = 1; return 1; });

# this will actually return 1 since it is not runnable
is ($return, 1, 'run_my should return 1 when the prerequisite has not run');
ok (!$subroutine_ran, 'The subref should not have run at all when the prerequisite has not run');

$entry = $google_agent->get_entry;
$content = $entry->content;
$content->{$prerequisite_cell_name} = 'r:'.Sys::Hostname::hostname;
$entry->content($content);

$return = $google_agent->run_my(sub { $subroutine_ran = 1; return 1; });

# this will actually return 1 since it is not runnable
is ($return, 1, 'run_my should return 1 when the prerequisite is running');
ok (!$subroutine_ran, 'The subref should not have run at all when the prerequisite is running');

$entry = $google_agent->get_entry;
$content = $entry->content;
$content->{$prerequisite_cell_name} = 'F:'.Sys::Hostname::hostname;
$entry->content($content);

$return = $google_agent->run_my(sub { $subroutine_ran = 1; return 1; });

# this will actually return 1 since it is not runnable
is ($return, 1, 'run_my should return 1 when the prerequisite has failed');
ok (!$subroutine_ran, 'The subref should not have run at all when the prerequisite has failed');

$entry = $google_agent->get_entry;
$content = $entry->content;
$content->{$prerequisite_cell_name} = 1;
$entry->content($content);

$return = $google_agent->run_my(sub { $subroutine_ran = 1; return 1; });

$entry = $google_agent->get_entry;
is ($return, 1, 'run_my should return 1 when the prerequisite has passed');
ok ($subroutine_ran, 'The subref should have run at all when the prerequisite has failed');
is ($entry->content->{$agent_name}, 1, $agent_name.' cell should have passed');
done_testing;
