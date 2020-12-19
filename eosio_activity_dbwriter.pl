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

my $dsn = 'DBI:MariaDB:database=eosio_activity;host=localhost';
my $db_user = 'eosio_activity';
my $db_password = 'De3PhooL';
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

my $sth_add_contract = $dbh->prepare
    ('INSERT INTO ' . $network . '_CONTRACTS ' .
     '(contract, istoken) ' .
     'VALUES(?,?) ' .
     'ON DUPLICATE KEY UPDATE istoken=?');

my $sth_add_counts = $dbh->prepare
    ('INSERT INTO ' . $network . '_DAILY_COUNTS ' .
     '(xday, contract, authorizer, firstauth, action, counter) ' .
     'VALUES(?,?,?,?,?,1) ' .
     'ON DUPLICATE KEY UPDATE counter=counter+1');

my $sth_add_actions = $dbh->prepare
    ('INSERT INTO ' . $network . '_DAILY_ACTIONS ' .
     '(xday, contract, action, counter) ' .
     'VALUES(?,?,?,1) ' .
     'ON DUPLICATE KEY UPDATE counter=counter+1');

my $sth_add_payin = $dbh->prepare
    ('INSERT INTO ' . $network . '_DAILY_PAYIN ' .
     '(xday, contract, tkcontract, currency, user, amount, counter) ' .
     'VALUES(?,?,?,?,?,?,1) ' .
     'ON DUPLICATE KEY UPDATE amount=amount+?, counter=counter+1');

my $sth_add_payout = $dbh->prepare
    ('INSERT INTO ' . $network . '_DAILY_PAYOUT ' .
     '(xday, contract, tkcontract, currency, user, amount, counter) ' .
     'VALUES(?,?,?,?,?,?,1) ' .
     'ON DUPLICATE KEY UPDATE amount=amount+?, counter=counter+1');


my $sth_upd_sync = $dbh->prepare
    ('INSERT INTO SYNC (network, block_num) VALUES(?,?) ' .
     'ON DUPLICATE KEY UPDATE block_num=?');

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
my %contract_accounts;
my %istoken;
{
    my $sth = $dbh->prepare('SELECT contract, istoken FROM ' . $network . '_CONTRACTS');
    $sth->execute();
    while( my $r = $sth->fetchrow_arrayref() )
    {
        $contract_accounts{$r->[0]} = 1;
        if( $r->[1] == 1 )
        {
            $istoken{$r->[0]} = 1;
        }
    }
}

my $blocks_counter = 0;
my $actions_counter = 0;
my $counter_start = time();

my $prev_day;


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
                my $block_date = $data->{'block_timestamp'};
                $block_date =~ s/T.*//;
                
                foreach my $atrace (@{$trace->{'action_traces'}})
                {
                    process_atrace($atrace, $block_date);
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
            printf STDERR ("blocks/s: %5.2f, actions/block: %5.2f, actions/s: %5.2f, gap: %6.2fh, ",
                           $blocks_counter/$period, $actions_counter/$blocks_counter, $actions_counter/$period,
                           $gap);
            $counter_start = time();
            $blocks_counter = 0;
            $actions_counter = 0;
            
            if( $uncommitted_block > $stored_block )
            {
                $sth_upd_sync->execute($network, $uncommitted_block, $uncommitted_block);
                $dbh->commit();
                $stored_block = $uncommitted_block;
                
                my $block_date = $data->{'block_timestamp'};
                $block_date =~ s/T.*//;
                if( defined($prev_day) and $prev_day ne $block_date )
                {
                    my $sth = $dbh->prepare
                        ('INSERT INTO ' . $network . '_AGGR_COUNTS ' .
                         ' (xday, contract, action, firstauth, numusers, counter) ' .
                         'SELECT xday, contract, action, firstauth, COUNT(*), SUM(counter) ' .
                         'FROM ' . $network . '_DAILY_COUNTS WHERE xday=? '.
                         ' GROUP BY xday, contract, action, firstauth');
                    $sth->execute($prev_day);
                    $sth->finish();
                    $dbh->commit();
                    
                    $sth = $dbh->prepare
                        ('INSERT INTO ' . $network . '_AGGR_PAYIN (xday, contract, tkcontract, currency, ' .
                         'numusers, amount, counter) ' .
                         'SELECT xday, contract, tkcontract, currency, ' .
                         'COUNT(*), SUM(amount), SUM(counter) ' .
                         'FROM ' . $network . '_DAILY_PAYIN WHERE xday=? ' .
                         'GROUP BY xday, contract, tkcontract, currency');
                    $sth->execute($prev_day);
                    $sth->finish();
                    $dbh->commit();
                    
                    $sth = $dbh->prepare
                        ('INSERT INTO ' . $network . '_AGGR_PAYOUT (xday, contract, tkcontract, currency, ' .
                         'numusers, amount, counter) ' .
                         'SELECT xday, contract, tkcontract, currency, ' .
                         'COUNT(*), SUM(amount), SUM(counter) ' .
                         'FROM ' . $network . '_DAILY_PAYOUT WHERE xday=? ' .
                         'GROUP BY xday, contract, tkcontract, currency');
                    $sth->execute($prev_day);
                    $sth->finish();
                    $dbh->commit();
                    
                    printf STDERR ("saved aggregates for %s\n", $prev_day);
                }
                
                $prev_day = $block_date;
            }
            return $committed_block;
        }
    }

    return 0;
}


sub process_atrace
{
    my $atrace = shift;
    my $block_date = shift;

    my $act = $atrace->{'act'};
    my $contract = $act->{'account'};
    my $receipt = $atrace->{'receipt'};
    
    if( $receipt->{'receiver'} eq $contract )
    {
        $actions_counter++;
        
        my $aname = $act->{'name'};
        my $data = $act->{'data'};
        return unless ( ref($data) eq 'HASH' );

        my $firstauth = 1;
        foreach my $auth (@{$act->{'authorization'}})
        {
            $sth_add_counts->execute($block_date, $contract, $auth->{'actor'}, $firstauth, $aname);
            $firstauth = 0;
        }

        $sth_add_actions->execute($block_date, $contract, $aname);
        
        my $thisistoken;
        
        if( $aname eq 'transfer' and 
            defined($data->{'quantity'}) and
            defined($data->{'to'}) and defined($data->{'from'}) )
        {
            my ($amount, $currency) = split(/\s+/, $data->{'quantity'});
            if( defined($amount) and defined($currency) and
                $amount =~ /^[0-9.]+$/ and $currency =~ /^[A-Z]{1,7}$/ )
            {
                $thisistoken = 1;
                
                my $sth;
                my $dapp;
                my $user;
                
                if( $contract_accounts{$data->{'to'}} )
                {
                    $sth = $sth_add_payin;
                    $dapp = $data->{'to'};
                    $user = $data->{'from'};
                }
                elsif( $contract_accounts{$data->{'from'}} )
                {
                    $sth = $sth_add_payout;
                    $dapp = $data->{'from'};
                    $user = $data->{'to'};
                }

                if( defined($sth) )
                {
                    $sth->execute($block_date, $dapp, $contract,
                                  $currency, $user, $amount, $amount);
                }
            }
        }

        if( not $contract_accounts{$contract} )
        {
            $contract_accounts{$contract} = 1;
            $sth_add_contract->execute($contract, 0, 0);
        }

        if( $thisistoken and not $istoken{$contract} )
        {
            $istoken{$contract} = 1;
            $sth_add_contract->execute($contract, 1, 1);
        }
    }    
}



    
        


   
