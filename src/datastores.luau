--!strict

-- Zune libraries:
local net = zune.net
local serde = zune.serde
local task = zune.task

-- Constants:
local MAX_RETRY_COUNT: number = 5
local RETRY_BASE_TIME: number = 0.5
local VERBOSE_OUTPUT: boolean = true

local ERROR_FORMAT: string = "Reason: %s (Code: %d)"
local ERROR_INFO_SEPARATOR: string = "\n -+- "

local BASE_URL: string = "https://apis.roblox.com/cloud/v2"
local HEADERS = {
	API_KEY = "x-api-key",
	RATE_LIMIT_RESET = "x-ratelimit-reset",
	CONTENT_TYPE = "content-type",
}

export type Context = {
	api_key: string,
	universe_id: number,
}
local function hide_context(ctx: Context): Context
	local metatable = getmetatable(ctx) or {} :: any
	metatable.__tostring = `[ Universe ID = {ctx.universe_id} ]`
	return setmetatable(ctx, metatable)
end

-- Pulled from: https://github.com/Scythe-Technology/zune-adapters/blob/master/impl/lune/runtime/net.luau
function url_encode(s: string, binary: boolean?): string
	local result = s:gsub("([^%w%.%-_])", function(c: string)
		return string.format("%%%02X", string.byte(c))
	end)
	return result
end

local function build_query(params: { [string]: unknown }?): string
	if not params then return "" end
	local queries: { string } = {}
	for key, value in params do
		value = url_encode(tostring(value))
		table.insert(queries, `{key}={value}`)
	end
	return if #queries > 0 then "?" .. table.concat(queries, "&") else ""
end

type RequestMethod = "GET" | "POST" | "PATCH" | "DELETE"
type RequestBody = { type: string, content: string }
type RequestParams = {
	-- Required Parameters:
	api_key: string,
	path: string,

	-- Optional parameters:
	method: RequestMethod?,
	body: RequestBody?,
	query: { [string]: unknown }?,
	skip_retry: boolean?,
}

local function parse_errors(response: HttpResponse<string>, content: { [string]: unknown }): string
	local message: string = ""
	if content.errors then
		local error_list: { string } = {}
		for index, info in content.errors do
			error_list[index] = string.format(ERROR_FORMAT :: any, content.message, content.code)
		end
		message = table.concat(error_list, ERROR_INFO_SEPARATOR)
	elseif content.code and content.message then
		message = string.format(ERROR_FORMAT :: any, content.message, content.code)
	else
		message = string.format(ERROR_FORMAT :: any, response.status_reason, response.status_code)
	end
	return message
end

local reset_times: { [RequestMethod]: number? } = {}
local function api_request<T>(params: RequestParams): (boolean, T)
	local method: RequestMethod = params.method or "GET"
	local body = (params.body or {} :: RequestBody)
	local query = build_query(params.query)

	local url = `{BASE_URL}/{params.path}{query}`
	local config: HttpRequestOptions = {
		method = method,
		headers = {
			[HEADERS.API_KEY] = params.api_key,
			[HEADERS.CONTENT_TYPE] = body.type,
		},
		body = body.content,
	}

	local response: HttpResponse<string>

	local attempt_count = 0
	local skip_retry, await_reset = params.skip_retry, false

	repeat
		if response then
			if await_reset and reset_times[method] then
				task.wait(reset_times[method])
			else
				task.wait(math.min(RETRY_BASE_TIME * 2 ^ attempt_count, 60))
			end
		end
		response = net.http.request(url, config)

		if response.status_code == 400 then
			skip_retry = true --> Skip on bad requests.
		else
			await_reset = response.status_code == 429
		end
		attempt_count += 1
	until response.ok or skip_retry or (attempt_count > MAX_RETRY_COUNT)

	local headers = response.headers
	local reset_time: string? = headers[HEADERS.RATE_LIMIT_RESET]
	if reset_time then reset_times[method] = tonumber(reset_time) or reset_times[method] end

	local content = serde.json.decode(response.body)
	if (not response.ok) and VERBOSE_OUTPUT then
		local error_segments = {
			`Request to Data Store API failed!`,
			parse_errors(response, content),
			`Path: {params.path}`,
			`Query: {query}`,
			if not params.skip_retry then `Retries: {attempt_count - 1}` else nil,
		}
		print("[ERROR]: " .. table.concat(error_segments, ERROR_INFO_SEPARATOR))
	end
	return response.ok, content :: T
end

local DataStore = {}
local METATABLE = { __index = DataStore }

type DataStoreState = "STATE_UNSPECIFIED" | "ACTIVE" | "DELETED"
type DataStoreInfo = {
	id: string,
	path: string,
	state: DataStoreState,
}

export type DataStoreKey = DataStoreInfo
export type DataStoreMetadata = { users: { string }?, attributes: { unknown }? }
export type DataStoreValue = {
	value: unknown,
} & DataStoreMetadata & DataStoreInfo

type _DataStore = { __context: Context } & DataStoreInfo
export type DataStore = setmetatable<_DataStore, typeof(METATABLE)>

local function construct(ctx: Context, info: DataStoreInfo): DataStore
	local datastore = table.clone(info) :: _DataStore
	datastore.__context = hide_context(ctx)
	setmetatable(datastore, METATABLE)
	return table.freeze(datastore :: any)
end

type ListQuery = {
	pageToken: string?,
	showDeleted: boolean?,
	maxPageSize: number?,
	filter: string?,
}

function DataStore.keys(self: DataStore, query: ListQuery?): ({ DataStoreKey }, string?)
	local out = {}
	local params: RequestParams = {
		api_key = self.__context.api_key,
		path = `{self.path}/entries`,
		query = query :: any,
	}

	local success, result = api_request(params)
	result = result :: {
		dataStoreEntries: { DataStoreKey },
		nextPageToken: string?,
	}
	if not success then return out, nil end

	local entries = result.dataStoreEntries
	if entries then table.move(entries, 1, #entries, #out + 1, out) end
	return out, result.nextPageToken
end

function DataStore.get(self: DataStore, key: DataStoreKey): DataStoreValue?
	local params: RequestParams = {
		api_key = self.__context.api_key,
		path = key.path,
	}
	local success, result = api_request(params)
	return if success then result :: DataStoreValue else nil
end

function DataStore.set(self: DataStore, value: DataStoreValue): ()
	local payload = {
		value = value.value,
		users = if value.users and #value.users > 0 then value.users else nil,
		attributes = if value.attributes and #value.attributes > 0 then value.attributes else nil,
	}
	local params: RequestParams = {
		api_key = self.__context.api_key,
		path = value.path,
		query = { allowMissing = true },
		method = "PATCH",
		body = {
			type = "application/json",
			content = serde.json.encode(payload),
		},
	}
	api_request(params)
end

local function list(ctx: Context, query: ListQuery?): ({ DataStore }, string?)
	local out = {}
	local params: RequestParams = {
		api_key = ctx.api_key,
		path = `universes/{ctx.universe_id}/data-stores`,
		query = query :: any,
	}

	local _, result = api_request(params)
	result = result :: {
		dataStores: { DataStoreInfo },
		nextPageToken: string?,
	}

	for index, info in result.dataStores or {} do
		out[index] = construct(ctx, info)
	end
	return out, result.nextPageToken
end

local function get(ctx: Context, id: string, validate: boolean?): DataStore?
	local state: DataStoreState = "STATE_UNSPECIFIED"
	local info: DataStoreInfo = {
		id = id,
		path = `universes/{ctx.universe_id}/data-stores/{id}`,
		state = state,
	}
	if validate == nil or validate then
		-- Validation via attempted key list operation:
		local params: RequestParams = {
			api_key = ctx.api_key,
			path = `{info.path}/entries`,
			query = { maxPageSize = 1 }, --> Limit to a single read operation.
			skip_retry = true,
		}
		local success = api_request(params)
		if not success then return nil end
	end

	return construct(ctx, info)
end

local function build_key(datastore: DataStore, id: string, scope: string?): DataStoreKey
	scope = scope or "global"
	return {
		id = `{scope}/{id}`,
		path = `{datastore.path}/scopes/{scope}/entries/{id}`,
		state = "STATE_UNSPECIFIED",
	}
end

local function build_value(key: DataStoreKey, value: unknown, meta: DataStoreMetadata?): DataStoreValue
	local object = {
		id = key.id,
		path = key.path,
		state = key.state,
		value = value,
		users = meta and meta.users,
		attributes = meta and meta.attributes,
	}
	return object
end

local function reassign_ownership(datastore: DataStore, object: DataStoreInfo): DataStoreInfo
	assert(not (object :: DataStore).__context, "Ownership reassginment of a DataStore objects is forbidden!")

	local index = string.find(object.path, "/scopes/") or string.find(object.path, "/entries/")
	assert(index, "Failed to parse path of object during ownership reassignment!")

	local new_object = table.clone(object)
	new_object.path = datastore.path .. string.sub(object.path, index, -1)

	return new_object
end

return {
	list = list,
	get = get,
	key = build_key,
	value = build_value,
	reassign = reassign_ownership,
}
