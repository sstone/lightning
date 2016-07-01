#include <ccan/build_assert/build_assert.h>
#include <daemon/log.h>
#ifndef TEST_STATE_COVERAGE
#include <daemon/peer.h>
#endif
#include <names.h>
#include <state.h>

static enum state next_state(struct peer *peer,
			     const enum state_input input,
			     const enum state state)
{
	assert(peer->state != state);
	return state;
}

static void queue_tx_broadcast(const struct bitcoin_tx **broadcast,
			       const struct bitcoin_tx *tx)
{
	assert(!*broadcast);
	assert(tx);
	*broadcast = tx;
}

enum state state(struct peer *peer,
		 const enum state_input input,
		 const Pkt *pkt,
		 const struct bitcoin_tx **broadcast)
{
	Pkt *err;

	*broadcast = NULL;

	switch (peer->state) {
	/*
	 * Initial channel opening states.
	 */
	case STATE_INIT:
		if (input_is(input, CMD_OPEN_WITH_ANCHOR)) {
			queue_pkt_open(peer,
				       OPEN_CHANNEL__ANCHOR_OFFER__WILL_CREATE_ANCHOR);
			return next_state(peer, input,
					  STATE_OPEN_WAIT_FOR_OPEN_WITHANCHOR);
		} else if (input_is(input, CMD_OPEN_WITHOUT_ANCHOR)) {
			queue_pkt_open(peer,
				       OPEN_CHANNEL__ANCHOR_OFFER__WONT_CREATE_ANCHOR);
			return next_state(peer, input,
					  STATE_OPEN_WAIT_FOR_OPEN_NOANCHOR);
		}
		break;
	case STATE_OPEN_WAIT_FOR_OPEN_NOANCHOR:
		if (input_is(input, PKT_OPEN)) {
			err = accept_pkt_open(peer, pkt);
			if (err) {
				peer_open_complete(peer, err->error->problem);
				goto err_breakdown;
			}
			return next_state(peer, input, STATE_OPEN_WAIT_FOR_ANCHOR);
		} else if (input_is_pkt(input)) {
			peer_open_complete(peer, "unexpected packet");
			goto unexpected_pkt;
		}
		break;
	case STATE_OPEN_WAIT_FOR_OPEN_WITHANCHOR:
		if (input_is(input, PKT_OPEN)) {
			err = accept_pkt_open(peer, pkt);
			if (err) {
				peer_open_complete(peer, err->error->problem);
				goto err_breakdown;
			}
			bitcoin_create_anchor(peer, BITCOIN_ANCHOR_CREATED);
			return next_state(peer, input,
					  STATE_OPEN_WAIT_FOR_ANCHOR_CREATE);
		} else if (input_is_pkt(input)) {
			peer_open_complete(peer, "unexpected packet");
			goto unexpected_pkt;
		}
		break;
	case STATE_OPEN_WAIT_FOR_ANCHOR_CREATE:
		if (input_is(input, BITCOIN_ANCHOR_CREATED)) {
			queue_pkt_anchor(peer);
			return next_state(peer, input,
					  STATE_OPEN_WAIT_FOR_COMMIT_SIG);
		} else if (input_is_pkt(input)) {
			bitcoin_release_anchor(peer, BITCOIN_ANCHOR_CREATED);
			peer_open_complete(peer, "unexpected packet");
			goto unexpected_pkt;
		}
		break;
	case STATE_OPEN_WAIT_FOR_ANCHOR:
		if (input_is(input, PKT_OPEN_ANCHOR)) {
			err = accept_pkt_anchor(peer, pkt);
			if (err) {
				peer_open_complete(peer, err->error->problem);
				goto err_breakdown;
			}
			queue_pkt_open_commit_sig(peer);
			peer_watch_anchor(peer, 
					  BITCOIN_ANCHOR_DEPTHOK,
					  BITCOIN_ANCHOR_TIMEOUT);

			return next_state(peer, input,
					  STATE_OPEN_WAITING_THEIRANCHOR);
		} else if (input_is_pkt(input)) {
			peer_open_complete(peer, "unexpected packet");
			goto unexpected_pkt;
		}
		break;
	case STATE_OPEN_WAIT_FOR_COMMIT_SIG:
		if (input_is(input, PKT_OPEN_COMMIT_SIG)) {
			err = accept_pkt_open_commit_sig(peer, pkt);
			if (err) {
				bitcoin_release_anchor(peer, INPUT_NONE);
				peer_open_complete(peer, err->error->problem);
				goto err_breakdown;
			}
			queue_tx_broadcast(broadcast, bitcoin_anchor(peer));
			peer_watch_anchor(peer,
					  BITCOIN_ANCHOR_DEPTHOK,
					  INPUT_NONE);
			return next_state(peer, input,
					  STATE_OPEN_WAITING_OURANCHOR);
		} else if (input_is_pkt(input)) {
			bitcoin_release_anchor(peer, INPUT_NONE);
			peer_open_complete(peer, "unexpected packet");
			goto unexpected_pkt;
		}
		break;
	case STATE_OPEN_WAITING_OURANCHOR:
		if (input_is(input, PKT_OPEN_COMPLETE)) {
			err = accept_pkt_open_complete(peer, pkt);
			if (err) {
				peer_open_complete(peer, err->error->problem);
				/* We no longer care about anchor depth. */
				peer_unwatch_anchor_depth(peer, 
							  BITCOIN_ANCHOR_DEPTHOK,
							  INPUT_NONE);
				goto err_breakdown;
			}
			return next_state(peer, input,
					  STATE_OPEN_WAITING_OURANCHOR_THEYCOMPLETED);
		}
	/* Fall thru */
	case STATE_OPEN_WAITING_OURANCHOR_THEYCOMPLETED:
		if (input_is(input, BITCOIN_ANCHOR_DEPTHOK)) {
			queue_pkt_open_complete(peer);
			if (peer->state == STATE_OPEN_WAITING_OURANCHOR_THEYCOMPLETED) {
				peer_open_complete(peer, NULL);
				return next_state(peer, input, STATE_NORMAL);
			}
			return next_state(peer, input,
					  STATE_OPEN_WAIT_FOR_COMPLETE_OURANCHOR);
		} else if (input_is(input, PKT_CLOSE_CLEARING)) {
			/* We no longer care about anchor depth. */
			peer_unwatch_anchor_depth(peer,
						  BITCOIN_ANCHOR_DEPTHOK,
						  INPUT_NONE);
			peer_open_complete(peer, "Received PKT_CLOSE_CLEARING");
			goto accept_clearing;
		} else if (input_is_pkt(input)) {
			/* We no longer care about anchor depth. */
			peer_unwatch_anchor_depth(peer,
						  BITCOIN_ANCHOR_DEPTHOK,
						  INPUT_NONE);
			peer_open_complete(peer, "unexpected packet");
			goto unexpected_pkt;
		}
		break;
	case STATE_OPEN_WAITING_THEIRANCHOR:
		if (input_is(input, PKT_OPEN_COMPLETE)) {
			err = accept_pkt_open_complete(peer, pkt);
			if (err) {
				peer_open_complete(peer, err->error->problem);
				/* We no longer care about anchor depth. */
				peer_unwatch_anchor_depth(peer, 
							  BITCOIN_ANCHOR_DEPTHOK,
							  BITCOIN_ANCHOR_TIMEOUT);
				goto err_breakdown;
			}
			return next_state(peer, input,
					  STATE_OPEN_WAITING_THEIRANCHOR_THEYCOMPLETED);
		}
	/* Fall thru */
	case STATE_OPEN_WAITING_THEIRANCHOR_THEYCOMPLETED:
		if (input_is(input, BITCOIN_ANCHOR_TIMEOUT)) {
			/* Anchor didn't reach blockchain in reasonable time. */
			queue_pkt_err(peer, pkt_err(peer, "Anchor timed out"));
			return next_state(peer, input, STATE_ERR_ANCHOR_TIMEOUT);
		} else if (input_is(input, BITCOIN_ANCHOR_DEPTHOK)) {
			queue_pkt_open_complete(peer);
			if (peer->state == STATE_OPEN_WAITING_THEIRANCHOR_THEYCOMPLETED) {
				peer_open_complete(peer, NULL);
				return next_state(peer, input, STATE_NORMAL);
			}
			return next_state(peer, input,
					  STATE_OPEN_WAIT_FOR_COMPLETE_THEIRANCHOR);
		} else if (input_is(input, PKT_CLOSE_CLEARING)) {
			/* We no longer care about anchor depth. */
			peer_unwatch_anchor_depth(peer,
						  BITCOIN_ANCHOR_DEPTHOK,
						  BITCOIN_ANCHOR_TIMEOUT);
			peer_open_complete(peer, "Received PKT_CLOSE_CLEARING");
			goto accept_clearing;
		} else if (input_is_pkt(input)) {
			/* We no longer care about anchor depth. */
			peer_unwatch_anchor_depth(peer,
						  BITCOIN_ANCHOR_DEPTHOK,
						  BITCOIN_ANCHOR_TIMEOUT);
			peer_open_complete(peer, "unexpected packet");
			goto unexpected_pkt;
		}
		break;
	case STATE_OPEN_WAIT_FOR_COMPLETE_OURANCHOR:
	case STATE_OPEN_WAIT_FOR_COMPLETE_THEIRANCHOR:
		if (input_is(input, PKT_OPEN_COMPLETE)) {
			/* Ready for business! */
			peer_open_complete(peer, NULL);
			return next_state(peer, input, STATE_NORMAL);
		} else if (input_is(input, PKT_CLOSE_CLEARING)) {
			peer_open_complete(peer, "Received PKT_CLOSE_CLEARING");
			goto accept_clearing;
		} else if (input_is_pkt(input)) {
			peer_open_complete(peer, "unexpected packet");
			goto unexpected_pkt;
		}
		break;

	/* Should never happen. */
	case STATE_NORMAL:
	case STATE_NORMAL_COMMITTING:
	case STATE_ERR_INTERNAL:
	case STATE_ERR_ANCHOR_TIMEOUT:
	case STATE_ERR_INFORMATION_LEAK:
	case STATE_ERR_BREAKDOWN:
	case STATE_CLOSED:
	case STATE_MAX:
	case STATE_CLEARING:
	case STATE_CLEARING_COMMITTING:
	case STATE_MUTUAL_CLOSING:
	case STATE_CLOSE_ONCHAIN_CHEATED:
	case STATE_CLOSE_ONCHAIN_THEIR_UNILATERAL:
	case STATE_CLOSE_ONCHAIN_OUR_UNILATERAL:
	case STATE_CLOSE_ONCHAIN_MUTUAL:
		return next_state(peer, input, STATE_ERR_INTERNAL);
	}

	/* State machine should handle all possible states. */
	return next_state(peer, input, STATE_ERR_INTERNAL);

unexpected_pkt:
	peer_unexpected_pkt(peer, pkt);

	/* Don't reply to an error with an error. */
	if (!input_is(input, PKT_ERROR)) {
		goto breakdown;
	}
	err = pkt_err_unexpected(peer, pkt);
	goto err_breakdown;

err_breakdown:
	queue_pkt_err(peer, err);
breakdown:
	return next_state(peer, input, STATE_ERR_BREAKDOWN);

accept_clearing:
	err = accept_pkt_close_clearing(peer, pkt);
	if (err)
		goto err_breakdown;

	/* If we've sent commit, we're still waiting for it when clearing. */
	if (peer->state == STATE_NORMAL_COMMITTING)
		return next_state(peer, input, STATE_CLEARING_COMMITTING);
	return next_state(peer, input, STATE_CLEARING);
}
