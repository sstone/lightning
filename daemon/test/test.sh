#! /bin/sh -e

# Wherever we are, we want to be in daemon/test dir.
cd `git rev-parse --show-toplevel`/daemon/test

. scripts/vars.sh

scripts/setup.sh

DIR1=/tmp/lightning.$$.1
DIR2=/tmp/lightning.$$.2
DIR3=/tmp/lightning.$$.3

REDIR1="$DIR1/output"
REDIR2="$DIR2/output"
REDIRERR1="$DIR1/errors"
REDIRERR2="$DIR2/errors"
FGREP="fgrep -q"

# We inject 0.01 bitcoin, but then fees (estimatefee fails and we use a
# fee rate as per the close tx).
AMOUNT=995940000

# Default fee rate per kb.
FEE_RATE=200000

# Fee in millisatoshi if we have no htlcs (note rounding to make it even)
NO_HTLCS_FEE=$((338 * $FEE_RATE / 2000 * 2000))
ONE_HTLCS_FEE=$(( (338 + 32) * $FEE_RATE / 2000 * 2000))
EXTRA_FEE=$(($ONE_HTLCS_FEE - $NO_HTLCS_FEE))

# Always use valgrind if available.
[ -n "$NO_VALGRIND" ] || PREFIX="valgrind -q --error-exitcode=7"

while [ $# != 0 ]; do
    case x"$1" in
	x"--valgrind-vgdb")
	    [ -n "$NO_VALGRIND" ] || PREFIX="valgrind --vgdb-error=1"
	    REDIR1="/dev/tty"
	    REDIRERR1="/dev/tty"
	    REDIR2="/dev/tty"
	    REDIRERR2="/dev/tty"
	    ;;
	x"--gdb1")
	    GDB1=1
	    ;;
	x"--gdb2")
	    GDB2=1
	    ;;
	x"--timeout-anchor")
	    TIMEOUT_ANCHOR=1
	    ;;
	x"--dump-onchain")
	    DUMP_ONCHAIN=1
	    ;;
	x"--steal")
	    STEAL=1
	    ;;
	x"--manual-commit")
	    MANUALCOMMIT=1
	    ;;
	x"--mutual-close-with-htlcs")
	    CLOSE_WITH_HTLCS=1
	    ;;
	x"--different-fee-rates")
	    DIFFERENT_FEES=1
	    ;;
	x"--normal")
	    ;;
	x"--crash")
	    CRASH_ON_FAIL=1
	    ;;
	x"--verbose")
	    VERBOSE=1
	    ;;
	*)
	    echo Unknown arg "$1" >&2
	    exit 1
    esac
    shift
done

LCLI1="../lightning-cli --lightning-dir=$DIR1"
LCLI2="../lightning-cli --lightning-dir=$DIR2"
LCLI3="../lightning-cli --lightning-dir=$DIR3"

if [ -n "$VERBOSE" ]; then
    FGREP="fgrep"
else
    # Suppress command output.
    exec >/dev/null
fi

lcli1()
{
    if [ -n "$VERBOSE" ]; then
	echo $LCLI1 "$@" >&2
    fi
    $LCLI1 "$@"
}

lcli2()
{
    if [ -n "$VERBOSE" ]; then
	echo $LCLI2 "$@" >&2
    fi
    $LCLI2 "$@"
}

lcli3()
{
    if [ -n "$VERBOSE" ]; then
	echo $LCLI3 "$@" >&2
    fi
    $LCLI3 "$@"
}

blockheight()
{
    $CLI getblockcount
}

# Usage: <cmd to test>...
check()
{
    local i=0
    while ! eval "$@"; do
	# Try making time pass for the nodes (if on mocktime), then sleeping.
	if [ -n "$MOCKTIME" ]; then 
	    MOCKTIME=$(($MOCKTIME + 1))
	    lcli1 dev-mocktime $MOCKTIME
	    lcli2 dev-mocktime $MOCKTIME
	fi
	sleep 1
	i=$(($i + 1))
	if [ $i = 20 ]; then
	    return 1
	fi
    done
}

check_status_single()
{
    lcli="$1"
    us_pay=$2
    us_fee=$3
    us_htlcs="$4"
    them_pay=$5
    them_fee=$6
    them_htlcs="$7"

    if check "$lcli getpeers | tr -s '\012\011\" ' ' ' | $FGREP \"our_amount : $us_pay, our_fee : $us_fee, their_amount : $them_pay, their_fee : $them_fee, our_htlcs : [ $us_htlcs], their_htlcs : [ $them_htlcs]\""; then :; else
	echo Cannot find $lcli output: '"our_amount" : '$us_pay', "our_fee" : '$us_fee', "their_amount" : '$them_pay', "their_fee" : '$them_fee', "our_htlcs" : [ '"$us_htlcs"'], "their_htlcs" : [ '"$them_htlcs"']' >&2
	$lcli getpeers | tr -s '\012\011 ' ' ' >&2
	return 1
    fi
}

check_status()
{
    us_pay=$1
    us_fee=$2
    us_htlcs="$3"
    them_pay=$4
    them_fee=$5
    them_htlcs="$6"

    check_status_single lcli1 "$us_pay" "$us_fee" "$us_htlcs" "$them_pay" "$them_fee" "$them_htlcs" 
    check_status_single lcli2 "$them_pay" "$them_fee" "$them_htlcs" "$us_pay" "$us_fee" "$us_htlcs"
}

check_staged()
{
    lcli="$1"
    what="$2"
    num_htlcs="$3"

    if check "$lcli getpeers | tr -s '\012\011\" ' ' ' | $FGREP ${what}_'staged_changes : '$num_htlcs"; then :; else
	echo Cannot find $lcli output: '"'${what}_'staged_changes" : '$num_htlcs >&2
	$lcli getpeers | tr -s '\012\011 ' ' ' >&2
	return 1
    fi
}

check_tx_spend()
{
    if check "$CLI getrawmempool | $FGREP '\"'"; then :;
    else
	echo "No tx in mempool:" >&2
	$CLI getrawmempool >&2
	exit 1
    fi
}

check_peerstate()
{
    if check "$1 getpeers | $FGREP -w $2"; then :
    else
	echo "$1" not in state "$2": >&2
	$1 getpeers >&2
	exit 1
    fi
}

check_peerconnected()
{
    if check "$1 getpeers | tr -s '\012\011\" ' ' ' | $FGREP -w 'connected : '$2"; then :
    else
	echo "$1" not connected "$2": >&2
	$1 getpeers >&2
	exit 1
    fi
}

check_no_peers()
{
    if check "$1 getpeers | tr -s '\012\011\" ' ' ' | $FGREP 'peers : [ ]'"; then :
    else
	echo "$1" still has peers: >&2
	$1 getpeers >&2
	exit 1
    fi
}
    
all_ok()
{
    # Look for valgrind errors.
    if grep ^== $DIR1/errors; then exit 1; fi
    if grep ^== $DIR2/errors; then exit 1; fi
    if grep ^== $DIR3/errors; then exit 1; fi
    scripts/shutdown.sh

    trap "rm -rf $DIR1 $DIR2 $DIR3" EXIT
    exit 0
}

if [ -n "$CRASH_ON_FAIL" ]; then
    trap "$LCLI1 dev-crash 2>/dev/null || true; $LCLI2 dev-crash 2>/dev/null || true; echo Crash results in $DIR1 and $DIR2 >&2; cat $DIR1/errors $DIR2/errors >&2" EXIT
else
    trap "echo Results in $DIR1 and $DIR2 >&2; cat $DIR1/errors $DIR2/errors >&2" EXIT
fi
mkdir $DIR1 $DIR2 $DIR3

if [ -n "$MANUALCOMMIT" ]; then
    # Aka. never. 
    COMMIT_TIME=1h
else
    COMMIT_TIME=10ms
fi

cat > $DIR1/config <<EOF
log-level=debug
bitcoind-poll=1s
deadline-blocks=5
min-htlc-expiry=6
bitcoin-datadir=$DATADIR
locktime-blocks=6
commit-time=$COMMIT_TIME
EOF

cat > $DIR2/config <<EOF
log-level=debug
bitcoind-poll=1s
deadline-blocks=5
min-htlc-expiry=6
bitcoin-datadir=$DATADIR
locktime-blocks=6
commit-time=$COMMIT_TIME
EOF

cp $DIR2/config $DIR3/config

if [ -n "$DIFFERENT_FEES" ]; then
    FEE_RATE2=300000
    CLOSE_FEE_RATE2=30000
    echo "commit-fee-rate=$FEE_RATE2" >> $DIR2/config
    echo "closing-fee-rate=$CLOSE_FEE_RATE2" >> $DIR2/config
fi

if [ -n "$GDB1" ]; then
    echo Press return once you run: gdb --args daemon/lightningd --lightning-dir=$DIR1 >&2
    read REPLY
else
    $PREFIX ../lightningd --lightning-dir=$DIR1 > $REDIR1 2> $REDIRERR1 &
fi

if [ -n "$GDB2" ]; then
    echo Press return once you run: gdb --args daemon/lightningd --lightning-dir=$DIR2 >&2
    read REPLY
else
    $PREFIX ../lightningd --lightning-dir=$DIR2 > $REDIR2 2> $REDIRERR2 &
fi
$PREFIX ../lightningd --lightning-dir=$DIR3 > $DIR3/output 2> $DIR3/errors &

if ! check "$LCLI1 getlog 2>/dev/null | $FGREP Hello"; then
    echo Failed to start daemon 1 >&2
    exit 1
fi

if ! check "$LCLI2 getlog 2>/dev/null | $FGREP Hello"; then
    echo Failed to start daemon 2 >&2
    exit 1
fi

if ! check "$LCLI3 getlog 2>/dev/null | $FGREP Hello"; then
    echo Failed to start daemon 3 >&2
    exit 1
fi

ID1=`$LCLI1 getlog | sed -n 's/.*"ID: \([0-9a-f]*\)".*/\1/p'`
ID2=`$LCLI2 getlog | sed -n 's/.*"ID: \([0-9a-f]*\)".*/\1/p'`
ID3=`$LCLI3 getlog | sed -n 's/.*"ID: \([0-9a-f]*\)".*/\1/p'`

PORT2=`$LCLI2 getlog | sed -n 's/.*on port \([0-9]*\).*/\1/p'`
PORT3=`$LCLI3 getlog | sed -n 's/.*on port \([0-9]*\).*/\1/p'`

# Make a payment into a P2SH for anchor.
P2SHADDR=`$LCLI1 newaddr | sed -n 's/{ "address" : "\(.*\)" }/\1/p'`
TXID=`$CLI sendtoaddress $P2SHADDR 0.01`
TX=`$CLI getrawtransaction $TXID`
$CLI generate 1

lcli1 connect localhost $PORT2 $TX

# Expect them to be waiting for anchor.
check_peerstate lcli1 STATE_OPEN_WAITING_OURANCHOR
check_peerstate lcli2 STATE_OPEN_WAITING_THEIRANCHOR

if [ -n "$TIMEOUT_ANCHOR" ]; then
    # Check anchor emitted, not mined deep enough.
    check_tx_spend lcli1
    $CLI generate 2

    # Timeout before anchor committed.
    MOCKTIME=$((`date +%s` + 7200 + 3 * 1200 + 1))

    lcli1 dev-mocktime $MOCKTIME
    lcli2 dev-mocktime $MOCKTIME

    # Node2 should have gone via STATE_ERR_ANCHOR_TIMEOUT, then closed.
    lcli2 getlog | grep STATE_ERR_ANCHOR_TIMEOUT
    check_no_peers lcli2

    # Node1 should be disconnected.
    check_peerconnected lcli1 false
    
    # Node1 should send out commit tx; mine it.
    check_tx_spend lcli1
    $CLI generate 1

    check_peerstate lcli1 STATE_CLOSE_ONCHAIN_OUR_UNILATERAL

    # Now "wait" for 1 day, which is what node2 asked for on commit.
    MOCKTIME=$(($MOCKTIME + 24 * 60 * 60 - 1))
    lcli1 dev-mocktime $MOCKTIME

    # Move bitcoind median time as well, so CSV moves.
    $CLI setmocktime $MOCKTIME
    $CLI generate 6

    # Now it should have spent the commit tx.
    check_tx_spend lcli1

    # 100 blocks pass...
    $CLI generate 100
    MOCKTIME=$(($MOCKTIME + 1))
    lcli1 dev-mocktime $MOCKTIME

    # Considers it all done now.
    check_no_peers lcli1

    lcli1 stop
    lcli2 stop
    all_ok
fi

# Now make it pass anchor (should be in mempool: three blocks bury it)
check_tx_spend lcli1
$CLI generate 3

check_peerstate lcli1 STATE_NORMAL
check_peerstate lcli2 STATE_NORMAL

# We turn off routing failure for the moment.
lcli1 dev-routefail false
lcli2 dev-routefail false

if [ -n "$DIFFERENT_FEES" ]; then 
    # This is 100,000 satoshi, so covers fees.
    HTLC_AMOUNT=100000000

    # Asymmetry, since fee rates different.
    NO_HTLCS_FEE2=$((338 * $FEE_RATE2 / 2000 * 2000))
    ONE_HTLCS_FEE2=$(( (338 + 32) * $FEE_RATE2 / 2000 * 2000))

    A_AMOUNT1=$(($AMOUNT - $NO_HTLCS_FEE))
    A_FEE1=$NO_HTLCS_FEE
    A_AMOUNT2=$(($AMOUNT - $NO_HTLCS_FEE2))
    A_FEE2=$NO_HTLCS_FEE2
    B_AMOUNT=0
    B_FEE=0
    
    check_status_single lcli1 $A_AMOUNT1 $A_FEE1 "" $B_AMOUNT $B_FEE "" 
    check_status_single lcli2 $B_AMOUNT $B_FEE "" $(($A_AMOUNT2)) $(($A_FEE2)) ""

    EXPIRY=$(( $(blockheight) + 10))
    SECRET=1de08917a61cb2b62ed5937d38577f6a7bfe59c176781c6d8128018e8b5ccdfd
    RHASH=`lcli1 dev-rhash $SECRET | sed 's/.*"\([0-9a-f]*\)".*/\1/'`
    lcli1 newhtlc $ID2 $HTLC_AMOUNT $EXPIRY $RHASH
    [ ! -n "$MANUALCOMMIT" ] || lcli1 commit $ID2
    [ ! -n "$MANUALCOMMIT" ] || lcli2 commit $ID1
    check_status_single lcli2 0 0 "" $(($AMOUNT - $HTLC_AMOUNT - $ONE_HTLCS_FEE2)) $(($ONE_HTLCS_FEE2)) '{ "msatoshis" : '$HTLC_AMOUNT', "expiry" : { "block" : '$EXPIRY' }, "rhash" : "'$RHASH'" } '
    lcli2 fulfillhtlc $ID1 $SECRET
    [ ! -n "$MANUALCOMMIT" ] || lcli2 commit $ID1
    [ ! -n "$MANUALCOMMIT" ] || lcli1 commit $ID2

    check_status_single lcli1 $(($AMOUNT - $HTLC_AMOUNT - $NO_HTLCS_FEE / 2)) $(($NO_HTLCS_FEE / 2)) "" $(($HTLC_AMOUNT - $NO_HTLCS_FEE / 2)) $(($NO_HTLCS_FEE / 2)) ""
    check_status_single lcli2 $(($HTLC_AMOUNT - $NO_HTLCS_FEE2 / 2)) $(($NO_HTLCS_FEE2 / 2)) "" $(($AMOUNT - $HTLC_AMOUNT - $NO_HTLCS_FEE2 / 2)) $(($NO_HTLCS_FEE2 / 2)) ""

    lcli1 close $ID2
    # Make sure they notice it.
    check_peerstate lcli1 STATE_MUTUAL_CLOSING
    check_peerstate lcli2 STATE_MUTUAL_CLOSING
    $CLI generate 1
    check_peerstate lcli1 STATE_CLOSE_ONCHAIN_MUTUAL
    check_peerstate lcli2 STATE_CLOSE_ONCHAIN_MUTUAL
    # Give it 100 blocks.
    $CLI generate 100
    check_no_peers lcli1
    check_no_peers lcli2

    lcli1 stop
    lcli2 stop

    all_ok
fi

A_AMOUNT=$(($AMOUNT - $NO_HTLCS_FEE))
A_FEE=$NO_HTLCS_FEE
B_AMOUNT=0
B_FEE=0
check_status $A_AMOUNT $A_FEE "" $B_AMOUNT $B_FEE ""

# This is 10,000 satoshi, so not dust!
HTLC_AMOUNT=10000000

EXPIRY=$(( $(blockheight) + 10))
SECRET=1de08917a61cb2b62ed5937d38577f6a7bfe59c176781c6d8128018e8b5ccdfd
RHASH=`lcli1 dev-rhash $SECRET | sed 's/.*"\([0-9a-f]*\)".*/\1/'`

lcli1 newhtlc $ID2 $HTLC_AMOUNT $EXPIRY $RHASH

if [ -n "$MANUALCOMMIT" ]; then
    # Nothing should have changed!
    check_status $A_AMOUNT $A_FEE "" $B_AMOUNT $B_FEE ""
    # But they should register a staged htlc.
    check_staged lcli2 local 1
    check_staged lcli1 remote 1

    # Now commit it.
    lcli1 commit $ID2

    # Node 1 hasn't got it committed, but node2 should have told it to stage.
    check_status_single lcli1 $A_AMOUNT $A_FEE "" $B_AMOUNT $B_FEE ""
    check_staged lcli1 local 1
    check_staged lcli2 remote 1

    # Check channel status
    A_AMOUNT=$(($A_AMOUNT - $EXTRA_FEE - $HTLC_AMOUNT))
    A_FEE=$(($A_FEE + $EXTRA_FEE))

    # Node 2 has it committed.
    check_status_single lcli2 $B_AMOUNT $B_FEE "" $A_AMOUNT $A_FEE '{ "msatoshis" : '$HTLC_AMOUNT', "expiry" : { "block" : '$EXPIRY' }, "rhash" : "'$RHASH'" } '

    # There should be no "both committed" here yet
    if lcli1 getlog debug | $FGREP "Both committed"; then
	echo "Node1 thinks they are both committed";
	exit 1
    fi
    if lcli2 getlog debug | $FGREP "Both committed"; then
	echo "Node2 thinks they are both committed";
	exit 1
    fi

    # Now node2 gives commitment to node1.
    lcli2 commit $ID1

    # After revocation, they should know they're both committed.
    check lcli1 "getlog debug | $FGREP 'Both committed to ADD of our HTLC'"
    check lcli2 "getlog debug | $FGREP 'Both committed to ADD of their HTLC'"
else
    A_AMOUNT=$(($A_AMOUNT - $EXTRA_FEE - $HTLC_AMOUNT))
    A_FEE=$(($A_FEE + $EXTRA_FEE))
fi

# Both should have committed tx.
check_status $A_AMOUNT $A_FEE '{ "msatoshis" : '$HTLC_AMOUNT', "expiry" : { "block" : '$EXPIRY' }, "rhash" : "'$RHASH'" } ' $B_AMOUNT $B_FEE ""

if [ -n "$STEAL" ]; then
    $LCLI1 dev-signcommit $ID2 >&2
    STEAL_TX=`$LCLI1 dev-signcommit $ID2 | cut -d\" -f4`
fi

if [ -n "$DUMP_ONCHAIN" ]; then
    # make node1 disconnect with node2.
    lcli1 dev-disconnect $ID2
    check_peerconnected lcli1 false

    # lcli1 should have sent out commitment tx
    check_peerstate lcli1 STATE_ERR_BREAKDOWN
    check_tx_spend lcli1

    # Mine it.
    $CLI generate 1
    check_peerstate lcli1 STATE_CLOSE_ONCHAIN_OUR_UNILATERAL
    check_peerstate lcli2 STATE_CLOSE_ONCHAIN_THEIR_UNILATERAL

    # both still know about htlc
    check_status $A_AMOUNT $A_FEE '{ "msatoshis" : '$HTLC_AMOUNT', "expiry" : { "block" : '$EXPIRY' }, "rhash" : "'$RHASH'" } ' $B_AMOUNT $B_FEE ""

    # Generate 6 blocks so CSV timeout has expired.
    $CLI generate 6

    # Now, lcli1 should spend its own output.
    check_tx_spend lcli1
    check_peerstate lcli1 STATE_CLOSE_ONCHAIN_OUR_UNILATERAL

    while [ $(blockheight) != $EXPIRY ]; do
	$CLI generate 1
    done

    # lcli1 should have gotten HTLC back.
    check_tx_spend lcli1

    # Now, after 100 blocks, should all be concluded.
    $CLI generate 100

    # Both consider it all done now.
    check_no_peers lcli1

    lcli1 stop
    all_ok
fi
    
lcli2 fulfillhtlc $ID1 $SECRET
[ ! -n "$MANUALCOMMIT" ] || lcli2 commit $ID1

# Without manual commit, this check is racy.
if [ -n "$MANUALCOMMIT" ]; then
    if lcli1 getlog debug | $FGREP 'Both committed to FULFILL'; then
	echo "Node1 thinks they are both committed";
	exit 1
    fi
    if lcli2 getlog debug | $FGREP 'Both committed to FULFILL'; then
	echo "Node2 thinks they are both committed";
	exit 1
    fi
fi
[ ! -n "$MANUALCOMMIT" ] || lcli1 commit $ID2

check lcli1 "getlog debug | $FGREP 'Both committed to FULFILL of our HTLC'"
check lcli2 "getlog debug | $FGREP 'Both committed to FULFILL of their HTLC'"

# We've transferred the HTLC amount to 2, who now has to pay fees,
# so no net change for A who saves on fees.
B_FEE=$HTLC_AMOUNT
# With no HTLCs, extra fee no longer required.
A_FEE=$(($A_FEE - $EXTRA_FEE - $B_FEE))
A_AMOUNT=$(($A_AMOUNT + $EXTRA_FEE + $HTLC_AMOUNT))

check_status $A_AMOUNT $A_FEE "" $B_AMOUNT $B_FEE ""

# A new one, at 10x the amount.
HTLC_AMOUNT=100000000

lcli1 newhtlc $ID2 $HTLC_AMOUNT $EXPIRY $RHASH
[ ! -n "$MANUALCOMMIT" ] || lcli1 commit $ID2
[ ! -n "$MANUALCOMMIT" ] || lcli2 commit $ID1

# Check channel status
A_AMOUNT=$(($A_AMOUNT - $EXTRA_FEE - $HTLC_AMOUNT))
A_FEE=$(($A_FEE + $EXTRA_FEE))
check_status $A_AMOUNT $A_FEE '{ "msatoshis" : '$HTLC_AMOUNT', "expiry" : { "block" : '$EXPIRY' }, "rhash" : "'$RHASH'" } ' $B_AMOUNT $B_FEE ""

lcli2 failhtlc $ID1 $RHASH
[ ! -n "$MANUALCOMMIT" ] || lcli2 commit $ID1
[ ! -n "$MANUALCOMMIT" ] || lcli1 commit $ID2

# Back to how we were before.
A_AMOUNT=$(($A_AMOUNT + $EXTRA_FEE + $HTLC_AMOUNT))
A_FEE=$(($A_FEE - $EXTRA_FEE))
check_status $A_AMOUNT $A_FEE "" $B_AMOUNT $B_FEE ""

# Same again, but this time it expires.
HTLC_AMOUNT=10000001
lcli1 newhtlc $ID2 $HTLC_AMOUNT $EXPIRY $RHASH
[ ! -n "$MANUALCOMMIT" ] || lcli1 commit $ID2
[ ! -n "$MANUALCOMMIT" ] || lcli2 commit $ID1

# Check channel status
A_AMOUNT=$(($A_AMOUNT - $EXTRA_FEE - $HTLC_AMOUNT))
A_FEE=$(($A_FEE + $EXTRA_FEE))
check_status $A_AMOUNT $A_FEE '{ "msatoshis" : '$HTLC_AMOUNT', "expiry" : { "block" : '$EXPIRY' }, "rhash" : "'$RHASH'" } ' $B_AMOUNT $B_FEE ""

# Make sure node1 accepts the expiry packet.
while [ $(blockheight) != $EXPIRY ]; do
    $CLI generate 1
done

# This should make node2 send it.
$CLI generate 1

if [ -n "$MANUALCOMMIT" ]; then
    # Don't commit until it's noticed the new block
    check_staged lcli2 remote 1

    lcli2 commit $ID1
    lcli1 commit $ID2
fi

# Back to how we were before.
A_AMOUNT=$(($A_AMOUNT + $EXTRA_FEE + $HTLC_AMOUNT))
A_FEE=$(($A_FEE - $EXTRA_FEE))
check_status $A_AMOUNT $A_FEE "" $B_AMOUNT $B_FEE ""

if [ -n "$STEAL" ]; then
    # Send out old commit tx from peer 1.
    $CLI sendrawtransaction $STEAL_TX
    $CLI generate 1

    # Node1 should get really upset; node2 should steal the transaction.
    check_peerstate lcli1 STATE_ERR_INFORMATION_LEAK
    check_peerstate lcli2 STATE_CLOSE_ONCHAIN_CHEATED
    check_tx_spend lcli2

    # Give it 100 blocks.
    $CLI generate 100

    check_no_peers lcli2

    lcli1 stop
    lcli2 stop
    
    all_ok
fi

# First, give more money to node2, so it can offer HTLCs.
EXPIRY=$(( $(blockheight) + 10))
HTLC_AMOUNT=100000000
lcli1 newhtlc $ID2 $HTLC_AMOUNT $EXPIRY $RHASH
[ ! -n "$MANUALCOMMIT" ] || lcli1 commit $ID2
[ ! -n "$MANUALCOMMIT" ] || lcli2 commit $ID1

check_status $(($A_AMOUNT - $HTLC_AMOUNT - $EXTRA_FEE)) $(($A_FEE + $EXTRA_FEE)) '{ "msatoshis" : '$HTLC_AMOUNT', "expiry" : { "block" : '$EXPIRY' }, "rhash" : "'$RHASH'" } ' $B_AMOUNT $B_FEE ""

lcli2 fulfillhtlc $ID1 $SECRET
[ ! -n "$MANUALCOMMIT" ] || lcli2 commit $ID1
[ ! -n "$MANUALCOMMIT" ] || lcli1 commit $ID2

# Both now pay equal fees.
A_FEE=$(($NO_HTLCS_FEE / 2))
B_FEE=$(($NO_HTLCS_FEE / 2))
# We transferred 10000000 before, and $HTLC_AMOUNT now.
A_AMOUNT=$(($AMOUNT - 10000000 - $HTLC_AMOUNT - $A_FEE))
B_AMOUNT=$((10000000 + $HTLC_AMOUNT - $B_FEE))

check_status $A_AMOUNT $A_FEE "" $B_AMOUNT $B_FEE ""

# Now, two HTLCs at once, one from each direction.
# Both sides can afford this.
HTLC_AMOUNT=1000000
lcli1 newhtlc $ID2 $HTLC_AMOUNT $EXPIRY $RHASH
SECRET2=1de08917a61cb2b62ed5937d38577f6a7bfe59c176781c6d8128018e8b5ccdfe
RHASH2=`lcli1 dev-rhash $SECRET2 | sed 's/.*"\([0-9a-f]*\)".*/\1/'`
lcli2 newhtlc $ID1 $HTLC_AMOUNT $EXPIRY $RHASH2
[ ! -n "$MANUALCOMMIT" ] || lcli1 commit $ID2
[ ! -n "$MANUALCOMMIT" ] || lcli2 commit $ID1
[ ! -n "$MANUALCOMMIT" ] || lcli1 commit $ID2

check_status $(($A_AMOUNT - $HTLC_AMOUNT - $EXTRA_FEE)) $(($A_FEE + $EXTRA_FEE)) '{ "msatoshis" : '$HTLC_AMOUNT', "expiry" : { "block" : '$EXPIRY' }, "rhash" : "'$RHASH'" } ' $(($B_AMOUNT - $HTLC_AMOUNT - $EXTRA_FEE)) $(($B_FEE + $EXTRA_FEE)) '{ "msatoshis" : '$HTLC_AMOUNT', "expiry" : { "block" : '$EXPIRY' }, "rhash" : "'$RHASH2'" } '

if [ -n "$CLOSE_WITH_HTLCS" ]; then
    # Now begin close
    lcli1 close $ID2

    # They should be waiting for it to clear up.
    check_peerstate lcli1 STATE_CLEARING
    check_peerstate lcli2 STATE_CLEARING

    # Fail one, still waiting.
    lcli2 failhtlc $ID1 $RHASH
    check_peerstate lcli1 STATE_CLEARING
    check_peerstate lcli2 STATE_CLEARING

    # Fulfill the other causes them to actually complete the close.
    lcli1 fulfillhtlc $ID2 $SECRET2
    check_peerstate lcli1 STATE_MUTUAL_CLOSING
    check_peerstate lcli2 STATE_MUTUAL_CLOSING

    $CLI generate 1

    check_peerstate lcli1 STATE_CLOSE_ONCHAIN_MUTUAL
    check_peerstate lcli2 STATE_CLOSE_ONCHAIN_MUTUAL

    # Give it 100 blocks.
    $CLI generate 99

    check_no_peers lcli1
    check_no_peers lcli2

    lcli1 stop
    lcli2 stop
    
    all_ok
fi

lcli2 failhtlc $ID1 $RHASH
lcli1 fulfillhtlc $ID2 $SECRET2
[ ! -n "$MANUALCOMMIT" ] || lcli2 commit $ID1
[ ! -n "$MANUALCOMMIT" ] || lcli1 commit $ID2
[ ! -n "$MANUALCOMMIT" ] || lcli2 commit $ID1

# We transferred amount from B to A.
A_AMOUNT=$(($A_AMOUNT + $HTLC_AMOUNT))
B_AMOUNT=$(($B_AMOUNT - $HTLC_AMOUNT))
check_status $A_AMOUNT $A_FEE "" $B_AMOUNT $B_FEE ""

# Now, test making more changes before receiving commit reply.
lcli2 dev-output $ID1 false
lcli1 newhtlc $ID2 $HTLC_AMOUNT $EXPIRY $RHASH

# Make sure node1 sends commit (in the background, since it will block!)
[ ! -n "$MANUALCOMMIT" ] || lcli1 commit $ID2 &
# node2 will consider this committed.
check_status_single lcli2 $(($B_AMOUNT - $EXTRA_FEE/2)) $(($B_FEE + $EXTRA_FEE/2)) "" $(($A_AMOUNT - $HTLC_AMOUNT - $EXTRA_FEE/2)) $(($A_FEE + $EXTRA_FEE/2)) '{ "msatoshis" : '$HTLC_AMOUNT', "expiry" : { "block" : '$EXPIRY' }, "rhash" : "'$RHASH'" } '

# Now send another offer, and enable node2 output.
lcli1 newhtlc $ID2 $HTLC_AMOUNT $EXPIRY $RHASH2
lcli2 dev-output $ID1 true

[ ! -n "$MANUALCOMMIT" ] || lcli2 commit $ID1
[ ! -n "$MANUALCOMMIT" ] || lcli1 commit $ID2
[ ! -n "$MANUALCOMMIT" ] || lcli2 commit $ID1

# Both sides should be committed to htlcs
check_status $(($A_AMOUNT - $HTLC_AMOUNT*2 - $EXTRA_FEE)) $(($A_FEE + $EXTRA_FEE)) '{ "msatoshis" : '$HTLC_AMOUNT', "expiry" : { "block" : '$EXPIRY' }, "rhash" : "'$RHASH'" }, { "msatoshis" : '$HTLC_AMOUNT', "expiry" : { "block" : '$EXPIRY' }, "rhash" : "'$RHASH2'" } ' $(($B_AMOUNT - $EXTRA_FEE)) $(($B_FEE + $EXTRA_FEE)) ""

# Node2 collects the HTLCs.
lcli2 fulfillhtlc $ID1 $SECRET
lcli2 fulfillhtlc $ID1 $SECRET2

[ ! -n "$MANUALCOMMIT" ] || lcli2 commit $ID1
[ ! -n "$MANUALCOMMIT" ] || lcli1 commit $ID2

# We transferred 2 * amount from A to B.
A_AMOUNT=$(($A_AMOUNT - $HTLC_AMOUNT * 2))
B_AMOUNT=$(($B_AMOUNT + $HTLC_AMOUNT * 2))
check_status $A_AMOUNT $A_FEE "" $B_AMOUNT $B_FEE ""

# Now, use automatic payment redemption
lcli1 dev-routefail true
lcli2 dev-routefail true
RHASH3=`lcli2 accept-payment $HTLC_AMOUNT | sed 's/.*"\([0-9a-f]*\)".*/\1/'`

lcli1 newhtlc $ID2 $HTLC_AMOUNT $EXPIRY $RHASH3
[ ! -n "$MANUALCOMMIT" ] || lcli1 commit $ID2
[ ! -n "$MANUALCOMMIT" ] || lcli2 commit $ID1

[ ! -n "$MANUALCOMMIT" ] || lcli2 commit $ID1
[ ! -n "$MANUALCOMMIT" ] || lcli1 commit $ID2

# We transferred amount from A to B.
A_AMOUNT=$(($A_AMOUNT - $HTLC_AMOUNT))
B_AMOUNT=$(($B_AMOUNT + $HTLC_AMOUNT))
check_status $A_AMOUNT $A_FEE "" $B_AMOUNT $B_FEE ""

# Now, failed payment (didn't pay enough)
RHASH4=`lcli2 accept-payment $HTLC_AMOUNT | sed 's/.*"\([0-9a-f]*\)".*/\1/'`

# Shouldn't have this already.
if lcli2 getlog | $FGREP 'Short payment for HTLC'; then exit 1; fi

lcli1 newhtlc $ID2 $(($HTLC_AMOUNT - 1)) $EXPIRY $RHASH4
[ ! -n "$MANUALCOMMIT" ] || lcli1 commit $ID2
[ ! -n "$MANUALCOMMIT" ] || lcli2 commit $ID1

[ ! -n "$MANUALCOMMIT" ] || lcli2 commit $ID1
[ ! -n "$MANUALCOMMIT" ] || lcli1 commit $ID2

check lcli2 "getlog | $FGREP 'Short payment for HTLC'"
check_status $A_AMOUNT $A_FEE "" $B_AMOUNT $B_FEE ""

if [ ! -n "$MANUALCOMMIT" ]; then
    # Test routing to a third node.
    P2SHADDR2=`$LCLI2 newaddr | sed -n 's/{ "address" : "\(.*\)" }/\1/p'`
    TXID2=`$CLI sendtoaddress $P2SHADDR2 0.01`
    TX2=`$CLI getrawtransaction $TXID2`
    $CLI generate 1

    lcli2 connect localhost $PORT3 $TX2
    check_tx_spend lcli2
    $CLI generate 3

    # Make sure it's STATE_NORMAL.
    check_peerstate lcli3 STATE_NORMAL

    # More than enough to cover commit fees.
    HTLC_AMOUNT=100000000

    # Tell node 1 about the 2->3 route.
    lcli1 add-route $ID2 $ID3 546000 10 36 36
    RHASH5=`lcli3 accept-payment $HTLC_AMOUNT | sed 's/.*"\([0-9a-f]*\)".*/\1/'`

    # Try wrong hash.
    if lcli1 pay $ID3 $HTLC_AMOUNT $RHASH4; then
	echo Paid with wrong hash? >&2
	exit 1
    fi

    # Try underpaying.
    if lcli1 pay $ID3 $(($HTLC_AMOUNT-1)) $RHASH5; then
	echo Paid with too little? >&2
	exit 1
    fi

    # Pay correctly.
    lcli1 pay $ID3 $HTLC_AMOUNT $RHASH5

    # Node 3 should end up with that amount (minus 1/2 tx fee)
    # Note that it is delayed a little, since node2 fulfils as soon as fulfill
    # starts.
    check lcli3 "getpeers | $FGREP \"\\\"our_amount\\\" : $(($HTLC_AMOUNT - $NO_HTLCS_FEE / 2))\""
    lcli3 close $ID2
fi

lcli1 close $ID2

# They should be negotiating the close.
check_peerstate lcli1 STATE_MUTUAL_CLOSING
check_peerstate lcli2 STATE_MUTUAL_CLOSING

$CLI generate 1

check_peerstate lcli1 STATE_CLOSE_ONCHAIN_MUTUAL
check_peerstate lcli2 STATE_CLOSE_ONCHAIN_MUTUAL

# Give it 99 blocks.
$CLI generate 98

# Make sure they saw it!
check_peerstate lcli1 STATE_CLOSE_ONCHAIN_MUTUAL
check_peerstate lcli2 STATE_CLOSE_ONCHAIN_MUTUAL

# Now the final one.
$CLI generate 1

check_no_peers lcli1
check_no_peers lcli2

lcli1 stop
lcli2 stop

all_ok
