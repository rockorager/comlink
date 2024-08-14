comlink(1)

# NAME

comlink - an IRC client

# SYNOPSIS

*comlink* [options...]

# DESCRIPTION

Comlink is an IRC client for your terminal. It employs many modern terminal
features, such as the Kitty Keyboard Protocol, mouse shapes, and OSC 8
hyperlinks. It also uses many IRCv3 extensions to provide a modern chat
experience.

# OPTIONS

*-v*, *--version*
	Print the version and exit.

# CONFIGURATION

Comlink is configured using *lua 5.4*. A lua file defining the API for
configuration should be available in _$PREFIX/share/comlink/lua/comlink.lua_.
Configuration will be loaded from _$XDG_CONFIG_HOME/comlink/init.lua_. Local lua
modules will be searched for within this directory. The search paths are:

```
	$XDG_CONFIG_HOME/comlink/\*.lua
	$XDG_CONFIG_HOME/comlink/lua/\*.lua
	$XDG_CONFIG_HOME/comlink/lua/\*/init.lua
```

The most simple configuration is

```
	local comlink = require("comlink")
	comlink.connect({
		server = "chat.sr.ht",
		user = "rockorager",
		nick = "rockorager",
		password = "password",
		real_name = "Tim Culverhouse",
	})
```

# KEYBOARD SHORTCUTS

Many keyboard shortcuts may be configured in the configuration file. The
shortcuts shown here are the defaults.

## NAVIGATION AND UI

*CTRL-C*
	Quit comlink.

*ALT-UP*
	Select the previous channel or buffer.

*ALT-DOWN*
	Select the next channel or buffer.

*CTRL-L*
	Redraw the entire screen.

*PAGE_UP*
	Scroll the channel up 3 messages.

*PAGE_DOWN*
	Scroll the channel down 3 messages.

*HOME*
	Scroll the channel to the most recent message.

*TAB*
	Open completion options for the last word in the input field. Cycle
	through options when the completion menu is open.

*SHIFT-TAB*
	If the compeletion menu is open, cycle through options.



## EDITING

*CTRL-A*
	Move the cursor to the beginning of the input field.

*CTRL-E*, *END*
	Move the cursor to the end of the input field.

*CTRL-B*
	Move the cursor left one character.

*CTRL-F*
	Move the cursor right one character.

*CTRL-K*
	Delete from the cursor to the end of the input field.

*CTRL-U*
	Delete from the cursor to the start of the input field.

*CTRL-D*
	Delete the character after the cursor

*ALT-B*, *ALT-LEFT*
	Move the cursor backwards one word.

*ALT-F*, *ALT-RIGHT*
	Move the cursor forwards one word.

*CTRL-W*, *ALT-BACKSPACE*
	Delete the word before the cursor.

*ALT-D*
	Delete the word after the cursor.

*ENTER*
	Send the text in the input field.

# SEE ALSO

*comlink*(3), *comlink_connection*(3), *comlink_channel*(3)

# AUTHORS

Written and maintained by Tim Culverhouse <tim@timculverhouse.com>, assisted by
open source contributors.

# REPORTING BUGS

Bugs may be reported to the mailing list <~rockorager/comlink@lists.sr.ht> or at
https://github.com/rockorager/comlink.
