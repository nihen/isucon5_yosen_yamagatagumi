#!/usr/bin/perl
use strict;
use warnings;
use utf8;
use FindBin;
use Parallel::Prefork;
use Gearman::Worker;
use Isucon5::Model;

warn "worker start";

my $max_job_per_child = 1000;

my $pm = Parallel::Prefork->new({
    max_workers  => 10,
    trap_signals => {
        # 親がTERM/HUPを受けたら子供にTERMを送る
        TERM => 'TERM',
        HUP  => 'TERM',
    }
});

# 親がTERMかHUPをうけたら死ぬように
while ( not ($pm->signal_received ~~ [qw/TERM HUP/]) ) {
    $pm->start(\&work);
}

$pm->wait_all_children();

sub gearman_worker {
    my $worker = Gearman::Worker->new;
    $worker->job_servers('127.0.0.1:3010');

    $worker->register_function('modify_cache_from_profile', sub {
        Isucon5::Model::modify_cache_from_profile(@_);
    });
    $worker->register_function('modify_cache_from_entry', sub {
        Isucon5::Model::modify_cache_from_entry(@_);
    });
    $worker->register_function('modify_cache_from_comment', sub {
        Isucon5::Model::modify_cache_from_comment(@_);
    });
    $worker->register_function('modify_cache_from_friend', sub {
        Isucon5::Model::modify_cache_from_friend(@_);
    });
    $worker->register_function('modify_cache_from_footprint', sub {
        Isucon5::Model::modify_cache_from_footprint(@_);
    });

    return $worker;
}
sub work {
    my $worker = gearman_worker();

    my $job_count = 0;
    local $SIG{TERM} = sub { $job_count = $max_job_per_child; };
    $worker->work(
        on_start => sub {
            $job_count++;
        },
        stop_if => sub {
            $job_count >= $max_job_per_child
        },
    );
}
