use strict;
use warnings;
use Module::Build;

my $builder = Module::Build->new(
    module_name         => 'Google::Spreadsheet::Agent',
    license             => 'perl',
    dist_author         => q{Darin London <darin.london@duke.edu>},
    dist_version_from   => 'lib/Google/Spreadsheet/Agent.pm',
    build_requires => {
        'Test::More' => 0,
    },
    add_to_cleanup      => [ 'Google-Spreadsheet-Agent-*' ],
    create_makefile_pl => 'traditional',
    requires => {
                          'Moose' => '>= 0.79',
                          'YAML::Any' => '>= 0.67',
                          'Net::Google::Spreadsheets' => '>= 0.04',
                          'Net::SMTP::TLS' => '>= 0.12',
                          'IO::CaptureOutput' => '>= 1.1101',
                 },
);

$builder->create_build_script();
