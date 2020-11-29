package Test2::Harness::Overseer::Muxer;
use strict;
use warnings;

use Test2::Util qw/ipc_separator/;
use Test2::Harness::Util qw/parse_exit/;
use Test2::Harness::Util::JSON qw/decode_json/;
use Test2::Harness::Util::UUID qw/gen_uuid/;

use Time::HiRes qw/time/;

use Carp qw/croak/;

our $VERSION = '1.000043';

use parent 'Test2::Harness::Overseer::EventGen';
use Test2::Harness::Util::HashBase qw{
    <output_dir

    <tap_parser

    <syncs
    <pending
    <stamps
    <ords
    <buffers
};

sub init {
    my $self = shift;

    $self->SUPER::init();

    unless ($self->{+TAP_PARSER}) {
        require Test2::Harness::Overseer::TapParser;
        $self->{+TAP_PARSER} = 'Test2::Harness::Overseer::TapParser';
    }

    $self->{+PENDING} //= {stderr => [], stdout => [], events => [], harness => []};
    $self->{+ORDS}    //= {stderr => 1,  stdout => 1,  events => 1,  harness => 1};

    $self->{+SYNCS}   //= {stderr => 0,     stdout => 0};
    $self->{+BUFFERS} //= {stderr => '',    stdout => ''};
    $self->{+STAMPS}  //= {stderr => undef, stdout => undef};
}

sub flush {
    my $self = shift;

    # Always flush harness events
    my @out = @{$self->{+PENDING}->{harness}};
    @{$self->{+PENDING}->{harness}} = ();

    my $syncs = $self->{+SYNCS} //= {};

    my $events = $self->{+PENDING}->{events} //= [];

    while (@$events) {
        my $e = $events->[0];

        my $id = $e->event_id;
        my $pf = $e->facet_data->{harness}->{parse_failure};

        my $sync = $syncs->{$id};

        # We do not want to flush this far unless stderr and stdout are both
        # synced. However if this event is a parse-fail it means sync is not
        # possible, so continue.
        # Also, it is possible the sync had a parse error, in which case a
        # following sync will set SYNC->{stream} to an ordinal higher than the
        # next object in the streams queue, in which case we flush.
        unless ($pf) {
            for my $stream (qw/stderr stdout/) {
                next if $sync->{$stream};

                my $max_synced = $syncs->{$stream};
                my $source     = $self->{+PENDING}->{$stream};

                last unless @$source && $source->[0]->from_ord < $max_synced;
            }
        }

        # Remove the one we are working with
        shift @$events;
        delete $syncs->{$id};

        # flush stream events where the ord is below or at our sync point
        for my $stream (qw/stderr stdout/) {
            my $ord    = $sync->{$stream} or next;
            my $source = $self->{+PENDING}->{$stream};

            while (@$source && $source->[0]->from_ord <= $ord) {
                my $se = shift @$source;
                push @out => $se unless @out && $self->_combine_comments($out[-1], $se);
            }
        }

        push @out => $e;
    }

    return \@out;
}

sub process_event {
    my $self = shift;

    push @{$self->{+PENDING}->{events}} => $self->_process_event(
        @_,
        from_ord => $self->{+ORDS}->{events}++,
    );

    return $self->flush();
}

sub process_stdout {
    my $self = shift;
    my ($line, %harness) = @_;

    $self->_process_text(
        parse_meth => 'parse_stdout_tap',
        source     => 'stdout',
        line       => $line,
        info       => {tag => 'STDOUT'},
        harness    => \%harness,
    );

    return $self->flush();
}

sub process_stderr {
    my $self = shift;
    my ($line, %harness) = @_;

    $self->_process_text(
        parse_meth => 'parse_stderr_tap',
        source     => 'stderr',
        line       => $line,
        info       => {tag => 'STDERR', debug => 1},
        harness    => \%harness,
    );

    return $self->flush();
}

sub finish {
    my $self = shift;

    my @out;

    # Clear any buffers
    for my $stream (keys %{$self->{+BUFFERS}}) {
        my $buff = $self->{+BUFFERS}->{$stream} // next;
        next unless length($buff);

        my $meth = "process_${stream}";

        push @out => @{$self->$meth("\n", from_stream => $stream)};
    }

    # flush
    push @out => @{$self->flush()};

    # dump any remaining events from all streams
    push @out => @{$_} for values %{$self->{+PENDING}};
    delete $self->{+PENDING};

    return \@out;
}

sub signal {
    my $self = shift;
    my ($sig) = @_;

    push @{$self->{+PENDING}->{harness}} => $self->gen_harness_event(
        harness => {
            stamp       => $sig->{stamp},
            from_stream => 'harness',
            from_ord    => $self->{+ORDS}->{harness}++,
        },
        errors => [{
            tag     => 'HARNESS',
            fail    => 1,
            details => "Harness overseer caught signal '$sig->{sig}', forwarding to test...",
        }]
    );

    return $self->flush;
}

sub start {
    my $self = shift;
    my ($job, $stamp) = @_;

    push @{$self->{+PENDING}->{harness}} => $self->gen_harness_event(
        harness_job => $job,
        harness     => {
            stamp       => $stamp,
            from_stream => 'harness',
            from_ord    => $self->{+ORDS}->{harness}++,
        },
        harness_job_launch => {
            stamp => $stamp,
            retry => $self->{+JOB_TRY},
        },
        harness_job_start => {
            details  => "Job $self->{+JOB_ID} started at $stamp",
            job_id   => $self->{+JOB_ID},
            stamp    => $stamp,
            file     => $job->file,
            rel_file => $job->rel_file,
            abs_file => $job->abs_file,
        },
    );

    return $self->flush;
}

sub exit {
    my $self = shift;
    my ($exit_data) = @_;

    my $wstat = parse_exit($exit_data->{exit});
    my $stamp = $exit_data->{stamp};

    push @{$self->{+PENDING}->{harness}} => $self->gen_harness_event(
        harness => {
            stamp       => $stamp,
            from_stream => 'harness',
            from_ord    => $self->{+ORDS}->{harness}++,
        },
        harness_job_exit => {
            stamp   => $stamp,
            job_id  => $self->{+JOB_ID},
            job_try => $self->{+JOB_TRY},

            details => "Test script exited $wstat->{all} ($wstat->{err}\:$wstat->{sig})",

            exit    => $wstat->{all},
            code    => $wstat->{err},
            signal  => $wstat->{sig},
            dumped  => $wstat->{dmp},

            retry   => $exit_data->{retry},
        },

        $exit_data->{error} ? (
            errors => [{
                details => $exit_data->{error},
                fail => 1,
                tag => 'HARNESS',
            }],
        ) : (),
    );

    return $self->flush;
}

my %EXIT_REASONS = (
    event => <<'    EOT',
Test2::Harness checks for timeouts at a configurable interval, if a test does
not produce any output to stdout or stderr between intervals it will be
forcefully killed under the assumption it has hung. See the '--event-timeout'
option to configure the interval.
    EOT

    exit => <<'    EOT',
Sometimes tests will fork and then return. On supported systems Test2::Harness
will start all tests with their own process group and will wait for the entire
group to exit before considering the test done. In these cases Test2::Harness
will poll for output from the process group at a configurable interval, if no
output is produced between intervals the process group will be forcefully
killed. See the '--post-exit-timeout' option to configure the interval.
    EOT
);

sub timeout {
    my $self = shift;
    my ($type, $timeout, $sig) = @_;

    my $stamp = time;
    chomp(my $reason = $EXIT_REASONS{$type});

    push @{$self->{+PENDING}->{harness}} => $self->gen_harness_event(
        harness => {
            stamp       => $stamp,
            from_stream => 'harness',
            from_ord    => $self->{+ORDS}->{harness}++,
        },
        errors => [{
            details => "A timeout ($type) has occured (after $timeout seconds), job was forcefully killed with signal $sig",
            fail    => 1,
            tag     => 'TIMEOUT',
        }],
        info => [{
            tag       => 'TIMEOUT',
            debug     => 1,
            important => 1,
            details   => $reason,
        }],
    );
}

sub lost_master {
    my $self = shift;
    my ($master_pid, $sig) = @_;

    push @{$self->{+PENDING}->{harness}} => $self->gen_harness_event(
        harness => {
            stamp       => time,
            from_stream => 'harness',
            from_ord    => $self->{+ORDS}->{harness}++,
        },
        errors => [{
            details => "The master process ($master_pid) went away! Killing test with signal $sig...",
            fail    => 1,
            tag     => 'TIMEOUT',
        }],
    );
}

my %COMBINABLE_STREAMS = (stderr => 1, stdout => 1);

sub _combine_comments {
    my $self = shift;
    my ($ea, $eb) = @_;

    # Only combine stderr/stdout lines
    return unless $COMBINABLE_STREAMS{$ea->from_stream};

    # Only combine lines from the same stream
    return unless $ea->from_stream eq $eb->from_stream;

    # Only combine sequential events.
    # (This should never fail if this method is used properly)
    return unless $eb->from_ord == 1 + $ea->from_ord;

    my $eaf = $ea->facet_data;
    my $ebf = $eb->facet_data;

    # if they are not both 1 line of info they cannot be combined
    ($_->{info} && @{$_->{info}} == 1) or return for $eaf, $ebf;

    # Must have same tag
    return if ($eaf->{info}->[0]->{tag} ne $ebf->{info}->[0]->{tag});

    # Must have same debug truthiness
    return if ($eaf->{info}->[0]->{debug} xor $ebf->{info}->[0]->{debug});

    # Only combine them if they are both from tap, or both not from tap
    return if (exists($eaf->{harness}->{from_tap}) xor exists($ebf->{harness}->{from_tap}));

    # They must have the same nesting
    my $ean = (exists $eaf->{trace} && exists $eaf->{trace}->{nested}) ? $eaf->{trace}->{nested} : 0;
    my $ebn = (exists $ebf->{trace} && exists $ebf->{trace}->{nested}) ? $ebf->{trace}->{nested} : 0;
    return unless $ean == $ebn;

    # OK combine!

    $eaf->{info}->[0]->{details} .= "\n" . $ebf->{info}->[0]->{details};
    $eaf->{harness}->{from_tap}  .= "\n" . $ebf->{harness}->{from_tap} if exists $ebf->{harness}->{from_tap};

    # Combine source_ord #..#
    $eaf->{harness}->{from_ord} =~ s/\.\.\d+$//;    # Strip any previous range info
    $eaf->{harness}->{from_ord} .= ".." . $ebf->{harness}->{from_ord};

    return 1;
}

sub _process_event {
    my $self = shift;
    my ($line, %harness) = @_;

    chomp($line);

    my $edata;
    my $ok  = eval { $edata = decode_json($line); 1 };
    my $err = $@;

    my $event;
    if ($ok) {
        $edata->{harness} = \%harness;
        return $self->gen_event($edata);
    }

    return $self->gen_harness_event(
        harness => {
            %harness,
            parse_failure => 1,
        },
        errors => [{
            fail    => 1,
            tag     => 'HARNESS',
            details => "Error parsing event:\n======\n$edata\n======\n$err",
        }],
    );
}

sub _process_text {
    my $self   = shift;
    my %params = @_;

    my $source = $params{source};
    my $line   = $params{line};

    $line = $self->_process_harness_line($source => $line);
    $line = $self->{+BUFFERS}->{$source} .= $line;

    # If it does not end with a newline it is not ready yet.
    return unless chomp($line);

    $self->{+BUFFERS}->{$source} = "";

    my $parse_meth = $params{parse_meth};
    my $facet_data = $self->{+TAP_PARSER}->$parse_meth($line);

    if ($facet_data) {
        $facet_data->{harness}->{from_tap} = $line;
    }
    else {
        my $info = $params{info};
        $facet_data //= {info => [{details => $line, %$info}]};
    }

    my $harness = $params{harness};
    $facet_data->{harness}->{$_} = $harness->{$_} for keys %$harness;

    $facet_data->{harness}->{from_ord} = $self->{+ORDS}->{$source}++;

    push @{$self->{+PENDING}->{$source}} => $self->gen_event($facet_data);
}

sub _process_harness_line {
    my $self = shift;
    my ($source, $line) = @_;

    my $job_id = $self->{+JOB_ID};

    if ($line =~ s/\QT2-HARNESS-$job_id-\E(ESYNC|EVENT):(.*)[\n\r]+//) {
        my ($type, $payload) = ($1, $2);

        my ($e, $stamp, $event_id, $ord);

        if ($type eq 'ESYNC') {
            if ($payload =~ m/\s*(\S+)\s+(\S+)\s*/) {
                ($stamp, $event_id) = ($1, $2);
                $ord = $self->{+ORDS}->{$source};
            }
            else {
                $ord = $self->{+ORDS}->{$source}++;

                $e = $self->gen_harness_event(
                    harness => {
                        from_stream   => $source,
                        from_ord      => $ord,
                        parse_failure => 1,
                    },
                    errors => [{
                        fail    => 1,
                        tag     => 'HARNESS',
                        details => "Error parsing $type '$payload'",
                    }],
                );
            }
        }
        else {
            $payload =~ s/^\s+//g;
            $ord = $self->{+ORDS}->{$source}++;
            my $e = $self->_process_event(
                $line,
                from_stream => $source,
                from_ord    => $ord,
            );

            unless ($e->facet_data->{harness}->{parse_failure}) {
                $stamp    = $e->stamp;
                $event_id = $e->event_id;
            }
        }

        $self->{+STAMPS}->{$source} = $stamp if $stamp;
        $self->{+SYNCS}->{$source}  = $ord   if $ord;

        push @{$self->{+PENDING}->{$source}} => $e if $e;

        $self->{+SYNCS}->{$event_id}->{$source} = $ord // $self->{+ORDS}->{$source} if $event_id;
    }

    return $line;
}

1;
