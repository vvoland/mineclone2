--[[

Copyright (C) 2016 - Auke Kok <sofar@foo-projects.org>

"lightning" is free software; you can redistribute it and/or modify
it under the terms of the GNU Lesser General Public License as
published by the Free Software Foundation; either version 2.1
of the license, or (at your option) any later version.

--]]

local S = minetest.get_translator("lightning")

lightning = {}

lightning.interval_low = 17
lightning.interval_high = 503
lightning.range_h = 100
lightning.range_v = 50
lightning.size = 100
-- disable this to stop lightning mod from striking
lightning.auto = true

local rng = PcgRandom(32321123312123)

local ps = {}
local ttl = -1

local revertsky = function(dtime)
	if ttl == 0 then
		return
	end
	ttl = ttl - dtime
	if ttl > 0 then
		return
	end

	mcl_weather.skycolor.remove_layer("lightning")

	ps = {}
end

minetest.register_globalstep(revertsky)

-- select a random strike point, midpoint
local function choose_pos(pos)
	if not pos then
		local playerlist = minetest.get_connected_players()
		local playercount = table.getn(playerlist)

		-- nobody on
		if playercount == 0 then
			return nil, nil
		end

		local r = rng:next(1, playercount)
		local randomplayer = playerlist[r]
		pos = randomplayer:get_pos()

		-- avoid striking underground
		if pos.y < -20 then
			return nil, nil
		end

		pos.x = math.floor(pos.x - (lightning.range_h / 2) + rng:next(1, lightning.range_h))
		pos.y = pos.y + (lightning.range_v / 2)
		pos.z = math.floor(pos.z - (lightning.range_h / 2) + rng:next(1, lightning.range_h))
	end

	local b, pos2 = minetest.line_of_sight(pos, {x = pos.x, y = pos.y - lightning.range_v, z = pos.z}, 1)

	-- nothing but air found
	if b then
		return nil, nil
	end

	local n = minetest.get_node({x = pos2.x, y = pos2.y - 1/2, z = pos2.z})
	if n.name == "air" or n.name == "ignore" then
		return nil, nil
	end

	return pos, pos2
end

-- lightning strike API
-- * pos: optional, if not given a random pos will be chosen
-- * returns: bool - success if a strike happened
lightning.strike = function(pos)
	if lightning.auto then
		minetest.after(rng:next(lightning.interval_low, lightning.interval_high), lightning.strike)
	end

	local pos2
	pos, pos2 = choose_pos(pos)

	if not pos then
		return false
	end

	minetest.add_particlespawner({
		amount = 1,
		time = 0.2,
		-- make it hit the top of a block exactly with the bottom
		minpos = {x = pos2.x, y = pos2.y + (lightning.size / 2) + 1/2, z = pos2.z },
		maxpos = {x = pos2.x, y = pos2.y + (lightning.size / 2) + 1/2, z = pos2.z },
		minvel = {x = 0, y = 0, z = 0},
		maxvel = {x = 0, y = 0, z = 0},
		minacc = {x = 0, y = 0, z = 0},
		maxacc = {x = 0, y = 0, z = 0},
		minexptime = 0.2,
		maxexptime = 0.2,
		minsize = lightning.size * 10,
		maxsize = lightning.size * 10,
		collisiondetection = true,
		vertical = true,
		-- to make it appear hitting the node that will get set on fire, make sure
		-- to make the texture lightning bolt hit exactly in the middle of the
		-- texture (e.g. 127/128 on a 256x wide texture)
		texture = "lightning_lightning_" .. rng:next(1,3) .. ".png",
		glow = minetest.LIGHT_MAX,
	})

	minetest.sound_play({ pos = pos, name = "lightning_thunder", gain = 10, max_hear_distance = 500 })

	-- damage nearby objects, transform mobs
	local objs = minetest.get_objects_inside_radius(pos2, 3.5)
	for o=1, #objs do
		local obj = objs[o]
		local lua = obj:get_luaentity()
		if obj:is_player() then
		-- Player damage
			if minetest.get_modpath("mcl_death_messages") then
				mcl_death_messages.player_damage(obj, S("@1 was struck by lightning.", obj:get_player_name()))
			end
			obj:set_hp(obj:get_hp()-5, { type = "punch", from = "mod" })
		-- Mobs
		elseif lua and lua._cmi_is_mob then
			-- pig → zombie pigman (no damage)
			if lua.name == "mobs_mc:pig" then
				local rot = obj:get_yaw()
				obj:remove()
				obj = minetest.add_entity(pos2, "mobs_mc:pigman")
				obj:set_yaw(rot)
			-- mooshroom: toggle color red/brown (no damage)
			elseif lua.name == "mobs_mc:mooshroom" then
				if lua.base_texture[1] == "mobs_mc_mooshroom.png" then
					lua.base_texture = { "mobs_mc_mooshroom_brown.png", "mobs_mc_mushroom_brown.png" }
				else
					lua.base_texture = { "mobs_mc_mooshroom.png", "mobs_mc_mushroom_red.png" }
				end
				obj:set_properties({textures = lua.base_texture})
			-- villager → witch (no damage)
			elseif lua.name == "mobs_mc:villager" then
			-- Witches are incomplete, this code is unused
			-- TODO: Enable this code when witches are working.
			--[[
				local rot = obj:get_yaw()
				obj:remove()
				obj = minetest.add_entity(pos2, "mobs_mc:witch")
				obj:set_yaw(rot)
			]]
			-- TODO: creeper → charged creeper (no damage)
			elseif lua.name == "mobs_mc:creeper" then

			-- Other mobs: Just damage
			else
				obj:set_hp(obj:get_hp()-5, { type = "punch", from = "mod" })
			end
		end
	end

	local playerlist = minetest.get_connected_players()
	for i = 1, #playerlist do
		local player = playerlist[i]
		local sky = {}

		sky.bgcolor, sky.type, sky.textures = player:get_sky()

		local name = player:get_player_name()
		if ps[name] == nil then
			ps[name] = {p = player, sky = sky}
			mcl_weather.skycolor.add_layer("lightning", {{r=255,g=255,b=255}}, true)
			mcl_weather.skycolor.active = true
		end
	end

	-- trigger revert of skybox
	ttl = 0.1

	-- Events caused by the lightning strike: Fire, damage, mob transformations, rare skeleton spawn

	pos2.y = pos2.y + 1/2
	local skeleton_lightning = false
	if rng:next(1,100) <= 3 then
		skeleton_lightning = true
	end
	if minetest.get_item_group(minetest.get_node({x = pos2.x, y = pos2.y - 1, z = pos2.z}).name, "liquid") < 1 then
		if minetest.get_node(pos2).name == "air" then
			-- Low chance for a lightning to spawn skeleton horse + skeletons
			if skeleton_lightning then
				minetest.add_entity(pos2, "mobs_mc:skeleton_horse")

				local angle, posadd
				angle = math.random(0, math.pi*2)
				for i=1,3 do
					posadd = {x=math.cos(angle),y=0,z=math.sin(angle)}
					posadd = vector.normalize(posadd)
					local mob = minetest.add_entity(vector.add(pos2, posadd), "mobs_mc:skeleton")
					mob:set_yaw(angle-math.pi/2)
					angle = angle + (math.pi*2) / 3
				end

			-- Cause a fire
			--else
				--minetest.set_node(pos2, {name = "mcl_fire:fire"})
			end
		end
	end

end

-- if other mods disable auto lightning during initialization, don't trigger the first lightning.
minetest.after(5, function(dtime)
	if lightning.auto then
		minetest.after(rng:next(lightning.interval_low,
			lightning.interval_high), lightning.strike)
	end
end)

minetest.register_chatcommand("lightning", {
	params = "[<X> <Y> <Z>]",
	description = S("Let lightning strike at the specified position or yourself"),
	privs = { maphack = true },
	func = function(name, param)
		local pos = {}
		pos.x, pos.y, pos.z = string.match(param, "^([%d.-]+)[, ] *([%d.-]+)[, ] *([%d.-]+)$")
		pos.x = tonumber(pos.x)
		pos.y = tonumber(pos.y)
		pos.z = tonumber(pos.z)
		if not (pos.x and pos.y and pos.z) then
			pos = nil
		end
		if name == "" and pos == nil then
			return false, "No position specified and unknown player"
		end
		if pos then
			lightning.strike(pos)
		else
			local player = minetest.get_player_by_name(name)
			if player then
				lightning.strike(player:get_pos())
			else
				return false, S("No position specified and unknown player")
			end
		end
		return true
	end,
})

