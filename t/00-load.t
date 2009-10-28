#!perl -T

use Test::More tests => 1;

BEGIN {
    use_ok( 'Google::Spreadsheet::Agent' );
}

diag( "Testing Google::Spreadsheet::Agent $Google::Spreadsheet::Agent::VERSION, Perl $], $^X" );
