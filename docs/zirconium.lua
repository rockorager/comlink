---@meta

--- The primary zirconium module
--
---@class zirconium
local zirconium = {}

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
function zirconium.connect(cfg) end

---Log a msg to the zirconium logs
--
---@param msg string The message to log
function zirconium.log(msg) end

return zirconium
