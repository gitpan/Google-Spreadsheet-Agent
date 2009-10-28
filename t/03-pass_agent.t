use FindBin;
use Test::More;
use Google::Spreadsheet::Agent;

my $conf_file = $FindBin::Bin.'/../config/agent.conf.yml';
if (-e $conf_file) {
  plan( tests => 3 );
}
else {
  plan( 
    skip_all => 'You must create a valid test Google Spreadsheet and a valid '
                .$conf_file
                .' configuration file pointing to it to run the tests. See README.txt file for more information on how to run the tests.'
      );
}

my $agent_name = 'pass';
my $page_name = 'testing';
my $bind_key_fields = { 'testentry' => 'test' };

my $google_agent = Google::Spreadsheet::Agent->new(
                   agent_name => $agent_name,
                   debug => 1,
                   page_name => $page_name,
                   bind_key_fields => $bind_key_fields
                 );

# cleanup from a previous run
my $entry = $google_agent->get_entry;
my $content = $entry->content;
$content->{$agent_name} = undef;
$entry->content($content);

my $subroutine_ran;
ok $google_agent->run_my(sub { $subroutine_ran = 1; return 1; });
$entry = $google_agent->get_entry;
is ($entry->content->{$agent_name}, 1, "${agent_name} passed");
ok($subroutine_ran, 'The subroutine should have actually run');
done_testing;
