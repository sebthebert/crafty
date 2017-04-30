package Crafty::Pool;
use Moo;

has 'config', is => 'ro', required => 1;
has 'db',     is => 'ro', required => 1;
has 'on_event', is => 'ro';

has '_on_destroy', is => 'rw';
has '_pool',       is => 'rw';

use Promises qw(deferred);
use AnyEvent::Fork;
use AnyEvent::Fork::Pool;
use Crafty::Log;
use Crafty::Fork::Pool;

sub start {
    my $self = shift;

    $self->{status} = {};

    my $workers = $self->config->{config}->{pool}->{workers}
      // scalar AnyEvent::Fork::Pool::ncpu [4];

    my $pool =
      AnyEvent::Fork->new->require('Crafty::Pool::Worker')
      ->Crafty::Fork::Pool::run(
        'Crafty::Pool::Worker::run',
        max        => $workers,
        idle       => $workers,
        load       => 1,
        start      => 0.1,
        stop       => 2,
        on_destroy => sub {
            Crafty::Log->info('Pool destroyed');

            $self->_on_destroy->() if $self->_on_destroy;
        },
        async    => 1,
        on_error => sub {
            Crafty::Log->info('Worker exited');
        },
        on_event => sub { $self->_handle_worker_event(@_) },
        init       => 'Crafty::Pool::Worker::init',
        serialiser => $AnyEvent::Fork::RPC::JSON_SERIALISER,
      );

    $self->_pool($pool);

    Crafty::Log->info('Pool started with %s worker(s)', $workers);

    $self->{peek} = AnyEvent->timer(
        interval => 10,
        cb       => sub { $self->peek }
    );

    return $self;
}

sub queue {
    return @Crafty::Fork::Pool::queue;
}

sub peek {
    my $self = shift;

    return if $self->{peeking};

    my $max_queue = $self->config->{config}->{pool}->{max_queue} // 10;

    my $slots = $max_queue - $self->queue;

    if ($slots && $slots > 0) {
        return if $self->{peeking};

        $self->{peeking}++;

        $self->db->find(
            where    => [ status  => 'I' ],
            order_by => [ created => 'ASC' ],
            limit    => 1
          )->then(
            sub {
                my ($builds) = @_;

                return deferred->reject unless @$builds;

                return $self->db->lock($builds->[0]);
            }
          )->then(
            sub {
                my ($build, $locked) = @_;

                if ($locked) {
                    $self->_build($build);
                }

                delete $self->{peeking};
            }
          )->catch(
            sub {
                delete $self->{peeking};
            }
          );
    }
}

sub stop {
    my $self = shift;
    my ($done) = @_;

    return unless $self->_pool;

    if (my @queue = $self->queue) {
        Crafty::Log->info('Cleaning up queue (%s)', scalar(@queue));

        @Crafty::Fork::Pool::queue = ();
    }

    my $workers = $self->{status};

    my @waitlist;
    if (%$workers) {
        foreach my $worker_pid (keys %$workers) {
            my $uuid = $workers->{$worker_pid}->{uuid};
            my $pid  = $workers->{$worker_pid}->{pid};

            if ($pid && kill 0, $pid) {
                push @waitlist, { uuid => $uuid, pid => $pid };
            }
        }
    }

    if (@waitlist) {
        Crafty::Log->info('Waiting for workers to finish (%s)',
            scalar(@waitlist));

        $self->{t} = AnyEvent->timer(
            interval => 2,
            cb       => sub {
                foreach my $wait (@waitlist) {
                    if (kill 0, $wait->{pid}) {
                        Crafty::Log->info("Waiting for $wait->{pid}...");
                        return;
                    }
                }

                delete $self->{t};

                $self->_stop($done);
            }
        );
    }
    else {
        $self->_stop($done);
    }

    return $self;
}

sub _stop {
    my $self = shift;
    my ($done) = @_;

    $self->{cv}->recv if $self->{cv};

    $self->_on_destroy(sub { $done->() if $done });
    $self->_pool(undef);
}

sub _build {
    my $self = shift;
    my ($build) = @_;

    my $project_config = $self->config->project($build->project);

    Crafty::Log->info('Build %s scheduled', $build->uuid);

    $self->{cv} //= AnyEvent->condvar;

    $self->{cv}->begin;

    $build->start;

    $self->_sync_build($build)->then(
        sub {
            $self->_pool->(
                $self->config->{config}->{pool}, $build->to_hash,
                $project_config->{build}, sub { }
            );
        }
    );
}

sub cancel {
    my $self = shift;
    my ($build) = @_;

    my $canceled = 0;
    foreach my $worker_id (keys %{ $self->{status} }) {
        my $worker = $self->{status}->{$worker_id};

        Crafty::Log->info('Canceling build %s', $build->uuid);

        if ($worker->{uuid} eq $build->uuid) {
            if ($worker->{status} eq 'forked') {
                $worker->{status} = 'killing';

                Crafty::Log->info('Sending INT to build %s', $build->uuid);

                $self->_kill_build($worker);
            }
            else {
                Crafty::Log->info('Build %s already finished', $build->uuid);
            }

            $canceled++;
            last;
        }
    }

    if (!$canceled) {
        Crafty::Log->info('Build %s unknown to pool, removing', $build->uuid);

        $build->finish('K');
        $self->_sync_build($build);
    }
}

sub _kill_build {
    my $self = shift;
    my ($worker) = @_;

    my $uuid = $worker->{uuid};

    kill 'INT', $worker->{pid};

    my $attempts = 0;
    $worker->{t} = AnyEvent->timer(
        interval => 0.5,
        cb       => sub {
            if (kill 0, $worker->{pid}) {
                $attempts++;

                if ($attempts > 5) {
                    Crafty::Log->info('Sending KILL to build %s', $uuid);

                    kill 'KILL', $worker->{pid};

                    Crafty::Log->info('Build %s killed', $uuid);
                }
                else {
                    Crafty::Log->info(
                        'Waiting for build %s to terminate [attempt %d]',
                        $uuid, $attempts);
                }
            }
            else {
                Crafty::Log->info('Build %s terminated', $uuid);

                delete $worker->{t};
            }
        }
    );
}

sub _handle_worker_event {
    my $self = shift;
    my ($worker_id, $ev, $uuid, @args) = @_;

    my $worker = $self->{status}->{$worker_id} //= {};

    $worker->{uuid} = $uuid;

    $self->{cv} //= AnyEvent->condvar;

    if ($ev eq 'build.started') {
        Crafty::Log->info('Build %s started', $uuid);

        $worker->{status} = 'started';

        $self->on_event->($ev, $uuid, @args) if $self->on_event;
    }
    elsif ($ev eq 'build.pid') {
        my $pid = $args[0];

        Crafty::Log->info('Build %s forked (%s)', $uuid, $pid);

        $worker->{status} = 'forked';

        $worker->{pid} = $pid;

        $self->{cv}->begin;

        $self->db->load($uuid)->then(
            sub {
                my ($build) = @_;

                $build->pid($pid);

                $self->db->update_field($build, pid => $pid)->then(
                    sub {
                        $self->{cv}->end;

                        $self->on_event->($ev, $uuid, @args) if $self->on_event;
                    }
                  )->catch(
                    sub {
                        Crafty::Log->error("Build %s field sync failed", $build->uuid);

                        $self->{cv}->end;

                        $self->on_event->($ev, $uuid, @args) if $self->on_event;
                    }
                  );
            }
        );
    }
    elsif ($ev eq 'build.done') {
        my $exit_code = $args[0];

        my $final_status = defined $exit_code ? $exit_code ? 'F' : 'S' : 'K';

        Crafty::Log->info('Build %s finished with status %s',
            $uuid, $final_status);

        $self->{cv}->begin;

        $self->db->load($uuid)->then(
            sub {
                my ($build) = @_;

                $build->finish($final_status);

                $self->_sync_build(
                    $build,
                    sub {
                        $self->on_event->($ev, $uuid, @args) if $self->on_event;
                    }
                );
            }
        );

        delete $self->{status}->{$worker_id}->{$uuid};
    }
    elsif ($ev eq 'build.error') {
        my $error = $args[0];

        Crafty::Log->error($error);

        Crafty::Log->info('Build %s errored', $uuid);

        $self->{cv}->begin;

        $self->db->load($uuid)->then(
            sub {
                my ($build) = @_;

                $build->finish('E');

                $self->_sync_build(
                    $build,
                    sub {
                        $self->on_event->($ev, $uuid, @args) if $self->on_event;
                    }
                );
            }
        );

        delete $self->{status}->{$worker_id}->{$uuid};
    }

    if ($ev eq 'build.done' || $ev eq 'build.error') {
        $self->peek;
    }

    return $self;
}

sub _sync_build {
    my $self = shift;
    my ($build, $done) = @_;

    $self->db->save($build)->then(
        sub {
            $self->{cv}->end;

            $done->() if $done;
        }
      )->catch(
        sub {
            Crafty::Log->error("Build %s sync failed", $build->uuid);

            $self->{cv}->end;

            $done->() if $done;
        }
      );
}

1;
