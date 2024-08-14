comlink_connection(3)

# NAME

comlink_connection - a lua type representing a connection to an IRC server

# SYNOPSIS

*local conn = comlink.connect*(_config_)

*conn.on_connect = function*(_conn_)

*conn.on_message = function*(_channel_, _sender_, _msg_)

*local name = conn.name*()

*conn.join*(_channel_)



# DESCRIPTION

A *connection* represents the connection to the IRC server. A *connection* is
received after calling *comlink.connect*, which posts an event to connect to the
server. The entire lua file is executed prior to the connection occuring. This
behavior allows setting of callbacks on the connection after calling connect.
All callbacks are called from the main thread, and will block the event loop
until they return.

*conn.on_connect* 
	A callback which receives the *connection* object. This callback is
	called when comlink receives a *RPL_WELCOME* command from the server. An
	example usage is to join channels after a connection has been
	established. The callback receives a *connection* object because in the
	presence of _soju.im/bouncer-networks_, networks may be discovered that
	the user never configured. These discovered networks will inherit the
	callbacks from the bouncer connection. Users of this callback may want
	to perform different actions based on the *connection*, which is best
	verified using the *name* function.

*conn.on_message*
	A callback which is called after any *PRIVMSG* or *NOTICE* is received
	on the *connection*. The callback receives the channel, the sender, and
	the content of the message - all as strings. The channel may be a
	nickname in the case of a direct message.

*conn.join*
	Accepts a string as the channel name to join. This performs the IRC
	command *JOIN*.

# RETURN VALUES

*conn.name*
	Returns a string which is the name of the connection. This is usually
	the URL, but may be something else if it is a discovered network from a
	bouncer.

# SEE ALSO

*comlink*(1), *comlink*(3)
