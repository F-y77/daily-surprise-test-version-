-- 新BUFF 121-130 定义 (复制并添加到modmain.lua中的BUFF_LIST的结尾，在"}"前)

    {
        id = "BUFF_121",
        name = "自然呼吸",
        description = "你的氧气消耗减少，潜水时间延长！",
        fn = function(player)
            -- 增加氧气容量
            if player.components.oxygen then
                local old_max = player.components.oxygen.max
                player.components.oxygen.max = old_max * 2
                player.components.oxygen:SetPercent(1)
                
                -- 降低氧气消耗
                local old_rate = player.components.oxygen.rate
                player.components.oxygen.rate = old_rate * 0.5
                
                return function()
                    if player:IsValid() and player.components.oxygen then
                        player.components.oxygen.max = old_max
                        player.components.oxygen.rate = old_rate
                    end
                end
            else
                -- 如果玩家没有氧气组件，则添加潜水标签
                player:AddTag("diver")
                
                return function()
                    if player:IsValid() then
                        player:RemoveTag("diver")
                    end
                end
            end
        end
    },
    {
        id = "BUFF_122",
        name = "音乐家",
        description = "你行走时会产生音符效果，吸引友好生物！",
        fn = function(player)
            local last_pos = {x=0, z=0}
            local note_prefabs = {"musical_note"}
            
            -- 获取玩家位置
            local x, y, z = player.Transform:GetWorldPosition()
            last_pos.x = x
            last_pos.z = z
            
            -- 定期检查玩家是否移动
            local task = player:DoPeriodicTask(0.5, function()
                local cur_x, cur_y, cur_z = player.Transform:GetWorldPosition()
                local dist = math.sqrt((cur_x - last_pos.x)^2 + (cur_z - last_pos.z)^2)
                
                -- 如果玩家移动了一定距离
                if dist > 1 then
                    -- 创建音符效果
                    local note = SpawnPrefab(note_prefabs[math.random(#note_prefabs)])
                    if note then
                        note.Transform:SetPosition(cur_x, cur_y + 1, cur_z)
                        
                        -- 让音符上升并消失
                        note:DoTaskInTime(2, function()
                            if note:IsValid() then
                                note:Remove()
                            end
                        end)
                    end
                    
                    -- 吸引附近友好生物
                    local ents = TheSim:FindEntities(cur_x, cur_y, cur_z, 20, nil, {"hostile", "INLIMBO"}, {"animal", "character", "critter", "bird"})
                    for _, ent in ipairs(ents) do
                        if ent.components.follower and math.random() < 0.1 then
                            ent.components.follower:SetLeader(player)
                            break -- 每次只吸引一个生物
                        end
                    end
                    
                    -- 更新上一次位置
                    last_pos.x = cur_x
                    last_pos.z = cur_z
                end
            end)
            
            return function()
                if task then
                    task:Cancel()
                end
                DebugLog(3, "清理音乐家效果")
            end
        end
    },
    {
        id = "BUFF_123",
        name = "贮藏大师",
        description = "你是贮藏大师，食物腐烂速度减慢50%！",
        fn = function(player)
            -- 监听获取物品事件
            local function on_item_get(inst, data)
                if data and data.item and data.item.components.perishable then
                    -- 减缓腐烂速度
                    data.item.components.perishable.perishremainingtime = data.item.components.perishable.perishremainingtime * 1.5
                    data.item:AddTag("preserved_by_buff")
                end
            end
            
            player:ListenForEvent("itemget", on_item_get)
            
            -- 处理背包中已有的物品
            if player.components.inventory then
                local items = player.components.inventory:GetItems()
                for _, item in pairs(items) do
                    if item.components.perishable and not item:HasTag("preserved_by_buff") then
                        item.components.perishable.perishremainingtime = item.components.perishable.perishremainingtime * 1.5
                        item:AddTag("preserved_by_buff")
                    end
                end
                
                -- 处理背包容器中的物品
                local containers = player.components.inventory:GetOpenContainers()
                for container, _ in pairs(containers) do
                    if container.components.container then
                        local container_items = container.components.container:GetItems()
                        for _, item in pairs(container_items) do
                            if item.components.perishable and not item:HasTag("preserved_by_buff") then
                                item.components.perishable.perishremainingtime = item.components.perishable.perishremainingtime * 1.5
                                item:AddTag("preserved_by_buff")
                            end
                        end
                    end
                end
            end
            
            return function()
                player:RemoveEventCallback("itemget", on_item_get)
                
                -- 恢复已被修改的物品
                if player.components.inventory then
                    local items = player.components.inventory:GetItems()
                    for _, item in pairs(items) do
                        if item:HasTag("preserved_by_buff") then
                            item:RemoveTag("preserved_by_buff")
                        end
                    end
                    
                    local containers = player.components.inventory:GetOpenContainers()
                    for container, _ in pairs(containers) do
                        if container.components.container then
                            local container_items = container.components.container:GetItems()
                            for _, item in pairs(container_items) do
                                if item:HasTag("preserved_by_buff") then
                                    item:RemoveTag("preserved_by_buff")
                                end
                            end
                        end
                    end
                end
                
                DebugLog(3, "清理贮藏大师效果")
            end
        end
    },
    {
        id = "BUFF_124",
        name = "幽灵漫步",
        description = "你变得半透明，有几率躲避攻击！",
        fn = function(player)
            -- 让玩家变得半透明
            if player.AnimState then
                player.AnimState:SetMultColour(1, 1, 1, 0.6)
            end
            
            -- 监听受击事件
            local function on_attacked(inst, data)
                if math.random() < 0.3 then -- 30%几率躲避攻击
                    if data and data.attacker and data.damage then
                        -- 取消伤害
                        if player.components.health then
                            player.components.health:DoDelta(data.damage)
                        end
                        
                        -- 显示躲避效果
                        local fx = SpawnPrefab("sleep_puff")
                        if fx then
                            local x, y, z = player.Transform:GetWorldPosition()
                            fx.Transform:SetPosition(x, y, z)
                        end
                        
                        if player.components.talker then
                            player.components.talker:Say("穿越攻击！")
                        end
                        
                        -- 让攻击者困惑
                        if data.attacker.components.combat then
                            data.attacker.components.combat:DropTarget()
                        end
                    end
                end
            end
            
            player:ListenForEvent("attacked", on_attacked)
            
            -- 添加幽灵移动效果
            local ghost_task = player:DoPeriodicTask(0.3, function()
                if player:IsValid() and player.components.locomotor:IsMoving() then
                    local fx = SpawnPrefab("wortox_soul_spawn")
                    if fx then
                        local x, y, z = player.Transform:GetWorldPosition()
                        fx.Transform:SetPosition(x, y, z)
                        fx:DoTaskInTime(1, function()
                            if fx:IsValid() then
                                fx:Remove()
                            end
                        end)
                    end
                end
            end)
            
            return function()
                if player:IsValid() then
                    player.AnimState:SetMultColour(1, 1, 1, 1)
                    player:RemoveEventCallback("attacked", on_attacked)
                    
                    if ghost_task then
                        ghost_task:Cancel()
                    end
                end
                DebugLog(3, "清理幽灵漫步效果")
            end
        end
    },
    {
        id = "BUFF_125",
        name = "季节适应",
        description = "你对当前季节的负面效果有更强的抵抗力！",
        fn = function(player)
            -- 处理季节相关的负面效果
            if TheWorld.state.iswinter then
                -- 冬季：提高保暖
                if player.components.temperature then
                    local old_insulation = player.components.temperature.inherentinsulation or 0
                    player.components.temperature.inherentinsulation = old_insulation + 120
                    
                    return function()
                        if player:IsValid() and player.components.temperature then
                            player.components.temperature.inherentinsulation = old_insulation
                        end
                    end
                end
            elseif TheWorld.state.issummer then
                -- 夏季：提高散热
                if player.components.temperature then
                    local old_insulation = player.components.temperature.inherentsummerinsulation or 0
                    player.components.temperature.inherentsummerinsulation = old_insulation + 120
                    
                    return function()
                        if player:IsValid() and player.components.temperature then
                            player.components.temperature.inherentsummerinsulation = old_insulation
                        end
                    end
                end
            elseif TheWorld.state.isspring then
                -- 春季：雨水抵抗
                player:AddTag("waterproofer")
                
                local old_moisture_rate = player.components.moisture.ratescale
                player.components.moisture.ratescale = old_moisture_rate * 0.5
                
                return function()
                    if player:IsValid() then
                        player:RemoveTag("waterproofer")
                        if player.components.moisture then
                            player.components.moisture.ratescale = old_moisture_rate
                        end
                    end
                end
            elseif TheWorld.state.isautumn then
                -- 秋季：理智提升
                if player.components.sanity then
                    local old_neg_aura_mult = player.components.sanity.neg_aura_mult or 1
                    player.components.sanity.neg_aura_mult = old_neg_aura_mult * 0.5
                    
                    return function()
                        if player:IsValid() and player.components.sanity then
                            player.components.sanity.neg_aura_mult = old_neg_aura_mult
                        end
                    end
                end
            end
            
            -- 默认效果
            return function()
                DebugLog(3, "清理季节适应效果")
            end
        end
    },
    {
        id = "BUFF_126",
        name = "壮硕身躯",
        description = "你的身体变得更加壮硕，可以携带更多物品！",
        fn = function(player)
            if player.components.inventory then
                local old_slots = player.components.inventory.numslots
                player.components.inventory.numslots = old_slots + 4
                
                -- 需要重建背包UI
                if player.HUD and player.HUD.controls and player.HUD.controls.inv then
                    player.HUD.controls.inv:Rebuild()
                end
                
                -- 增加负重能力
                if player.components.locomotor then
                    player.components.locomotor:SetExternalSpeedMultiplier(player, "strength_buff", 1.1)
                end
                
                return function()
                    if player:IsValid() then
                        if player.components.inventory then
                            player.components.inventory.numslots = old_slots
                            if player.HUD and player.HUD.controls and player.HUD.controls.inv then
                                player.HUD.controls.inv:Rebuild()
                            end
                        end
                        
                        if player.components.locomotor then
                            player.components.locomotor:RemoveExternalSpeedMultiplier(player, "strength_buff")
                        end
                    end
                end
            end
        end
    },
    {
        id = "BUFF_127",
        name = "弹性皮肤",
        description = "你的皮肤具有弹性，有几率反弹部分伤害！",
        fn = function(player)
            -- 监听受击事件
            local function on_attacked(inst, data)
                if data and data.attacker and data.damage and math.random() < 0.4 then
                    -- 40%几率反弹30%的伤害
                    local reflected_damage = data.damage * 0.3
                    
                    if data.attacker.components.health and data.attacker ~= player then
                        data.attacker.components.health:DoDelta(-reflected_damage)
                        
                        -- 显示反弹效果
                        local fx = SpawnPrefab("splash_spiderweb")
                        if fx then
                            local x, y, z = data.attacker.Transform:GetWorldPosition()
                            fx.Transform:SetPosition(x, y, z)
                        end
                        
                        if player.components.talker then
                            player.components.talker:Say("反弹伤害！")
                        end
                    end
                end
            end
            
            player:ListenForEvent("attacked", on_attacked)
            
            -- 增加减伤效果
            if player.components.health then
                local old_absorb = player.components.health.absorb or 0
                player.components.health.absorb = old_absorb + 0.1
                
                return function()
                    if player:IsValid() then
                        player:RemoveEventCallback("attacked", on_attacked)
                        
                        if player.components.health then
                            player.components.health.absorb = old_absorb
                        end
                    end
                end
            else
                return function()
                    if player:IsValid() then
                        player:RemoveEventCallback("attacked", on_attacked)
                    end
                end
            end
        end
    },
    {
        id = "BUFF_128",
        name = "宝藏探测器",
        description = "靠近宝藏时你的屏幕会闪烁！",
        fn = function(player)
            local treasures = {
                "blueprint", "redgem", "bluegem", "yellowgem", "greengem", "purplegem", 
                "orangegem", "opalpreciousgem", "moonrocknugget", "moonglass",
                "thulecite", "thulecite_pieces", "nightmare_timepiece"
            }
            
            local last_hint_time = 0
            
            local function is_treasure(item)
                if not item then return false end
                
                for _, treasure in ipairs(treasures) do
                    if item.prefab == treasure then
                        return true
                    end
                end
                
                return false
            end
            
            local task = player:DoPeriodicTask(1, function()
                local x, y, z = player.Transform:GetWorldPosition()
                local items = TheSim:FindEntities(x, y, z, 15, nil, {"INLIMBO"})
                
                local has_treasure = false
                local treasure_distance = 15
                
                for _, item in ipairs(items) do
                    if is_treasure(item) then
                        has_treasure = true
                        
                        -- 计算距离
                        local ix, iy, iz = item.Transform:GetWorldPosition()
                        local dist = math.sqrt((x-ix)^2 + (z-iz)^2)
                        treasure_distance = math.min(treasure_distance, dist)
                    end
                end
                
                -- 如果有宝藏，并且上次提示已经过去至少5秒
                if has_treasure and GetTime() - last_hint_time > 5 then
                    last_hint_time = GetTime()
                    
                    -- 根据距离决定提示频率
                    local hint_delay = math.max(1, treasure_distance / 3)
                    
                    -- 闪烁效果
                    player:DoTaskInTime(0, function()
                        if player.HUD then
                            player.HUD.vignette:SetVignettePriority(6, 3)
                            player.HUD.vignette:SetVignetteIntensity(6, .7)
                            
                            player:DoTaskInTime(0.2, function()
                                player.HUD.vignette:SetVignetteIntensity(6, 0)
                            end)
                        end
                    end)
                    
                    if treasure_distance < 5 and player.components.talker then
                        player.components.talker:Say("非常接近宝藏！")
                    elseif treasure_distance < 10 and player.components.talker then
                        player.components.talker:Say("附近有宝藏...")
                    end
                end
            end)
            
            return function()
                if task then
                    task:Cancel()
                end
                
                if player:IsValid() and player.HUD then
                    player.HUD.vignette:SetVignetteIntensity(6, 0)
                end
                
                DebugLog(3, "清理宝藏探测器效果")
            end
        end
    },
    {
        id = "BUFF_129",
        name = "生命共享",
        description = "你会缓慢吸收附近队友失去的生命值！",
        fn = function(player)
            local function on_health_delta(target, data)
                if target == player or not data or data.amount >= 0 then return end
                
                -- 队友失去生命值
                local x, y, z = player.Transform:GetWorldPosition()
                local tx, ty, tz = target.Transform:GetWorldPosition()
                local dist = math.sqrt((x-tx)^2 + (z-tz)^2)
                
                -- 在范围内的队友
                if dist < 30 and player.components.health and target.components.health then
                    -- 吸收20%的伤害
                    local heal_amount = -data.amount * 0.2
                    player:DoTaskInTime(1, function()
                        if player:IsValid() and player.components.health then
                            player.components.health:DoDelta(heal_amount)
                            
                            -- 显示治疗效果
                            local fx = SpawnPrefab("lavaarena_heal_projectile")
                            if fx then
                                fx.Transform:SetPosition(tx, ty, tz)
                                fx:DoTaskInTime(0.5, function()
                                    if fx:IsValid() then
                                        fx.Transform:SetPosition(x, y, z)
                                    end
                                end)
                            end
                            
                            if player.components.talker and math.random() < 0.3 then
                                player.components.talker:Say("我感受到了" .. target.name .. "的痛苦...")
                            end
                        end
                    end)
                end
            end
            
            -- 监听所有玩家的生命值变化
            for i, v in ipairs(AllPlayers) do
                if v ~= player then
                    v:ListenForEvent("healthdelta", on_health_delta)
                end
            end
            
            return function()
                for i, v in ipairs(AllPlayers) do
                    if v ~= player and v:IsValid() then
                        v:RemoveEventCallback("healthdelta", on_health_delta)
                    end
                end
                DebugLog(3, "清理生命共享效果")
            end
        end
    },
    {
        id = "BUFF_130",
        name = "爆发力量",
        description = "你的攻击有几率造成爆发性伤害！",
        fn = function(player)
            -- 修改攻击伤害计算
            if player.components.combat then
                local old_calc_damage = player.components.combat.CalcDamage
                player.components.combat.CalcDamage = function(self, target, weapon, multiplier)
                    local damage = old_calc_damage(self, target, weapon, multiplier)
                    
                    -- 20%几率造成双倍伤害
                    if math.random() < 0.2 then
                        -- 显示暴击效果
                        local x, y, z = target.Transform:GetWorldPosition()
                        local fx = SpawnPrefab("explode_small")
                        if fx then
                            fx.Transform:SetPosition(x, y, z)
                        end
                        
                        if player.components.talker then
                            player.components.talker:Say("暴击！")
                        end
                        
                        return damage * 2
                    end
                    
                    return damage
                end
                
                return function()
                    if player:IsValid() and player.components.combat then
                        player.components.combat.CalcDamage = old_calc_damage
                    end
                end
            end
        end
    },
} 

-- 新BUFF 131-140 定义
    {
        id = "BUFF_131",
        name = "雷电引导者",
        description = "你可以引导雷电攻击敌人！",
        fn = function(player)
            -- 添加雷电引导能力
            local lightning_target = nil
            
            -- 监听攻击事件
            local function on_attacked_other(inst, data)
                if data and data.target and data.target.components.health and not data.target:HasTag("player") then
                    lightning_target = data.target
                    
                    -- 30%几率触发雷电
                    if math.random() < 0.3 then
                        local tx, ty, tz = lightning_target.Transform:GetWorldPosition()
                        TheWorld:PushEvent("ms_sendlightningstrike", Vector3(tx, ty, tz))
                        
                        if player.components.talker then
                            player.components.talker:Say("雷霆万钧！")
                        end
                    end
                end
            end
            
            player:ListenForEvent("attacked", on_attacked_other)
            
            -- 雷电不会伤害玩家
            player:AddTag("lightningrod")
            
            return function()
                player:RemoveEventCallback("attacked", on_attacked_other)
                player:RemoveTag("lightningrod")
                DebugLog(3, "清理雷电引导者效果")
            end
        end
    },
    {
        id = "BUFF_132",
        name = "植物催生",
        description = "你可以加速植物生长！",
        fn = function(player)
            -- 为玩家添加光环效果
            local aura = SpawnPrefab("moonpulse_fx")
            if aura then
                aura.entity:SetParent(player.entity)
                aura.Transform:SetScale(0.5, 0.5, 0.5)
            end
            
            -- 定期加速周围植物生长
            local task = player:DoPeriodicTask(10, function()
                local x, y, z = player.Transform:GetWorldPosition()
                local plants = TheSim:FindEntities(x, y, z, 8, nil, {"player", "monster"}, {"plant", "crop", "bush", "tree", "sapling"})
                
                local growth_count = 0
                for _, plant in ipairs(plants) do
                    if growth_count >= 3 then break end -- 每次最多催生3个植物
                    
                    local success = false
                    
                    -- 处理作物
                    if plant.components.crop and not plant.components.crop:IsReadyForHarvest() then
                        plant.components.crop:DoGrow(5)
                        success = true
                    -- 处理可采集的植物    
                    elseif plant.components.pickable and not plant.components.pickable.canbepicked then
                        plant.components.pickable.targettime = plant.components.pickable.targettime - 120
                        if plant.components.pickable.targettime <= GetTime() then
                            plant.components.pickable:Regen()
                        end
                        success = true
                    -- 处理树木
                    elseif plant.components.growable and not plant.components.growable:IsFullyGrown() then
                        plant.components.growable:DoGrowth()
                        success = true
                    end
                    
                    if success then
                        growth_count = growth_count + 1
                        -- 生成效果
                        local fx = SpawnPrefab("pollen_fx")
                        if fx then
                            local px, py, pz = plant.Transform:GetWorldPosition()
                            fx.Transform:SetPosition(px, py, pz)
                        end
                    end
                end
                
                if growth_count > 0 and player.components.talker then
                    player.components.talker:Say("我感受到植物的生命在加速流动...")
                end
            end)
            
            return function()
                if aura and aura:IsValid() then
                    aura:Remove()
                end
                
                if task then
                    task:Cancel()
                end
                
                DebugLog(3, "清理植物催生效果")
            end
        end
    },
    {
        id = "BUFF_133",
        name = "危险感知",
        description = "你可以感知危险的靠近！",
        fn = function(player)
            -- 定期检查附近的危险
            local task = player:DoPeriodicTask(5, function()
                local x, y, z = player.Transform:GetWorldPosition()
                local danger_range = 15
                
                -- 检查危险生物
                local monsters = TheSim:FindEntities(x, y, z, danger_range, {"hostile", "_combat"}, {"player", "companion", "wall", "INLIMBO"})
                
                for _, monster in ipairs(monsters) do
                    -- 只检查正在追击的敌人
                    if monster.components.combat and monster.components.combat.target == player then
                        -- 计算距离
                        local mx, my, mz = monster.Transform:GetWorldPosition()
                        local dist = math.sqrt((x-mx)^2 + (z-mz)^2)
                        
                        -- 距离越近警告越强烈
                        if dist < 5 and player.components.talker then
                            player.components.talker:Say("危险就在身边！")
                            
                            -- 屏幕闪红
                            if player.HUD then
                                player.HUD.vignette:SetVignettePriority(5, 3)
                                player.HUD.vignette:SetVignetteIntensity(5, .8)
                                
                                player:DoTaskInTime(0.5, function()
                                    player.HUD.vignette:SetVignetteIntensity(5, 0)
                                end)
                            end
                            
                            -- 只警告一次最近的敌人
                            break
                        elseif dist < 10 and player.components.talker and math.random() < 0.5 then
                            player.components.talker:Say("我感觉有东西在靠近...")
                            break
                        end
                    end
                end
            end)
            
            return function()
                if task then
                    task:Cancel()
                end
                
                if player:IsValid() and player.HUD then
                    player.HUD.vignette:SetVignetteIntensity(5, 0)
                end
                
                DebugLog(3, "清理危险感知效果")
            end
        end
    },
    {
        id = "BUFF_134",
        name = "火焰掌控",
        description = "你可以掌控火焰，并且不会被火伤害！",
        fn = function(player)
            -- 抵抗火焰伤害
            player:AddTag("fireimmune")
            
            -- 增强火焰伤害
            if player.components.combat then
                local old_calc_damage = player.components.combat.CalcDamage
                player.components.combat.CalcDamage = function(self, target, weapon, multiplier)
                    local damage = old_calc_damage(self, target, weapon, multiplier)
                    
                    -- 如果目标是可燃的，增加50%伤害
                    if target.components.burnable or target:HasTag("monster") then
                        return damage * 1.5
                    end
                    
                    return damage
                end
            end
            
            -- 攻击有概率点燃目标
            local function on_attacked_other(inst, data)
                if data and data.target and data.target.components.burnable and math.random() < 0.4 then
                    data.target.components.burnable:Ignite()
                    
                    if player.components.talker then
                        player.components.talker:Say("燃烧吧！")
                    end
                end
            end
            
            player:ListenForEvent("onhitother", on_attacked_other)
            
            -- 火焰环绕效果
            local flames = {}
            for i = 1, 3 do
                local flame = SpawnPrefab("lavaarena_creature_teleport_small_fx")
                if flame then
                    flame.entity:SetParent(player.entity)
                    flame.Transform:SetPosition(0, 0, 0)
                    table.insert(flames, flame)
                end
            end
            
            return function()
                player:RemoveTag("fireimmune")
                
                if player.components.combat then
                    player.components.combat.CalcDamage = old_calc_damage
                end
                
                player:RemoveEventCallback("onhitother", on_attacked_other)
                
                for _, flame in ipairs(flames) do
                    if flame:IsValid() then
                        flame:Remove()
                    end
                end
                
                DebugLog(3, "清理火焰掌控效果")
            end
        end
    },
    {
        id = "BUFF_135",
        name = "冰霜掌控",
        description = "你可以掌控冰霜，并且不会被冻伤！",
        fn = function(player)
            -- 抵抗冻伤
            player:AddTag("frostimmune")
            
            -- 冰冻光环
            local task = player:DoPeriodicTask(3, function()
                local x, y, z = player.Transform:GetWorldPosition()
                local enemies = TheSim:FindEntities(x, y, z, 5, {"_combat"}, {"player", "companion", "wall", "INLIMBO"})
                
                for _, enemy in ipairs(enemies) do
                    if enemy.components.freezable then
                        enemy.components.freezable:AddColdness(1)
                        
                        -- 生成冻结效果
                        local fx = SpawnPrefab("ice_splash")
                        if fx then
                            local ex, ey, ez = enemy.Transform:GetWorldPosition()
                            fx.Transform:SetPosition(ex, ey, ez)
                        end
                    end
                    
                    -- 减缓敌人速度
                    if enemy.components.locomotor then
                        enemy.components.locomotor:SetExternalSpeedMultiplier(enemy, "frost_aura", 0.8)
                        
                        -- 3秒后恢复
                        enemy:DoTaskInTime(3, function()
                            if enemy:IsValid() and enemy.components.locomotor then
                                enemy.components.locomotor:RemoveExternalSpeedMultiplier(enemy, "frost_aura")
                            end
                        end)
                    end
                end
            end)
            
            -- 冰霜环绕效果
            local fx = SpawnPrefab("icefishing_ice_fx")
            if fx then
                fx.entity:SetParent(player.entity)
                fx.Transform:SetPosition(0, 0, 0)
                fx.Transform:SetScale(0.5, 0.5, 0.5)
            end
            
            return function()
                player:RemoveTag("frostimmune")
                
                if task then
                    task:Cancel()
                end
                
                if fx and fx:IsValid() then
                    fx:Remove()
                end
                
                DebugLog(3, "清理冰霜掌控效果")
            end
        end
    },
    {
        id = "BUFF_136",
        name = "幸运星",
        description = "你的运气增加，有几率获得额外物品！",
        fn = function(player)
            -- 监听采集事件
            local old_pick = ACTIONS.PICK.fn
            ACTIONS.PICK.fn = function(act)
                local result = old_pick(act)
                
                if act.doer == player and math.random() < 0.15 then -- 15%几率额外收获
                    if act.target and act.target.components.pickable and act.target.components.pickable.product then
                        local product = act.target.components.pickable.product
                        local bonus = SpawnPrefab(product)
                        
                        if bonus and player.components.inventory then
                            player.components.inventory:GiveItem(bonus)
                            
                            if player.components.talker then
                                player.components.talker:Say("太幸运了，多收获了一个！")
                            end
                            
                            -- 生成幸运效果
                            local fx = SpawnPrefab("golden_item_fx")
                            if fx then
                                fx.entity:SetParent(player.entity)
                            end
                        end
                    end
                end
                
                return result
            end
            
            -- 监听采矿事件
            local old_mine = ACTIONS.MINE.fn
            ACTIONS.MINE.fn = function(act)
                local result = old_mine(act)
                
                if act.doer == player and act.target and act.target:HasTag("boulder") and math.random() < 0.15 then
                    local bonus_items = {"rocks", "nitre", "flint", "goldnugget"}
                    
                    -- 随机选择一种资源
                    local bonus_item = bonus_items[math.random(#bonus_items)]
                    local bonus = SpawnPrefab(bonus_item)
                    
                    if bonus and player.components.inventory then
                        player.components.inventory:GiveItem(bonus)
                        
                        if player.components.talker then
                            player.components.talker:Say("哇，意外收获！")
                        end
                    end
                end
                
                return result
            end
            
            -- 更好的钓鱼运气
            local old_fish = ACTIONS.FISH.fn
            ACTIONS.FISH.fn = function(act)
                if act.doer == player and math.random() < 0.2 then
                    -- 提高稀有鱼的几率
                    -- 实现依赖于游戏内部钓鱼机制
                end
                
                return old_fish(act)
            end
            
            return function()
                ACTIONS.PICK.fn = old_pick
                ACTIONS.MINE.fn = old_mine
                ACTIONS.FISH.fn = old_fish
                
                DebugLog(3, "清理幸运星效果")
            end
        end
    },
    {
        id = "BUFF_137",
        name = "夜视能力",
        description = "你获得了夜视能力，在夜晚也能看清周围！",
        fn = function(player)
            -- 添加夜视效果
            player:AddTag("nightvision")
            
            -- 减轻黑暗引起的理智损失
            if player.components.sanity then
                local old_night_drain = player.components.sanity.night_drain_mult or 1
                player.components.sanity.night_drain_mult = 0.1
            end
            
            -- 让玩家发光
            local light = SpawnPrefab("minerhatlight")
            if light then
                light.entity:SetParent(player.entity)
                light.Transform:SetPosition(0, 0, 0)
                
                -- 调整光照范围和强度
                if light.Light then
                    light.Light:SetRadius(6)
                    light.Light:SetFalloff(0.6)
                    light.Light:SetIntensity(0.6)
                    light.Light:SetColour(0.8, 0.8, 1)
                end
            end
            
            return function()
                player:RemoveTag("nightvision")
                
                if player.components.sanity then
                    player.components.sanity.night_drain_mult = old_night_drain
                end
                
                if light and light:IsValid() then
                    light:Remove()
                end
                
                DebugLog(3, "清理夜视能力效果")
            end
        end
    },
    {
        id = "BUFF_138",
        name = "暗影朋友",
        description = "暗影生物将不再敌视你，甚至可能成为你的朋友！",
        fn = function(player)
            -- 让暗影生物不再敌视玩家
            player:AddTag("shadowfriend")
            
            -- 暗影生物有几率跟随玩家
            local function on_attacked(inst, data)
                if data and data.attacker and data.attacker:HasTag("shadow") and math.random() < 0.3 then
                    if data.attacker.components.combat then
                        data.attacker.components.combat:SetTarget(nil)
                    end
                    
                    if data.attacker.components.follower then
                        data.attacker.components.follower:SetLeader(player)
                        
                        if player.components.talker then
                            player.components.talker:Say("这个暗影生物似乎对我有好感...")
                        end
                    end
                end
            end
            
            player:ListenForEvent("attacked", on_attacked)
            
            -- 理智值低时有几率生成友好暗影生物
            local shadow_task = player:DoPeriodicTask(30, function()
                if player.components.sanity and player.components.sanity:GetPercent() < 0.3 and math.random() < 0.2 then
                    local shadow_types = {"crawlinghorror", "terrorbeak"}
                    local shadow_type = shadow_types[math.random(#shadow_types)]
                    
                    local shadow = SpawnPrefab(shadow_type)
                    if shadow then
                        local x, y, z = player.Transform:GetWorldPosition()
                        local angle = math.random() * 2 * math.pi
                        local radius = 3
                        
                        shadow.Transform:SetPosition(x + radius * math.cos(angle), 0, z + radius * math.sin(angle))
                        
                        -- 让暗影生物友好
                        shadow:AddTag("companion")
                        shadow:RemoveTag("hostile")
                        
                        if shadow.components.combat then
                            shadow.components.combat:SetTarget(nil)
                        end
                        
                        if shadow.components.follower then
                            shadow.components.follower:SetLeader(player)
                        end
                        
                        -- 一段时间后消失
                        shadow:DoTaskInTime(120, function()
                            if shadow:IsValid() then
                                shadow:Remove()
                            end
                        end)
                        
                        if player.components.talker then
                            player.components.talker:Say("黑暗中的朋友来了...")
                        end
                    end
                end
            end)
            
            return function()
                player:RemoveTag("shadowfriend")
                player:RemoveEventCallback("attacked", on_attacked)
                
                if shadow_task then
                    shadow_task:Cancel()
                end
                
                DebugLog(3, "清理暗影朋友效果")
            end
        end
    },
    {
        id = "BUFF_139",
        name = "魔法工匠",
        description = "你制作的魔法物品更强大，耐久更长！",
        fn = function(player)
            -- 监听制作事件
            local function on_item_crafted(inst, data)
                if data and data.item then
                    local item = data.item
                    
                    -- 检查是否是魔法物品
                    local is_magical = false
                    if item:HasTag("sharp") or item:HasTag("weapon") or item:HasTag("tool") then
                        -- 魔法武器和工具的标签检查
                        if item.prefab:find("nightsword") or 
                           item.prefab:find("fire") or 
                           item.prefab:find("ice") or 
                           item.prefab:find("telestaff") or
                           item.prefab:find("orangestaff") or
                           item.prefab:find("yellowstaff") or
                           item.prefab:find("greenstaff") or
                           item.prefab:find("opalstaff") or
                           item.prefab:find("ruins") then
                            is_magical = true
                        end
                    end
                    
                    if is_magical then
                        -- 增加耐久度
                        if item.components.finiteuses then
                            item.components.finiteuses:SetMaxUses(item.components.finiteuses.total * 1.5)
                            item.components.finiteuses:SetUses(item.components.finiteuses.total * 1.5)
                        end
                        
                        -- 增加伤害
                        if item.components.weapon then
                            item.components.weapon.damage = item.components.weapon.damage * 1.2
                        end
                        
                        -- 增加效率
                        if item.components.tool then
                            for action, eff in pairs(item.components.tool.effectiveness) do
                                item.components.tool.effectiveness[action] = eff * 1.2
                            end
                        end
                        
                        -- 添加魔法效果
                        local fx = SpawnPrefab("lavaarena_player_revive_from_corpse_fx")
                        if fx then
                            fx.entity:SetParent(item.entity)
                        end
                        
                        if player.components.talker then
                            player.components.talker:Say("我在这件物品中注入了强大的魔力！")
                        end
                    end
                end
            end
            
            player:ListenForEvent("itemcrafted", on_item_crafted)
            
            return function()
                player:RemoveEventCallback("itemcrafted", on_item_crafted)
                DebugLog(3, "清理魔法工匠效果")
            end
        end
    },
    {
        id = "BUFF_140",
        name = "灵魂链接",
        description = "你可以看到并与灵魂互动！",
        fn = function(player)
            -- 增加灵魂感知
            player:AddTag("ghostvision")
            
            -- 让玩家发光
            player.Light:Enable(true)
            player.Light:SetRadius(2)
            player.Light:SetFalloff(0.7)
            player.Light:SetIntensity(0.6)
            player.Light:SetColour(0.8, 0.5, 1.0)
            
            -- 有几率在死亡生物处生成灵魂
            local function on_entity_death(world, data)
                if data and data.inst and not data.inst:HasTag("player") and math.random() < 0.2 then
                    local x, y, z = data.inst.Transform:GetWorldPosition()
                    
                    -- 创建灵魂效果
                    local soul = SpawnPrefab("wortox_soul")
                    if soul then
                        soul.Transform:SetPosition(x, y + 1, z)
                        
                        -- 让灵魂飘向玩家
                        soul:DoTaskInTime(1, function()
                            if soul:IsValid() and player:IsValid() then
                                local px, py, pz = player.Transform:GetWorldPosition()
                                soul.Transform:SetPosition(px, py, pz)
                                
                                -- 给予玩家治疗
                                if player.components.health then
                                    player.components.health:DoDelta(5)
                                    
                                    if player.components.talker then
                                        player.components.talker:Say("我能感受到这个灵魂的力量...")
                                    end
                                end
                                
                                soul:DoTaskInTime(0.5, function()
                                    if soul:IsValid() then
                                        soul:Remove()
                                    end
                                end)
                            end
                        end)
                    end
                end
            end
            
            TheWorld:ListenForEvent("entity_death", on_entity_death)
            
            -- 允许玩家看到鬼魂
            local on_ghost_appeared = function(world, ghost)
                if ghost and ghost:HasTag("playerghost") then
                    ghost:DoTaskInTime(1, function()
                        if ghost:IsValid() and player:IsValid() and player.components.talker then
                            player.components.talker:Say("我能看到你的灵魂...")
                        end
                    end)
                end
            end
            
            TheWorld:ListenForEvent("ms_playerjoined", on_ghost_appeared)
            
            return function()
                player:RemoveTag("ghostvision")
                player.Light:Enable(false)
                
                TheWorld:RemoveEventCallback("entity_death", on_entity_death)
                TheWorld:RemoveEventCallback("ms_playerjoined", on_ghost_appeared)
                
                DebugLog(3, "清理灵魂链接效果")
            end
        end
    },
} 