--[[
     NetRay 2.0 - Enhanced Roblox Networking Library
     
     A powerful, optimized networking library that provides advanced tools
     while maintaining the familiar feel of standard Roblox RemoteEvents.
     
     Key Features:
     - Intuitive API with Roblox-native patterns
     - Promise-based request/response pattern
     - Typed events support for Luau
     - Automatic compression optimization
     - Circuit breaker pattern to prevent cascading failures
     - Event prioritization system
     - Event versioning for backward compatibility
     - Batched events for reducing network overhead
     - Network metrics and analytics dashboard
     - Secure events with server-side verification
     - Comprehensive documentation generator
     - Enhanced error handling and debugging tools
     - Chainable method calls for cleaner code
     
     Performance Benefits:
     - Minimizes network traffic through intelligent throttling and compression
     - Prevents event spam with configurable rate limits
     - Reduces memory usage through optimized event handling
     - Dynamic adjustment of network parameters based on server load
     - Batch processing of frequent small events
     - Prioritization of critical network operations
     
    Created by [Asta] - v2.0.2
 ]]

-- Services
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local Stats = game:GetService("Stats") -- For network stats
local Bits = require(script.Bits) -- Utility functions for bit operations optimized for Luau 
local BinaryEncoder = require(script.BinaryEncoder) -- Utility function for custom binary encoding and decoding
local Promise = require(script.Promise)
local TypeChecker = require(script.TypeChecker)

-- Environment detection
local IS_SERVER = RunService:IsServer()
local IS_CLIENT = RunService:IsClient()

-- Constants
local DEFAULT_RATE_LIMIT = 70 -- events per minute
local DEFAULT_THROTTLE_WAIT = 0.05 -- 50ms minimum between events
local COMPRESSION_THRESHOLD = 128 -- bytes
local DEFAULT_TIMEOUT = 10 -- seconds
local BATCH_INTERVAL = 0.2 -- seconds between batch processing
local BATCH_SIZE_LIMIT = 20 -- maximum events per batch
local CIRCUIT_BREAKER_THRESHOLD = 5 -- failures before circuit opens
local CIRCUIT_BREAKER_RESET_TIME = 30 -- seconds before trying again

-- Type definitions for documentation
 --[=[
     @type EventPriority "high" | "medium" | "low"
     @within NetRay
 ]=]
 --[=[
     @type CompressionType "none" | "rle" | "lzw" | "auto"
     @within NetRay
 ]=]
 --[=[
     @type RequestOptions {timeout: number?, priority: EventPriority?}
     @within NetRay
 ]=]

-- Priority Enum
local Priority = {
	HIGH = 1,
	MEDIUM = 2,
	LOW = 3
}

-- Compression Type Enum
local CompressionType = {
	NONE = 0,
	RLE = 1,
	LZW = 2,
	AUTO = 3
}

-- Circuit Breaker States
local CircuitState = {
	CLOSED = 1, -- Normal operation
	OPEN = 2, -- Failing, not accepting events
	HALF_OPEN = 3 -- Testing if system recovered
}

-- Run-Length Encoding (RLE) Compression
local function rleCompress(data)
	if type(data) ~= "string" then
		return data, CompressionType.NONE
	end

	if #data < 8 then -- Too small to benefit from compression
		return data, CompressionType.NONE
	end

	local compressed = {}
	local count = 1
	local currentChar = string.sub(data, 1, 1)

	for i = 2, #data do
		local char = string.sub(data, i, i)

		if char == currentChar and count < 255 then
			count = count + 1
		else
			table.insert(compressed, string.char(count))
			table.insert(compressed, currentChar)
			currentChar = char
			count = 1
		end
	end

	-- Add the last run
	table.insert(compressed, string.char(count))
	table.insert(compressed, currentChar)

	local result = table.concat(compressed)

	-- Only return compressed version if it's actually smaller
	if #result < #data then
		return result, CompressionType.RLE
	else
		return data, CompressionType.NONE
	end
end

local function rleDecompress(data)
	data = data[1]

	local decompressed = {}
	local i = 1

	while i <= #data do
		local count = string.byte(string.sub(data, i, i))
		local char = string.sub(data, i + 1, i + 1)

		for j = 1, count do
			table.insert(decompressed, char)
		end

		i = i + 2
	end

	return table.concat(decompressed)
end

-- LZW Compression
local function lzwCompress(data)
	-- Type check for early return
	if type(data) ~= "string" then
		return data, 0 -- CompressionType.NONE
	end

	-- Size check for early return
	local COMPRESSION_THRESHOLD = 128
	if #data < COMPRESSION_THRESHOLD then
		return data, 0 -- CompressionType.NONE
	end

	-- Initialize dictionary with single characters (0-255)
	local dictionary = {}
	for i = 0, 255 do
		dictionary[string.char(i)] = i
	end

	local result = table.create(#data / 2) -- Pre-allocate with estimated size
	local resultIndex = 1
	local w = ""
	local dictSize = 256

	-- Process each character
	for i = 1, #data do
		local c = string.sub(data, i, i)
		local wc = w .. c

		if dictionary[wc] then
			w = wc
		else
			-- Output code for w
			result[resultIndex] = dictionary[w]
			resultIndex = resultIndex + 1

			-- Add wc to dictionary if there's room
			if dictSize < 65536 then -- 2^16, using 16-bit codes max
				dictionary[wc] = dictSize
				dictSize = dictSize + 1
			end

			w = c
		end
	end

	-- Output code for remaining w
	if w ~= "" then
		result[resultIndex] = dictionary[w]
		resultIndex = resultIndex + 1
	end

	-- Convert to binary representation - optimized for Luau
	local binaryResult = table.create(resultIndex * 2)
	for i = 1, resultIndex - 1 do
		local code = result[i]
		binaryResult[i*2-1] = string.char(Bits.band(code, 255))
		binaryResult[i*2] = string.char(Bits.rshift(code, 8))
	end

	-- Add dictionary size metadata at beginning
	local header = string.char(Bits.band(dictSize, 255)) .. string.char(Bits.rshift(dictSize, 8))
	local compressed = header .. table.concat(binaryResult)

	-- Only return compressed version if it's actually smaller
	if #compressed < #data then
		return compressed, 2 -- CompressionType.LZW
	else
		return data, 0 -- CompressionType.NONE
	end
end

local function lzwDecompress(data)
	data = data[1]
	--	print("Input data length:", #data) -- Debug print to check the input data length

	-- Read dictionary size from header
	local dictSizeLow = string.byte(string.sub(data, 1, 1))
	local dictSizeHigh = string.byte(string.sub(data, 2, 2))
	local dictSize = Bits.bor(dictSizeLow, Bits.lshift(dictSizeHigh, 8))
	--	print("Initial dictionary size:", dictSize)

	-- Initialize dictionary (0-255 for single chars)
	local dictionary = {}
	for i = 0, 255 do
		dictionary[i] = string.char(i)
	end

	-- Read compressed codes
	local codes = {}
	local i = 3 -- Start after header
	local codesCount = 0

	while i <= #data - 1 do
		local codeLow = string.byte(string.sub(data, i, i))
		local codeHigh = string.byte(string.sub(data, i + 1, i + 1))
		local code = Bits.bor(codeLow, Bits.lshift(codeHigh, 8))
		codesCount = codesCount + 1
		codes[codesCount] = code
		i = i + 2
	end

	--	print("Number of codes read:", codesCount)
	--	print("First few codes:", codes[1], codes[2], codes[3], codes[4])

	if codesCount == 0 then
		return ""
	end

	-- Decompress
	local result = {}
	local w = dictionary[codes[1]] -- First code gives first string
	table.insert(result, w)

	local nextDictSize = 256 -- Next available dictionary index

	for i = 2, codesCount do
		local k = codes[i]
		local entry

		if dictionary[k] then
			entry = dictionary[k]
		elseif k == nextDictSize then
			entry = w .. string.sub(w, 1, 1)
		else
			warn("Invalid code encountered:", k)
			--	print("Current dictionary size:", nextDictSize)
			return table.concat(result) -- Return what we've got so far
		end

		table.insert(result, entry)

		-- Add to dictionary if there's room
		if nextDictSize < 65536 then
			dictionary[nextDictSize] = w .. string.sub(entry, 1, 1)
			nextDictSize = nextDictSize + 1
		end

		w = entry
	end

	return table.concat(result)
end

-- Data stats collection for auto compression
local compressionStats = {
	strings = {
		totalRle = 0,
		totalLzw = 0,
		totalUncompressed = 0,
		countRle = 0,
		countLzw = 0,
		countUncompressed = 0
	},
	tables = {
		avgDepth = 0,
		totalCount = 0
	}
}

-- Recursive table compression with auto-selection
local function compressTableData(data, preferredMethod)
	if type(data) ~= "table" then
		if type(data) == "string" and #data >= COMPRESSION_THRESHOLD then
			local compressedData, compressionType 
			if preferredMethod == CompressionType.AUTO then
				-- Calculate efficiency ratio for string compression methods
				local rleRatio = compressionStats.strings.countRle > 0 
					and compressionStats.strings.totalRle / compressionStats.strings.countRle 
					or 1

				local lzwRatio = compressionStats.strings.countLzw > 0 
					and compressionStats.strings.totalLzw / compressionStats.strings.countLzw 
					or 1

				-- Choose compression based on historical performance
				if lzwRatio < rleRatio then
					compressedData, compressionType = lzwCompress(data)
				else
					compressedData, compressionType = rleCompress(data)
				end
			elseif preferredMethod == CompressionType.RLE then
				compressedData, compressionType = rleCompress(data)
			elseif preferredMethod == CompressionType.LZW then
				compressedData, compressionType = lzwCompress(data)
			else
				compressedData, compressionType = data, CompressionType.NONE
			end

			-- Update compression statistics
			if compressionType == CompressionType.RLE then
				compressionStats.strings.totalRle = compressionStats.strings.totalRle + (#data / #compressedData)
				compressionStats.strings.countRle = compressionStats.strings.countRle + 1
			elseif compressionType == CompressionType.LZW then
				compressionStats.strings.totalLzw = compressionStats.strings.totalLzw + (#data / #compressedData)
				compressionStats.strings.countLzw = compressionStats.strings.countLzw + 1
			else
				compressionStats.strings.countUncompressed = compressionStats.strings.countUncompressed + 1
			end
			return compressedData, compressionType
		else
			return data, CompressionType.NONE
		end
	end

	-- Update table statistics
	compressionStats.tables.totalCount = compressionStats.tables.totalCount + 1

	local result = {}
	local compressionInfo = {}
	local tableDepth = 0

	for k, v in pairs(data) do
		local compressedValue, compressionType = compressTableData(v, preferredMethod)
		result[k] = compressedValue
		if compressionType ~= CompressionType.NONE then
			compressionInfo[k] = compressionType
		end

		-- Track max depth
		if type(v) == "table" then
			tableDepth = math.max(tableDepth, 1)
		end
	end

	-- Update average table depth
	compressionStats.tables.avgDepth = (compressionStats.tables.avgDepth * (compressionStats.tables.totalCount - 1) + tableDepth) 
		/ compressionStats.tables.totalCount

	return result, compressionInfo
end

local function decompressTableData(data)
	if type(data) ~= "table" or not data.data or not data.compressionInfo then
		return data
	end

	local result = {}

	for k, v in pairs(data.data) do
		if type(v) == "table" and v.data and v.compressionInfo then
			result[k] = decompressTableData(v)
		elseif data.compressionInfo[k] then
			if data.compressionInfo[k] == CompressionType.RLE then
				if type(v) == "string" then
					result[k] = rleDecompress(v)
				else
					result[k] = v
				end
			elseif data.compressionInfo[k] == CompressionType.LZW then
				if type(v) == "string" then
					result[k] = lzwDecompress(v)
				else
					result[k] = v
				end
			else
				result[k] = v
			end
		else
			result[k] = v
		end
	end

	return result
end

-- Enhanced compression function with auto selection
local function compressData(data, preferredMethod)
	if type(data) ~= "string" and type(data) ~= "table" then
		return data, CompressionType.NONE
	end
	preferredMethod = preferredMethod or CompressionType.AUTO
	if type(data) == "string" then
		if #data < COMPRESSION_THRESHOLD then
			return data, CompressionType.NONE
		end
		if preferredMethod == CompressionType.AUTO then
			-- Calculate efficiency ratio for string compression methods
			local rleRatio = compressionStats.strings.countRle > 0 
				and compressionStats.strings.totalRle / compressionStats.strings.countRle 
				or 1
			local lzwRatio = compressionStats.strings.countLzw > 0 
				and compressionStats.strings.totalLzw / compressionStats.strings.countLzw 
				or 1
			-- Try the historically better method first
			if lzwRatio < rleRatio then
				local lzwData, lzwType = lzwCompress(data)
				if lzwType ~= CompressionType.NONE then
					compressionStats.strings.totalLzw = compressionStats.strings.totalLzw + (#data / #lzwData)
					compressionStats.strings.countLzw = compressionStats.strings.countLzw + 1
					return lzwData, lzwType
				end
				-- Fall back to RLE if LZW wasn't effective
				local rleData, rleType = rleCompress(data)
				if rleType ~= CompressionType.NONE then
					compressionStats.strings.totalRle = compressionStats.strings.totalRle + (#data / #rleData)
					compressionStats.strings.countRle = compressionStats.strings.countRle + 1
					return rleData, rleType
				end
				compressionStats.strings.countUncompressed = compressionStats.strings.countUncompressed + 1
				return data, CompressionType.NONE
			else
				local rleData, rleType = rleCompress(data)
				if rleType ~= CompressionType.NONE then
					compressionStats.strings.totalRle = compressionStats.strings.totalRle + (#data / #rleData)
					compressionStats.strings.countRle = compressionStats.strings.countRle + 1
					return rleData, rleType
				end
				-- Fall back to LZW if RLE wasn't effective
				local lzwData, lzwType = lzwCompress(data)
				if lzwType ~= CompressionType.NONE then
					compressionStats.strings.totalLzw = compressionStats.strings.totalLzw + (#data / #lzwData)
					compressionStats.strings.countLzw = compressionStats.strings.countLzw + 1
					return lzwData, lzwType
				end
				compressionStats.strings.countUncompressed = compressionStats.strings.countUncompressed + 1
				return data, CompressionType.NONE
			end
		elseif preferredMethod == CompressionType.RLE then
			local rleData, rleType = rleCompress(data)
			if rleType ~= CompressionType.NONE then
				compressionStats.strings.totalRle = compressionStats.strings.totalRle + (#data / #rleData)
				compressionStats.strings.countRle = compressionStats.strings.countRle + 1
			else
				compressionStats.strings.countUncompressed = compressionStats.strings.countUncompressed + 1
			end
			return rleData, rleType
		elseif preferredMethod == CompressionType.LZW then
			local lzwData, lzwType = lzwCompress(data)
			if lzwType ~= CompressionType.NONE then
				compressionStats.strings.totalLzw = compressionStats.strings.totalLzw + (#data / #lzwData)
				compressionStats.strings.countLzw = compressionStats.strings.countLzw + 1
			else
				compressionStats.strings.countUncompressed = compressionStats.strings.countUncompressed + 1
			end
			return lzwData, lzwType
		else
			compressionStats.strings.countUncompressed = compressionStats.strings.countUncompressed + 1
			return data, CompressionType.NONE
		end
	else -- table
		local compressedData, compressionType = compressTableData(data, preferredMethod)
		return compressedData, compressionType
	end
end

local function decompressData(data, compressionType)

	if compressionType == CompressionType.NONE then
		return data
	elseif compressionType == CompressionType.RLE then
		return rleDecompress(data)
	elseif compressionType == CompressionType.LZW then
		return lzwDecompress(data)
	elseif type(data) == "table" and data.data and data.compressionInfo then
		return decompressTableData(data)
	else
		return data
	end
end

-- Generate a unique ID for requests
local function generateRequestId()
	local template = "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"
	return string.gsub(template, "[xy]", function(c)
		local v = c == "x" and math.random(0, 0xf) or math.random(0x8, 0xb)
		return string.format("%x", v)
	end)
end

-- Main NetRay module
local NetRay = {
	_version = "2.0.2",
	_events = {},
	_remotes = {},
	_middleware = {},
	_rateLimits = {},
	_throttles = {},
	_debug = true,
	_metrics = {
		totalEventsFired = 0,
		totalBytesSent = 0,
		totalBytesReceived = 0,
		eventCounts = {},
		compressionSavings = 0,
		avgResponseTime = 0,
		totalRequests = 0,
		failedRequests = 0
	},
	_pendingRequests = {},
	_batchQueues = {},
	_circuitBreakers = {},
	_typeDefinitions = {},
	_requestHandlers = {},
	_securityHandlers = {}
}

-- Promise support
NetRay.Promise = Promise

-- Setup function
function NetRay:Setup()
	if not IS_SERVER then
		error("NetRay:Setup() can only be called from the server")
		return
	end

	-- Create container for RemoteEvents if it doesn't exist
	local netFolder = ReplicatedStorage:FindFirstChild("NetRayEvents")
	if not netFolder then
		netFolder = Instance.new("Folder")
		netFolder.Name = "NetRayEvents"
		netFolder.Parent = ReplicatedStorage
	end

	-- Create folder for batched events
	local batchFolder = netFolder:FindFirstChild("NetRayBatched")
	if not batchFolder then
		batchFolder = Instance.new("Folder")
		batchFolder.Name = "NetRayBatched"
		batchFolder.Parent = netFolder
	end

	-- Create a single RemoteEvent for batched events
	local batchRemote = batchFolder:FindFirstChild("BatchedEvents")
	if not batchRemote then
		batchRemote = Instance.new("RemoteEvent")
		batchRemote.Name = "BatchedEvents"
		batchRemote.Parent = batchFolder
	end

	-- Create a single RemoteEvent for requests
	local requestRemote = netFolder:FindFirstChild("Requests")
	if not requestRemote then
		requestRemote = Instance.new("RemoteEvent")
		requestRemote.Name = "Requests"
		requestRemote.Parent = netFolder
	end

	-- Create a single RemoteEvent for responses
	local responseRemote = netFolder:FindFirstChild("Responses")
	if not responseRemote then
		responseRemote = Instance.new("RemoteEvent")
		responseRemote.Name = "Responses"
		responseRemote.Parent = netFolder
	end
	
	-- Create a single RemoteEvent for syncing
	local SyncRemote = netFolder:FindFirstChild("Sync")
	if not SyncRemote then
		SyncRemote = Instance.new("RemoteEvent")
		SyncRemote.Name = "Sync"
		SyncRemote.Parent = netFolder
	end

	
	-- Store references
	self._batchRemote = batchRemote
	self._requestRemote = requestRemote
	self._responseRemote = responseRemote
	self._SyncRemote = SyncRemote
	
	-- Set up batch processing
	self:_setupBatchProcessing()

	-- Set up request/response system
	self:_setupRequestSystem()

	return self
end

-- Register event (server-side)
function NetRay:RegisterEvent(eventName, options)
	if not IS_SERVER then
		error("NetRay:RegisterEvent() can only be called from the server")
		return self
	end

	options = options or {}
	local rateLimit = options.rateLimit or DEFAULT_RATE_LIMIT
	local throttleWait = options.throttleWait or DEFAULT_THROTTLE_WAIT
	local middleware = options.middleware or {}
	local typeDefinitions = options.typeDefinitions
	local priority = options.priority or Priority.MEDIUM
	local batchable = options.batchable ~= false -- Default to true
	local version = options.version or "2.0.2"

	-- Register event settings
	self._events[eventName] = {
		name = eventName,
		rateLimit = rateLimit,
		throttleWait = throttleWait,
		middleware = middleware,
		typeDefinitions = typeDefinitions,
		priority = priority,
		batchable = batchable,
		version = version,
	}

	self._SyncRemote:FireAllClients(self._events)
	
	-- Store type definitions for documentation
	if typeDefinitions then
		self._typeDefinitions[eventName] = typeDefinitions
	end

	return self
end

-- Set up batch processing system
function NetRay:_setupBatchProcessing()
	if IS_SERVER then
		-- Handle batched events from clients
		self._batchRemote.OnServerEvent:Connect(function(player, batchData)
			-- Decompress batch data if needed
			local batch
			if type(batchData) == "table" and batchData.compressed then
				batch = decompressData(batchData.data, batchData.compressionType)
			else
				batch = batchData
			end

			-- Process each event in the batch
			for _, eventData in ipairs(batch) do
				local eventName = eventData.name
				local args = eventData.args or {}
				
				-- Process as if it was a regular event
				self:_handleServerReceive(eventName, player, unpack(args))
			end
		end)
	else
		-- Set up client-side batch processing
		self._batchInterval = BATCH_INTERVAL
		self._maxBatchSize = BATCH_SIZE_LIMIT

		-- Initialize batch queues for different priorities
		self._batchQueues = {
			[Priority.HIGH] = {},
			[Priority.MEDIUM] = {},
			[Priority.LOW] = {}
		}

		-- Start the batch processing loop
		task.spawn(function()
			while true do
				self:_processBatches()
				task.wait(self._batchInterval)
			end
		end)
	end
end

function NetRay:_setupClientEventReceiving()
	if not IS_CLIENT then return end

	self._responseRemote.OnClientEvent:Connect(function(eventData)
		-- Skip if this is a response to a request
		if eventData.id then return end

		local eventName = eventData.name
		local eventConfig = self._events[eventName]

		-- If no connections for this event, ignore
		if not eventConfig or not eventConfig.connections then return end

		-- Decompress data if needed
		local args
		if eventData.compressed then
			args = decompressData(eventData.data, eventData.compressionType[1])
		else
			args = eventData.data
		end

		-- Ensure args is a table
		if type(args) ~= "table" then
			args = {args}
		end

		-- Call all connected callbacks
		for _, conn in ipairs(eventConfig.connections) do
			if conn.connection.Connected then
				task.spawn(function()
					conn.callback(unpack(args))
				end)
			end
		end
	end)
end

local function sanitizeData(data)
	if type(data) == "string" then
		-- Replace non-ASCII characters with '?'
		return data:gsub("[\128-\255]", "?")
	elseif type(data) == "table" then
		-- Recursively sanitize each element in the table
		local sanitizedTable = {}
		for key, value in pairs(data) do
			sanitizedTable[key] = sanitizeData(value)
		end
		return sanitizedTable
	else
		-- Return the data as is if it's not a string or table
		return data
	end
end

-- Process batched events on client
function NetRay:_processBatches()
	if not IS_CLIENT then return end

	-- Process each priority level, starting with highest
	for priority = Priority.HIGH, Priority.LOW do
		local queue = self._batchQueues[priority]
		if #queue > 0 then
			-- Create batch with up to maxBatchSize events
			local batch = {}
			local count = math.min(#queue, self._maxBatchSize)

			for i = 1, count do
				table.insert(batch, table.remove(queue, 1))
			end

			-- Compress the batch if it's large enough
			local batchSize = #BinaryEncoder.encode(batch)
			if batchSize >= COMPRESSION_THRESHOLD then
				local compressedData, compressionType = compressData(batch)
				self._batchRemote:FireServer({
					compressed = true,
					data = compressedData,
					compressionType = compressionType
				})
				-- Update metrics
				self._metrics.compressionSavings = self._metrics.compressionSavings + (batchSize - #BinaryEncoder.encode(sanitizeData(batch)))
			else
				-- Send uncompressed
				self._batchRemote:FireServer(batch)
			end

			-- Update metrics
			self._metrics.totalEventsFired = self._metrics.totalEventsFired + count
			self._metrics.totalBytesSent = self._metrics.totalBytesSent + batchSize

			-- Exit after processing one batch (to handle high priority first)
			-- Will Process more in the next cycle
			break
		end
	end
end

-- Set up request/response system
function NetRay:_setupRequestSystem()
	if IS_SERVER then
		-- Handle incoming requests from clients
		self._requestRemote.OnServerEvent:Connect(function(player, requestData)
			local requestId = requestData.id
			local eventName = requestData.name
			local args = requestData.args or {}

			if requestData.compressed then
				args = decompressData(requestData.data, requestData.compressionType[1])
			else
				args = unpack(requestData.args)
			end

			-- Check if handler exists
			if not self._requestHandlers[eventName] then
				self._responseRemote:FireClient(player, {
					id = requestId,
					success = false,
					error = "No handler registered for " .. eventName
				})
				return
			end

			-- Execute handler
			local handler = self._requestHandlers[eventName]
			local success, result = pcall(function()
				return handler(player, args)
			end)

			-- Send response
			if success then
				self._responseRemote:FireClient(player, {
					id = requestId,
					success = true,
					result = result
				})
			else
				self._responseRemote:FireClient(player, {
					id = requestId,
					success = false,
					error = result
				})
			end
		end)
	else
		-- Handle responses on client
		self._responseRemote.OnClientEvent:Connect(function(responseData)
			local requestId = responseData.id
			local pendingRequest = self._pendingRequests[requestId]

			if pendingRequest then

				-- Resolve or reject the promise
				if responseData.success then
					pendingRequest.resolve(responseData.result)
				else
					pendingRequest.reject(responseData.error)
				end

				-- Remove from pending requests
				self._pendingRequests[requestId] = nil

				-- Update metrics
				self._metrics.totalRequests = self._metrics.totalRequests + 1
				local duration = tick() - pendingRequest.startTime
				self._metrics.avgResponseTime = (self._metrics.avgResponseTime * (self._metrics.totalRequests - 1) + duration) / self._metrics.totalRequests
			end
		end)
	end
end

-- Register a request handler (server-side)
function NetRay:RegisterRequestHandler(eventName, handler, options)
	if not IS_SERVER then
		error("NetRay:RegisterRequestHandler() can only be called from the server")
		return self
	end

	options = options or {}
	local typeDefinitions = options.typeDefinitions
	local returnType = options.returnType

	-- Register the handler
	self._requestHandlers[eventName] = handler
	self._events[eventName].callback = handler

	-- Store type definitions
	if typeDefinitions then
		self._typeDefinitions[eventName .. "_request"] = typeDefinitions
	end
	if returnType then
		self._typeDefinitions[eventName .. "_response"] = returnType
	end

	return self
end

-- Register a security handler (server-side)
function NetRay:RegisterSecurityHandler(eventName, handler)
	if not IS_SERVER then
		error("NetRay:RegisterSecurityHandler() can only be called from the server")
		return self
	end

	self._securityHandlers[eventName] = handler
	return self
end

-- Connect to an event (client-side)
function NetRay:Connect(eventName, callback)
	if not IS_CLIENT then
		error("NetRay:Connect() can only be called from the client")
		return
	end

	print("[NetRay] Attempting to connect to event:", eventName) -- DEBUG LINE

	local connection = {
		Connected = true,
		Disconnect = function(self)
			self.Connected = false
		end
	}

	if not self._events[eventName] then
		self._events[eventName] = { name = eventName, connections = {} }
	elseif not self._events[eventName].connections then
		self._events[eventName].connections = {}
	end

	table.insert(self._events[eventName].connections, {
		callback = callback,
		connection = connection
	})

	print("[NetRay] Successfully connected to event:", eventName) -- DEBUG LINE

	return connection
end

-- Request from server (client-side)
function NetRay:RequestFromServer(eventName, ...)
	if not IS_CLIENT then
		return Promise.reject("NetRay:RequestFromServer() can only be called from the client")
	end

	local args = {...}
	local options = {}

	-- Check if last argument is options table
	if type(args[#args]) == "table" and args[#args]._isRequestOptions then
		options = table.remove(args)
	end

	local timeout = options.timeout or DEFAULT_TIMEOUT
	local priority = options.priority or Priority.MEDIUM

	-- Generate request ID
	local requestId = generateRequestId()

	-- Create and return a promise
	return Promise.new(function(resolve, reject)
		-- Add to pending requests
		self._pendingRequests[requestId] = {
			resolve = resolve,
			reject = reject,
			startTime = tick()
		}

		-- Set timeout
		self._pendingRequests[requestId].timeoutConnection = task.delay(timeout, function()
			if self._pendingRequests[requestId] then
				self._pendingRequests[requestId] = nil
				self._metrics.failedRequests = self._metrics.failedRequests + 1
				reject("Request timed out after " .. timeout .. " seconds")
			end
		end)


		-- Send request
		self._requestRemote:FireServer({
			id = requestId,
			name = eventName,
			args = args,
			priority = priority
		})
	end)
end

-- Add to batch queue (client-side)
function NetRay:_addToBatchQueue(eventName, priority, ...)
	if not IS_CLIENT then return end

	local args = {...}

	-- Add to appropriate queue
	table.insert(self._batchQueues[priority], {
		name = eventName,
		args = args
	})
end

-- Fire event to server (client-side)
function NetRay:FireServer(eventName, ...)
	if not IS_CLIENT then
		error("NetRay:FireServer() can only be called from the client")
		return self
	end

	local args = {...}
	local eventConfig = self._events[eventName]

	-- Default configuration if event not registered
	if not eventConfig then
		eventConfig = {
			name = eventName,
			priority = Priority.MEDIUM,
			batchable = true
		}
	end

	-- Apply rate limiting
	if self:_isRateLimited(eventName) then
		if self._debug then
			warn("[NetRay] Event '" .. eventName .. "' rate limited")
		end
		return self
	end

	-- Apply throttling
	if self:_isThrottled(eventName) then
		if self._debug then
			warn("[NetRay] Event '" .. eventName .. "' throttled")
		end
		return self
	end

	-- Check circuit breaker
	if self:_isCircuitOpen(eventName) then
		if self._debug then
			warn("[NetRay] Circuit breaker open for event '" .. eventName .. "'")
		end
		return self
	end

	-- Check type definitions
	if eventConfig.typeDefinitions then
		local valid, errorMsg = TypeChecker.validateArgs(args, eventConfig.typeDefinitions)
		if not valid then
			if self._debug then
				warn("[NetRay] Type check failed for '" .. eventName .. "': " .. errorMsg)
			end
			return self
		end
	end

	-- Update metrics
	self._metrics.totalEventsFired = self._metrics.totalEventsFired + 1
	if not self._metrics.eventCounts[eventName] then
		self._metrics.eventCounts[eventName] = 0
	end
	self._metrics.eventCounts[eventName] = self._metrics.eventCounts[eventName] + 1

	-- Add to batch queue if batchable, otherwise fire directly
	if eventConfig.batchable then
		self:_addToBatchQueue(eventName, eventConfig.priority, unpack(args))
	else
		local jsonData = BinaryEncoder.encode(args)
		local byteSize = #jsonData

		if byteSize >= COMPRESSION_THRESHOLD then
			-- Compress the data
			local compressedData, compressionType = compressData(args)
			self._requestRemote:FireServer({
				name = eventName,
				compressed = true,
				data = compressedData,
				compressionType = compressionType,
				direct = true
			})

			-- Update metrics
			self._metrics.compressionSavings = self._metrics.compressionSavings + (byteSize - #BinaryEncoder.encode(sanitizeData(compressedData)))
		else
			-- Send uncompressed
			self._requestRemote:FireServer({
				name = eventName,
				args = args,
				direct = true
			})
		end
	end

	return self
end

-- Fire event to client (server-side)
function NetRay:FireClient(eventName, player, ...)
	if not IS_SERVER then
		error("NetRay:FireClient() can only be called from the server")
		return self
	end

	local args = {...}
	local eventConfig = self._events[eventName]

	-- Default configuration if event not registered
	if not eventConfig then
		eventConfig = {
			name = eventName,
			priority = Priority.MEDIUM
		}
	end

	-- Check type definitions
	if eventConfig.typeDefinitions then
		local valid, errorMsg = TypeChecker.validateArgs(args, eventConfig.typeDefinitions)
		if not valid then
			if self._debug then
				warn("[NetRay] Type check failed for '" .. eventName .. "': " .. errorMsg)
			end
			return self
		end
	end

	-- Apply middleware
	if eventConfig.middleware and #eventConfig.middleware > 0 then
		local shouldContinue = true
		for _, middleware in ipairs(eventConfig.middleware) do
			shouldContinue = middleware(player, args)
			if shouldContinue == false then
				if self._debug then
					warn("[NetRay] Event '" .. eventName .. "' blocked by middleware")
				end
				return self
			end
		end
	end

	-- Update metrics
	self._metrics.totalEventsFired = self._metrics.totalEventsFired + 1
	if not self._metrics.eventCounts[eventName] then
		self._metrics.eventCounts[eventName] = 0
	end
	self._metrics.eventCounts[eventName] = self._metrics.eventCounts[eventName] + 1

	-- Determine if compression needed based on data size
	local jsonData = BinaryEncoder.encode(args)
	local byteSize = #jsonData
	self._metrics.totalBytesSent = self._metrics.totalBytesSent + byteSize

	if byteSize >= COMPRESSION_THRESHOLD then
		-- Compress the data
		local compressedData, compressionType = compressData(args)
		local compressedSize = #BinaryEncoder.encode(sanitizeData(compressedData))
		self._metrics.compressionSavings = self._metrics.compressionSavings + (byteSize - compressedSize)

		-- Create the event data structure
		local eventData = {
			name = eventName,
			compressed = true,
			compressionType = compressionType,
			data = compressedData,
			version = eventConfig.version
		}

		-- Fire the event
		self._responseRemote:FireClient(player, eventData)
	else
		-- Fire uncompressed
		self._responseRemote:FireClient(player, {
			name = eventName,
			data = args,
			version = eventConfig.version
		})
	end

	return self
end

-- Fire event to all clients (server-side)
function NetRay:FireAllClients(eventName, ...)
	if not IS_SERVER then
		error("NetRay:FireAllClients() can only be called from the server")
		return self
	end

	for _, player in ipairs(Players:GetPlayers()) do
		self:FireClient(eventName, player, ...)
	end

	return self
end

-- Fire event to specific clients (server-side)
function NetRay:FireClients(eventName, players, ...)
	if not IS_SERVER then
		error("NetRay:FireClients() can only be called from the server")
		return self
	end

	for _, player in ipairs(players) do
		self:FireClient(eventName, player, ...)
	end

	return self
end

-- Handle received events on server
function NetRay:_handleServerReceive(eventName, player, ...)
	if not IS_SERVER then return end

	local args = {...}
	local eventConfig = self._events[eventName]

	-- Check if event exists
	if not eventConfig then
		if self._debug then
			warn("[NetRay] Received unregistered event: " .. eventName)
		end
		return
	end

	-- Check type definitions
	if eventConfig.typeDefinitions then
		local valid, errorMsg = TypeChecker.validateArgs(args, eventConfig.typeDefinitions)
		if not valid then
			if self._debug then
				warn("[NetRay] Type check failed for '" .. eventName .. "': " .. errorMsg)
			end
			return
		end
	end

	-- Apply security handler if exists
	if self._securityHandlers[eventName] then
		local securityHandler = self._securityHandlers[eventName]
		local securityPassed = pcall(function()
			return securityHandler(player, unpack(args))
		end)

		if not securityPassed then
			if self._debug then
				warn("[NetRay] Security check failed for '" .. eventName .. "' from player " .. player.Name)
			end
			return
		end
	end

	-- Apply middleware
	if eventConfig.middleware and #eventConfig.middleware > 0 then
		local shouldContinue = true
		for _, middleware in ipairs(eventConfig.middleware) do
			shouldContinue = middleware(player, args)
			if shouldContinue == false then
				if self._debug then
					warn("[NetRay] Event '" .. eventName .. "' blocked by middleware")
				end
				return
			end
		end
	end
	
	print(self._events[eventName].callback)
	
	-- Trigger event for listeners
	if eventConfig.callback then
		eventConfig.callback(player, unpack(args))
	end
end

-- Check if an event is rate limited
function NetRay:_isRateLimited(eventName)
	local eventConfig = self._events[eventName]
	if not eventConfig or not eventConfig.rateLimit then
		return false
	end

	local rateLimit = eventConfig.rateLimit

	-- Initialize rate limit tracking
	if not self._rateLimits[eventName] then
		self._rateLimits[eventName] = {
			count = 0,
			resetTime = tick() + 60 -- 1 minute window
		}
	end

	local limitInfo = self._rateLimits[eventName]

	-- Reset counter if time expired
	if tick() > limitInfo.resetTime then
		limitInfo.count = 0
		limitInfo.resetTime = tick() + 60
	end

	-- Check if over limit
	if limitInfo.count >= rateLimit then
		return true
	end

	-- Increment counter
	limitInfo.count = limitInfo.count + 1
	return false
end

-- Check if an event is throttled
function NetRay:_isThrottled(eventName)
	local eventConfig = self._events[eventName]
	if not eventConfig or not eventConfig.throttleWait then
		return false
	end

	local throttleWait = eventConfig.throttleWait

	-- Initialize throttle tracking
	if not self._throttles[eventName] then
		self._throttles[eventName] = 0
	end

	local lastTime = self._throttles[eventName]
	local currentTime = tick()

	-- Check if enough time has passed
	if currentTime - lastTime < throttleWait then
		return true
	end

	-- Update last time
	self._throttles[eventName] = currentTime
	return false
end

-- Check if circuit breaker is open for an event
function NetRay:_isCircuitOpen(eventName)
	local circuitBreaker = self._circuitBreakers[eventName]
	if not circuitBreaker then
		-- Initialize circuit breaker
		self._circuitBreakers[eventName] = {
			state = CircuitState.CLOSED,
			failureCount = 0,
			lastFailure = 0,
			lastAttempt = 0
		}
		return false
	end

	-- If circuit is closed, allow the event
	if circuitBreaker.state == CircuitState.CLOSED then
		return false
	end

	-- If circuit is open, check if enough time has passed to try again
	if circuitBreaker.state == CircuitState.OPEN then
		local currentTime = tick()
		if currentTime - circuitBreaker.lastFailure > CIRCUIT_BREAKER_RESET_TIME then
			-- Transition to half-open state
			circuitBreaker.state = CircuitState.HALF_OPEN
			circuitBreaker.lastAttempt = currentTime
			return false
		end
		return true
	end

	-- If circuit is half-open, allow one test request
	if circuitBreaker.state == CircuitState.HALF_OPEN then
		local currentTime = tick()
		if currentTime - circuitBreaker.lastAttempt < 1 then
			-- Only allow one request per second in half-open state
			return true
		end
		circuitBreaker.lastAttempt = currentTime
		return false
	end

	return false
end

-- Record a successful event (for circuit breaker)
function NetRay:RecordSuccess(eventName)
	local circuitBreaker = self._circuitBreakers[eventName]
	if not circuitBreaker then return end

	if circuitBreaker.state == CircuitState.HALF_OPEN then
		-- Reset circuit breaker on successful test
		circuitBreaker.state = CircuitState.CLOSED
		circuitBreaker.failureCount = 0
	end
end

-- Record a failed event (for circuit breaker)
function NetRay:RecordFailure(eventName)
	if not self._circuitBreakers[eventName] then
		self._circuitBreakers[eventName] = {
			state = CircuitState.CLOSED,
			failureCount = 0,
			lastFailure = 0,
			lastAttempt = 0
		}
	end

	local circuitBreaker = self._circuitBreakers[eventName]
	circuitBreaker.failureCount = circuitBreaker.failureCount + 1
	circuitBreaker.lastFailure = tick()

	-- Open circuit if failure threshold is reached
	if circuitBreaker.failureCount >= CIRCUIT_BREAKER_THRESHOLD then
		circuitBreaker.state = CircuitState.OPEN
	end
end

-- Get metrics and analytics data
function NetRay:GetMetrics()
	local currentStats = Stats.DataSendKbps

	return {
		totalEventsFired = self._metrics.totalEventsFired,
		totalBytesSent = self._metrics.totalBytesSent,
		totalBytesReceived = self._metrics.totalBytesReceived,
		eventCounts = self._metrics.eventCounts,
		compressionSavings = self._metrics.compressionSavings,
		avgResponseTime = self._metrics.avgResponseTime,
		totalRequests = self._metrics.totalRequests,
		failedRequests = self._metrics.failedRequests,
		currentBandwidthKbps = currentStats,
		compressionStats = compressionStats
	}
end

-- Enable or disable debug mode
function NetRay:SetDebug(enabled)
	self._debug = enabled
	return self
end

-- Generate documentation for all registered events
function NetRay:GenerateDocumentation()
	local docs = {
		library = {
			name = "NetRay",
			version = self._version,
			description = "A powerful, optimized Roblox networking library"
		},
		events = {},
		requestHandlers = {}
	}

	-- Document registered events
	for name, config in pairs(self._events) do
		local eventDoc = {
			name = name,
			description = config.description or "No description provided",
			rateLimit = config.rateLimit or DEFAULT_RATE_LIMIT,
			throttleWait = config.throttleWait or DEFAULT_THROTTLE_WAIT,
			priority = config.priority or Priority.MEDIUM,
			batchable = config.batchable ~= false,
			version = config.version or "2.0.2"
		}

		-- Add type definitions if available
		if self._typeDefinitions[name] then
			eventDoc.parameters = self._typeDefinitions[name]
		end

		table.insert(docs.events, eventDoc)
	end

	-- Document request handlers
	for name, _ in pairs(self._requestHandlers) do
		local handlerDoc = {
			name = name,
			description = "Request handler for " .. name
		}

		-- Add parameter types if available
		if self._typeDefinitions[name .. "_request"] then
			handlerDoc.parameters = self._typeDefinitions[name .. "_request"]
		end

		-- Add return type if available
		if self._typeDefinitions[name .. "_response"] then
			handlerDoc.returnType = self._typeDefinitions[name .. "_response"]
		end

		table.insert(docs.requestHandlers, handlerDoc)
	end

	return docs
end

function NetRay:Sync()
	self._SyncRemote.OnClientEvent:Connect(function(serverTable)
		for eventName, serverArgs in pairs(serverTable) do
			if self._events[eventName] then
				-- Update existing event configurations
				for key, value in pairs(serverArgs) do
					self._events[eventName][key] = value
				end
			else
				-- Add new event if it doesn't exist
				self._events[eventName] = serverArgs
			end
		end
		print(self._events)
	end)
end

-- Create a RequestOptions object
function NetRay.RequestOptions(options)
	options = options or {}
	options._isRequestOptions = true
	options.timeout = options.timeout or DEFAULT_TIMEOUT
	options.priority = options.priority or Priority.MEDIUM
	return options
end

-- Add ability to create namespaces for organization
function NetRay:CreateNamespace(namespaceName)
	local namespace = {}

	-- Clone main methods to namespace with prefixing
	for key, value in pairs(NetRay) do
		if type(value) == "function" and key:sub(1, 1) ~= "_" then
			namespace[key] = function(_, ...)
				local args = {...}

				-- For event registration and firing, prefix event names
				if key == "RegisterEvent" or key == "Connect" or key == "FireServer" or 
					key == "FireClient" or key == "FireAllClients" or key == "FireClients" or
					key == "RegisterRequestHandler" or key == "RequestFromServer" or
					key == "RegisterSecurityHandler" then

					if type(args[1]) == "string" then
						args[1] = namespaceName .. "." .. args[1]
					end
				end

				-- Call original method
				return NetRay[key](NetRay, unpack(args))
			end
		end
	end

	return namespace
end

-- Initialize module based on environment
if IS_SERVER then
	NetRay:Setup()
	Players.PlayerAdded:Connect(function(player)	
		NetRay._SyncRemote:FireClient(player,NetRay._events)	-- Syncing already registered events
	end)
else
	-- Wait for remotes to be created on the client
	task.spawn(function()
		local netFolder = ReplicatedStorage:WaitForChild("NetRayEvents")
		if not netFolder then
			warn("[NetRay] Failed to find NetRayEvents folder")
			return
		end

		local batchFolder = netFolder:WaitForChild("NetRayBatched")
		if batchFolder then
			NetRay._batchRemote = batchFolder:WaitForChild("BatchedEvents")
		end

		NetRay._requestRemote = netFolder.Requests
		NetRay._responseRemote = netFolder.Responses
		NetRay._SyncRemote = netFolder.Sync

		if NetRay._batchRemote and NetRay._requestRemote and NetRay._responseRemote and NetRay._SyncRemote then
			-- Setup Syncing
			NetRay:Sync()
			
			-- Set up batch processing
			NetRay:_setupBatchProcessing()

			-- Set up request/response system
			NetRay:_setupRequestSystem()

			-- Set up client event receiving
			NetRay:_setupClientEventReceiving()
		else
			warn("[NetRay] Failed to find all required RemoteEvents")
		end
	end)
end

return NetRay
