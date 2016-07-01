#include "channel.h"
#include "htlc.h"
#include <assert.h>
#include <ccan/array_size/array_size.h>
#include <ccan/mem/mem.h>
#include <ccan/structeq/structeq.h>
#include <string.h>

uint64_t fee_by_feerate(size_t txsize, uint32_t fee_rate)
{
	/* BOLT #2:
	 * 
	 * The fee for a transaction MUST be calculated by multiplying this
	 * bytecount by the fee rate, dividing by 1000 and truncating
	 * (rounding down) the result to an even number of satoshis.
	 */
	return txsize * fee_rate / 2000 * 2;
}

static uint64_t calculate_fee_msat(size_t num_nondust_htlcs,
				   uint32_t fee_rate)
{
	uint64_t bytes;

	/* BOLT #2:
	 *
	 * A node MUST use the formula 338 + 32 bytes for every
	 * non-dust HTLC as the bytecount for calculating commitment
	 * transaction fees.  Note that the fee requirement is
	 * unchanged, even if the elimination of dust HTLC outputs has
	 * caused a non-zero fee already.
	*/
	bytes = 338 + 32 * num_nondust_htlcs;

	/* milli-satoshis */
	return fee_by_feerate(bytes, fee_rate) * 1000;
}

/* Total, in millisatoshi. */
static uint64_t htlcs_total(struct htlc **htlcs)
{
	size_t i, n = tal_count(htlcs);
	uint64_t total = 0;

	for (i = 0; i < n; i++)
		total += htlcs[i]->msatoshis;
	return total;
}

/* Pay this much fee, if possible.  Return amount unpaid. */
static uint64_t pay_fee(struct channel_oneside *side, uint64_t fee_msat)
{
	if (side->pay_msat >= fee_msat) {
		side->pay_msat -= fee_msat;
		side->fee_msat += fee_msat;
		return 0;
	} else {
		uint64_t remainder = fee_msat - side->pay_msat;
		side->fee_msat += side->pay_msat;
		side->pay_msat = 0;
		return remainder;
	}
}

/* Charge the fee as per BOLT #2 */
static void recalculate_fees(struct channel_oneside *a,
			     struct channel_oneside *b,
			     uint64_t fee_msat)
{
	uint64_t remainder;

	/* Fold in fees, to recalcuate again below. */
	a->pay_msat += a->fee_msat;
	b->pay_msat += b->fee_msat;
	a->fee_msat = b->fee_msat = 0;

	/* BOLT #2:
	 *
	 * 1. If each nodes can afford half the fee from their
	 *    to-`final_key` output, reduce the two to-`final_key`
	 *    outputs accordingly.
	 *
	 * 2. Otherwise, reduce the to-`final_key` output of one node
	 *    which cannot afford the fee to zero (resulting in that
	 *    entire output paying fees).  If the remaining
	 *    to-`final_key` output is greater than the fee remaining,
	 *    reduce it accordingly, otherwise reduce it to zero to
	 *    pay as much fee as possible.
	 */
	remainder = pay_fee(a, fee_msat / 2) + pay_fee(b, fee_msat / 2);

	/* If there's anything left, the other side tries to pay for it. */
	remainder = pay_fee(a, remainder);
	pay_fee(b, remainder);
}

/* a transfers htlc_msat to a HTLC (gains it, if -ve) */
static bool change_funding(uint64_t anchor_satoshis,
			   uint32_t fee_rate,
			   int64_t htlc_msat,
			   struct channel_oneside *a,
			   struct channel_oneside *b,
			   size_t num_nondust_htlcs)
{
	uint64_t fee_msat;

	assert(a->pay_msat + a->fee_msat
	       + b->pay_msat + b->fee_msat
	       + htlcs_total(a->htlcs) + htlcs_total(b->htlcs)
	       == anchor_satoshis * 1000);

	fee_msat = calculate_fee_msat(num_nondust_htlcs, fee_rate);

	/* If A is paying, can it afford it? */
	if (htlc_msat > 0) {
		if (htlc_msat + fee_msat / 2 > a->pay_msat + a->fee_msat)
			return false;
	}

	/* OK, now adjust funds for A, then recalculate fees. */
	a->pay_msat -= htlc_msat;
	recalculate_fees(a, b, fee_msat);

	assert(a->pay_msat + a->fee_msat
	       + b->pay_msat + b->fee_msat
	       + htlcs_total(a->htlcs) + htlcs_total(b->htlcs) + htlc_msat
	       == anchor_satoshis * 1000);
	return true;
}

struct channel_state *initial_cstate(const tal_t *ctx,
				      uint64_t anchor_satoshis,
				      uint32_t fee_rate,
				      enum channel_side funding)
{
	uint64_t fee_msat;
	struct channel_state *cstate = talz(ctx, struct channel_state);
	struct channel_oneside *funder, *fundee;

	cstate->fee_rate = fee_rate;
	cstate->anchor = anchor_satoshis;
	cstate->changes = 0;

	/* Anchor must fit in 32 bit. */
	if (anchor_satoshis >= (1ULL << 32) / 1000)
		return tal_free(cstate);

	fee_msat = calculate_fee_msat(0, fee_rate);
	if (fee_msat > anchor_satoshis * 1000)
		return tal_free(cstate);

	funder = &cstate->side[funding];
	fundee = &cstate->side[!funding];

	/* Neither side has HTLCs. */
	funder->htlcs = tal_arr(cstate, struct htlc *, 0);
	fundee->htlcs = tal_arr(cstate, struct htlc *, 0);

	/* Initially, all goes back to funder. */
	funder->pay_msat = anchor_satoshis * 1000 - fee_msat;
	funder->fee_msat = fee_msat;

	/* Make sure it checks out. */
	assert(change_funding(anchor_satoshis, fee_rate, 0, funder, fundee, 0));
	assert(funder->fee_msat == fee_msat);
	assert(fundee->fee_msat == 0);

	return cstate;
}

/* Dust is defined as an output < 546*minRelayTxFee/1000.
 * minRelayTxFee defaults to 1000 satoshi. */
bool is_dust_amount(uint64_t satoshis)
{
	return satoshis < 546;
}

static size_t count_nondust_htlcs(struct htlc **htlcs)
{
	size_t i, n = tal_count(htlcs), nondust = 0;

	for (i = 0; i < n; i++)
		if (!is_dust_amount(htlcs[i]->msatoshis / 1000))
			nondust++;
	return nondust;
}

static size_t total_nondust_htlcs(const struct channel_state *cstate)
{
	return count_nondust_htlcs(cstate->side[OURS].htlcs)
		+ count_nondust_htlcs(cstate->side[THEIRS].htlcs);
}

void adjust_fee(struct channel_state *cstate, uint32_t fee_rate)
{
	uint64_t fee_msat;

	fee_msat = calculate_fee_msat(total_nondust_htlcs(cstate), fee_rate);

	recalculate_fees(&cstate->side[OURS], &cstate->side[THEIRS], fee_msat);
	cstate->changes++;
}

bool force_fee(struct channel_state *cstate, uint64_t fee)
{
	/* Beware overflow! */
	if (fee > 0xFFFFFFFFFFFFFFFFULL / 1000)
		return false;
	recalculate_fees(&cstate->side[OURS], &cstate->side[THEIRS], fee * 1000);
	cstate->changes++;
	return cstate->side[OURS].fee_msat + cstate->side[THEIRS].fee_msat == fee * 1000;
}

/* Add a HTLC to @creator if it can afford it. */
bool cstate_add_htlc(struct channel_state *cstate,
		     struct htlc *htlc,
		     enum channel_side side)
{
	size_t n, nondust;
	struct channel_oneside *creator, *recipient;

	creator = &cstate->side[side];
	recipient = &cstate->side[!side];
	
	/* Remember to count the new one in total txsize if not dust! */
	nondust = total_nondust_htlcs(cstate);
	if (!is_dust_amount(htlc->msatoshis / 1000))
		nondust++;
	
	if (!change_funding(cstate->anchor, cstate->fee_rate,
			    htlc->msatoshis, creator, recipient, nondust))
		return false;

	n = tal_count(creator->htlcs);
	tal_resize(&creator->htlcs, n+1);

	creator->htlcs[n] = htlc;
	memcheck(&creator->htlcs[n]->msatoshis,
		 sizeof(creator->htlcs[n]->msatoshis));
	memcheck(&creator->htlcs[n]->rhash, sizeof(creator->htlcs[n]->rhash));
	cstate->changes++;
	return true;
}

/* Remove htlc from creator, credit it to beneficiary. */
static void remove_htlc(struct channel_state *cstate,
			enum channel_side creator,
			enum channel_side beneficiary,
			struct htlc *htlc)
{
	size_t nondust;
	size_t i, n = tal_count(cstate->side[creator].htlcs); 

	/* Remember to remove this one in total txsize if not dust! */
	nondust = total_nondust_htlcs(cstate);
	if (!is_dust_amount(htlc->msatoshis / 1000)) {
		assert(nondust > 0);
		nondust--;
	}

	/* Can't fail since msatoshis is positive. */
	if (!change_funding(cstate->anchor, cstate->fee_rate,
			    -(int64_t)htlc->msatoshis,
			    &cstate->side[beneficiary],
			    &cstate->side[!beneficiary], nondust))
		abort();

	/* Actually remove the HTLC. */
	for (i = 0; i < tal_count(cstate->side[creator].htlcs); i++) {
		if (cstate->side[creator].htlcs[i] == htlc) {
			memmove(cstate->side[creator].htlcs + i,
				cstate->side[creator].htlcs + i + 1,
				(n - i - 1) * sizeof(htlc));
			tal_resize(&cstate->side[creator].htlcs, n-1);
			cstate->changes++;
			return;
		}
	}
	abort();
}

void cstate_fail_htlc(struct channel_state *cstate,
		      struct htlc *htlc,
		      enum channel_side side)
{
	remove_htlc(cstate, side, side, htlc);
}

void cstate_fulfill_htlc(struct channel_state *cstate,
			 struct htlc *htlc,
			 enum channel_side side)
{
	remove_htlc(cstate, side, !side, htlc);
}

struct htlc *cstate_find_htlc(const struct channel_state *cstate,
			      const struct sha256 *rhash,
			      enum channel_side side)
{
	size_t i;

	for (i = 0; i < tal_count(cstate->side[side].htlcs); i++) {
		if (structeq(&cstate->side[side].htlcs[i]->rhash, rhash))
			return cstate->side[side].htlcs[i];
	}
	return NULL;
}

struct htlc *cstate_htlc_by_id(const struct channel_state *cstate,
			       uint64_t id,
			       enum channel_side side)
{
	size_t i;

	for (i = 0; i < tal_count(cstate->side[side].htlcs); i++) {
		if (cstate->side[side].htlcs[i]->id == id)
			return cstate->side[side].htlcs[i];
	}
	return NULL;
}

struct channel_state *copy_cstate(const tal_t *ctx,
				  const struct channel_state *cstate)
{
	struct channel_state *cs = tal_dup(ctx, struct channel_state, cstate);
	size_t i;

	for (i = 0; i < ARRAY_SIZE(cs->side); i++) {
		cs->side[i].htlcs = tal_dup_arr(cs, struct htlc *,
						cs->side[i].htlcs,
						tal_count(cs->side[i].htlcs), 0);
	}
	return cs;
}
