package Test2::Harness::Overseer::Recorder;
use strict;
use warnings;

use Carp qw/croak/;

use Test2::Harness::Event qw/TERMINATOR/;

our $VERSION = '1.000043';

use Test2::Harness::Util::HashBase qw{ <fh };

sub init {
    my $self = shift;
    croak "'fh' is a required attribute" unless $self->{+FH};
}

sub process {
    my $self = shift;
    my ($events) = @_;

    for my $e (@$events) {
        my $json  = $e->as_json;
        my $level = $e->level;

        print {$self->{+FH}} "$level\n$json\n";
    }

    return $events;
}

sub finish {
    my $self = shift;
    $self->process(@_);
    print {$self->{+FH}} TERMINATOR, "\nnull\n";
    close($self->{+FH});
}

1;
