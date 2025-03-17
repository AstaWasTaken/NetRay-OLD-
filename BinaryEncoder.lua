-- Depednacy for Netray module
-- Created by [Asta] - v1.0.0

-- Binary type identifiers
local TYPE = {
	NIL = 0,
	BOOLEAN_FALSE = 1,
	BOOLEAN_TRUE = 2,
	NUMBER_INT = 3,
	NUMBER_FLOAT = 4,
	STRING_SHORT = 5,  -- String with length < 255
	STRING_LONG = 6,   -- String with length >= 255
	TABLE_START = 7,
	TABLE_END = 8,
	ARRAY_START = 9,
	ARRAY_END = 10,
	KEY_VALUE_SEPARATOR = 11,
	REFERENCE = 12,    -- For cyclic references
	VECTOR3 = 13,      -- Common Roblox type
	COLOR3 = 14,       -- Common Roblox type
	UDIM2 = 15,        -- Common Roblox type
	CFRAME = 16        -- Common Roblox type
}

-- Convert a number to a byte string
local function numberToBytes(num, isInteger)
	if isInteger or math.floor(num) == num then
		-- Integer encoding (more efficient for whole numbers)
		if num >= -128 and num <= 127 then
			-- Single byte for small integers (-128 to 127)
			return string.char(TYPE.NUMBER_INT, 1, num >= 0 and num or (256 + num))
		elseif num >= -32768 and num <= 32767 then
			-- Two bytes for medium integers (-32768 to 32767)
			local b1 = math.floor(num / 256) % 256
			local b2 = num % 256
			return string.char(TYPE.NUMBER_INT, 2, b1 >= 0 and b1 or (256 + b1), b2 >= 0 and b2 or (256 + b2))
		else
			-- Four bytes for larger integers
			local b1 = math.floor(num / 16777216) % 256
			local b2 = math.floor(num / 65536) % 256
			local b3 = math.floor(num / 256) % 256
			local b4 = num % 256
			return string.char(TYPE.NUMBER_INT, 4, 
				b1 >= 0 and b1 or (256 + b1),
				b2 >= 0 and b2 or (256 + b2),
				b3 >= 0 and b3 or (256 + b3),
				b4 >= 0 and b4 or (256 + b4))
		end
	else
		-- Float encoding using string.pack
		local packedFloat = string.pack("d", num)  -- Double precision
		return string.char(TYPE.NUMBER_FLOAT) .. packedFloat
	end
end

-- Convert a string to a byte string
local function stringToBytes(str)
	local length = #str
	if length < 255 then
		-- Short string
		return string.char(TYPE.STRING_SHORT, length) .. str
	else
		-- Long string
		local b1 = math.floor(length / 16777216) % 256
		local b2 = math.floor(length / 65536) % 256
		local b3 = math.floor(length / 256) % 256
		local b4 = length % 256
		return string.char(TYPE.STRING_LONG, b1, b2, b3, b4) .. str
	end
end

-- Check if table is an array
local function isArray(t)
	local count = 0
	for _ in pairs(t) do
		count = count + 1
	end
	return count == #t
end

-- Binary serialization of Roblox data types
local function serializeRobloxTypes(value)
	local typeOf = typeof(value)

	if typeOf == "Vector3" then
		return string.char(TYPE.VECTOR3) .. 
			string.pack("d", value.X) .. 
			string.pack("d", value.Y) .. 
			string.pack("d", value.Z)
	elseif typeOf == "Color3" then
		return string.char(TYPE.COLOR3) .. 
			string.pack("d", value.R) .. 
			string.pack("d", value.G) .. 
			string.pack("d", value.B)
	elseif typeOf == "UDim2" then
		return string.char(TYPE.UDIM2) .. 
			string.pack("d", value.X.Scale) .. 
			string.pack("d", value.X.Offset) .. 
			string.pack("d", value.Y.Scale) .. 
			string.pack("d", value.Y.Offset)
	elseif typeOf == "CFrame" then
		local x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22 = value:GetComponents()
		return string.char(TYPE.CFRAME) .. 
			string.pack("d", x) .. string.pack("d", y) .. string.pack("d", z) ..
			string.pack("d", r00) .. string.pack("d", r01) .. string.pack("d", r02) ..
			string.pack("d", r10) .. string.pack("d", r11) .. string.pack("d", r12) ..
			string.pack("d", r20) .. string.pack("d", r21) .. string.pack("d", r22)
	end

	return nil  -- Not a handled Roblox type
end

-- Main binary serialization function
local function binaryEncode(value, references)
	references = references or {}

	-- Check for reference cycles
	if type(value) == "table" then
		if references[value] then
			return string.char(TYPE.REFERENCE) .. numberToBytes(references[value], true)
		end
		references[value] = #references + 1
	end

	-- Handle nil
	if value == nil then
		return string.char(TYPE.NIL)

		-- Handle booleans
	elseif value == false then
		return string.char(TYPE.BOOLEAN_FALSE)
	elseif value == true then
		return string.char(TYPE.BOOLEAN_TRUE)

		-- Handle numbers
	elseif type(value) == "number" then
		return numberToBytes(value)

		-- Handle strings
	elseif type(value) == "string" then
		return stringToBytes(value)

		-- Handle Roblox types
	elseif typeof(value) ~= "table" then
		local robloxEncoded = serializeRobloxTypes(value)
		if robloxEncoded then
			return robloxEncoded
		end

		-- Handle tables (including arrays)
	elseif type(value) == "table" then
		local result = {}
		local isArrayTable = isArray(value)

		-- Start marker for table or array
		table.insert(result, string.char(isArrayTable and TYPE.ARRAY_START or TYPE.TABLE_START))

		if isArrayTable then
			-- Array encoding (just values)
			for _, v in ipairs(value) do
				table.insert(result, binaryEncode(v, references))
			end
		else
			-- Dictionary encoding (key-value pairs)
			for k, v in pairs(value) do
				table.insert(result, binaryEncode(k, references))
				table.insert(result, string.char(TYPE.KEY_VALUE_SEPARATOR))
				table.insert(result, binaryEncode(v, references))
			end
		end

		-- End marker for table or array
		table.insert(result, string.char(isArrayTable and TYPE.ARRAY_END or TYPE.TABLE_END))

		return table.concat(result)
	end

	-- Fallback for unsupported types
	return stringToBytes(tostring(value))
end

-- Binary decoding helper functions
local function readByte(data, index)
	return string.byte(string.sub(data, index, index)), index + 1
end

local function readBytes(data, index, count)
	return string.sub(data, index, index + count - 1), index + count
end

local function readInt(data, index, size)
	local value = 0
	for i = 0, size - 1 do
		local byte
		byte, index = readByte(data, index)
		value = value + byte * (256 ^ (size - i - 1))
	end
	return value, index
end

-- Main binary deserialization function
local function binaryDecode(data)
	local index = 1
	local references = {}

	local function decode()
		local typeId
		typeId, index = readByte(data, index)

		if typeId == TYPE.NIL then
			return nil
		elseif typeId == TYPE.BOOLEAN_FALSE then
			return false
		elseif typeId == TYPE.BOOLEAN_TRUE then
			return true
		elseif typeId == TYPE.NUMBER_INT then
			local size
			size, index = readByte(data, index)

			if size == 1 then
				local byte
				byte, index = readByte(data, index)
				return byte <= 127 and byte or (byte - 256)
			elseif size == 2 then
				local b1, b2
				b1, index = readByte(data, index)
				b2, index = readByte(data, index)
				local value = (b1 * 256) + b2
				return value <= 32767 and value or (value - 65536)
			else -- size == 4
				local b1, b2, b3, b4
				b1, index = readByte(data, index)
				b2, index = readByte(data, index)
				b3, index = readByte(data, index)
				b4, index = readByte(data, index)
				local value = (b1 * 16777216) + (b2 * 65536) + (b3 * 256) + b4
				return value <= 2147483647 and value or (value - 4294967296)
			end
		elseif typeId == TYPE.NUMBER_FLOAT then
			local packedFloat
			packedFloat, index = readBytes(data, index, 8) -- 8 bytes for double precision
			return string.unpack("d", packedFloat)
		elseif typeId == TYPE.STRING_SHORT then
			local length
			length, index = readByte(data, index)
			local str
			str, index = readBytes(data, index, length)
			return str
		elseif typeId == TYPE.STRING_LONG then
			local b1, b2, b3, b4
			b1, index = readByte(data, index)
			b2, index = readByte(data, index)
			b3, index = readByte(data, index)
			b4, index = readByte(data, index)
			local length = (b1 * 16777216) + (b2 * 65536) + (b3 * 256) + b4
			local str
			str, index = readBytes(data, index, length)
			return str
		elseif typeId == TYPE.TABLE_START then
			local tbl = {}
			references[#references + 1] = tbl

			while true do
				local nextByte
				nextByte, index = readByte(data, index)
				if nextByte == TYPE.TABLE_END then
					break
				end

				-- Go back one byte
				index = index - 1

				local key = decode()
				local separator
				separator, index = readByte(data, index)
				if separator ~= TYPE.KEY_VALUE_SEPARATOR then
					error("Expected key-value separator")
				end
				local value = decode()
				tbl[key] = value
			end

			return tbl
		elseif typeId == TYPE.ARRAY_START then
			local arr = {}
			references[#references + 1] = arr

			local i = 1
			while true do
				local nextByte
				nextByte, index = readByte(data, index)
				if nextByte == TYPE.ARRAY_END then
					break
				end

				-- Go back one byte
				index = index - 1

				arr[i] = decode()
				i = i + 1
			end

			return arr
		elseif typeId == TYPE.REFERENCE then
			local refId = decode()
			return references[refId]
		elseif typeId == TYPE.VECTOR3 then
			local x = string.unpack("d", readBytes(data, index, 8))
			index = index + 8
			local y = string.unpack("d", readBytes(data, index, 8))
			index = index + 8
			local z = string.unpack("d", readBytes(data, index, 8))
			index = index + 8
			return Vector3.new(x, y, z)
		elseif typeId == TYPE.COLOR3 then
			local r = string.unpack("d", readBytes(data, index, 8))
			index = index + 8
			local g = string.unpack("d", readBytes(data, index, 8))
			index = index + 8
			local b = string.unpack("d", readBytes(data, index, 8))
			index = index + 8
			return Color3.new(r, g, b)
		elseif typeId == TYPE.UDIM2 then
			local xScale = string.unpack("d", readBytes(data, index, 8))
			index = index + 8
			local xOffset = string.unpack("d", readBytes(data, index, 8))
			index = index + 8
			local yScale = string.unpack("d", readBytes(data, index, 8))
			index = index + 8
			local yOffset = string.unpack("d", readBytes(data, index, 8))
			index = index + 8
			return UDim2.new(xScale, xOffset, yScale, yOffset)
		elseif typeId == TYPE.CFRAME then
			local x = string.unpack("d", readBytes(data, index, 8))
			index = index + 8
			local y = string.unpack("d", readBytes(data, index, 8))
			index = index + 8
			local z = string.unpack("d", readBytes(data, index, 8))
			index = index + 8

			local r00 = string.unpack("d", readBytes(data, index, 8))
			index = index + 8
			local r01 = string.unpack("d", readBytes(data, index, 8))
			index = index + 8
			local r02 = string.unpack("d", readBytes(data, index, 8))
			index = index + 8
			local r10 = string.unpack("d", readBytes(data, index, 8))
			index = index + 8
			local r11 = string.unpack("d", readBytes(data, index, 8))
			index = index + 8
			local r12 = string.unpack("d", readBytes(data, index, 8))
			index = index + 8
			local r20 = string.unpack("d", readBytes(data, index, 8))
			index = index + 8
			local r21 = string.unpack("d", readBytes(data, index, 8))
			index = index + 8
			local r22 = string.unpack("d", readBytes(data, index, 8))
			index = index + 8

			return CFrame.new(x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22)
		end

		-- Fallback for unsupported types
		error("Unknown type ID: " .. typeId)
	end

	return decode()
end

-- Expose the module
return {
	encode = binaryEncode,
	decode = binaryDecode,
	TYPE = TYPE
}
