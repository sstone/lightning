LIGHTNING-CONNECT(7) Manual Page
================================
lightning-connect - Command for connecting to another lightning node.

SYNOPSIS
--------

**connect** *id* \[*host* *port*\]

DESCRIPTION
-----------

The **connect** RPC command establishes a new connection with another
node in the Lightning Network.

*id* represents the target node’s public key. As a convenience, *id* may
be of the form *id@host* or *id@host:port*. In this case, the *host* and
*port* parameters must be omitted.

*host* is the peer’s hostname or IP address.

If not specified, the *port* defaults to 9735.

If *host* is not specified, the connection will be attempted to an IP
belonging to *id* obtained through gossip with other already connected
peers.

If *host* begins with a */* it is interpreted as a local path, and the
connection will be made to that local socket (see **bind-addr** in
lightningd-config(5)).

Connecting to a node is just the first step in opening a channel with
another node. Once the peer is connected a channel can be opened with
lightning-fundchannel(7).

RETURN VALUE
------------

On success the peer *id* is returned.

The following error codes may occur:
-   -1: Catchall nonspecific error. This may occur if the host is not
    valid or there are problems communicating with the peer. **connect**
    will make up to 10 attempts to connect to the peer before giving up.

AUTHOR
------

Rusty Russell <<rusty@rustcorp.com.au>> is mainly responsible.
Felix <<fixone@gmail.com>> is the original author of this manpage.

SEE ALSO
--------

lightning-fundchannel(7), lightning-listpeers(7),
lightning-listchannels(7), lightning-disconnect(7)

RESOURCES
---------

Main web site: <https://github.com/ElementsProject/lightning>

------------------------------------------------------------------------

Last updated 2019-08-01 14:59:36 CEST
