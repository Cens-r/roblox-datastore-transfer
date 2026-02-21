--!strict

local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")

local ENV_FILE_PATH: string = ".env"

type Environment = { API_KEY: string }

local env = fs.isFile(ENV_FILE_PATH) and serde.decode("toml", fs.readFile(ENV_FILE_PATH))
return setmetatable((env or {}) :: Environment, {
	__index = process.env,
	__newindex = process.env,
})
