# comlink

An experimental IRC client written in zig

![screenshot of comlink](screenshot.png)

## Configuration

Configuration is loaded from `$HOME/.config/comlink/init.lua`

Works best with `soju`

```zig
local comlink = require("comlink")

local config = {
	server = "chat.sr.ht",
	user = "rockorager",
	nick = "rockorager",
	password = "password",
	real_name = "Tim Culverhouse",
	tls = true,
}

comlink.connect(config)
```

## Contributing

Patches accepted on the [mailing list](~rockorager/comlink@lists.sr.ht)

Pull requests accepted on [Github](https://github.com/rockorager/comlink)
