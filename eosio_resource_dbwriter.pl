# install dependencies:
#  sudo apt install cpanminus libjson-xs-perl libjson-perl libmysqlclient-dev libdbi-perl
#  sudo cpanm Net::WebSocket::Server
#  sudo cpanm DBD::MariaDB

use strict;
use warnings;
use JSON;
use Getopt::Long;
use DBI;
use Time::HiRes qw (time);
use Time::Local 'timegm_nocheck';

use Net::WebSocket::Server;
use Protocol::WebSocket::Frame;

$Protocol::WebSocket::Frame::MAX_PAYLOAD_SIZE = 100*1024*1024;
$Protocol::WebSocket::Frame::MAX_FRAGMENTS_AMOUNT = 102400;

$| = 1;

my $network;

my $port = 8800;

my $dsn = 'DBI:MariaDB:database=eosio_resource;host=localhost';
my $db_user = 'eosio_resource';
my $db_password = 'tau9Oixe';
my $commit_every = 10;
my $endblock = 2**32 - 1;

my $ok = GetOptions
    ('network=s' => \$network,
     'port=i'    => \$port,
     'ack=i'     => \$commit_every,
     'endblock=i'  => \$endblock,
     'dsn=s'     => \$dsn,
     'dbuser=s'  => \$db_user,
     'dbpw=s'    => \$db_password,
    );


if( not $network or not $ok or scalar(@ARGV) > 0 )
{
    print STDERR "Usage: $0 --network=X [options...]\n",
        "Options:\n",
        "  --network=X        network name\n",
        "  --port=N           \[$port\] TCP port to listen to websocket connection\n",
        "  --ack=N            \[$commit_every\] Send acknowledgements every N blocks\n",
        "  --endblock=N       \[$endblock\] Stop before given block\n",
        "  --dsn=DSN          \[$dsn\]\n",
        "  --dbuser=USER      \[$db_user\]\n",
        "  --dbpw=PASSWORD    \[$db_password\]\n";
    exit 1;
}


my $dbh = DBI->connect($dsn, $db_user, $db_password,
                       {'RaiseError' => 1, AutoCommit => 0,
                        mariadb_server_prepare => 1});
die($DBI::errstr) unless $dbh;

my $sth_upd_sync = $dbh->prepare
    ('INSERT INTO SYNC (network, block_num) VALUES(?,?) ' .
     'ON DUPLICATE KEY UPDATE block_num=?');


my $sth_add_powerup = $dbh->prepare
    ('INSERT IGNORE INTO POWERUP ' .
     '(network, seq, block_num, block_time, trx_id, payer, receiver, ndays, net_frac, cpu_frac, ' .
     'max_payment, fee, powup_net, powup_cpu) ' .
     'VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)');


my $committed_block = 0;
my $stored_block = 0;
my $uncommitted_block = 0;
{
    my $sth = $dbh->prepare
        ('SELECT block_num FROM SYNC WHERE network=?');
    $sth->execute($network);
    my $r = $sth->fetchall_arrayref();
    if( scalar(@{$r}) > 0 )
    {
        $stored_block = $r->[0][0];
        printf STDERR ("Starting from stored_block=%d\n", $stored_block);
    }
}



my $json = JSON->new;

my $blocks_counter = 0;
my $counter_start = time();


Net::WebSocket::Server->new(
    listen => $port,
    on_connect => sub {
        my ($serv, $conn) = @_;
        $conn->on(
            'binary' => sub {
                my ($conn, $msg) = @_;
                my ($msgtype, $opts, $js) = unpack('VVa*', $msg);
                my $data = eval {$json->decode($js)};
                if( $@ )
                {
                    print STDERR $@, "\n\n";
                    print STDERR $js, "\n";
                    exit;
                }

                my $ack = process_data($msgtype, $data);
                if( $ack > 0 )
                {
                    $conn->send_binary(sprintf("%d", $ack));
                    print STDERR "ack $ack\n";
                }

                if( $ack >= $endblock )
                {
                    print STDERR "Reached end block\n";
                    exit(0);
                }
            },
            'disconnect' => sub {
                my ($conn, $code) = @_;
                print STDERR "Disconnected: $code\n";
                $dbh->rollback();
                $committed_block = 0;
                $uncommitted_block = 0;
            },

            );
    },
    )->start;


sub process_data
{
    my $msgtype = shift;
    my $data = shift;

    if( $msgtype == 1001 ) # CHRONICLE_MSGTYPE_FORK
    {
        my $block_num = $data->{'block_num'};
        print STDERR "fork at $block_num\n";
        $uncommitted_block = 0;
        return $block_num-1;
    }
    elsif( $msgtype == 1003 ) # CHRONICLE_MSGTYPE_TX_TRACE
    {
        if( $data->{'block_num'} > $stored_block )
        {
            my $trace = $data->{'trace'};
            if( $trace->{'status'} eq 'executed' )
            {
                my $block_time = $data->{'block_timestamp'};
                $block_time =~ s/T/ /;

                my $tx = {
                    'block_num' => $data->{'block_num'},
                    'block_time' => $block_time,
                    'trx_id' => $trace->{'id'},
                };

                my $row = {};

                foreach my $atrace (@{$trace->{'action_traces'}})
                {
                    process_atrace($tx, $atrace, $row);
                }

                if( defined($row->{'seq'}) and defined($row->{'fee'}) )
                {
                    $sth_add_powerup->execute(map {$row->{$_}}
                                              ('network',
                                               'seq',
                                               'block_num',
                                               'block_time',
                                               'trx_id',
                                               'payer',
                                               'receiver',
                                               'ndays',
                                               'net_frac',
                                               'cpu_frac',
                                               'max_payment',
                                               'fee',
                                               'powup_net',
                                               'powup_cpu'));

                    printf STDERR ('.');
                }
            }
        }
    }
    elsif( $msgtype == 1009 ) # CHRONICLE_MSGTYPE_RCVR_PAUSE
    {
        if( $uncommitted_block > $committed_block )
        {
            if( $uncommitted_block > $stored_block )
            {
                $sth_upd_sync->execute($network, $uncommitted_block, $uncommitted_block);
                $dbh->commit();
                $stored_block = $uncommitted_block;
            }
            $committed_block = $uncommitted_block;
            return $committed_block;
        }
    }
    elsif( $msgtype == 1010 ) # CHRONICLE_MSGTYPE_BLOCK_COMPLETED
    {
        $blocks_counter++;
        $uncommitted_block = $data->{'block_num'};
        if( $uncommitted_block - $committed_block >= $commit_every or
            $uncommitted_block >= $endblock )
        {
            $committed_block = $uncommitted_block;

            my $gap = 0;
            {
                my ($year, $mon, $mday, $hour, $min, $sec, $msec) =
                    split(/[-:.T]/, $data->{'block_timestamp'});
                my $epoch = timegm_nocheck($sec, $min, $hour, $mday, $mon-1, $year);
                $gap = (time() - $epoch)/3600.0;
            }

            my $period = time() - $counter_start;
            printf STDERR ("blocks/s: %8.2f, gap: %8.2fh, ",
                           $blocks_counter/$period, $gap);
            $counter_start = time();
            $blocks_counter = 0;

            if( $uncommitted_block > $stored_block )
            {
                $sth_upd_sync->execute($network, $uncommitted_block, $uncommitted_block);
                $dbh->commit();
                $stored_block = $uncommitted_block;
            }
            return $committed_block;
        }
    }

    return 0;
}


sub process_atrace
{
    my $tx = shift;
    my $atrace = shift;
    my $row = shift;

    my $act = $atrace->{'act'};
    my $contract = $act->{'account'};
    my $receipt = $atrace->{'receipt'};

    if( $receipt->{'receiver'} eq $contract )
    {
        my $data = $act->{'data'};
        return unless ( ref($data) eq 'HASH' );

        my $aname = $act->{'name'};

        if( $contract eq 'eosio' and $aname eq 'powerup' )
        {
            $row->{'network'} = $network;
            $row->{'seq'} = $receipt->{'global_sequence'};
            $row->{'block_num'} = $tx->{'block_num'};
            $row->{'block_time'} = $tx->{'block_time'};
            $row->{'trx_id'} = $tx->{'trx_id'};
            $row->{'payer'} = $data->{'payer'};
            $row->{'receiver'} = $data->{'receiver'};
            $row->{'ndays'} = $data->{'days'};
            $row->{'net_frac'} = $data->{'net_frac'};
            $row->{'cpu_frac'} = $data->{'cpu_frac'};

            my ($amount, $currency) = split(/\s+/, $data->{'max_payment'});
            $row->{'max_payment'} = $amount;

            printf STDERR ('!');
        }
        elsif( $contract eq 'eosio.reserv' and $aname eq 'powupresult' )
        {
            my ($amount, $currency) = split(/\s+/, $data->{'fee'});
            $row->{'fee'} = $amount;
            $row->{'powup_net'} = $data->{'powup_net'};
            $row->{'powup_cpu'} = $data->{'powup_cpu'};
            printf STDERR ('+');
        }
    }
}
