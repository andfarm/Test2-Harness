package Test2::Harness::Overseer;
use strict;
use warnings;

our $VERSION = '1.000043';

use Carp qw/croak/;
use POSIX qw/:sys_wait_h/;
use Fcntl qw/SEEK_CUR/;
use Time::HiRes qw/time sleep/;

use Test2::Harness::Util::IPC qw/USE_P_GROUPS/;

use Test2::Harness::Overseer::Muxer;
use Test2::Harness::Overseer::Auditor;
use Test2::Harness::Overseer::Recorder;

use Test2::Harness::Util::HashBase qw{
    <job_id
    <job_try
    <job

    <output_handle
    <source_handles
    <buffers

    <master_pid
    <child_pid

    <muxer
    <auditor
    <time_tracker
    <recorder

    <event_timeout
    <exit_timeout

    <child_exited

    +signal

    <start_stamp
};

sub init {
    my $self = shift;

    $self->{+START_STAMP} //= time;

    croak "'job' is a required attribute"            unless $self->{+JOB};
    croak "'job_id' is a required attribute"         unless $self->{+JOB_ID};
    croak "'job_try' is a required attribute"        unless defined $self->{+JOB_TRY};
    croak "'child_pid' is a required attribute"      unless $self->{+CHILD_PID};
    croak "'output_handle' if a required attribute"  unless $self->{+OUTPUT_HANDLE};
    croak "'source_handles' if a required attribute" unless $self->{+SOURCE_HANDLES};


    $_->blocking(0) for values %{$self->{+SOURCE_HANDLES}};

    my @args = (
        JOB()     => $self->{+JOB},
        JOB_ID()  => $self->{+JOB_ID},
        JOB_TRY() => $self->{+JOB_TRY},
    );

    $self->{+MUXER}    = Test2::Harness::Overseer::Muxer->new(@args);
    $self->{+AUDITOR}  = Test2::Harness::Overseer::Auditor->new(@args);
    $self->{+RECORDER} = Test2::Harness::Overseer::Recorder->new(@args, fh => $self->{+OUTPUT_HANDLE});

    return;
}

sub event_chain {
    my $self = shift;
    my ($mux_meth, $other_meth, @input) = @_;

    my $events = $self->{+MUXER}->$mux_meth(@input);
    $self->{+AUDITOR}->$other_meth($events);
    $self->{+RECORDER}->$other_meth($events);
}

sub watch {
    my $self = shift;

    # Write out a job start event
    $self->event_chain(start => 'process', $self->{+JOB}, $self->{+START_STAMP});

    my $keep_going = 1;

    # This process (overseer) should ONLY ever have 1 child process, the one we
    # care about.
    local $SIG{CHLD} = sub { $keep_going = 1; $self->wait(fatal => 1) };
    local $SIG{$_} = do { my $sig = $_; sub { $keep_going = 1; $self->signal($sig) }} for qw/TERM INT/;

    # In case the sigchld already happened
    $self->wait(fatal => 0, inject => {early_exit => 1});

    my $handles = $self->{+SOURCE_HANDLES};
    my $buffers = $self->{+BUFFERS};

    my $child_exited;

    my $last_event = time;
    while ($keep_going || !$self->{+CHILD_EXITED}) {
        unless ($child_exited) {
            if ($child_exited = $self->{+CHILD_EXITED}) {
                $self->event_chain(exit => 'process', $child_exited);
            }
        }

        if ($self->{+MASTER_PID} && !kill(0, $self->{+MASTER_PID})) {
            $self->kill_child(lost_master => 'process', $self->{+MASTER_PID});
            last;
        }

        if (my $sig = $self->{+SIGNAL}) {
            $self->event_chain(signal => 'process', $sig);
            last;
        }

        sleep 0.05 unless $keep_going;
        $keep_going = 0;

        while (my ($source, $fh) = each %$handles) {
            my $line = <$fh> // next;
            $last_event = time;
            $keep_going++;

            if (substr($line, -1, 1) eq "\n") {
                $line = delete($buffers->{$source}) . $line if exists $buffers->{$source};
                $self->event_chain("process_$source" => 'process', $line, from_stream => $source);
            }
            else {
                $buffers->{$source} //= '';
                $buffers->{$source} .= $line;
                seek($fh, 0, SEEK_CUR) if -f $fh; # CLEAR EOF
            }
        }

        if (my $eto = $self->{+EVENT_TIMEOUT}) {
            my $timeout_check = time - $last_event;
            $self->do_timeout(event => $timeout_check) if $timeout_check >= $eto;
            last;
        }

        if (my $exit = $self->{+CHILD_EXITED}) {
            if (my $xto = $self->{+EXIT_TIMEOUT}) {
                my $timeout_check = time - $exit;
                $self->do_timeout(exit => $timeout_check) if $timeout_check >= $xto;
                last;
            }
        }
    }

    $SIG{CHLD} = 'DEFAULT';
    $self->wait(block => 1, fatal => 1) unless $self->{+CHILD_EXITED};
    unless ($child_exited) {
        if ($child_exited = $self->{+CHILD_EXITED}) {
            $self->event_chain(exit => 'process', $child_exited);
        }
    }

    $self->event_chain(finish => 'finish');

    if (my $sig = $self->{+SIGNAL}) {
        $SIG{$sig} = 'DEFAULT';

        $sig = "-$sig" if USE_P_GROUPS;
        kill($sig, $$);
    }

    return $self->{+AUDITOR}->fail ? 1 : 0;
}

sub do_timeout {
    my $self = shift;
    my ($type, $timeout) = @_;

    $self->kill_child(timeout => 'process', $type => $timeout);
}

sub kill_child {
    my $self = shift;
    my (@chain_args) = @_;

    my $sig = 'TERM';
    $self->event_chain(@chain_args, $sig);

    $sig = "-$sig" if USE_P_GROUPS;
    kill($sig, $self->{+CHILD_PID}) or return;

    # Wait for SIGCHLD or 5 seconds
    sleep 5;

    return if $self->{+CHILD_EXITED};

    $sig = 'KILL';
    $self->event_chain(@chain_args, $sig);

    $sig = "-$sig" if USE_P_GROUPS;
    kill($sig, $self->{+CHILD_PID});
}

sub wait {
    my $self = shift;
    my (%params) = @_;

    return if $self->{+CHILD_EXITED};

    my $check = waitpid($self->{+CHILD_PID}, $params{block} ? 0 : WNOHANG);
    my $exit = $?;

    # $check == 0 means the child is still running, if fatal is not set we simply return.
    # fatal being true means we got a signal and 0 means some other process
    # exited, that should not be possible in an overseer.
    return if $check == 0 && !$params{fatal};

    $SIG{CHLD} = 'DEFAULT';

    my $retry = $self->{+JOB_TRY} < $self->{+JOB}->retry ? 'will-retry' : '';

    my $event_data = {
        %{$params{inject} // {}},
        stamp    => time,
        wstat    => $exit,
        childpid => $self->{+CHILD_PID},
        waitpid  => $check,
        retry    => $retry,
    };

    $event_data->{error} = "Could not wait on process!"
        unless $check == $self->{+CHILD_PID};

    $self->{+CHILD_EXITED} = $event_data;

    return;
}

sub signal {
    my $self = shift;
    my ($sig) = @_;

    $self->{+SIGNAL} = {sig => $sig, stamp => time};

    print STDERR "Got signal $sig, forwarding signal to child, and closing out logs...\n";

    my $ssig = USE_P_GROUPS ? "-$sig" : $sig;
    kill($ssig, $self->{+CHILD_PID}) or warn "Could not forward signal ($sig) to child";

    # If we get the signal again use the default handler.
    $SIG{$sig} = 'DEFAULT';

    return;
}

1;
