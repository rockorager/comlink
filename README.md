#zircon

An experimental IRC client written in zig

## Configuration

Configuration is loaded from `$HOME/.config/zircon/init.lua`

Works best (maybe only?) with `soju`

```zig
local zirc = require("zircon")

local config = {
	server = "chat.sr.ht",
	user = "rockorager",
	nick = "rockorager",
	password = "password",
	real_name = "Tim Culverhouse",
}

zirc.connect(config)
```
