-- ==========================================
-- PROXY BJ - GROWLAUNCHER EDITION (UPDATED)
-- ==========================================

local TAX_PERCENT = 5

local PATH_TIMEOUT = 5000
local PATH_CHECK_INTERVAL = 100
local DROP_DELAY = 500
local DROP_VERIFY_TIMEOUT = 4000
local MAX_BREAK_RETRIES = 5  -- Batas maksimum percobaan pecah BGL/DL (Anti Infinite Loop)

local rawSendPacket = SendPacket or sendPacket
local rawSleep = Sleep or sleep
local rawFindPath = FindPath or findPath
local rawGetLocal = getLocal or GetLocal
local rawGetObjectList = getObjectList or GetObjectList
local rawGetInventory = getInventory or GetInventory
local rawLogToConsole = LogToConsole or logToConsole

local P1_lock = nil
local P2_lock = nil

local G = {}
for i = 1, 6 do G[i] = nil end

local ID_WL = 242
local ID_DL = 1796
local ID_BGL = 7188
local ID_GEM = 112

local stored_payout = 0
local last_winner = nil

local processingTake = false
local processingScan = false
local processingWinner = false

-- ==========================================
-- UTILS & HELPER FUNCTIONS
-- ==========================================

local function log(text)
    if type(rawLogToConsole) == "function" then
        rawLogToConsole("`5[PROXY]`0 " .. tostring(text))
    end
end

local function sleepMs(ms)
    if type(rawSleep) == "function" then
        rawSleep(math.max(0, tonumber(ms) or 0))
    end
end

local function sendPacket(type_pkt, packet)
    if type(rawSendPacket) ~= "function" then
        log("`4ERROR:`0 SendPacket API tidak ditemukan.")
        return false
    end
    local ok, result = pcall(rawSendPacket, type_pkt, packet)
    if not ok then
        log("`4ERROR SendPacket:`0 " .. tostring(result))
        return false
    end
    return true
end

local function pathFind(x, y)
    if type(rawFindPath) ~= "function" then
        log("`4ERROR:`0 FindPath API tidak ditemukan.")
        return false
    end
    local ok, result = pcall(rawFindPath, x, y)
    if not ok then
        log("`4ERROR FindPath:`0 " .. tostring(result))
        return false
    end
    return true
end

local function execThread(fn)
    if type(runThread) == "function" then runThread(fn) return end
    if type(RunThread) == "function" then RunThread(fn) return end
    if type(CreateThread) == "function" then CreateThread(fn) return end
    local co = coroutine.create(fn)
    coroutine.resume(co)
end

-- ==========================================
-- PLAYER & MOVEMENT
-- ==========================================

local function getPlayerTile()
    if type(rawGetLocal) ~= "function" then return nil, nil end
    local ok, p = pcall(rawGetLocal)
    if not ok or not p then return nil, nil end
    local px = tonumber(p.posX)
    local py = tonumber(p.posY)
    if not px or not py then return nil, nil end
    return math.floor(px / 32), math.floor(py / 32)
end

local function isAtTile(x, y)
    local px, py = getPlayerTile()
    return px ~= nil and py ~= nil and px == x and py == y
end

local function moveToAndWait(x, y, timeout)
    x = tonumber(x)
    y = tonumber(y)
    timeout = tonumber(timeout) or PATH_TIMEOUT

    if not x or not y then return false end
    if isAtTile(x, y) then return true end

    if not pathFind(x, y) then
        log("`4PATHFIND FAILED:`0 " .. x .. "," .. y)
        return false
    end

    local elapsed = 0
    local lastX, lastY = getPlayerTile()

    while elapsed < timeout do
        if isAtTile(x, y) then return true end

        sleepMs(PATH_CHECK_INTERVAL)
        elapsed = elapsed + PATH_CHECK_INTERVAL

        if elapsed % 1000 == 0 then
            local currX, currY = getPlayerTile()
            if currX == lastX and currY == lastY then
                pathFind(x, y)
            end
            lastX, lastY = currX, currY
        end
    end

    if isAtTile(x, y) then return true end
    log("`4PATH TIMEOUT:`0 " .. x .. "," .. y)
    return false
end

-- ==========================================
-- OBJECTS SCANNING
-- ==========================================

local function getObjects()
    if type(rawGetObjectList) ~= "function" then return {} end
    local ok, objects = pcall(rawGetObjectList)
    if not ok or type(objects) ~= "table" then return {} end
    return objects
end

local function getObjectTile(obj)
    if not obj or not obj.pos then return nil, nil end
    local x = tonumber(obj.pos.x)
    local y = tonumber(obj.pos.y)
    if not x or not y then return nil, nil end
    return math.floor(x / 32), math.floor(y / 32)
end

local function tileKey(x, y)
    return tostring(x) .. ":" .. tostring(y)
end

local function buildObjectMap()
    local objects = getObjects()
    local lockMap = {}
    local gemMap = {}

    for _, obj in pairs(objects) do
        local itemID = tonumber(obj.itemid) or 0
        local amount = tonumber(obj.amount) or 1
        local x, y = getObjectTile(obj)

        if x and y then
            local key = tileKey(x, y)
            if itemID == ID_WL then
                lockMap[key] = (lockMap[key] or 0) + amount
            elseif itemID == ID_DL then
                lockMap[key] = (lockMap[key] or 0) + amount * 100
            elseif itemID == ID_BGL then
                lockMap[key] = (lockMap[key] or 0) + amount * 10000
            elseif itemID == ID_GEM then
                gemMap[key] = (gemMap[key] or 0) + amount
            end
        end
    end

    return lockMap, gemMap
end

local function scanLockAtTileFromMap(map, x, y)
    if not x or not y then return 0 end
    return map[tileKey(x, y)] or 0
end

local function scanGemsAtTileFromMap(map, x, y)
    if not x or not y then return 0 end
    return map[tileKey(x, y)] or 0
end

local function scanGemsForGroupFromMap(map, firstIndex, lastIndex)
    local total = 0
    for i = firstIndex, lastIndex do
        local tile = G[i]
        if tile then
            total = total + scanGemsAtTileFromMap(map, tile.x, tile.y)
        end
    end
    return total
end

-- ==========================================
-- INVENTORY MANAGEMENT
-- ==========================================

local function getInventoryAmount(itemID)
    if type(rawGetInventory) ~= "function" then return 0 end
    local ok, inv = pcall(rawGetInventory)
    if not ok or type(inv) ~= "table" then return 0 end

    for _, item in pairs(inv) do
        local id = tonumber(item.id or item.itemID)
        if id == tonumber(itemID) then
            return tonumber(item.amount or item.count) or 0
        end
    end
    return 0
end

local function getTotalWLInInventory()
    local bgl = getInventoryAmount(ID_BGL)
    local dl = getInventoryAmount(ID_DL)
    local wl = getInventoryAmount(ID_WL)
    return (bgl * 10000) + (dl * 100) + wl
end

-- ==========================================
-- DROP & AUTO BREAK WITH MAX RETRY GUARD
-- ==========================================

local function dropSingleItem(itemID, count)
    count = math.floor(tonumber(count) or 0)
    if count <= 0 then return true end

    local before = getInventoryAmount(itemID)
    if before < count then
        log("`4DROP GAGAL:`0 Jumlah item di inventori tidak cukup (" .. before .. "/" .. count .. ")")
        return false
    end

    sleepMs(200)

    sendPacket(2, "action|drop\nitemID|" .. itemID)
    sleepMs(250)

    local packet = "action|dialog_return\n" ..
                   "dialog_name|drop_item\n" ..
                   "itemID|" .. itemID .. "|\n" ..
                   "count|" .. count .. "\n"

    if not sendPacket(2, packet) then return false end

    local elapsed = 0
    while elapsed < DROP_VERIFY_TIMEOUT do
        sleepMs(150)
        elapsed = elapsed + 150

        local after = getInventoryAmount(itemID)
        if after <= (before - count) then
            log("`2DROP SUKSES:`0 ID " .. itemID .. " x" .. count)
            return true
        end
    end

    local finalCheck = getInventoryAmount(itemID)
    if finalCheck <= (before - count) then
        log("`2DROP SUKSES (LATE SYNC):`0 ID " .. itemID .. " x" .. count)
        return true
    end

    log("`4DROP GAGAL (TIMEOUT):`0 Server tidak memproses drop ID " .. itemID)
    return false
end

local function smartDropWL(totalWL)
    totalWL = math.floor(tonumber(totalWL) or 0)
    if totalWL <= 0 then
        log("`4Payout kosong.`0")
        return false
    end

    if getTotalWLInInventory() < totalWL then
        log("`4PAYOUT GAGAL:`0 Total saldo kurang! (" .. getTotalWLInInventory() .. "/" .. totalWL .. " WL)")
        return false
    end

    local remainingWL = totalWL

    local dropBGL = math.min(getInventoryAmount(ID_BGL), math.floor(remainingWL / 10000))
    remainingWL = remainingWL - (dropBGL * 10000)

    -- Auto Break BGL ke DL dengan Max Retry
    local neededDL = math.floor(remainingWL / 100)
    local retries = 0
    while getInventoryAmount(ID_DL) < neededDL and getInventoryAmount(ID_BGL) > 0 do
        if retries >= MAX_BREAK_RETRIES then
            log("`4AUTO BREAK GAGAL:`0 Mencapai batas maksimum percobaan pemecahan BGL.")
            break
        end
        log("`6AUTO BREAK:`0 Memecah 1 BGL ke DL... (" .. (retries + 1) .. "/" .. MAX_BREAK_RETRIES .. ")")
        sendPacket(2, "action|item_use\nitemID|" .. ID_BGL .. "|\n")
        sleepMs(600)
        retries = retries + 1
    end

    local dropDL = math.min(getInventoryAmount(ID_DL), math.floor(remainingWL / 100))
    remainingWL = remainingWL - (dropDL * 100)

    -- Auto Break DL ke WL dengan Max Retry
    retries = 0
    while getInventoryAmount(ID_WL) < remainingWL do
        if retries >= MAX_BREAK_RETRIES then
            log("`4AUTO BREAK GAGAL:`0 Mencapai batas maksimum percobaan pemecahan DL/BGL.")
            break
        end
        if getInventoryAmount(ID_DL) > 0 then
            log("`6AUTO BREAK:`0 Memecah 1 DL ke WL... (" .. (retries + 1) .. "/" .. MAX_BREAK_RETRIES .. ")")
            sendPacket(2, "action|item_use\nitemID|" .. ID_DL .. "|\n")
            sleepMs(600)
        elseif getInventoryAmount(ID_BGL) > 0 then
            log("`6AUTO BREAK:`0 Memecah 1 BGL ke DL... (" .. (retries + 1) .. "/" .. MAX_BREAK_RETRIES .. ")")
            sendPacket(2, "action|item_use\nitemID|" .. ID_BGL .. "|\n")
            sleepMs(600)
        else
            break
        end
        retries = retries + 1
    end

    local dropWL = remainingWL

    if getInventoryAmount(ID_WL) < dropWL then
        log("`4PAYOUT GAGAL:`0 Pecahan WL tidak mencukupi.")
        return false
    end

    log("`6PAYOUT:`0 " .. dropBGL .. " BGL | " .. dropDL .. " DL | " .. dropWL .. " WL")

    if dropBGL > 0 and not dropSingleItem(ID_BGL, dropBGL) then return false end
    if dropDL > 0 and not dropSingleItem(ID_DL, dropDL) then return false end
    if dropWL > 0 and not dropSingleItem(ID_WL, dropWL) then return false end

    log("`2PAYOUT BERHASIL:`0 " .. totalWL .. " WL")
    return true
end

-- ==========================================
-- MAIN LOGICS: TAKE, SCAN, WINNER
-- ==========================================

local function processTake()
    if processingTake then
        log("`eTAKE:`0 Masih diproses.")
        return
    end

    processingTake = true

    if not P1_lock or not P2_lock then
        log("`4Gagal Take:`0 P1/P2 belum diset.")
        processingTake = false
        return
    end

    -- Auto-Collect Safety Guard: Cek apakah inventori siap menerima taruhan baru
    local lockMap = buildObjectMap()
    local betP1 = scanLockAtTileFromMap(lockMap, P1_lock.x, P1_lock.y)
    local betP2 = scanLockAtTileFromMap(lockMap, P2_lock.x, P2_lock.y)

    log("`2BET TERDETEKSI:`0 P1 = " .. betP1 .. " WL | P2 = " .. betP2 .. " WL")

    if betP1 <= 0 or betP2 <= 0 then
        log("`4TAKE GAGAL:`0 Salah satu lock di tanah kosong.")
        processingTake = false
        return
    end

    if betP1 ~= betP2 then
        log("`4LOCK TIDAK SETARA!`0 P1 " .. betP1 .. " WL vs P2 " .. betP2 .. " WL")
        processingTake = false
        return
    end

    local startX, startY = getPlayerTile()
    local initialInvWL = getTotalWLInInventory()
    local expectedPot = betP1 + betP2

    -- Ambil Lock P1
    if not moveToAndWait(P1_lock.x, P1_lock.y) then
        log("`4TAKE GAGAL:`0 Tidak sampai P1.")
        processingTake = false
        return
    end
    sleepMs(400)

    -- Ambil Lock P2
    if not moveToAndWait(P2_lock.x, P2_lock.y) then
        log("`4TAKE GAGAL:`0 Tidak sampai P2.")
        processingTake = false
        return
    end
    sleepMs(400)

    -- Kembali ke koordinat asal
    if startX and startY then
        moveToAndWait(startX, startY)
    end

    local currentInvWL = getTotalWLInInventory()
    local gainedWL = currentInvWL - initialInvWL

    if gainedWL <= 0 then
        log("`4TAKE ABORT:`0 Lock tidak terambil ke inventori (Cek ruang inventori).")
        processingTake = false
        return
    end

    local actualPot = (gainedWL >= expectedPot) and expectedPot or gainedWL
    local taxAmount = math.floor(actualPot * TAX_PERCENT / 100)
    stored_payout = actualPot - taxAmount

    log("`2TAKE BERHASIL:`0 Pot " .. actualPot .. " WL | Tax " .. taxAmount .. " WL | Payout " .. stored_payout .. " WL")
    processingTake = false
end

local function processScan()
    if processingScan then
        log("`eSCAN:`0 Masih diproses.")
        return
    end

    processingScan = true

    local _, gemMap = buildObjectMap()
    local gemsP1 = scanGemsForGroupFromMap(gemMap, 1, 3)
    local gemsP2 = scanGemsForGroupFromMap(gemMap, 4, 6)

    local p1_bust = gemsP1 > 21
    local p2_bust = gemsP2 > 21
    local winnerStr

    if p1_bust and p2_bust then
        last_winner = "TIE"
        winnerStr = "`eDOUBLE BUST"
    elseif p1_bust then
        last_winner = "P2"
        winnerStr = "`2P2 WIN"
    elseif p2_bust then
        last_winner = "P1"
        winnerStr = "`2P1 WIN"
    elseif gemsP1 > gemsP2 then
        last_winner = "P1"
        winnerStr = "`2P1 WIN"
    elseif gemsP2 > gemsP1 then
        last_winner = "P2"
        winnerStr = "`2P2 WIN"
    else
        last_winner = "TIE"
        winnerStr = "`eTIE"
    end

    local msg = "`2P1: `w" .. gemsP1 .. " Gems `0vs `2P2: `w" .. gemsP2 .. " Gems `6=> " .. winnerStr

    if type(growtopia) == "table" and type(growtopia.sendChat) == "function" then
        pcall(growtopia.sendChat, msg)
    else
        sendPacket(2, "action|input\ntext|" .. msg)
    end

    log(msg)
    processingScan = false
end

local function processWinner()
    if processingWinner then
        log("`eWINNER:`0 Masih diproses.")
        return
    end

    processingWinner = true

    if stored_payout <= 0 then
        log("`4PAYOUT GAGAL:`0 Tidak ada payout tersimpan.")
        processingWinner = false
        return
    end

    if last_winner ~= "P1" and last_winner ~= "P2" then
        if last_winner == "TIE" then
            log("`eTIE:`0 Payout ditahan (Seri).")
        else
            log("`4WINNER:`0 Belum ada pemenang terdeteksi.")
        end
        processingWinner = false
        return
    end

    local target = (last_winner == "P1") and P1_lock or P2_lock
    if not target then
        log("`4PAYOUT GAGAL:`0 Lock pemenang belum diset.")
        processingWinner = false
        return
    end

    -- Simpan koordinat awal pemain sebelum proses /w dimulai
    local startX, startY = getPlayerTile()

    log("`2WINNER " .. last_winner .. ".`0 Menuju tempat payout lock...")

    -- 1. Payout Drop WL di Lock Pemenang
    if not moveToAndWait(target.x, target.y) then
        log("`4PAYOUT GAGAL:`0 Tidak bisa mencapai posisi winner.")
        processingWinner = false
        return
    end

    sleepMs(400)
    local success = smartDropWL(stored_payout)

    if success then
        stored_payout = 0
        log("`2PAYOUT WL SELESAI.`0 Menuju tile G untuk mengambil gems pemenang...")

        -- 2. Sapu/Ambil Gems di Tile G Pemenang
        local startG = (last_winner == "P1") and 1 or 4
        local endG = (last_winner == "P1") and 3 or 6

        for i = startG, endG do
            if G[i] then
                log("`6MENGAMBIL GEMS G" .. i .. ":`0 " .. G[i].x .. "," .. G[i].y)
                moveToAndWait(G[i].x, G[i].y)
                sleepMs(300) -- Jeda sebentar untuk menyerap gems di tanah
            end
        end

        last_winner = nil
        log("`2PEMBERSIHAN GEMS SELESAI.`0 Kembali ke tile awal...")
    else
        log("`4PAYOUT BELUM SELESAI.`0 Gunakan /w untuk mencoba ulang.")
    end

    -- 3. Kembali ke Tile Awal Saat Perintah /w Dipanggil
    if startX and startY then
        moveToAndWait(startX, startY)
    end

    processingWinner = false
end

-- ==========================================
-- COMMAND HANDLER
-- ==========================================

local function showHelp()
    log("`6========== PROXY ==========`0")
    log("`w/p1`0 = Set P1 Lock")
    log("`w/p2`0 = Set P2 Lock")
    log("`w/g1-g6`0 = Set Posisi Gem 1 sampai 6")
    log("`w/take`0 = Take Bet")
    log("`w/s`0 = Scan Winner")
    log("`w/w`0 = Payout + Sapu Gems + Balik Tile Awal")
    log("`w/reset`0 = Reset Proxy")
    log("`6============================`0")
end

local function handlePacketHook(a, b)
    local str = (type(a) == "string" and a) or (type(b) == "string" and b) or ""
    if str == "" then return false end

    local chatText = str:match("action|input\ntext|([^\n]+)") or
                     str:match("|text|([^\n]+)") or
                     str:match("text|([^\n]+)")

    if not chatText then return false end
    chatText = chatText:match("^%s*(.-)%s*$"):lower()

    if chatText == "/proxy" then showHelp() return true end

    if chatText == "/p1" then
        local x, y = getPlayerTile()
        if not x or not y then log("`4P1 gagal:`0 Posisi tidak tersedia.") return true end
        P1_lock = { x = x, y = y }
        log("`2P1 LOCK SET:`0 " .. x .. "," .. y)
        return true
    end

    if chatText == "/p2" then
        local x, y = getPlayerTile()
        if not x or not y then log("`4P2 gagal:`0 Posisi tidak tersedia.") return true end
        P2_lock = { x = x, y = y }
        log("`2P2 LOCK SET:`0 " .. x .. "," .. y)
        return true
    end

    if chatText == "/take" then execThread(processTake) return true end
    if chatText == "/s" then execThread(processScan) return true end
    if chatText == "/w" then execThread(processWinner) return true end

    if chatText == "/reset" then
        stored_payout = 0
        last_winner = nil
        processingTake, processingScan, processingWinner = false, false, false
        P1_lock, P2_lock = nil, nil
        for i = 1, 6 do
            G[i] = nil
        end
        log("`2PROXY RESET.`0")
        return true
    end

    for i = 1, 6 do
        if chatText == "/g" .. i then
            local x, y = getPlayerTile()
            if not x or not y then log("`4G" .. i .. " gagal:`0 Posisi tidak tersedia.") return true end
            G[i] = { x = x, y = y }
            local group = (i <= 3) and "P1" or "P2"
            log("`2G" .. i .. " (" .. group .. "):`0 " .. x .. "," .. y)
            return true
        end
    end

    return false
end

local function registerHook()
    local hookFn = (type(addHook) == "function" and addHook) or (type(AddHook) == "function" and AddHook) or nil
    if hookFn then
        pcall(hookFn, "OnSendPacket", "GrowProxyHook", handlePacketHook)
        pcall(hookFn, handlePacketHook, "OnSendPacket")
    else
        log("`4WARNING:`0 API Hook tidak terdeteksi.")
    end
end

registerHook()
log("`2PROXY LOADED SUCCESSFULLY.`0 Tax " .. TAX_PERCENT .. "%")
