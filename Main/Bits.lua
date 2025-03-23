-- Utility functions for bit operations optimized for Luau
-- @Asta 
-- NetRay
-- V1.0.0

local Bits = {}

function Bits.lshift(x, by)
	return x * (2 ^ by)
end

function Bits.rshift(x, by)
	return math.floor(x / (2 ^ by))
end

function Bits.band(x, y)
	-- Luau doesn't have native bitwise operations, so we implement them
	local result = 0
	local bitval = 1

	while x > 0 and y > 0 do
		if x % 2 == 1 and y % 2 == 1 then
			result = result + bitval
		end
		bitval = bitval * 2
		x = math.floor(x / 2)
		y = math.floor(y / 2)
	end

	return result
end

function Bits.bor(x, y)
	-- Luau doesn't have native bitwise operations, so we implement them
	local result = 0
	local bitval = 1

	while x > 0 or y > 0 do
		if x % 2 == 1 or y % 2 == 1 then
			result = result + bitval
		end
		bitval = bitval * 2
		x = math.floor(x / 2)
		y = math.floor(y / 2)
	end

	return result
end

return Bits
