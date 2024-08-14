comlink(3)

# NAME

comlink - primary lua module for use in comlink configuration

# SYNOPSIS

*local comlink = require*(_"comlink"_)

*local conn = comlink.connect*(_config_)

*local channel = comlink.selected_channel*()

*comlink.log*(_msg_)

*comlink.bind*(_key_, _action_)

*comlink.notify*(_title_, _body_)

*comlink.add_command*(_cmd_, _callback_)

# DESCRIPTION

The comlink module is the entrypoint into configuring and scripting comlink.
This module provides application level API calls.

*comlink.connect* 
	Accepts a configuration table. This table defines the server
	configuration. The table has the following required fields:

	- *server*: string, the server URL
	- *user*: string, username used in SASL
	- *nick*: string, nickname to identify as
	- *password*: string, password to use in SASL
	- *real_name*: string, user's real name

	The following optional fields are available:

	- *tls*: boolean (default=true), when true, use an encrypted connection

*comlink.log*
	Accepts a string and inserts a log statement into the comlink
	logs. This can be helpful for debugging.

*comlink.bind*
	Accepts a string description of the _key_, as well an _action_. Keys may
	include modifiers which must be of the form *shift*, *alt*, *ctrl*,
	*super*, *hyper*, or *meta*. Named keys may be used as well, for example
	*f1* or *tab*. To add a modifier to a key use a *+*, for example
	"*ctrl+a*". An _action_ can be either a string or a lua function.
	Available string actions are:

	- *next_channel*
	- *prev_channel*
	- *quit*
	- *redraw*

*comlink.notify*
	Accepts two strings: the first is the title of the notification and the
	second is the body of the notification. This function produces a system
	notification on terminals which support OSC 777.

*comlink.add_command* 
	Adds the string _cmd_ as an available command in comlink. This command
	will show up in the completion list as well. When invoked, the
	_callback_ function will be called and receives the arguments from the
	command line, with the command removed and whitespace stripped.

# RETURN VALUES

*comlink.connect*
	Returns a *connection*. The connection represents a connection to a
	single server. In the presence of the _soju.im/bouncer-networks_
	extension, discovered networks will inherit callbacks set on
	*connection*. See *comlink_connection*(3).

*comlink.selected_channel*
	Returns a *channel*, or *nil* if no channel is selected. See
	*comlink_channel*(3).

# SEE ALSO

*comlink*(1), *comlink_connection*(3), *comlink_channel*(3)
