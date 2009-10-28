package Google::Spreadsheet::Agent;

use FindBin;
use YAML::Any qw/LoadFile/;
use Net::Google::Spreadsheets;
use Net::SMTP::TLS;
use IO::CaptureOutput qw/capture/;
use Sys::Hostname;
use Moose;
use Carp;

our $VERSION = '0.01';

sub BUILD {
    my $self = shift;

    my @required_key_fields = grep { $self->config->{key_fields}->{$_}->{required} } keys %{$self->config->{key_fields}};
    die ("Your configuration must have at least one required key_fields key!\n") unless (@required_key_fields);

    foreach my $required_query_field (@required_key_fields) {
        croak ("You must provide a bind_key_fields ${required_query_field} key - value pair!\n")
          unless ($self->bind_key_fields->{$required_query_field});
    }
}

has 'bind_key_fields' => (
                            is => 'ro',
                            isa => 'HashRef',
                            required => 1
                    );

has 'agent_name' => ( 
                      is => 'ro',
                      isa => 'Str',
                      required => 1
                      );

has 'page_name' => (
                    is => 'ro',
                    required => 1
                    );

has 'prerequisites' => (
                        is => 'ro',
                        isa => 'ArrayRef'
                        );

has 'debug' => (
                is => 'ro',
                isa => 'Bool'
                );

has 'max_selves' => (
                     is => 'ro',
                     isa => 'Int'
                     );

has 'subsumed_by' => (
                      is => 'ro',
                      isa => 'HashRef'
                      );

has 'config_file' => (
                      is => 'ro',
                      isa => 'Str',
                      );

has 'config' => (
                 is => 'ro',
                 builder => '_build_config'
                 );

has 'google_db' => (
                    is => 'ro',
                    builder => '_build_google_db',
                    lazy => 1, # depends on config
                    init_arg => undef # google_db cannot be overridden
                    );

#### BUILDERS

sub _build_config {
    my $self = shift;
    my $config_file = $self->config_file || $FindBin::Bin.'/../config/agent.conf.yml';
    croak "Config ${config_file} not found!\n" unless (-e $config_file);
    return YAML::Any::LoadFile($config_file);
}

sub _build_google_db {
    my $self = shift;
    my $service = Net::Google::Spreadsheets->new(
                                                 username => $self->config->{guser},
                                                 password => $self->config->{gpass},
                                                 );
    return $service->spreadsheet({
        title => $self->config->{spreadsheet_name}
    });
}

#### METHODS

around 'run_my' => sub {
    my ($orig, $self, @args) = @_;

    if ($self->debug) {
        return $self->$orig(@args);
    }
    else {
        my $capture_output;
        my $no_problems = capture {
            my $ret;
            eval {
                $ret = $self->$orig(@args);
            };
            if ($@) {
                print STDERR $@;
                return;
            }
            return $ret;
        } \$capture_output, \$capture_output;
        $self->mail_error($capture_output) unless ($no_problems);
        return $no_problems;
    }
};

sub run_my {
    my ($self, $agent_code) = @_;
    return 1 if ($self->is_subsumed);
    my $entry = $self->run_entry();
    
    return unless ($entry);
    return 1 if ($entry->{'not_runnable'}); # this is one that is not ready, already running, or already run, or the entry is complete

    my ($success, $update_entry) = $agent_code->($entry->content);
    if ($success) {
        $self->complete_entry($update_entry);
        return 1;
    }
    else {
        $self->fail_entry($update_entry);
        return;
    }
}

sub is_subsumed {
    my $self = shift;

    return unless ($self->max_selves || $self->subsumed_by); # nothing to subsume here

    my $subsumed;
    my %running_subsumers;

    my $subsume_opened = open (my $subsuming_in, '-|', 'ps', '-eo', 'pid,command');
    unless ($subsume_opened) {
        print STDERR "Couldnt check subsumption $!\n";
        return 1; # subsume to be safe
    }

    SUBIN: while (my $in = <$subsuming_in>) {
        next if ($in =~ m/emacs|vi|screen|SCREEN/); # skip editing and screen
        next if ($in =~ m/\s*$$/); # skip this agent
        next if ($in =~ m/(\[|\])/); # skip daemons

        my $self_name = $self->agent_name;
        if ($self->max_selves 
            && $in =~ m/$self_name/) {
            $running_subsumers{$self->agent_name}++;
            if ($running_subsumers{$self->agent_name} == $self->max_selves) {
                print STDERR "max_selves limit reached\n";
                $subsumed = 1;
                last SUBIN;
            }
        }

        if ($self->subsumed_by) {
            foreach my $subsumer (keys %{$self->subsumed_by}) {
                if ($in =~ m/$subsumer/) {
                    $running_subsumers{$subsumer}++;
                    if ($running_subsumers{$subsumer} == $self->subsumed_by->{$subsumer}) {
                        print STDERR "subsumed by ${subsumer}\n";
                        $subsumed = 1;
                        last SUBIN;
                    }
                }
            }
        }
    }
    close $subsuming_in;

    return $subsumed;
}

sub get_entry {
    my $self = shift;
    my $entry;

    my $worksheet = $self->google_db->worksheet({
        title => $self->page_name
    });

    # note, the Google Spreadsheet Data API does supply an sq query operator
    # which could be used here, but, as of 0.04 of Net::Google::Spreadsheets
    # this did not prove to be reliable during the tests.  This may be 
    # a limitation of the Google API rather than Net::Google::Spreadsheets
    # as it appeared that Net::Google::Spreadsheets was submitting valid,
    # url encoded queries that the Google system rejected. Instead this software
    # conducts a full table scan to ensure the correct row is returned
    if ($worksheet) {
        my @rows = $worksheet->rows();
        ROW: foreach my $row (@rows) {
            ARG: foreach my $arg (keys %{$self->config->{key_fields}}) {
                next ARG if (
                             !($self->config->{key_fields}->{$arg}->{required}) 
                             && !($self->bind_key_fields->{$arg})
                             ); # skip args that are not required and not bound
                next ROW unless ($row->content->{$arg} eq $self->bind_key_fields->{$arg});
            }
            $entry = $row;
            last ROW;
        }
    }

    return $entry;
}

# this call initiates a race resistant attempt to make sure that there is only 1 clear 'winner' among N potential
# agents attempting to run the same goal on the same spreadsheet agent's cell
sub run_entry {
    my $self = shift;

    my $entry = $self->get_entry();

    my $output = '';
    foreach my $bound_arg (keys %{$self->bind_key_fields}) {
        next if (!($self->config->{key_fields}->{$bound_arg}) && !($self->bind_key_fields->{$bound_arg}));
        $output .= join(' ', $bound_arg, $self->bind_key_fields->{$bound_arg})." ";
    }

    unless ($entry) {
        print STDERR $output." is not supported on ".$self->page_name."\n";
        return;
    }

    unless ($entry->content->{ready}) {
        print STDERR $output." is not ready to run ".$self->agent_name."\n";
        return {'not_runnable' => 1};
    }

    if ($entry->content->{complete}) {
        print STDERR "All goals are completed for ".$output."\n";
        return {'not_runnable' => 1};
    }

    if ($entry->content->{$self->agent_name}) {
        my ($status, $running_hostname) = split /\:/, $entry->content->{$self->agent_name};
        if ($status eq 'r') {
            print STDERR $output." is already running ".$self->agent_name." on ${running_hostname}\n";
            return {'not_runnable' => 1};
        }
        
        if ($status == 1) {
            print STDERR $output." has already run ".$self->agent_name."\n";
            return {'not_runnable' => 1};
        }

        if ($status eq 'F') {
            print STDERR $output." has already Failed ".$self->agent_name." on a previous run and must be investigated on ${running_hostname}\n";
            return {'not_runnable' => 1};
        }
    }

    if ($self->prerequisites) {
        foreach my $prereq_field (@{$self->prerequisites}) {
            unless ($entry->content->{$prereq_field} == 1) {
                print STDERR $output." has not finished ${prereq_field}\n";
                return {'not_runnable' => 1};
            }
        }
    }

    my $content = $entry->content;

    # first attempt to set the hostname of the machine as the value of the agent
    my $hostname = Sys::Hostname::hostname;
    $content->{$self->agent_name} = 'r:'.$hostname;
    eval { 
        $entry->content($content); 
    };
    if ($@) {
        # this is a collision, which is to be treated as if it is not runnable
        print STDERR $output." lost ".$self->agent_name." on ${hostname}\n";
        return {'not_runnable' => 1};
    }

    sleep 3;
    my $nentry;
    eval {
        $nentry = $self->get_entry();
    };
    if ($@) {
        # this is a collision, which is to be treated as if it is not runnable
        print STDERR $output." lost ".$self->agent_name." on ${hostname}\n";
        return {'not_runnable' => 1};
    }

    my $check = $nentry->content->{$self->agent_name};
    my ($status, $running_hostname) = split /\:/, $check;
    return $nentry if ($hostname eq $running_hostname);
    print STDERR $output." lost ".$self->agent_name." on ${hostname}\n";
    return {'not_runnable' => 1};
}

sub fail_entry {
    my $self = shift;
    my $update_entry = shift;

    my $entry = $self->get_entry();
    my $hostname = Sys::Hostname::hostname;
    my $content = $entry->content;
    if ($update_entry) {
        print STDERR "Updating entry\n";
        foreach my $key (keys %{$update_entry}) {
            $content->{$key} = $update_entry->{$key};
        }
    }

    $content->{$self->agent_name} = 'F:'.$hostname;
    $entry->content($content);
}

sub complete_entry {
    my $self = shift;
    my $update_entry = shift;

    print STDERR "All Complete\n";
    my $entry = $self->get_entry();
    my $content = $entry->content;
    if ($update_entry) {
        print STDERR "Updating entry\n";
        foreach my $key (keys %{$update_entry}) {
            $content->{$key} = $update_entry->{$key};
        }
    }
    $content->{$self->agent_name} = 1;
    $entry->content($content);
}

sub mail_error {
    my ($self, $error) = @_;

    my $output = '';
    foreach my $bound_arg (keys %{$self->bind_key_fields}) {
        $output .= join(' ', $bound_arg, $self->bind_key_fields->{$bound_arg})." ";
    }

    my $prefix = join(' ', Sys::Hostname::hostname, $output, $self->agent_name);
    eval {
        my $mailer = new Net::SMTP::TLS(  
                                          'smtp.gmail.com',  
                                          Hello   =>      'smtp.gmail.com',  
                                          Port    =>      587,  
                                          User    =>      $self->config->{guser},  
                                          Password =>      $self->config->{gpass});
        $mailer->mail($self->config->{reply_email});  
        $mailer->to($self->config->{send_to});  
        $mailer->data;  
        $mailer->datasend(join("\n", $prefix,$error));
        $mailer->dataend;  
        $mailer->quit;
    };
}

1;  # End of Google::Spreadsheet::Agent
__END__

=head1 NAME

Google::Spreadsheet::Agent - A Distributed Agent System using Google Spreadsheets

=head1 VERSION

Version 0.01

=head1 SYNOPSIS

  use Google::Spreadsheet::Agent;

  my $google_agent = Google::Spreadsheet::Agent->new(
                                          agent_name => $goal,
                                          page_name => $google_page,
                                          debug => $debug,
                                          max_selves => $max, 
                                          bind_key_fields => {
                                               'foo' => 'this_particular_foo'
                                          },
                                          prerequisites => [ 'isitdone', 'isthisone' ],
                                          subsumed_by => {
                                                           'someother_agent.pl' => 3,
                                                           'someother_process' => 1
                                                         }
                                          );

  $google_agent->run_my(sub {
                               print STDERR "THIS ONE PASSES!!!";
                               return 1;
                        });


  $google_agent->run_my(sub {
                               print STDERR "THIS ONE FAILS AND EITHER EMAILS OR PRINTS THIS ERROR TO STDERR (depending on debug)!!!";
                               return;
                        });

  $google_agent->run_my(sub {
                               print STDERR "THIS ONE PASSES AND UPDATES THE 'cool' field in the spreadsheet!!!";
                               return (1, {'cool' => 'really cool'});
                        });


=head1 DESCRIPTION

  Google::Spreadsheet::Agent is a framework for creating massively distributed pipelines
  across many different servers, each using the same google spreadsheet as a
  control panel.  It is extensible, and flexible.  It doesnt specify what
  goals any pipeline should be working towards, or which goals are prerequisites
  for other goals, but it does provide logic for easily defining these relationships
  based on your own needs.  It does this by providing a subsumption architecture,
  whereby many small, highly focused agents are written to perform specific goals,
  and also know what resources they require to perform them.  In addition, it is
  designed from the beginning to support the creation of simple human-computational
  workflows.

=head1 CONFIGURATION

  Scripts which use Google::Spreadsheet::Agents must supply the appropriate
  configuration for it to work.  This can be done one of two ways.

=over 2

=item YAML file supplied as config_file constructor argument.

  This is the easiest way to configure a set of agents using the same configuration.
  See config/agent.conf.yml.tmpl for a template, with documentation, of what needs
  to be defined.

=item HashRef supplied as config constructor argument.

  You can define a HashRef with all of the key-value pairs defined in config/agent.conf.yml.tmpl
  and pass that to the constructor.  This may be more useful where you want to use other serialization
  systems (e.g. JSON, XML, etc) to store configuration, which can be manipulated into a HashRef to
  be passed into the constructor.

=back

=head1 METHODS

=head2 new

 This method constructs a new instance of an Google::Spreadsheet::Agent.  An instance must
 specify its name, the name of the Worksheet within the spreadsheet that it is
 working off, and values for the required key_field(s) within the configuration
 which will result in a single row being returned from the given spreadsheet.
 Optionally, you can specify an ArrayRef of prerequisite fields in the spreadsheet
 which must be true before the agent can run, whether to print out debug information
 to the terminal, or email the errors using the configured email only on errors (default),
 the maximum number of agents of this name to allow to run on the given machine,
 and a HashRef of processes which, if a certain number are already running on the machine,
 should cause the agent to exit without running.

 required:
  agent_name => Str
  config || config_file (you must supply configuration)
  page_name => Str
  bind_key_fields => HashRef { key_field_name => bound_value, ... }

 optional:
  prerequisites => []
  debug => Bool
  max_selves => Int
  subsumed_by => { process_name => max_allowed, ... }

  This method will throw an exception if bind_key_fields are
  not supplied for required key_fields, as specified in the
  configuration.

  Also, there must be a field in the spreadsheet name for the agent_name.
  This field will be filled in with the status of the agent for a particular
  row, e.g. 1 for finished, r:hostname for running, or f:hostname for failure.

=head2 run_my

  This method takes a subroutine codeRef as an argument.  It then checks to determine
  if the agent needs to run for the given bind_key_field(s) specified row (it must
  have a 1 in the 'ready' field for the row, and the agent_name field must be empty),
  whether any prerequisite fields are true, whether the agent is subsumed by something
  else running on the machine, and whether there are not already max_selves other
  instances of the agent running on the machine.  If all of these are true, it then
  attempts to fill its hostname into the field for the agent_name.  If it succeeds,
  it will then run the code_ref.  If it does not succeed (such as if an instance 
  running on another server already chose that job and won the field) it exits.

  The coderef can do almost anything it wants to do, but it must return one of the following:

=over 3

=item return true

  This instructs Google::Spreadsheet::Agent to place a 1 (true) value in the field for the agent on
  the spreadsheet, signifying that it has been completed.

=item return false

  This instructs Google::Spreadsheet::Agent to place F:hostname into the field for the agent on the
  spreadsheet, signifying that it has failed.  It will not run again for this job until the
  failure is cleared from the spreadsheet (by any other agent).

=item return (true|false, HashRef)

  This does what returning true or false does, as well as allowing specific fields in the 
  spreadsheet to also be modified by the calling code.  The HashRef should contain keys
  only for those fields to be updated (it should not attempt to update the field for the
  agent_name itself, as this will be ignored).

=back

  In addition, the coderef can print to STDOUT and STDERR.  If the agent was instantiated in
  debug mode (true), it will print these to their normal destination.  If the agent was
  instantiated without debug mode (the default), STDOUT and STDERR are captured, and, if
  the codeRef returned false, emailed to the address specified in the configuration using the
  same google account that configures access to the google spreadsheet.

  One thing the agent must try at all costs to avoid is dying during the subref (e.g. use
  eval for anything that you dont have control over).  It should always try to return one
  of the valid return states so that the spreadsheet status can be updated correctly.

=head2 agent_name

 This returns the name of the agent, in case it is needed by the calling code for other reasons.

=head2 debug

 This returns the debug state specified in the constructor.

=head2 google_db

 This returns the actual Net::Google::Spreadsheet object used
 by the agent, in case other types of queries, or modifications
 need to be made that do not fit within this system.

=head1 AUTHOR

Darin London, C<< <darin.london at duke.edu> >>

=head1 BUGS

Please report any bugs or feature requests to C<bug-google-spreadsheet-agent at rt.cpan.org>, or through
the web interface at L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=Google-Spreadsheet-Agent>.  I will be
notified, and then you'll automatically be notified of progress on your bug as I make changes.

=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc Google::Spreadsheet::Agent


You can also look for information at:

=over 4

=item * RT: CPAN's request tracker

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=Google-Spreadsheet-Agent>

=item * AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/Google-Spreadsheet-Agent>

=back

=head1 SEE ALSO

L<Net::Google::Spreadsheets>
L<Moose>

=head1 COPYRIGHT & LICENSE

Copyright 2009 Darin London.

This program is free software; you can redistribute it and/or modify it
under the terms of either: the GNU General Public License as published
by the Free Software Foundation; or the Artistic License.

See http://dev.perl.org/licenses/ for more information.

=head1 PerlMonks Nodes

Note, these use an older Namespace IGSP::GoogleAgent instead of Google::Spreadsheet::Agent.
RFC: 798154
Code: 798311

=cut
