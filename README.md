# comlink

An experimental IRC client written in zig. Join the discussion in #comlink on
libera.chat.

![screenshot of comlink](screenshot.png)

## Installation

### Arch Linux

[comlink](https://aur.archlinux.org/packages/comlink) is available as a package in the AUR. It can be installed using an AUR helper (e.g. paru).

```sh
paru -S comlink
```

### Zig Build System

`comlink` is written in zig and can be installed using the zig build system,
version 0.14.0.

```sh
git clone https://github.com/rockorager/comlink
cd comlink
zig build -Doptimize=ReleaseSafe --prefix ~/.local
```

## Configuration

Configuration is loaded from `$HOME/.config/comlink/init.lua`

Works best with `soju`. pico.sh runs a free instance of `soju` and has fantastic
[documentation](https://pico.sh/irc) on how to get connected

```lua
local comlink = require("comlink")

local config = {
	server = "chat.sr.ht",
	user = "rockorager",
	nick = "rockorager",
	password = "password",
	real_name = "Tim Culverhouse",
	tls = true,
}

-- Pass the server config to connect. Connect to as many servers as you need
comlink.connect(config)

-- Bind a key to an action
comlink.bind("ctrl+c", "quit")
```

## Contributing

Patches accepted on the [mailing list](https://lists.sr.ht/~rockorager/comlink)

Pull requests accepted on [Github](https://github.com/rockorager/comlink)
