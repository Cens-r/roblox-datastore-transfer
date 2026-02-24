--!strict

-- Zune libraries:
local sqlite = zune.sqlite
local process = zune.process
local fs = zune.fs
local luau = zune.luau
local io = zune.io

local OUTPUT_PATH: string = "./output"

local VALIDATE_DATASTORES: boolean = true
local MAX_PAGE_SIZE: number = 10

local env = process.env :: { API_KEY: string?, [string]: string }
assert(env.API_KEY, "Missing `API_KEY` variable in environment!")

local cli = require("@self/cli")
local args = cli.parser()

args:add("__file__", "positional", {})
args:add("list", "positional", {})

args:add("to", "option", { aliases = { "t" }, required = true })
args:add("from", "option", { aliases = { "f" }, required = true })
args:add("pagesize", "option", { default = tostring(MAX_PAGE_SIZE) })
args:add("filter", "option", {})

args:parse(process.args)

MAX_PAGE_SIZE = math.clamp(tonumber(args:get("pagesize")) or MAX_PAGE_SIZE, 1, 256)

-- Iteratively calls a function until it stop producing tokens.
local function drain<T>(func: (T?) -> T?, token: T?): ()
	repeat
		token = func(token)
	until token == nil
end

local datastores = require("@self/datastores")
type Context = datastores.Context

local context: { to: Context, from: Context } = {
	to = {
		api_key = env.API_KEY,
		universe_id = assert(tonumber(args:get("to")), "Invalid argument: to"),
	},
	from = {
		api_key = env.API_KEY,
		universe_id = assert(tonumber(args:get("from")), "Invalid argument: from"),
	},
}

type Filter = (datastores.DataStoreValue) -> boolean

local filter: Filter? = nil
do -- Construct filter function:
	local VALID_EXTENSIONS = { [".luau"] = true, [".lua"] = true }

	local function keys<T>(tbl: { [T]: any }): { T }
		local out = {}
		for key in tbl do
			table.insert(out, key)
		end
		return out
	end

	local path = args:get("filter")
	if path then
		assert(
			VALID_EXTENSIONS[fs.path.extension(path)],
			`File wasn't in one of these formats: {table.concat(keys(VALID_EXTENSIONS), ", ")}`
		)
		assert(fs.stat(path).kind == "file", `Couldn't find filter at path: {path}`)

		local source = fs.readFile(path)
		local bytecode = luau.compile(source)
		filter = luau.load(bytecode)() :: Filter
		assert(typeof(filter) == "function", "Filter script must return a function!")
	end
end

do -- Ensure output path exists:
	local output_stat = fs.stat(OUTPUT_PATH)
	if output_stat.kind == "none" then
		fs.makeDir("./output")
	elseif output_stat.kind ~= "directory" then
		error("Output file already exists, but isn't a directory!")
	end
end

local db = sqlite.open(`./output/transfer_{context.from.universe_id}_{context.to.universe_id}.db`)
db:exec([[
	PRAGMA journal_mode = WAL;      --> Simultaneous read and writes.
	PRAGMA synchronous = NORMAL;    --> Reduce number of write confirmations.
	PRAGMA cache_size = -64000;     --> Sets cache size to about 64MB.
	PRAGMA foreign_keys = ON;       --> Ensures foreign keys are enabled.
]])

local MISSING_DATASTORE_ERROR: string =
	"[SKIPPING]: Couldn't find '%s' DataStore in the Universe (%d) you're transferring %s!"

local function transfer(from_datastore: datastores.DataStore)
	local identifier = from_datastore.id

	local to_datastore = datastores.get(context.to, identifier, VALIDATE_DATASTORES)
	if not to_datastore then
		print(string.format(MISSING_DATASTORE_ERROR :: any, identifier, context.to.universe_id, "to"))
		return
	end

	local transfer_count = 0

	-- Construct a table for the datastore:
	local table_name = string.format("%q", `ds_{identifier}`)
	db:exec(string.format(
		[[
				CREATE TABLE IF NOT EXISTS %s (
					key_name TEXT PRIMARY KEY
				) WITHOUT ROWID;
			]],
		table_name
	))

	-- Prepare datastore relevant queries:
	local key_find = db:query(`SELECT 1 FROM {table_name} WHERE key_name = $key LIMIT 1;`)
	local key_insert = db:query(`INSERT OR IGNORE INTO {table_name} (key_name) VALUES ($key);`)

	print(`[TRANSFER]: Starting for '{identifier}' DataStore:`)
	drain(function(key_token: string?)
		local keys: { datastores.DataStoreKey }
		keys, key_token = from_datastore:keys({
			pageToken = key_token,
			showDeleted = false,
			maxPageSize = MAX_PAGE_SIZE,
		})
		if #keys == 0 then return key_token end

		local keys_transferred: { string } = {}

		io.stdout:write(`* * * * * | Processing batch of {#keys} keys...`)
		for _, key in keys do
			local result = key_find:all({ ["$key"] = key.id })
			if #result > 0 then continue end

			local value = from_datastore:get(key)
			if value == nil then continue end --> This shouldn't ever happen.

			if filter and not (filter :: Filter)(value) then continue end

			value = datastores.reassign(to_datastore, value) :: datastores.DataStoreValue
			to_datastore:set(value)

			table.insert(keys_transferred, key.id)
		end

		-- Batch save all keys to the database:
		if #keys_transferred > 0 then
			db:transaction(function()
				for _, key in keys_transferred do
					key_insert:run({ ["$key"] = key })
				end
			end, "immediate")()
			transfer_count += #keys_transferred
		end
		io.stdout:write(` Transferred: {#keys_transferred}\n`)

		return key_token
	end)
	print(`\b[COMPLETE]: Transferred a total of {transfer_count} keys for '{identifier}' DataStore!`)
end

local function transfer_multiple(list: { datastores.DataStore })
	print("- - - - - -")
	for _, from_datastore in list do
		transfer(from_datastore)
		print("- - - - - -")
	end
end

local datastore_list = args:get("list")
if datastore_list then
	local list: { datastores.DataStore } = {}
	for _, identifier in string.split(datastore_list) do
		local from_datastore = datastores.get(context.from, identifier)
		if not from_datastore then
			print(string.format(MISSING_DATASTORE_ERROR :: any, identifier, context.from.universe_id, "from"))
			continue
		end
		table.insert(list, from_datastore)
	end
	if #list > 0 then transfer_multiple(list) end
else --> Transfer all datastores that can be found:
	drain(function(ds_token: string?)
		local page: { datastores.DataStore }
		page, ds_token = datastores.list(context.from, {
			pageToken = ds_token,
			showDeleted = false,
			maxPageSize = MAX_PAGE_SIZE,
		})
		transfer_multiple(page)
		return ds_token
	end)
end

db:close()
