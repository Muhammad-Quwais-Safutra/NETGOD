use warnings;
use strict;
use Getopt::Std;
use Net::Pcap 0.16;
use File::Basename qw(basename);
use POSIX qw(:signal_h pause :sys_wait_h SIG_BLOCK SIG_UNBLOCK);
use Pod::Usage;
use Fcntl qw(:flock);
use Systemd::Daemon qw{ -soft };

BEGIN {
    use constant INSTALL_DIR => '/usr/local/pf';
    use lib INSTALL_DIR . "/lib";
    use pf::log(service => 'pfmon');
}

use pf::file_paths qw($var_dir);
use pf::accounting qw(acct_maintenance);
use pf::config qw(%Config);
use pf::config::pfmon qw(%ConfigPfmon);
use pf::factory::pfmon::task;
use pf::constants qw($FALSE $TRUE);
use pf::inline::accounting;
use pf::locationlog;
use pf::auth_log;
use pf::node;
use pf::db;
use pf::services;
use pf::util;
use pf::services::util;
use pf::violation qw(violation_maintenance);
use pf::ConfigStore::Provisioning;
use pf::factory::provisioner;
use pf::SwitchFactory;
use pf::radius_audit_log;
use pf::StatsD;
use pf::person;
use pf::fingerbank;
use fingerbank::Config;
use fingerbank::DB;
use pf::cluster;
use Time::HiRes qw(time sleep);
use pf::CHI::Request;

pf::SwitchFactory->preloadConfiguredModules();

our $PROGRAM_NAME = $0 = "pfmon";
our @REGISTERED_TASKS;
our $IS_CHILD = 0;
our %CHILDREN;
our @TASKS_RUN;
our $ALARM_RECV = 0;
our $DEFAULT_TASK_COUNT = 100;
our $DEFAULT_TASK_JITTER = 10;

my $logger = get_logger( $PROGRAM_NAME );
my $old_child_sigaction = POSIX::SigAction->new;

$SIG{ALRM} = \&alarm_sighandler;

$SIG{HUP} = \&reload_config;

$SIG{INT} = \&normal_sighandler;

$SIG{TERM} = \&normal_sighandler;

$SIG{CHLD} = \&child_sighandler;

POSIX::sigaction(
    &POSIX::SIGUSR1,
    POSIX::SigAction->new(
        'usr1_sighandler' , POSIX::SigSet->new(), &POSIX::SA_NODEFER
    )
) or die("pfmon could not set SIGUSR1 handler: $!");

my %args;
getopts( 'dhvr', \%args );

pod2usage( -verbose => 1 ) if ( $args{h} );

my $daemonize = $args{d};
my $verbose   = $args{v};
my $restart   = $args{r};

my $pidfile = "${var_dir}/run/pfmon.pid";

our $HAS_LOCK = 0;
open(my $fh,">>$pidfile");
flock($fh, LOCK_EX | LOCK_NB) or die "cannot lock $pidfile another pfmon is running\n";
$HAS_LOCK = 1;

our $running = 1;
our $TASKS   = 0;
our $process = 0;

daemonize($PROGRAM_NAME) if ($daemonize);
our $PARENT_PID = $$;


sub start {
    reload_config();
    registertasks();
    Systemd::Daemon::notify( READY => 1, STATUS => "Ready", unset => 1 );
    waitforit();
}

start();
cleanup();

END {
    if ( !$args{h} && $HAS_LOCK ) {
        unless($IS_CHILD) {
            Systemd::Daemon::notify( STOPPING => 1 );
            deletepid();
            $logger->info("stopping pfmon");
        }
    }
}

exit(0);

=head1 SUBROUTINES
=head2 registertasks
    Register all tasks
=cut

sub registertasks  {
    for my $task_id (keys %ConfigPfmon) {
        my $task = pf::factory::pfmon::task->new($task_id);
        next unless $task->is_enabled;
        register_task($task_id);
    }
}

=head2 cleanup
cleans after children
=cut

sub cleanup {
    kill_and_wait_for_children('INT',30);
    kill_and_wait_for_children('USR1',10);
    signal_children('KILL');
}

=head2 kill_and_wait_for_children
signal children and waits for them to exit process
=cut

sub kill_and_wait_for_children {
    my ($signal,$waittime) = @_;
    signal_children($signal);
    $ALARM_RECV = 0;
    alarm $waittime;
    while (((keys %CHILDREN) != 0 ) && !$ALARM_RECV) {
        pause;
    }
}

=head2 signal_children
sends a signal to all active children
=cut

sub signal_children {
    my ($signal) = @_;
    kill ( $signal, keys %CHILDREN);
}

=head2 normal_sighandler
the signal handler to shutdown the service
=cut

sub normal_sighandler {
    $running = 0;
}

=head2 reload_config
=cut

sub reload_config {
    if ( pf::cluster::is_management ) {
        $process = $TRUE;
    }
    elsif ( !$pf::cluster::cluster_enabled ) {
        $process = $TRUE;
    }
    else {
        $process = $FALSE;
    }

    $logger->debug("Reload configuration with status $process");
}

=head2 runtasks
run all runtasks
=cut

sub runtasks {
    my $mask = POSIX::SigSet->new(POSIX::SIGCHLD());
    sigprocmask(SIG_BLOCK,$mask);
    while(@REGISTERED_TASKS) {
        my $task = shift @REGISTERED_TASKS;
        runtask($task);
    }
    sigprocmask(SIG_UNBLOCK,$mask);
}

=head2 runtask
creates a new child to run a task
=cut

sub runtask {
    my ($task) = @_;
    db_disconnect();
    my $pid = fork();
    if($pid) {
        $CHILDREN{$pid} = $task;
    } elsif ($pid == 0) {
        $SIG{CHLD} = "DEFAULT";
        $IS_CHILD = 1;
        Log::Log4perl::MDC->put('tid', $$);
        _runtask($task);
    } else {
    }
}

=head2 _runtask
the task to is ran in a loop until it is finished
=cut

sub _runtask {
    my ($task_id) = @_;
    $0 = "pfmon - $task_id";
    my $time_taken = 0;
    $TASKS = tasks_count($DEFAULT_TASK_COUNT, $DEFAULT_TASK_JITTER);
    while (is_worker_runnable()) {
        pf::CHI::Request::clear_all();
        pf::log::reset_log_context();
        my $task = pf::factory::pfmon::task->new($task_id);
        my $interval = $task->interval;
        unless ($interval) {
            $logger->warn("task $task_id is disabled");
            $time_taken = 0;
            alarm 60;
            pause;
            next;
        }
        my $final_interval = $interval - $time_taken;
        $logger->trace("$task_id is sleeping for $final_interval ($interval from configuration - $time_taken)");
        if ($final_interval >= 1) {
            alarm $final_interval;
            pause;
            last unless $running;
        }
        
        $logger->trace("$task_id is running");
        my $start = time();
        if (db_check_readonly()) {
            $logger->warn(sub { "The database is in readonly mode skipping task $task_id" });
            $time_taken = 0;
            next;
        }

        eval {
            $task->run();
        };
        if ($@) {
            $logger->error("Error running task $task_id: $@");
        }
        $time_taken = time() - $start;
        unless(is_parent_alive()) {
            $logger->error("Parent is no longer running shutting down");
            $running = 0;
        }
    } continue {
        reload_config();
        if ($TASKS > 0) {
            $TASKS--;
        }
    }
    $logger->info("$$ $task_id shutting down");
    POSIX::_exit(0);
}

sub is_worker_runnable {
    $running && $process && $TASKS
}

sub tasks_count {
    my ($count, $jitter) = @_;
    if ($count <= 0) {
        return -1;
    }
    if ($jitter > $count / 4) {
        $jitter = int($count / 4);
    }

    return add_jitter($count, $jitter);
}

=head2 is_parent_alive
Checks to see if parent is alive
=cut

sub is_parent_alive {
    kill (0,$PARENT_PID)
}

=head2 register_task
registers the task to run
=cut

sub register_task {
    my ($taskId) = @_;
    push @REGISTERED_TASKS, $taskId;

}

=head2 waitforit
waits for signals
=cut

sub waitforit {
    while($running) {
        if ($process) {
            runtasks();
        }

        alarm(1);
        pause;
        $logger->debug("Awake from pause");
        reload_config();
    }
}


sub alarm_sighandler {
    $ALARM_RECV = 1;
}


sub child_sighandler {
    local ($!, $?);
    while(1) {
        my $child = waitpid(-1, WNOHANG);
        last unless $child > 0;
        my $task = delete $CHILDREN{$child};
        register_task($task);
    }
}

sub usr1_sighandler {
   db_cancel_current_query();
}
