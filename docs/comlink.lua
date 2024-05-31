---@meta

--- The primary comlink module
--
---@class comlink
local comlink = {}

---@class ConnectionConfiguration
--
---@field server string The server to connect to, eg "chat.sr.ht"
---@field user string Username for server connection
---@field nick string Nick to use when connecting via SASL to IRC
---@field password string Password for server
---@field real_name string Real name of user

---Set connection configuration
--
---@param cfg ConnectionConfiguration
function comlink.connect(cfg) end

---Log a msg to the comlink logs
--
---@param msg string The message to log
function comlink.log(msg) end

--- A command for comlink to execute
--
---@enum action
local Action = {
	quote = "quote",
	me = "me",
	msg = "msg",
	next_channel = "next-channel",
	prev_channel = "prev-channel",
	quit = "quit",
	who = "who",
}

---Bind a key
--
---@param key string The key to bind, eg "alt+n", "shift+left"
---@param action action The action to perform, eg "quit"
function comlink.bind(key, action) end

return comlink
