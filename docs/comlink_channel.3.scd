comlink_channel(3)

# NAME

comlink_channel - a lua type representing an IRC channel

# SYNOPSIS

*local channel = comlink.selected_channel*()

*local name = channel:name*()

*channel:send_msg*(_msg_)

# DESCRIPTION

A *channel* represents an IRC channel.

*channel:send_msg* 
	A method on *channel* which accepts a string (_msg_). _Msg_ is sent to
	the *channel* using a *PRIVMSG* IRC command. Note that this is a method
	call, using lua colon syntax.

# RETURN VALUES

*channel:name*
	Returns a string which is the name of the channel. Note that this is a
	method call, using lua colon syntax.

# SEE ALSO

*comlink*(1), *comlink*(3)
