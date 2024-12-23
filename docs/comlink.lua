---@meta

--- The primary comlink module
---
---@class comlink
local comlink = {}

---@class ConnectionConfiguration
---
---@field server string The server to connect to, eg "chat.sr.ht"
---@field user string Username for server connection
---@field nick string Nick to use when connecting via SASL to IRC
---@field password string Password for server
---@field real_name string Real name of user
---@field tls? boolean Whether to encrypt connections
---@field port? number Optional port to use for server connection. Defaults to 6697 for TLS connections and 6667 for plaintext connections

---A connection to a server
---
---@class Connection
---
---@field on_connect fun(conn: Connection) Called after successful connection to the server
---@field on_message fun(channel: string, sender: string, msg: string) Called after receiving a PRIVMSG
local conn = {}

---Returns the name of the connection
---
---@return string name Name of the connection
function conn.name() end

---Joins a channel
---
---@param channel string Name of the channel to join
function conn.join(channel) end

---Set connection configuration
---
---@param cfg ConnectionConfiguration
---@return Connection
function comlink.connect(cfg) end

---Log a msg to the comlink logs
---
---@param msg string The message to log
function comlink.log(msg) end

--- A command for comlink to execute
---
---@enum action
local Action = {
	quote = "quote",
	me = "me",
	msg = "msg",
	next_channel = "next-channel",
	prev_channel = "prev-channel",
	quit = "quit",
	redraw = "redraw",
	who = "who",
}

---Bind a key
---
---@param key string The key to bind, eg "alt+n", "shift+left"
---@param action action|function The action to perform, eg "quit"
function comlink.bind(key, action) end

---Send a system notification
---
---@param title string Title of the notification
---@param body string Body of the notification
function comlink.notify(title, body) end

---Add a custom command to comlink
---
---@param name string Name of the command
---@param fn fun(cmdline: string) Callback for the command. Receives the commandline as enterred, with the name removed, then any leading or trailing whitespace removed
function comlink.add_command(name, fn) end

---Get the currently selected buffer
---
---@return Channel|nil
function comlink.selected_channel() end

---A channel.
---
---@class Channel
local channel = {}

---Get the name of the channel
---
---@param chan Channel // this channel
---@return string name name of the channel
function channel.name(chan) end

---Mark a channel as read
---
---@param chan Channel // this channel
function channel.mark_read(chan) end

---Send a message to the channel. If the message begins with a '/', it will be processed as a command. This allows for sending of "/me <msg>" style messages from lua
---
---@param chan Channel this channel
---@param msg string message to send
function channel.send_msg(chan, msg) end

return comlink
