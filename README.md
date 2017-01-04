# NAME

Test2::Harness - Test2 based test harness.

# DESCRIPTION

This is an alternative to [Test::Harness](https://metacpan.org/pod/Test::Harness). See the [App::Yath](https://metacpan.org/pod/App::Yath) module for
more details.

Try running the `yath` command inside a perl repository.

    $ yath

For help:

    $ yath --help

# USING THE HARNESS IN YOUR DISTRIBUTION

If you want to have your tests run via Test2::Harness instead of
[Test::Harness](https://metacpan.org/pod/Test::Harness) you need to do two things:

- Move your test files

    You need to put any tests that you want to run under Test2::Harness into a
    directory other than `t/`. A good name to pick is `t2/`, as it will not be
    picked up by [Test::Harness](https://metacpan.org/pod/Test::Harness) automatically.

- Add a test.pl script

    You need a script that loads Test2::Harness and tells it to run the tests. You
    can find this script in `examples/test.pl` in this distribution. The example
    test.pl is listed here for convenience:

        #!/usr/bin/env perl
        use strict;
        use warnings;

        # Change this to list the directories where tests can be found. This should not
        # include the directory where this file lives.

        my @DIRS = ('./t2');

        # PRELOADS GO HERE
        # Example:
        # use Moose;

        ###########################################
        # Do not change anything below this point #
        ###########################################

        use App::Yath;

        # After fork, Yath will break out of this block so that the test file being run
        # in the new process has as small a stack as possible. It would be awful to
        # have a bunch of Test2::Harness frames on all stack traces.
        T2_DO_FILE: {
            # Add eveything in @INC via -I so that using `perl -Idir this_file` will
            # pass the include dirs on to any tests that decline to accept the preload.
            my $yath = App::Yath->new(args => [(map { "-I$_" } @INC), '--exclude=use_harness', @DIRS, @ARGV]);

            # This is where we turn control over to yath.
            my $exit = $yath->run();
            exit($exit);
        }

        # At this point we are in a child process and need to run a test file specified
        # in this package var.
        my $file = $Test2::Harness::Runner::DO_FILE
            or die "No file to run!";

        # Test files do not always return a true value, so we cannot use require. We
        # also cannot trust $!
        $@ = '';
        do $file;
        die $@ if $@;
        exit 0;

    Most (if not all) module installation tools will find `test.pl` and run it,
    using the exit value to determine pass/fail.

    **Note:** Since Test2::Harness does not output the traditional TAP, you cannot
    use this example as a .t file in t/.

# SOURCE

The source code repository for Test2-Harness can be found at
`http://github.com/Test-More/Test2-Harness/`.

# MAINTAINERS

- Chad Granum <exodist@cpan.org>

# AUTHORS

- Chad Granum <exodist@cpan.org>

# COPYRIGHT

Copyright 2016 Chad Granum <exodist7@gmail.com>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See `http://dev.perl.org/licenses/`
