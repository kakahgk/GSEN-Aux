--==================== 服务与变量 ====================
local Players          = game:GetService("Players")
local RunService       = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TweenService     = game:GetService("TweenService")
local Workspace        = game:GetService("Workspace")

local LocalPlayer = Players.LocalPlayer
local Camera      = Workspace.CurrentCamera
local playerGui   = LocalPlayer:WaitForChild("PlayerGui")

-- 默认值(关闭时恢复用)
local DEFAULT_WALKSPEED = 16

-- 全局开关状态
local State = {
	-- 透视
	espEnabled       = false,
	boxEnabled       = false,
	antennaEnabled   = false,
	nameEnabled      = false,
	nickEnabled      = false,
	skeletonEnabled  = false,
	-- 移动
	flyEnabled     = false,
	noclipEnabled  = false,
	speedEnabled   = false,
	walkSpeed      = DEFAULT_WALKSPEED,
	flySpeed       = 60,
	flingEnabled   = false,
	flingTarget    = nil,
	-- 旋转
	spinEnabled    = false,
	spinSpeed      = 5,
	-- 无限跳
	infJumpEnabled = false,
	-- 隐身
	invisibleEnabled = false,
	-- 本地玩家
	godHealthEnabled = false,
	customHealth     = 100,
	-- 秒交互
	promptInstantEnabled = false,
	-- 聊天翻译
	chatTranslateEnabled = false,
	translateTargetLang = "中文",
	textTranslateTargetLang = "English",
	-- 环绕
	orbitEnabled   = false,
	orbitTarget    = nil,
	orbitRadius    = 8,
	orbitSpeed     = 5,
	-- 循环传送
	loopTpEnabled    = false,
	loopTpTarget     = nil,
	loopTpAllEnabled = false,
	loopTpInterval   = 0.01,
	-- 自瞄
	aimEnabled  = false,
	aimMode     = "FOV",   -- FOV / 180 / 360
	aimFov      = 120,
	aimSmooth   = 0.30,
	aimPart     = "Body",
	aimDistance = 500,
	aimHeadLock = 100,   -- 概率锁头 0-100%, 仅 aimPart=="Head" 时生效
	wallCheck   = true,
	-- 展开动画
	animMode    = "碎片",  -- 碎片 / 平滑 (会被 loadAnimMode 覆盖)
	teamCheck   = true,
	aliveCheck  = true,
}

-- 运行时资源(关闭时统一清理)
local Runtime = {
	espObjects   = {},   -- [player] = {highlight, boxFrame, beam, nameGui}
	connections  = {},   -- 所有 event connection
	instances    = {},   -- 需销毁的实例
	originalCollide = {},-- noclip 用, 缓存原 CanCollide
	flyParts     = {},   -- BodyVelocity / BodyGyro
}

-- 配置控件注册表 (保存/加载配置用)
local ConfigControls = {}  -- { {key=, get=, apply=} }
local CONFIG_DIR  = "GSEN"
local ANIM_CONFIG_FILE = CONFIG_DIR .. "/animMode.json"

-- 兼容多种执行器的文件操作 (四层查找: _G / getfenv(0) / rawget / loadstring)
local function resolveFileFunc(name)
	-- 1. _G 表 (最常见, 几乎所有执行器都把文件函数放在 _G)
	if type(_G[name]) == "function" then return _G[name] end
	-- 2. getfenv(0) = 全局环境 (部分执行器在沙盒环境中注册)
	local okEnv, env = pcall(getfenv, 0)
	if okEnv and type(env) == "table" and type(env[name]) == "function" then
		return env[name]
	end
	-- 3. rawget 查找 (绕过 __index 元方法)
	local okRaw, fn = pcall(function() return rawget(_G, name) end)
	if okRaw and type(fn) == "function" then return fn end
	-- 4. 尝试通过 loadstring 获取 (某些执行器用不同环境)
	local okLoad, fn2 = pcall(function()
		local f = loadstring("return " .. name)
		if f then return f() end
	end)
	if okLoad and type(fn2) == "function" then return fn2 end
	return nil
end

local _writefile  = resolveFileFunc("writefile")
local _readfile   = resolveFileFunc("readfile")
local _isfile     = resolveFileFunc("isfile")
local _isfolder   = resolveFileFunc("isfolder")
local _makefolder  = resolveFileFunc("makefolder")
local _delfile    = resolveFileFunc("delfile")
local _listfiles  = resolveFileFunc("listfiles")

-- 文件系统诊断信息 (供设置页显示)
local FS_DIAG = nil
local function getFSDiag()
	if FS_DIAG then return FS_DIAG end
	FS_DIAG = {
		writefile  = _writefile  ~= nil,
		readfile   = _readfile   ~= nil,
		isfile     = _isfile     ~= nil,
		isfolder   = _isfolder   ~= nil,
		makefolder  = _makefolder  ~= nil,
		delfile    = _delfile    ~= nil,
		listfiles  = _listfiles  ~= nil,
	}
	return FS_DIAG
end

-- 健壮的文件写入: 尝试目录路径, 失败则回退到平铺路径
-- 返回 true | false, errMsg, usedPath
local function safeWriteFile(filePath, content)
	if not _writefile then return false, "执行器不支持文件写入", nil end

	-- 提取目录部分
	local dir = filePath:match("^(.+)[/\\][^/\\]+$")

	-- 策略1: 先尝试创建目录再写入完整路径
	if dir and _makefolder then
		pcall(_makefolder, dir)
	end
	local ok, ret1, ret2 = pcall(_writefile, filePath, content)
	-- pcall 成功且 writefile 没有返回 false
	if ok and ret1 ~= false then
		return true, nil, filePath
	end
	-- 如果 pcall 报错, 收集错误信息
	local err1 = ok and tostring(ret1 or "") or tostring(ret1)

	-- 策略2: 如果是带目录的路径, 尝试不带目录的平铺路径
	if dir then
		local flatName = filePath:match("[^/\\]+$")
		if flatName then
			local ok2, r1, r2 = pcall(_writefile, flatName, content)
			if ok2 and r1 ~= false then
				return true, nil, flatName
			end
			local err2 = ok2 and tostring(r1 or "") or tostring(r1)
			-- 策略3: 尝试不同的路径分隔符
			local altPath = filePath:gsub("/", "\\")
			if altPath ~= filePath then
				if dir and _makefolder then pcall(_makefolder, dir:gsub("/", "\\")) end
				local ok3, r3 = pcall(_writefile, altPath, content)
				if ok3 and r3 ~= false then
					return true, nil, altPath
				end
			end
			return false, "写入失败\n路径1: " .. filePath .. " -> " .. err1 .. "\n路径2: " .. flatName .. " -> " .. (ok2 and tostring(r1 or "") or tostring(r1)), nil
		end
	end

	-- 无目录路径, 直接报告错误
	if ok then
		-- pcall 成功但 writefile 返回了 false
		return false, "写入被拒绝: " .. tostring(ret1 or ret2 or "未知原因"), nil
	else
		return false, "写入错误: " .. tostring(ret1), nil
	end
end

-- 健壮的文件读取: 尝试目录路径, 失败则尝试平铺路径
-- 返回 content(string) | nil
local function safeReadFile(filePath)
	if not _readfile then return nil end

	-- 检查文件是否存在 (优先用 isfile)
	if _isfile then
		local exists = _isfile(filePath)
		if not exists then
			-- 尝试平铺路径
			local flatName = filePath:match("[^/\\]+$")
			if flatName and flatName ~= filePath and _isfile(flatName) then
				filePath = flatName
			else
				return nil
			end
		end
	end

	local ok, content = pcall(_readfile, filePath)
	if ok and type(content) == "string" and content ~= "" then
		return content, filePath
	end

	-- 回退: 尝试平铺路径
	local flatName = filePath:match("[^/\\]+$")
	if flatName and flatName ~= filePath then
		local ok2, content2 = pcall(_readfile, flatName)
		if ok2 and type(content2) == "string" and content2 ~= "" then
			return content2, flatName
		end
		-- 回退: 尝试反斜杠路径
		local altPath = filePath:gsub("/", "\\")
		if altPath ~= filePath then
			local ok3, content3 = pcall(_readfile, altPath)
			if ok3 and type(content3) == "string" and content3 ~= "" then
				return content3, altPath
			end
		end
	end

	return nil
end

-- 健壮的文件存在检查
local function safeIsFile(filePath)
	if _isfile then
		if _isfile(filePath) then return true end
		local flatName = filePath:match("[^/\\]+$")
		if flatName and flatName ~= filePath and _isfile(flatName) then return true end
		local altPath = filePath:gsub("/", "\\")
		if altPath ~= filePath and _isfile(altPath) then return true end
	end
	-- 无 isfile 函数时, 尝试读取来判断
	if _readfile then
		local ok, content = pcall(_readfile, filePath)
		if ok and type(content) == "string" and content ~= "" then return true end
		local flatName = filePath:match("[^/\\]+$")
		if flatName and flatName ~= filePath then
			local ok2, content2 = pcall(_readfile, flatName)
			if ok2 and type(content2) == "string" and content2 ~= "" then return true end
		end
	end
	return false
end

-- 简易 JSON 编码 (仅用于简单键值对, 避免 HttpService 尚未初始化的问题)
local function simpleJSONEncode(t)
	local parts = {}
	for k, v in pairs(t) do
		local key = '"' .. tostring(k):gsub('"', '\\"') .. '"'
		local val
		if type(v) == "string" then
			val = '"' .. v:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n') .. '"'
		elseif type(v) == "number" then
			val = tostring(v)
		elseif type(v) == "boolean" then
			val = v and "true" or "false"
		else
			val = '"' .. tostring(v) .. '"'
		end
		table.insert(parts, key .. ": " .. val)
	end
	return "{" .. table.concat(parts, ", ") .. "}"
end

-- 简易 JSON 解码 (仅提取字符串值, 用于动画配置)
local function simpleJSONDecode(content)
	if type(content) ~= "string" then return nil end
	-- 匹配 "animMode": "xxx" 或 "animMode":"xxx"
	local mode = content:match('"animMode"%s*:%s*"([^"]*)"')
	return mode
end

-- 自动保存展开动画模式
local function saveAnimMode(mode)
	if not _writefile then return false, "执行器不支持文件写入" end
	-- 手动拼接 JSON, 不依赖 HttpService (此时可能尚未初始化)
	local json = simpleJSONEncode({ animMode = mode })
	if not json or json == "" then return false, "序列化失败" end
	local success, err, usedPath = safeWriteFile(ANIM_CONFIG_FILE, json)
	if not success then return false, err or "写入失败" end
	return true
end

-- 自动加载展开动画模式 (返回字符串或 nil)
local function loadAnimMode()
	local content = safeReadFile(ANIM_CONFIG_FILE)
	if not content then return nil end
	-- 优先用 simpleJSONDecode (不依赖 HttpService)
	local mode = simpleJSONDecode(content)
	if mode then return mode end
	-- 回退到 HttpService (如果已初始化)
	local okHS = pcall(function()
		local hs = game:GetService("HttpService")
		if hs then
			local ok2, data = pcall(function() return hs:JSONDecode(content) end)
			if ok2 and type(data) == "table" and data.animMode then
				mode = data.animMode
			end
		end
	end)
	return mode
end

-- 注册连接, 方便统一断开
local function trackConnection(conn)
	table.insert(Runtime.connections, conn)
	return conn
end
local function trackInstance(inst)
	table.insert(Runtime.instances, inst)
	return inst
end

-- 前向声明: 这些函数会被更早注册的回调引用, 在此先声明局部
local setFly, setNoclip, setFling, setOrbit, setSpin, setLoopTp, setLoopTpAll, setInstantPrompt, setChatTranslation, setInvisible, setGodHealth, ResetAndDestroy
local flingToggleSet = nil  -- 甩飞开关的 set 函数引用, 用于自动关闭时同步 UI
local orbitToggleSet = nil  -- 环绕开关的 set 函数引用, 用于自动关闭时同步 UI
local orbitAngle = 0        -- 环绕角度累加器
local savedCamOffset = nil  -- 环绕时摄像机相对目标的位置偏移
local spinAngle = 0         -- 自旋角度累加器
local spinYVelocity = 0     -- 自旋时手动管理的垂直速度 (跳跃/重力)
local GROUND_OFFSET = 3.2   -- HRootPart 中心到脚底的近似距离
local JUMP_POWER = 50       -- 跳跃初速度

--========================================================
-- 1. WindUI 风格 GUI 框架
--========================================================
-- 颜色从原始截图提取
local Theme = {
	Background = Color3.fromRGB(24, 24, 36),
	Window     = Color3.fromRGB(30, 30, 46),
	TabBar     = Color3.fromRGB(31, 30, 44),
	TabBtn     = Color3.fromRGB(17, 17, 25),
	Element    = Color3.fromRGB(49, 50, 68),
	Hover      = Color3.fromRGB(69, 71, 90),
	Text       = Color3.fromRGB(205, 214, 244),
	SubText    = Color3.fromRGB(137, 140, 160),
	Accent     = Color3.fromRGB(203, 166, 247),
	AccentDark = Color3.fromRGB(137, 100, 180),
	Stroke     = Color3.fromRGB(88, 91, 112),
	Green      = Color3.fromRGB(166, 227, 161),
	GreenDark  = Color3.fromRGB(100, 140, 97),
	Red        = Color3.fromRGB(243, 139, 168),
}

local FontMain = Enum.Font.GothamMedium
local FontBold = Enum.Font.GothamBold

-- 清理旧实例, 防止重复执行脚本时旧 GUI 残留导致修改不生效
do
	local oldMain = playerGui:FindFirstChild("GSEN_Menu")
	if oldMain then oldMain:Destroy() end
	local oldOverlay = playerGui:FindFirstChild("WindUI_Overlay")
	if oldOverlay then oldOverlay:Destroy() end
end

-- 根 ScreenGui
local MainGui = trackInstance(Instance.new("ScreenGui"))
MainGui.Name = "GSEN_Menu"
MainGui.ResetOnSpawn = false
MainGui.ZIndexBehavior = Enum.ZIndexBehavior.Global
MainGui.IgnoreGuiInset = true
MainGui.Parent = playerGui

-- 用于 ESP 方框 / FOV 圈的独立层 (AlwaysOnTop)
local OverlayGui = trackInstance(Instance.new("ScreenGui"))
OverlayGui.Name = "WindUI_Overlay"
OverlayGui.ResetOnSpawn = false
OverlayGui.IgnoreGuiInset = true
OverlayGui.DisplayOrder = 9999
OverlayGui.Parent = playerGui

-- ---------- 主窗口 ----------
local Window = trackInstance(Instance.new("Frame"))
Window.Name = "Window"
Window.Size = UDim2.fromOffset(460, 330)
Window.Position = UDim2.new(0.5, -230, 0.5, -165)
Window.BackgroundColor3 = Theme.Window
Window.BorderSizePixel = 0
Window.Active = true
Window.ClipsDescendants = true
Window.Parent = MainGui

local winCorner = trackInstance(Instance.new("UICorner"))
winCorner.CornerRadius = UDim.new(0, 10)
winCorner.Parent = Window

local winStroke = trackInstance(Instance.new("UIStroke"))
winStroke.Color = Theme.Stroke
winStroke.Thickness = 1
winStroke.Parent = Window

-- 拖拽
do
	local dragging, dragStart, startPos
	trackConnection(Window.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			dragStart = input.Position
			startPos = Window.Position
		end
	end))
	trackConnection(Window.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = false
		end
	end))
	trackConnection(UserInputService.InputChanged:Connect(function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			local delta = input.Position - dragStart
			Window.Position = UDim2.new(
				startPos.X.Scale, startPos.X.Offset + delta.X,
				startPos.Y.Scale, startPos.Y.Offset + delta.Y
			)
		end
	end))
end

-- 右下角缩放把手 (白色半透明空心圆角正方形), 拖动等比例调整窗口大小, 内容随容器自适应
do
	local WSAR = 460 / 330 -- 锁定宽高比, 保证内容排版不破版
	local MINW = 360  -- 最小宽度, 防止过度缩小
	-- handle 挂到 Window 的父级 MainGui, 使正方形可溢出窗口显示(不受 Window.ClipsDescendants 裁切)
	-- 通过监听 Window 的 Size/Position 变化, 让矩形中心始终跟随窗口右下角
	local handle = trackInstance(Instance.new("ImageButton"))
	handle.Size = UDim2.fromOffset(32, 32)
	handle.AnchorPoint = Vector2.new(0.5, 0.5) -- 中心对准窗口右下角
	handle.BackgroundTransparency = 1
	handle.ZIndex = 100 -- 在窗口内容之上
	handle.Parent = MainGui -- 挂到 MainGui, 溢出可用 ClipsDescendants

	-- 圆角正方形边框 (空心, 白色半透明描边)
	local box = trackInstance(Instance.new("Frame"))
	box.Size = UDim2.fromOffset(32, 32)
	box.AnchorPoint = Vector2.new(0.5, 0.5)
	box.Position = UDim2.fromScale(0.5, 0.5) -- 相对 handle 居中
	box.BackgroundTransparency = 1 -- 空心
	box.BorderSizePixel = 0
	box.ZIndex = 100
	local boxC = trackInstance(Instance.new("UICorner"))
	boxC.CornerRadius = UDim.new(0, 6) -- 圆角6px
	boxC.Parent = box
	local boxStroke = trackInstance(Instance.new("UIStroke"))
	boxStroke.Color = Color3.fromRGB(255, 255, 255) -- 白色边框
	boxStroke.Thickness = 1.2
	boxStroke.Transparency = 0.3 -- 半透明
	boxStroke.Parent = box
	box.Parent = handle

	-- 同步 handle 位置到窗口右下角 (MainGui 坐标系, 相对 MainGui 的百分比+偏移)
	local function syncHandlePos()
		handle.Position = UDim2.new(
			Window.Position.X.Scale, Window.Position.X.Offset + Window.Size.X.Offset,
			Window.Position.Y.Scale, Window.Position.Y.Offset + Window.Size.Y.Offset
		)
	end
	syncHandlePos()
	-- handle 挂到 MainGui 后不受 Window.Visible 传播, 需手动同步可见性
	local function syncHandleVisible()
		handle.Visible = Window.Visible
	end
	syncHandleVisible()
	-- 监听窗口位置/大小变化(拖拽移动、缩放均会触发), 实时跟随
	trackConnection(Window:GetPropertyChangedSignal("Position"):Connect(syncHandlePos))
	trackConnection(Window:GetPropertyChangedSignal("Size"):Connect(syncHandlePos))
	-- 监听窗口可见性变化(隐藏/显示菜单), 同步缩放把手
	trackConnection(Window:GetPropertyChangedSignal("Visible"):Connect(syncHandleVisible))

	-- 拖拽缩放
	local resizing, resStart, resWinW
	trackConnection(handle.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			resizing = true
			resStart = input.Position
			resWinW = Window.Size.X.Offset
		end
	end))
	trackConnection(UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			resizing = false
		end
	end))
	trackConnection(UserInputService.InputChanged:Connect(function(input)
		if resizing and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			local dx = input.Position.X - resStart.X
			local dy = input.Position.Y - resStart.Y
			local delta = dx
			if math.abs(dy) > math.abs(dx) then delta = dy end
			local base = resWinW or 460
			local nw = math.max(MINW, base + delta)
			local nh = nw / WSAR
			Window.Size = UDim2.fromOffset(nw, nh)
		end
	end))
end

--========================================================
-- 5.5 飞行控制悬浮窗
--========================================================
local FlyPanel       -- 面板根
local FlyPanelToggle -- 面板内的飞行开关引用
local FlySpeedInput  -- 飞行速度输入框
local toggleFlyPanel
local syncFlyPanelUI -- 同步飞行面板开关 UI (供移动页 toggle 调用)

do
	FlyPanel = trackInstance(Instance.new("Frame"))
	FlyPanel.Name = "FlyControlPanel"
	FlyPanel.Size = UDim2.fromOffset(180, 130)
	FlyPanel.Position = UDim2.new(0.5, -90, 0.5, -65)
	FlyPanel.BackgroundColor3 = Theme.Window
	FlyPanel.BorderSizePixel = 0
	FlyPanel.Visible = false
	FlyPanel.Active = true
	FlyPanel.ClipsDescendants = true
	FlyPanel.ZIndex = 0
	local fc = trackInstance(Instance.new("UICorner"))
	fc.CornerRadius = UDim.new(0, 8)
	fc.Parent = FlyPanel
	local fs = trackInstance(Instance.new("UIStroke"))
	fs.Color = Theme.Stroke
	fs.Thickness = 1
	fs.Parent = FlyPanel
	FlyPanel.Parent = MainGui

	-- 标题栏 (拖拽区域)
	local panelTitle = trackInstance(Instance.new("Frame"))
	panelTitle.Size = UDim2.new(1, 0, 0, 28)
	panelTitle.BackgroundColor3 = Theme.TabBar
	panelTitle.BorderSizePixel = 0
	panelTitle.ZIndex = 0
	panelTitle.Active = true
	local pt = trackInstance(Instance.new("UICorner"))
	pt.CornerRadius = UDim.new(0, 8)
	pt.Parent = panelTitle
	local ptMask = trackInstance(Instance.new("Frame"))
	ptMask.Size = UDim2.new(1, 0, 0, 14)
	ptMask.Position = UDim2.fromOffset(0, 14)
	ptMask.BackgroundColor3 = Theme.TabBar
	ptMask.BorderSizePixel = 0
	ptMask.ZIndex = 0
	ptMask.Parent = panelTitle
	local panelTitleText = trackInstance(Instance.new("TextLabel"))
	panelTitleText.Size = UDim2.new(1, 0, 1, 0)
	panelTitleText.BackgroundTransparency = 1
	panelTitleText.Text = "  飞行控制"
	panelTitleText.TextColor3 = Theme.Text
	panelTitleText.TextXAlignment = Enum.TextXAlignment.Left
	panelTitleText.TextYAlignment = Enum.TextYAlignment.Center
	panelTitleText.Font = FontBold
	panelTitleText.TextSize = 13
	panelTitleText.ZIndex = 0
	panelTitleText.Parent = panelTitle
	panelTitle.Parent = FlyPanel

	-- 缩小/展开按钮
	local flyPanelMinimized = false
	local flyPanelExpandedH = 130
	local flyPanelMinimizedH = 28

	local flyMinBtn = trackInstance(Instance.new("TextButton"))
	flyMinBtn.Size = UDim2.fromOffset(22, 22)
	flyMinBtn.Position = UDim2.new(1, -27, 0, 3)
	flyMinBtn.BackgroundColor3 = Theme.Element
	flyMinBtn.Text = "-"
	flyMinBtn.TextColor3 = Theme.Text
	flyMinBtn.Font = FontBold
	flyMinBtn.TextSize = 14
	flyMinBtn.BorderSizePixel = 0
	flyMinBtn.ZIndex = 0
	flyMinBtn.AutoButtonColor = false
	local fmC = trackInstance(Instance.new("UICorner"))
	fmC.CornerRadius = UDim.new(1, 0)
	fmC.Parent = flyMinBtn
	flyMinBtn.Parent = FlyPanel

	trackConnection(flyMinBtn.MouseEnter:Connect(function() flyMinBtn.BackgroundColor3 = Theme.Hover end))
	trackConnection(flyMinBtn.MouseLeave:Connect(function() flyMinBtn.BackgroundColor3 = Theme.Element end))
	trackConnection(flyMinBtn.MouseButton1Click:Connect(function()
		flyPanelMinimized = not flyPanelMinimized
		if flyPanelMinimized then
			flyMinBtn.Text = "+"
			ptMask.Visible = false
			TweenService:Create(FlyPanel, TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut), {
				Size = UDim2.fromOffset(180, flyPanelMinimizedH),
			}):Play()
		else
			flyMinBtn.Text = "-"
			TweenService:Create(FlyPanel, TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut), {
				Size = UDim2.fromOffset(180, flyPanelExpandedH),
			}):Play()
			task.delay(0.2, function()
				ptMask.Visible = true
			end)
		end
	end))

	-- 拖拽 (仅标题栏可拖动)
	local dragging, dragStart, startPos
	trackConnection(panelTitle.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			dragStart = input.Position
			startPos = FlyPanel.Position
		end
	end))
	trackConnection(panelTitle.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = false
		end
	end))
	trackConnection(UserInputService.InputChanged:Connect(function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			local delta = input.Position - dragStart
			FlyPanel.Position = UDim2.new(
				startPos.X.Scale, startPos.X.Offset + delta.X,
				startPos.Y.Scale, startPos.Y.Offset + delta.Y
			)
		end
	end))

	-- 飞行开关
	local flyLabel = trackInstance(Instance.new("TextLabel"))
	flyLabel.Size = UDim2.new(0, 60, 0, 18)
	flyLabel.Position = UDim2.fromOffset(12, 36)
	flyLabel.BackgroundTransparency = 1
	flyLabel.Text = "飞行"
	flyLabel.TextColor3 = Theme.Text
	flyLabel.Font = FontMain
	flyLabel.TextSize = 13
	flyLabel.TextXAlignment = Enum.TextXAlignment.Left
	flyLabel.ZIndex = 0
	flyLabel.Parent = FlyPanel

	local flyTrack = trackInstance(Instance.new("Frame"))
	flyTrack.Size = UDim2.fromOffset(44, 22)
	flyTrack.Position = UDim2.new(1, -56, 0, 34)
	flyTrack.BackgroundColor3 = Theme.Background
	flyTrack.BorderSizePixel = 0
	flyTrack.ZIndex = 0
	local ftc = trackInstance(Instance.new("UICorner"))
	ftc.CornerRadius = UDim.new(1, 0)
	ftc.Parent = flyTrack
	local fts = trackInstance(Instance.new("UIStroke"))
	fts.Color = Theme.Stroke
	fts.Thickness = 1
	fts.Transparency = 0.4
	fts.Parent = flyTrack
	flyTrack.Parent = FlyPanel

	local flyKnob = trackInstance(Instance.new("Frame"))
	flyKnob.Size = UDim2.fromOffset(18, 18)
	flyKnob.Position = UDim2.fromOffset(2, 2)
	flyKnob.BackgroundColor3 = Theme.Stroke
	flyKnob.BorderSizePixel = 0
	local fkc = trackInstance(Instance.new("UICorner"))
	fkc.CornerRadius = UDim.new(1, 0)
	fkc.Parent = flyKnob
	flyKnob.ZIndex = 0
	flyKnob.Parent = flyTrack

	local flyBtn = trackInstance(Instance.new("TextButton"))
	flyBtn.Size = UDim2.new(1, 0, 1, 0)
	flyBtn.BackgroundTransparency = 1
	flyBtn.Text = ""
	flyBtn.ZIndex = 0
	flyBtn.Parent = flyTrack

	trackConnection(flyBtn.MouseButton1Click:Connect(function()
		local newState = not State.flyEnabled
		setFly(newState)
		TweenService:Create(flyKnob, TweenInfo.new(0.18, Enum.EasingStyle.Quad), {
			Position = newState and UDim2.fromOffset(24, 2) or UDim2.fromOffset(2, 2),
		}):Play()
		TweenService:Create(flyTrack, TweenInfo.new(0.18), {
			BackgroundColor3 = newState and Theme.GreenDark or Theme.Background,
		}):Play()
	end))

	-- 飞行速度标签
	local spdLabel = trackInstance(Instance.new("TextLabel"))
	spdLabel.Size = UDim2.new(0, 60, 0, 18)
	spdLabel.Position = UDim2.fromOffset(12, 68)
	spdLabel.BackgroundTransparency = 1
	spdLabel.Text = "飞行速度"
	spdLabel.TextColor3 = Theme.Text
	spdLabel.Font = FontMain
	spdLabel.TextSize = 13
	spdLabel.TextXAlignment = Enum.TextXAlignment.Left
	spdLabel.ZIndex = 0
	spdLabel.Parent = FlyPanel

	-- 飞行速度输入框
	FlySpeedInput = trackInstance(Instance.new("TextBox"))
	FlySpeedInput.Size = UDim2.fromOffset(70, 24)
	FlySpeedInput.Position = UDim2.new(1, -82, 0, 65)
	FlySpeedInput.BackgroundColor3 = Theme.Background
	FlySpeedInput.BorderSizePixel = 0
	FlySpeedInput.Text = tostring(State.flySpeed)
	FlySpeedInput.TextColor3 = Theme.Accent
	FlySpeedInput.Font = FontBold
	FlySpeedInput.TextSize = 13
	FlySpeedInput.TextXAlignment = Enum.TextXAlignment.Center
	FlySpeedInput.ClearTextOnFocus = false
	FlySpeedInput.ZIndex = 0
	local sic = trackInstance(Instance.new("UICorner"))
	sic.CornerRadius = UDim.new(0, 4)
	sic.Parent = FlySpeedInput
	FlySpeedInput.Parent = FlyPanel

	-- 输入框提交
	trackConnection(FlySpeedInput.FocusLost:Connect(function(enterPressed)
		local raw = FlySpeedInput.Text
		local numStr = raw:match("[-+]?%d+%.?%d*")
		if numStr then
			local v = tonumber(numStr)
			if v then
				v = math.clamp(v, 10, 10000)
				State.flySpeed = v
				FlySpeedInput.Text = tostring(v)
				return
			end
		end
		FlySpeedInput.Text = tostring(State.flySpeed)
	end))

	-- ±10 / ±100 按钮
	local function makeSpeedButton(text, dx, dy, delta)
		local b = trackInstance(Instance.new("TextButton"))
		b.Size = UDim2.fromOffset(32, 22)
		b.Position = UDim2.fromOffset(dx, dy)
		b.BackgroundColor3 = Theme.Element
		b.BorderSizePixel = 0
		b.Text = text
		b.TextColor3 = Theme.Text
		b.Font = FontBold
		b.TextSize = 11
		b.ZIndex = 0
		local bc = trackInstance(Instance.new("UICorner"))
		bc.CornerRadius = UDim.new(0, 4)
		bc.Parent = b
		trackConnection(b.MouseButton1Click:Connect(function()
			local v = math.clamp(State.flySpeed + delta, 10, 10000)
			State.flySpeed = v
			FlySpeedInput.Text = tostring(v)
		end))
		trackConnection(b.MouseEnter:Connect(function() b.BackgroundColor3 = Theme.Hover end))
		trackConnection(b.MouseLeave:Connect(function() b.BackgroundColor3 = Theme.Element end))
		b.Parent = FlyPanel
		return b
	end

	makeSpeedButton("-100", 12, 96, -100)
	makeSpeedButton("-10",  50, 96, -10)
	makeSpeedButton("+10",  98, 96, 10)
	makeSpeedButton("+100", 136, 96, 100)

	-- 开关面板函数
	toggleFlyPanel = function(show)
		FlyPanel.Visible = show
		if show then
			-- 重新显示时恢复展开状态
			flyPanelMinimized = false
			flyMinBtn.Text = "-"
			FlyPanel.Size = UDim2.fromOffset(180, flyPanelExpandedH)
			ptMask.Visible = true
		end
		if not show and State.flyEnabled then
			setFly(false)
			TweenService:Create(flyKnob, TweenInfo.new(0.18, Enum.EasingStyle.Quad), {
				Position = UDim2.fromOffset(2, 2),
			}):Play()
			TweenService:Create(flyTrack, TweenInfo.new(0.18), {
				BackgroundColor3 = Theme.Background,
			}):Play()
		end
		-- 同步飞行速度显示
		FlySpeedInput.Text = tostring(State.flySpeed)
	end

	-- 同步飞行面板开关 UI (供移动页 toggle / 配置加载调用)
	syncFlyPanelUI = function(state)
		TweenService:Create(flyKnob, TweenInfo.new(0.18, Enum.EasingStyle.Quad), {
			Position = state and UDim2.fromOffset(24, 2) or UDim2.fromOffset(2, 2),
		}):Play()
		TweenService:Create(flyTrack, TweenInfo.new(0.18), {
			BackgroundColor3 = state and Theme.GreenDark or Theme.Background,
		}):Play()
	end
end

-- ---------- 标题栏 ----------
local TitleBar = trackInstance(Instance.new("Frame"))
TitleBar.Name = "TitleBar"
TitleBar.Size = UDim2.new(1, 0, 0, 38)
TitleBar.BackgroundColor3 = Theme.TabBar
TitleBar.BorderSizePixel = 0
TitleBar.Parent = Window

local tbCorner = trackInstance(Instance.new("UICorner"))
tbCorner.CornerRadius = UDim.new(0, 10)
tbCorner.Parent = TitleBar

-- 用一个矩形挡住标题栏下半部分, 让圆角只在上方
local tbMask = trackInstance(Instance.new("Frame"))
tbMask.Size = UDim2.new(1, 0, 0, 19)
tbMask.Position = UDim2.fromOffset(0, 19)
tbMask.BackgroundColor3 = Theme.TabBar
tbMask.BorderSizePixel = 0
tbMask.Parent = TitleBar

local TitleLabel = trackInstance(Instance.new("TextLabel"))
TitleLabel.Size = UDim2.new(1, -100, 1, 0)
TitleLabel.Position = UDim2.fromOffset(14, 0)
TitleLabel.BackgroundTransparency = 1
TitleLabel.Text = "GSEN辅助"
TitleLabel.TextColor3 = Theme.Text
TitleLabel.Font = FontBold
TitleLabel.TextSize = 15
TitleLabel.TextXAlignment = Enum.TextXAlignment.Left
TitleLabel.Parent = TitleBar

-- 关闭 / 最小化按钮
local function makeTopButton(text, color)
	local btn = trackInstance(Instance.new("TextButton"))
	btn.Size = UDim2.fromOffset(26, 26)
	btn.Position = UDim2.new(1, -32, 0.5, -13)
	btn.BackgroundColor3 = Theme.Element
	btn.Text = text
	btn.TextColor3 = color
	btn.Font = FontBold
	btn.TextSize = 14
	btn.BorderSizePixel = 0
	btn.AutoButtonColor = false
	local c = trackInstance(Instance.new("UICorner"))
	c.CornerRadius = UDim.new(1, 0)
	c.Parent = btn
	-- 悬停效果
	trackConnection(btn.MouseEnter:Connect(function() btn.BackgroundColor3 = Theme.Hover end))
	trackConnection(btn.MouseLeave:Connect(function() btn.BackgroundColor3 = Theme.Element end))
	return btn
end

local MinimizeBtn = makeTopButton("-", Theme.Text)
MinimizeBtn.Position = UDim2.new(1, -64, 0.5, -13)
MinimizeBtn.Parent = TitleBar

local CloseBtn = makeTopButton("X", Theme.Red)
CloseBtn.Position = UDim2.new(1, -32, 0.5, -13)
CloseBtn.Parent = TitleBar

-- ---------- 左侧标签栏 ----------
local Sidebar = trackInstance(Instance.new("Frame"))
Sidebar.Size = UDim2.new(0, 123, 1, -38)
Sidebar.Position = UDim2.fromOffset(0, 38)
Sidebar.BackgroundColor3 = Theme.TabBar
Sidebar.BorderSizePixel = 0
Sidebar.Parent = Window

-- Sidebar 圆角匹配 Window (10px), 防止左下角尖角
local sideCorner = trackInstance(Instance.new("UICorner"))
sideCorner.CornerRadius = UDim.new(0, 10)
sideCorner.Parent = Sidebar

local TabList = trackInstance(Instance.new("ScrollingFrame"))
TabList.Size = UDim2.new(1, -16, 1, -16)
TabList.Position = UDim2.new(0, 8, 0, 8)
TabList.BackgroundTransparency = 1
TabList.BorderSizePixel = 0
TabList.ScrollBarThickness = 0
TabList.CanvasSize = UDim2.new(0, 0, 0, 0)
TabList.AutomaticCanvasSize = Enum.AutomaticSize.Y
TabList.ScrollingDirection = Enum.ScrollingDirection.Y
TabList.ClipsDescendants = true
TabList.Parent = Sidebar

local tabLayout = trackInstance(Instance.new("UIListLayout"))
tabLayout.FillDirection = Enum.FillDirection.Vertical
tabLayout.SortOrder = Enum.SortOrder.LayoutOrder
tabLayout.Padding = UDim.new(0, 6)
tabLayout.Parent = TabList

-- 显式追踪 UIListLayout 内容高度, 保证超出时能滚动
-- X 用 1,0 (= 框架宽度) 使子元素 Scale=1 能正确取到宽度
trackConnection(tabLayout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
	TabList.CanvasSize = UDim2.new(1, 0, 0, tabLayout.AbsoluteContentSize.Y)
end))

-- 裁切容器: 比 TabList 略大 (四周多 6px), 给高亮框动画放大留空间, 同时仍能裁切超出滚动范围的标签
local TabClip = trackInstance(Instance.new("Frame"))
TabClip.Name = "TabClip"
TabClip.Size = UDim2.new(1, -4, 1, -4)
TabClip.Position = UDim2.new(0, 2, 0, 2)
TabClip.BackgroundTransparency = 1
TabClip.BorderSizePixel = 0
TabClip.ClipsDescendants = true
TabClip.ZIndex = 10
TabClip.Parent = Sidebar

-- 共享高亮选中框 (挂在 TabClip 下, 避开 TabList 的 UIListLayout 自动排列, 同时被裁切)
local TabHighlight = trackInstance(Instance.new("Frame"))
TabHighlight.Name = "TabHighlight"
TabHighlight.Size = UDim2.new(1, -16, 0, 32)
TabHighlight.Position = UDim2.new(0, 8, 0, 8)
TabHighlight.BackgroundColor3 = Theme.Element
TabHighlight.BackgroundTransparency = 1
TabHighlight.BorderSizePixel = 0
TabHighlight.Visible = false
TabHighlight.ZIndex = 11
local thc = trackInstance(Instance.new("UICorner"))
thc.CornerRadius = UDim.new(0, 6)
thc.Parent = TabHighlight
local ths = trackInstance(Instance.new("UIStroke"))
ths.Color = Theme.Accent
ths.Thickness = 1.5
ths.Transparency = 0.3
ths.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
ths.Parent = TabHighlight
TabHighlight.Parent = TabClip

-- 跟踪当前选中标签按钮 & 动画状态, 用于滚动时同步高亮框位置
local currentTabBtn = nil
local highlightAnimating = false

-- 滚动时同步高亮框位置 (TabHighlight 在 TabClip 下, 跟随 TabList 滚动)
trackConnection(TabList:GetPropertyChangedSignal("CanvasPosition"):Connect(function()
	if currentTabBtn and TabHighlight.Visible and not highlightAnimating then
		local clipPos = TabClip.AbsolutePosition
		local btnPos = currentTabBtn.AbsolutePosition
		local btnSize = currentTabBtn.AbsoluteSize
		-- 用按钮可见位置 (AbsolutePosition 已反映滚动状态)
		TabHighlight.Position = UDim2.fromOffset(btnPos.X - clipPos.X, btnPos.Y - clipPos.Y)
		TabHighlight.Size = UDim2.fromOffset(btnSize.X, 32)
	end
end))

-- ---------- 内容区 ----------
local Content = trackInstance(Instance.new("Frame"))
Content.Size = UDim2.new(1, -120, 1, -38)
Content.Position = UDim2.fromOffset(120, 38)
Content.BackgroundColor3 = Theme.Background
Content.BorderSizePixel = 0
Content.ClipsDescendants = true
Content.Parent = Window

local contentCorner = trackInstance(Instance.new("UICorner"))
contentCorner.CornerRadius = UDim.new(0, 10)
contentCorner.Parent = Content

-- 每个标签页对应一个容器
local Tabs = {}        -- [name] = {button, page, order}
local currentPage = nil
local tabOrderCounter = 0

local function addTab(name, iconText)
	tabOrderCounter = tabOrderCounter + 1
	local btn = trackInstance(Instance.new("TextButton"))
	btn.Size = UDim2.new(0, 100, 0, 32)
	btn.BackgroundColor3 = Theme.TabBtn
	btn.Text = "  " .. (iconText or "●") .. "  " .. name
	btn.TextColor3 = Theme.SubText
	btn.Font = FontMain
	btn.TextSize = 13
	btn.TextXAlignment = Enum.TextXAlignment.Left
	btn.AutoButtonColor = false
	btn.BorderSizePixel = 0
	local bc = trackInstance(Instance.new("UICorner"))
	bc.CornerRadius = UDim.new(0, 6)
	bc.Parent = btn

	trackConnection(btn.MouseEnter:Connect(function()
		if currentPage ~= name then
			TweenService:Create(btn, TweenInfo.new(0.15), { BackgroundColor3 = Theme.Element }):Play()
		end
	end))
	trackConnection(btn.MouseLeave:Connect(function()
		if currentPage ~= name then
			TweenService:Create(btn, TweenInfo.new(0.15), { BackgroundColor3 = Theme.TabBtn }):Play()
		end
	end))
	btn.Parent = TabList
	btn.LayoutOrder = tabOrderCounter

	local page = trackInstance(Instance.new("ScrollingFrame"))
	page.Size = UDim2.new(1, -24, 1, -24)
	page.Position = UDim2.fromOffset(12, 12)
	page.BackgroundTransparency = 1
	page.BorderSizePixel = 0
	page.ScrollBarThickness = 4
	page.ScrollBarImageColor3 = Theme.Stroke
	page.CanvasSize = UDim2.new(0, 0, 0, 0)
	page.AutomaticCanvasSize = Enum.AutomaticSize.None
	page.ClipsDescendants = true
	page.Visible = false
	page.Parent = Content

	local pl = trackInstance(Instance.new("UIListLayout"))
	pl.FillDirection = Enum.FillDirection.Vertical
	pl.SortOrder = Enum.SortOrder.LayoutOrder
	pl.Padding = UDim.new(0, 8)
	pl.Parent = page

	-- 显式追踪 UIListLayout 内容高度, 保证超出时能滚动
	trackConnection(pl:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
		page.CanvasSize = UDim2.new(0, 0, 0, pl.AbsoluteContentSize.Y)
	end))

	Tabs[name] = {button = btn, page = page, order = tabOrderCounter}

	trackConnection(btn.MouseButton1Click:Connect(function()
		if currentPage == name then return end
		local oldTab = currentPage and Tabs[currentPage]
		local newTab = Tabs[name]

		-- 旧标签背景变暗
		if oldTab then
			TweenService:Create(oldTab.button, TweenInfo.new(0.2, Enum.EasingStyle.Quad), {
				BackgroundColor3 = Theme.TabBtn,
				TextColor3 = Theme.SubText,
			}):Play()
		end

		-- 新标签背景变亮 (Element 比 TabBar 稍亮, 突出选中态)
		TweenService:Create(newTab.button, TweenInfo.new(0.2, Enum.EasingStyle.Quad), {
			BackgroundColor3 = Theme.Element,
			TextColor3 = Theme.Text,
		}):Play()

		-- 高亮框: 从旧位置放大 → 移动到新位置 → 缩小回原尺寸
		-- 高亮框在 TabClip 下, 用按钮可见位置 (AbsolutePosition 已反映滚动)
		local clipPos = TabClip.AbsolutePosition
		local newBtnPos = newTab.button.AbsolutePosition
		local newY = newBtnPos.Y - clipPos.Y
		local oldY = newY
		if oldTab then
			local oldBtnPos = oldTab.button.AbsolutePosition
			oldY = oldBtnPos.Y - clipPos.Y
		end
		local newX = newBtnPos.X - clipPos.X
		local newW = newTab.button.AbsoluteSize.X
		local oldX = newX
		local oldW = newW
		if oldTab then
			oldX = oldTab.button.AbsolutePosition.X - clipPos.X
			oldW = oldTab.button.AbsoluteSize.X
		end

		-- 更新当前选中按钮引用, 动画期间禁止滚动同步
		currentTabBtn = newTab.button

		if not TabHighlight.Visible then
			-- 首次显示
			TabHighlight.Size = UDim2.fromOffset(newW, 32)
			TabHighlight.Position = UDim2.fromOffset(newX, newY)
			TabHighlight.Visible = true
		else
			highlightAnimating = true
			-- 放大 (宽高各+4, 位置偏移-2 保持居中)
			TweenService:Create(TabHighlight, TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
				Size = UDim2.fromOffset(oldW + 4, 40),
				Position = UDim2.fromOffset(oldX - 2, oldY - 4),
			}):Play()

			-- 0.12秒后移动到新位置 (保持放大状态)
			task.delay(0.12, function()
				TweenService:Create(TabHighlight, TweenInfo.new(0.15, Enum.EasingStyle.Quart, Enum.EasingDirection.InOut), {
					Position = UDim2.fromOffset(newX - 2, newY - 4),
					Size = UDim2.fromOffset(newW + 4, 40),
				}):Play()
			end)

			-- 0.39秒后缩小回正常尺寸 (和标签一样大), 恢复滚动同步
			task.delay(0.27, function()
				TweenService:Create(TabHighlight, TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
					Size = UDim2.fromOffset(newW, 32),
					Position = UDim2.fromOffset(newX, newY),
				}):Play()
				-- 动画结束后恢复滚动同步, 并立即校正位置 (防止动画期间用户滚动了)
				task.delay(0.12, function()
					highlightAnimating = false
					if currentTabBtn then
						local cp = TabClip.AbsolutePosition
						local bp = currentTabBtn.AbsolutePosition
						local bs = currentTabBtn.AbsoluteSize
						TabHighlight.Position = UDim2.fromOffset(bp.X - cp.X, bp.Y - cp.Y)
						TabHighlight.Size = UDim2.fromOffset(bs.X, 32)
					end
				end)
			end)
		end

		-- 判断方向
		local goingDown = newTab.order > (oldTab and oldTab.order or 0)
		local slideDist = 300
		local oldOffsetY = goingDown and -slideDist or slideDist
		local newOffsetY = goingDown and slideDist or -slideDist

		-- 旧页滑出
		if oldTab and oldTab.page.Visible then
			local oldTween = TweenService:Create(oldTab.page, TweenInfo.new(0.18, Enum.EasingStyle.Quart, Enum.EasingDirection.In), {
				Position = UDim2.fromOffset(12, 12 + oldOffsetY),
			})
			oldTween:Play()
			oldTween.Completed:Connect(function()
				oldTab.page.Visible = false
				oldTab.page.Position = UDim2.fromOffset(12, 12)
			end)
		end

		-- 新页从对应方向滑入
		newTab.page.Position = UDim2.fromOffset(12, 12 + newOffsetY)
		newTab.page.Visible = true
		TweenService:Create(newTab.page, TweenInfo.new(0.25, Enum.EasingStyle.Quart, Enum.EasingDirection.Out), {
			Position = UDim2.fromOffset(12, 12),
		}):Play()

		currentPage = name
	end))
	return page
end

-- ---------- UI 元素工厂 ----------
local function makeSectionLabel(parent, text)
	local lbl = trackInstance(Instance.new("TextLabel"))
	lbl.Size = UDim2.new(1, 0, 0, 18)
	lbl.BackgroundTransparency = 1
	lbl.Text = text
	lbl.TextColor3 = Theme.SubText
	lbl.Font = FontBold
	lbl.TextSize = 12
	lbl.TextXAlignment = Enum.TextXAlignment.Left
	lbl.Parent = parent
	return lbl
end

-- 开关
local function makeToggle(parent, text, callback, height, configKey)
	height = height or 31
	local container = trackInstance(Instance.new("Frame"))
	container.Size = UDim2.new(1, -5, 0, height)
	container.BackgroundColor3 = Theme.Element
	container.BorderSizePixel = 0
	local cc = trackInstance(Instance.new("UICorner"))
	cc.CornerRadius = UDim.new(0, 6)
	cc.Parent = container

	local label = trackInstance(Instance.new("TextLabel"))
	label.Size = UDim2.new(1, -66, 1, 0)
	label.Position = UDim2.fromOffset(12, 0)
	label.BackgroundTransparency = 1
	label.Text = text
	label.TextColor3 = Theme.Text
	label.Font = FontMain
	label.TextSize = 13
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Parent = container

	-- 轨道 (背景)
	local track = trackInstance(Instance.new("Frame"))
	track.Size = UDim2.fromOffset(44, 22)
	track.Position = UDim2.new(1, -54, 0.5, -11)
	track.BackgroundColor3 = Theme.Background
	track.BorderSizePixel = 0
	local tc = trackInstance(Instance.new("UICorner"))
	tc.CornerRadius = UDim.new(1, 0)
	tc.Parent = track
	local ts = trackInstance(Instance.new("UIStroke"))
	ts.Color = Theme.Stroke
	ts.Thickness = 1
	ts.Transparency = 0.4
	ts.Parent = track
	track.Parent = container

	-- 滑块 (拨钮)
	local knob = trackInstance(Instance.new("Frame"))
	knob.Size = UDim2.fromOffset(18, 18)
	knob.Position = UDim2.fromOffset(2, 2)
	knob.BackgroundColor3 = Theme.Stroke
	knob.BorderSizePixel = 0
	local kc = trackInstance(Instance.new("UICorner"))
	kc.CornerRadius = UDim.new(1, 0)
	kc.Parent = knob
	knob.Parent = track

	local on = false
	local btn = trackInstance(Instance.new("TextButton"))
	btn.Size = UDim2.new(1, 0, 1, 0)
	btn.BackgroundTransparency = 1
	btn.Text = ""
	btn.Parent = container

	local function set(state)
		on = state
		TweenService:Create(knob, TweenInfo.new(0.18, Enum.EasingStyle.Quad), {
			Position = on and UDim2.fromOffset(24, 2) or UDim2.fromOffset(2, 2),
		}):Play()
		TweenService:Create(track, TweenInfo.new(0.18), {
			BackgroundColor3 = on and Theme.GreenDark or Theme.Background,
		}):Play()
		task.spawn(callback, on)
	end
	trackConnection(btn.MouseButton1Click:Connect(function() set(not on) end))
	container.Parent = parent
	if configKey then
		ConfigControls[#ConfigControls + 1] = {
			key = configKey,
			get = function() return State[configKey] end,
			apply = function(v) set(v) end,
		}
	end
	return {container = container, set = set}
end

-- 滑条
local function makeSlider(parent, text, min, max, default, suffix, callback, configKey)
	local container = trackInstance(Instance.new("Frame"))
	container.Size = UDim2.new(1, -5, 0, 46)
	container.BackgroundColor3 = Theme.Element
	container.BorderSizePixel = 0
	local cc = trackInstance(Instance.new("UICorner"))
	cc.CornerRadius = UDim.new(0, 6)
	cc.Parent = container

	local label = trackInstance(Instance.new("TextLabel"))
	label.Size = UDim2.new(1, -110, 0, 18)
	label.Position = UDim2.fromOffset(12, 6)
	label.BackgroundTransparency = 1
	label.Text = text
	label.TextColor3 = Theme.Text
	label.Font = FontMain
	label.TextSize = 13
	label.TextTruncate = Enum.TextTruncate.AtEnd
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Parent = container

	-- 用 TextBox 替代 TextLabel, 支持点击手动输入
	local valueLbl = trackInstance(Instance.new("TextBox"))
	valueLbl.Size = UDim2.new(0, 80, 0, 18)
	valueLbl.Position = UDim2.new(1, -90, 0, 6)
	valueLbl.BackgroundTransparency = 1
	valueLbl.TextColor3 = Theme.Accent
	valueLbl.Font = FontBold
	valueLbl.TextSize = 13
	valueLbl.TextXAlignment = Enum.TextXAlignment.Right
	valueLbl.ClearTextOnFocus = false
	valueLbl.Text = ""
	valueLbl.Parent = container

	-- 根据范围确定格式化字符串 (给 setValue 和手动输入共用)
	local fmt
	if max - min >= 10 then
		fmt = "%d"
	elseif max - min >= 1 then
		fmt = "%.1f"
	else
		fmt = "%.2f"
	end

	local track = trackInstance(Instance.new("Frame"))
	track.Size = UDim2.new(1, -24, 0, 4)
	track.Position = UDim2.fromOffset(12, 30)
	track.BackgroundColor3 = Theme.Background
	track.BorderSizePixel = 0
	local tc = trackInstance(Instance.new("UICorner"))
	tc.CornerRadius = UDim.new(1, 0)
	tc.Parent = track
	track.Parent = container

	local fill = trackInstance(Instance.new("Frame"))
	fill.Size = UDim2.new(0, 0, 1, 0)
	fill.BackgroundColor3 = Theme.Accent
	fill.BorderSizePixel = 0
	local fc = trackInstance(Instance.new("UICorner"))
	fc.CornerRadius = UDim.new(1, 0)
	fc.Parent = fill
	fill.Parent = track

	local knob = trackInstance(Instance.new("Frame"))
	knob.Size = UDim2.fromOffset(12, 12)
	knob.Position = UDim2.fromOffset(0, -4)
	knob.BackgroundColor3 = Theme.Text
	knob.BorderSizePixel = 0
	local kc = trackInstance(Instance.new("UICorner"))
	kc.CornerRadius = UDim.new(1, 0)
	kc.Parent = knob
	knob.Parent = track

	local function setValue(v)
		v = math.clamp(v, min, max)
		local pct = (v - min) / (max - min)
		fill.Size = UDim2.new(pct, 0, 1, 0)
		knob.Position = UDim2.new(pct, -6, 0, -4)
		-- 只在 TextBox 没有焦点时更新显示, 避免覆盖用户正在输入的内容
		if not valueLbl:IsFocused() then
			valueLbl.Text = string.format(fmt, v) .. (suffix or "")
		end
		task.spawn(callback, v)
	end

	-- 手动输入提交: 失去焦点或按回车时解析数字
	local function commitInput()
		local raw = valueLbl.Text
		-- 去掉后缀和非数字字符, 提取数字部分
		local numStr = raw:match("[-+]?%d+%.?%d*")
		if numStr then
			local v = tonumber(numStr)
			if v then
				setValue(v)
				return
			end
		end
		-- 解析失败, 恢复当前值显示
		local pct = (fill.Size.X.Scale)
		local curVal = min + (max - min) * pct
		valueLbl.Text = string.format(fmt, curVal) .. (suffix or "")
	end
	trackConnection(valueLbl.FocusLost:Connect(function(enterPressed)
		commitInput()
	end))

	local dragging = false
	local hit = trackInstance(Instance.new("TextButton"))
	hit.Size = UDim2.new(1, 0, 0, 20)
	hit.Position = UDim2.fromOffset(0, -8)
	hit.BackgroundTransparency = 1
	hit.Text = ""
	hit.Parent = track
	local function update(inputX)
		local rel = inputX - track.AbsolutePosition.X
		local pct = math.clamp(rel / track.AbsoluteSize.X, 0, 1)
		setValue(min + (max - min) * pct)
	end
	trackConnection(hit.MouseButton1Down:Connect(function()
		dragging = true
		update(UserInputService:GetMouseLocation().X)
	end))
	trackConnection(hit.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = false
		end
	end))
	trackConnection(UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then dragging = false end
	end))
	trackConnection(UserInputService.InputChanged:Connect(function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			update(input.Position.X)
		end
	end))

	container.Parent = parent
	setValue(default)
	if configKey then
		ConfigControls[#ConfigControls + 1] = {
			key = configKey,
			get = function() return State[configKey] end,
			apply = function(v) setValue(v) end,
		}
	end
	return {container = container, setValue = setValue}
end

-- 下拉框 (列表 + 透明全屏按钮均挂载到 MainGui, 不受 Content.ClipsDescendants 裁切)
local function makeDropdown(parent, text, options, default, callback, configKey)
	local container = trackInstance(Instance.new("TextButton"))
	container.Size = UDim2.new(1, -5, 0, 36)
	container.BackgroundColor3 = Theme.Element
	container.BorderSizePixel = 0
	container.Text = ""
	container.AutoButtonColor = false
	local cc = trackInstance(Instance.new("UICorner"))
	cc.CornerRadius = UDim.new(0, 6)
	cc.Parent = container

	local label = trackInstance(Instance.new("TextLabel"))
	label.Size = UDim2.new(1, -160, 1, 0)
	label.Position = UDim2.fromOffset(12, 0)
	label.BackgroundTransparency = 1
	label.Text = text
	label.TextColor3 = Theme.Text
	label.Font = FontMain
	label.TextSize = 13
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.ZIndex = 11
	label.Parent = container

	local valLbl = trackInstance(Instance.new("TextLabel"))
	valLbl.Size = UDim2.new(0, 130, 1, 0)
	valLbl.Position = UDim2.new(1, -138, 0, 0)
	valLbl.BackgroundTransparency = 1
	valLbl.Text = default
	valLbl.TextColor3 = Theme.Accent
	valLbl.Font = FontBold
	valLbl.TextSize = 13
	valLbl.TextTruncate = Enum.TextTruncate.AtEnd
	valLbl.TextXAlignment = Enum.TextXAlignment.Right
	valLbl.ZIndex = 11
	valLbl.Parent = container

	-- 透明全屏按钮: 列表展开时拦截外部点击 → 关闭列表
	local catcher = trackInstance(Instance.new("TextButton"))
	catcher.Size = UDim2.new(1, 0, 1, 0)
	catcher.BackgroundTransparency = 1
	catcher.Text = ""
	catcher.AutoButtonColor = false
	catcher.Visible = false
	catcher.ZIndex = 49
	catcher.Parent = MainGui

	-- 列表挂到 MainGui 层, 不受 Content / page 的 ClipsDescendants 裁切
	local MAX_LIST_HEIGHT = 140
	local listHeight = math.min(#options * 28, MAX_LIST_HEIGHT)
	local list = trackInstance(Instance.new("ScrollingFrame"))
	list.BackgroundColor3 = Theme.Element
	list.BorderSizePixel = 0
	list.Visible = false
	list.ZIndex = 50
	list.ScrollBarThickness = 4
	list.ScrollBarImageColor3 = Theme.Stroke
	list.CanvasSize = UDim2.new(0, 0, 0, #options * 28)
	list.AutomaticCanvasSize = Enum.AutomaticSize.Y
	list.ClipsDescendants = true
	list.Active = true
	list.Parent = MainGui

	local lc = trackInstance(Instance.new("UICorner"))
	lc.CornerRadius = UDim.new(0, 6)
	lc.Parent = list

	local lst = trackInstance(Instance.new("UIStroke"))
	lst.Color = Theme.Stroke
	lst.Thickness = 1
	lst.Transparency = 0.3
	lst.Parent = list

	local ll = trackInstance(Instance.new("UIListLayout"))
	ll.Parent = list

	-- ---- 开关列表 ----
	local renderConn = nil
	local closeList, openList

	closeList = function()
		list.Visible = false
		catcher.Visible = false
		container.ZIndex = 1
		if renderConn then
			renderConn:Disconnect()
			renderConn = nil
		end
	end

	openList = function()
		-- 立即设置位置和尺寸, 不等 RenderStepped
		local cPos  = container.AbsolutePosition
		local cSize = container.AbsoluteSize
		list.Position = UDim2.fromOffset(cPos.X + 6, cPos.Y + 38)
		list.Size = UDim2.new(0, cSize.X - 12, 0, listHeight)
		list.Visible = true
		catcher.Visible = true
		container.ZIndex = 10
		-- 持续更新位置 (窗口可能被拖动)
		if renderConn then renderConn:Disconnect() end
		renderConn = RunService.RenderStepped:Connect(function()
			local ok = pcall(function()
				if not list.Visible then return end
				local cp = container.AbsolutePosition
				local cs = container.AbsoluteSize
				list.Position = UDim2.fromOffset(cp.X + 6, cp.Y + 38)
				list.Size = UDim2.new(0, cs.X - 12, 0, listHeight)
			end)
			if not ok and renderConn then
				renderConn:Disconnect()
				renderConn = nil
			end
		end)
		trackConnection(renderConn)
	end

	-- 点击外部关闭 (由透明全屏按钮处理)
	trackConnection(catcher.MouseButton1Click:Connect(function()
		closeList()
	end))

	-- 创建选项按钮
	local function createOptionButton(opt)
		local b = trackInstance(Instance.new("TextButton"))
		b.Size = UDim2.new(1, 0, 0, 28)
		b.BackgroundColor3 = Theme.Element
		b.Text = "  " .. opt
		b.TextColor3 = Theme.Text
		b.Font = FontMain
		b.TextSize = 13
		b.TextXAlignment = Enum.TextXAlignment.Left
		b.AutoButtonColor = false
		b.BorderSizePixel = 0
		b.ZIndex = 51
		trackConnection(b.MouseEnter:Connect(function() b.BackgroundColor3 = Theme.Hover end))
		trackConnection(b.MouseLeave:Connect(function() b.BackgroundColor3 = Theme.Element end))
		trackConnection(b.MouseButton1Click:Connect(function()
			valLbl.Text = opt
			closeList()
			task.spawn(callback, opt)
		end))
		b.Parent = list
	end

	for _, opt in ipairs(options) do
		createOptionButton(opt)
	end

	trackConnection(container.MouseButton1Click:Connect(function()
		if list.Visible then closeList() else openList() end
	end))

	-- 页面隐藏时自动关闭
	trackConnection(parent:GetPropertyChangedSignal("Visible"):Connect(function()
		if not parent.Visible then closeList() end
	end))

	-- 设置选项 (配置加载用)
	local function setOption(opt)
		for _, o in ipairs(options) do
			if o == opt then
				valLbl.Text = opt
				task.spawn(callback, opt)
				return
			end
		end
	end

	container.Parent = parent
	-- 刷新选项列表
	local function refresh(newOptions)
		-- 清空旧选项按钮
		for _, child in ipairs(list:GetChildren()) do
			if child:IsA("TextButton") then
				child:Destroy()
			end
		end
		options = newOptions
		listHeight = math.min(#options * 28, MAX_LIST_HEIGHT)
		list.CanvasSize = UDim2.new(0, 0, 0, #options * 28)
		for _, opt in ipairs(options) do
			createOptionButton(opt)
		end
	end
	if configKey then
		ConfigControls[#ConfigControls + 1] = {
			key = configKey,
			get = function() return valLbl.Text end,
			apply = function(v) setOption(v) end,
		}
	end
	return {container = container, refresh = refresh, valLbl = valLbl, setOption = setOption}
end

-- 普通按钮
local function makeButton(parent, text, callback)
	local btn = trackInstance(Instance.new("TextButton"))
	btn.Size = UDim2.new(1, -5, 0, 34)
	btn.BackgroundColor3 = Theme.AccentDark
	btn.Text = text
	btn.TextColor3 = Theme.Text
	btn.Font = FontBold
	btn.TextSize = 13
	btn.AutoButtonColor = false
	btn.BorderSizePixel = 0
	local bc = trackInstance(Instance.new("UICorner"))
	bc.CornerRadius = UDim.new(0, 6)
	bc.Parent = btn
	trackConnection(btn.MouseButton1Click:Connect(function() task.spawn(callback) end))
	trackConnection(btn.MouseEnter:Connect(function() btn.BackgroundColor3 = Theme.Accent end))
	trackConnection(btn.MouseLeave:Connect(function() btn.BackgroundColor3 = Theme.AccentDark end))
	btn.Parent = parent
	return btn
end

--========================================================
-- 2. 透视模块 (ESP)
--========================================================
local function getCharacter(player)
	return player and player.Character
end
local function getTargetPart(player, partName)
	local c = getCharacter(player)
	if not c then return nil end
	if partName == "Head" then
		return c:FindFirstChild("Head")
	elseif partName == "Body" then
		return c:FindFirstChild("HumanoidRootPart")
			or c:FindFirstChild("Torso")
			or c:FindFirstChild("UpperTorso")
	end
	return c:FindFirstChild(partName)
end
local function isAlive(player)
	local c = getCharacter(player)
	local h = c and c:FindFirstChildOfClass("Humanoid")
	if not h then return false end
	if h.Health <= 0 then return false end
	-- 活体检测: Humanoid 状态为 Dead 则不算存活
	if State.aliveCheck then
		local ok, state = pcall(function() return h:GetState() end)
		if ok and state == Enum.HumanoidStateType.Dead then
			return false
		end
	end
	return true
end

-- 清理单个玩家的 ESP 对象
local function clearEspFor(player)
	local obj = Runtime.espObjects[player]
	if obj then
		if obj.highlight then obj.highlight:Destroy() end
		if obj.box then obj.box:Destroy() end
		if obj.antenna then obj.antenna:Destroy() end
		if obj.nameGui then obj.nameGui:Destroy() end
		if obj.nickGui then obj.nickGui:Destroy() end
		if obj.skeleton then
			for _, inst in ipairs(obj.skeleton) do inst:Destroy() end
			obj.skeleton = nil
		end
		Runtime.espObjects[player] = nil
	end
end

-- 为玩家创建/刷新 ESP 对象
local function ensureEspFor(player)
	if player == LocalPlayer then return end
	local c = getCharacter(player)
	if not c then return end
	if not isAlive(player) then return end

	local obj = Runtime.espObjects[player]
	if not obj then
		obj = {}
		Runtime.espObjects[player] = obj
	end

	-- ESP 高亮 (chams 透视)
	if State.espEnabled and not obj.highlight then
		local h = trackInstance(Instance.new("Highlight"))
		h.Adornee = c
		h.FillColor = Theme.Accent
		h.FillTransparency = 0.6
		h.OutlineColor = Theme.Text
		h.OutlineTransparency = 0
		h.Parent = c
		obj.highlight = h
	end

	-- 方框 (屏幕空间, 用 OverlayGui 里的 Frame)
	if State.boxEnabled and not obj.box then
		local f = trackInstance(Instance.new("Frame"))
		f.BackgroundColor3 = Color3.new(0,0,0)
		f.BackgroundTransparency = 1
		f.BorderSizePixel = 0
		local s = trackInstance(Instance.new("UIStroke"))
		s.Color = Theme.Accent
		s.Thickness = 1.5
		s.Parent = f
		f.Visible = false
		f.Parent = OverlayGui
		obj.box = f
		obj.boxStroke = s
	end

	-- 天线 (屏幕空间线: 头部 → 屏幕正上方顶端)
	if State.antennaEnabled and not obj.antenna then
		local f = trackInstance(Instance.new("Frame"))
		f.BackgroundColor3 = Theme.Accent
		f.BorderSizePixel = 0
		f.AnchorPoint = Vector2.new(0.5, 0.5)
		f.Visible = false
		f.Parent = OverlayGui
		obj.antenna = f
	end

	-- 骨骼透视 (屏幕空间线条, 始终显示在最上层)
	if State.skeletonEnabled and not obj.skeleton then
		obj.skeleton = {}
		obj.skeletonLines = {}
		-- R15 骨骼连接表
		local r15Bones = {
			{"Head", "UpperTorso"},
			{"UpperTorso", "LowerTorso"},
			{"UpperTorso", "LeftUpperArm"},
			{"LeftUpperArm", "LeftLowerArm"},
			{"LeftLowerArm", "LeftHand"},
			{"UpperTorso", "RightUpperArm"},
			{"RightUpperArm", "RightLowerArm"},
			{"RightLowerArm", "RightHand"},
			{"LowerTorso", "LeftUpperLeg"},
			{"LeftUpperLeg", "LeftLowerLeg"},
			{"LeftLowerLeg", "LeftFoot"},
			{"LowerTorso", "RightUpperLeg"},
			{"RightUpperLeg", "RightLowerLeg"},
			{"RightLowerLeg", "RightFoot"},
		}
		-- R6 骨骼连接表
		local r6Bones = {
			{"Head", "Torso"},
			{"Torso", "Left Arm"},
			{"Torso", "Right Arm"},
			{"Torso", "Left Leg"},
			{"Torso", "Right Leg"},
		}
		local isR15 = c:FindFirstChild("UpperTorso") ~= nil
		local bones = isR15 and r15Bones or r6Bones
		for _, pair in ipairs(bones) do
			local p0 = c:FindFirstChild(pair[1])
			local p1 = c:FindFirstChild(pair[2])
			if p0 and p1 then
				-- 存储骨骼节点对, 每帧投影到屏幕
				table.insert(obj.skeletonLines, {part0 = p0, part1 = p1})
				-- 为每条线创建一个 Frame (屏幕空间)
				local line = trackInstance(Instance.new("Frame"))
				line.BackgroundColor3 = Theme.Accent
				line.BorderSizePixel = 0
				line.AnchorPoint = Vector2.new(0.5, 0.5)
				line.Visible = false
				line.Parent = OverlayGui
				table.insert(obj.skeleton, line)
			end
		end
	end

	-- 用户名 BillboardGui
	if State.nameEnabled and not obj.nameGui then
		local head = c:FindFirstChild("Head")
		if head then
			local bg = trackInstance(Instance.new("BillboardGui"))
			bg.Adornee = head
			bg.Size = UDim2.fromOffset(200, 30)
			bg.StudsOffset = Vector3.new(0, 3, 0)
			bg.AlwaysOnTop = true
			bg.Parent = head
			local tl = trackInstance(Instance.new("TextLabel"))
			tl.Size = UDim2.new(1, 0, 1, 0)
			tl.BackgroundTransparency = 1
			tl.Text = player.Name
			tl.TextColor3 = Theme.Text
			tl.Font = FontBold
			tl.TextSize = 14
			tl.TextStrokeTransparency = 0.2
			tl.TextStrokeColor3 = Color3.new(0,0,0)
			tl.Parent = bg
			obj.nameGui = bg
		end
	end

	-- 昵称 BillboardGui
	if State.nickEnabled and not obj.nickGui then
		local head = c:FindFirstChild("Head")
		if head then
			local bg = trackInstance(Instance.new("BillboardGui"))
			bg.Adornee = head
			bg.Size = UDim2.fromOffset(200, 30)
			bg.StudsOffset = Vector3.new(0, 5, 0)
			bg.AlwaysOnTop = true
			bg.Parent = head
			local tl = trackInstance(Instance.new("TextLabel"))
			tl.Size = UDim2.new(1, 0, 1, 0)
			tl.BackgroundTransparency = 1
			tl.Text = player.DisplayName
			tl.TextColor3 = Theme.Accent
			tl.Font = FontBold
			tl.TextSize = 14
			tl.TextStrokeTransparency = 0.2
			tl.TextStrokeColor3 = Color3.new(0,0,0)
			tl.Parent = bg
			obj.nickGui = bg
		end
	end
end

-- 根据当前开关重建所有 ESP
local function rebuildEsp()
	for _, p in ipairs(Players:GetPlayers()) do
		-- 先按"关"清理需要关掉的, 保留需要开着的
		local obj = Runtime.espObjects[p]
		if obj then
			if not State.espEnabled and obj.highlight then obj.highlight:Destroy(); obj.highlight = nil end
			if not State.boxEnabled and obj.box then obj.box:Destroy(); obj.box = nil end
			if not State.antennaEnabled and obj.antenna then
				obj.antenna:Destroy(); obj.antenna = nil
			end
			if not State.nameEnabled and obj.nameGui then obj.nameGui:Destroy(); obj.nameGui = nil end
			if not State.nickEnabled and obj.nickGui then obj.nickGui:Destroy(); obj.nickGui = nil end
			if not State.skeletonEnabled and obj.skeleton then
				for _, inst in ipairs(obj.skeleton) do inst:Destroy() end
				obj.skeleton = nil
			end
		end
		ensureEspFor(p)
	end
end

local function sameTeam(p)
	if not State.teamCheck then return false end
	return p.Team == LocalPlayer.Team and LocalPlayer.Team ~= nil
end

-- 方框每帧更新 (屏幕空间投影) — 不含清理逻辑, 清理在 updateEsp 中统一处理
local function updateBoxes()
	for player, obj in pairs(Runtime.espObjects) do
		if obj.box and State.boxEnabled then
			local c = getCharacter(player)
			local root = c and c:FindFirstChild("HumanoidRootPart")
			local head = c and c:FindFirstChild("Head")
			local hum = c and c:FindFirstChildOfClass("Humanoid")
			if root and head and hum and hum.Health > 0 then
				local topPos = head.Position + Vector3.new(0, 1, 0)
				local botPos = root.Position - Vector3.new(0, 3, 0)
				local topScreen, topOn = Camera:WorldToViewportPoint(topPos)
				local botScreen, botOn = Camera:WorldToViewportPoint(botPos)
				if topOn and botOn and topScreen.Z > 0 then
					local h = math.abs(botScreen.Y - topScreen.Y)
					local w = h * 0.55
					local cx = (topScreen.X + botScreen.X) / 2
					local cy = (topScreen.Y + botScreen.Y) / 2
					obj.box.Size = UDim2.fromOffset(w, h)
					obj.box.Position = UDim2.fromOffset(cx - w/2, cy - h/2)
					obj.box.Visible = true
				else
					obj.box.Visible = false
				end
			else
				obj.box.Visible = false
			end
		end
	end
end

-- 天线每帧更新 (屏幕空间线: 头部 → 屏幕正上方顶端) — 不含清理逻辑
local function updateAntennas()
	for player, obj in pairs(Runtime.espObjects) do
		if obj.antenna and State.antennaEnabled then
			local c = getCharacter(player)
			local head = c and c:FindFirstChild("Head")
			local hum = c and c:FindFirstChildOfClass("Humanoid")
			if head and hum and hum.Health > 0 then
				local sp, onScreen = Camera:WorldToViewportPoint(head.Position)
				if onScreen and sp.Z > 0 then
					local headX = sp.X
					local headY = sp.Y
					local topX = Camera.ViewportSize.X / 2
					local topY = 0
					local dx = topX - headX
					local dy = topY - headY
					local len = math.sqrt(dx*dx + dy*dy)
					local angle = math.deg(math.atan2(dy, dx))
					local midX = (headX + topX) / 2
					local midY = (headY + topY) / 2
					obj.antenna.Position = UDim2.fromOffset(midX, midY)
					obj.antenna.Size = UDim2.fromOffset(len, 1)
					obj.antenna.Rotation = angle
					obj.antenna.BackgroundColor3 = sameTeam(player) and Theme.Green or Theme.Red
					obj.antenna.Visible = true
				else
					obj.antenna.Visible = false
				end
			else
				obj.antenna.Visible = false
			end
		end
	end
end

-- 骨骼每帧更新 (屏幕空间线条投影)
local function updateSkeletons()
	for player, obj in pairs(Runtime.espObjects) do
		if obj.skeleton and obj.skeletonLines and State.skeletonEnabled then
			local c = getCharacter(player)
			local hum = c and c:FindFirstChildOfClass("Humanoid")
			local isTeammate = sameTeam(player)
			local skelColor = isTeammate and Theme.Green or Theme.Red
			if hum and hum.Health > 0 then
				for i, lineData in ipairs(obj.skeletonLines) do
					local line = obj.skeleton[i]
					if not line then break end
					local p0 = lineData.part0
					local p1 = lineData.part1
					-- 确保部件仍然存在
					if p0 and p0.Parent and p1 and p1.Parent then
						local sp0, on0 = Camera:WorldToViewportPoint(p0.Position)
						local sp1, on1 = Camera:WorldToViewportPoint(p1.Position)
						if on0 and on1 and sp0.Z > 0 and sp1.Z > 0 then
							local dx = sp1.X - sp0.X
							local dy = sp1.Y - sp0.Y
							local len = math.sqrt(dx*dx + dy*dy)
							local angle = math.deg(math.atan2(dy, dx))
							local midX = (sp0.X + sp1.X) / 2
							local midY = (sp0.Y + sp1.Y) / 2
							line.Position = UDim2.fromOffset(midX, midY)
							line.Size = UDim2.fromOffset(len, 1)
							line.Rotation = angle
							line.BackgroundColor3 = skelColor
							line.Visible = true
						else
							line.Visible = false
						end
					else
						line.Visible = false
					end
				end
			else
				for _, line in ipairs(obj.skeleton) do
					line.Visible = false
				end
			end
		end
	end
end

-- 统一 ESP 清理 + 颜色更新 (合并为一次遍历, 玩家离开检测降频)
local espFrameCount = 0
local function updateEsp()
	espFrameCount = espFrameCount + 1
	-- 每 30 帧检查一次玩家是否还在游戏中 (不需要每帧查)
	local checkInGame = (espFrameCount % 30 == 0)

	for p, obj in pairs(Runtime.espObjects) do
		local c = getCharacter(p)
		local hum = c and c:FindFirstChildOfClass("Humanoid")
		local alive = hum and hum.Health > 0

		-- 降频: 玩家离开检测
		if checkInGame and not Players:FindFirstChild(p.Name) then
			if obj.highlight then obj.highlight:Destroy(); obj.highlight = nil end
			if obj.box then obj.box:Destroy(); obj.box = nil end
			if obj.boxStroke then obj.boxStroke = nil end
			if obj.antenna then obj.antenna:Destroy(); obj.antenna = nil end
			if obj.nameGui then obj.nameGui:Destroy(); obj.nameGui = nil end
			if obj.nickGui then obj.nickGui:Destroy(); obj.nickGui = nil end
			if obj.skeleton then
				for _, inst in ipairs(obj.skeleton) do inst:Destroy() end
				obj.skeleton = nil
			end
		end

		-- 每帧: 死亡或功能关闭 → 清理对应 ESP
		if not alive or not State.espEnabled then
			if obj.highlight then obj.highlight:Destroy(); obj.highlight = nil end
		end
		if not alive or not State.boxEnabled then
			if obj.box then obj.box:Destroy(); obj.box = nil end
			if obj.boxStroke then obj.boxStroke = nil end
		end
		if not alive or not State.antennaEnabled then
			if obj.antenna then obj.antenna:Destroy(); obj.antenna = nil end
		end
		if not alive or not State.nameEnabled then
			if obj.nameGui then obj.nameGui:Destroy(); obj.nameGui = nil end
		end
		if not alive or not State.nickEnabled then
			if obj.nickGui then obj.nickGui:Destroy(); obj.nickGui = nil end
		end
		if not alive or not State.skeletonEnabled then
			if obj.skeleton then
				for _, inst in ipairs(obj.skeleton) do inst:Destroy() end
				obj.skeleton = nil
			end
		end

		-- 高亮颜色更新
		if obj.highlight then
			if sameTeam(p) then
				obj.highlight.FillColor = Theme.Green
				obj.highlight.OutlineColor = Theme.Green
			else
				obj.highlight.FillColor = Theme.Accent
				obj.highlight.OutlineColor = Theme.Text
			end
		end
		if obj.boxStroke then
			obj.boxStroke.Color = sameTeam(p) and Theme.Green or Theme.Accent
		end
	end
end

-- 玩家加入/离开 / 角色重生 处理
local function hookPlayer(player)
	trackConnection(player.CharacterAdded:Connect(function()
		task.wait(0.3)
		-- 角色重生时清理旧 ESP 引用 (旧实例已随角色销毁, 但引用残留)
		local obj = Runtime.espObjects[player]
		if obj then
			obj.highlight = nil
			obj.box = nil
			obj.boxStroke = nil
			obj.antenna = nil
			obj.nameGui = nil
		end
		ensureEspFor(player)
	end))
	ensureEspFor(player)
end
for _, p in ipairs(Players:GetPlayers()) do hookPlayer(p) end
trackConnection(Players.PlayerAdded:Connect(hookPlayer))
trackConnection(Players.PlayerRemoving:Connect(function(p) clearEspFor(p) end))

-- 玩家数量显示 HUD
local CountLabel
-- 灵动岛时间标签 (前向声明, 在灵动岛创建时赋值)
local IslandTimeLabel
-- 灵动岛按钮 (前向声明, 在灵动岛创建时赋值)
local ExpandButton
do
	CountLabel = trackInstance(Instance.new("TextLabel"))
	CountLabel.Size = UDim2.fromOffset(220, 24)
	CountLabel.AnchorPoint = Vector2.new(0.5, 0)
	CountLabel.Position = UDim2.new(0.5, 0, 0, 40)
	CountLabel.ZIndex = 0
	CountLabel.BackgroundTransparency = 1
	CountLabel.TextColor3 = Color3.fromRGB(255, 80, 80)
	CountLabel.Font = FontBold
	CountLabel.TextSize = 12
	CountLabel.Text = "Players: 0"
	CountLabel.Parent = MainGui
end

--========================================================
-- 3. 移动模块
--========================================================
local function getLocalChar()
	return LocalPlayer.Character
end

-- 移速: 开关关闭时恢复默认, 打开时使用参数值
local function applyWalkSpeed()
	local c = getLocalChar()
	local h = c and c:FindFirstChildOfClass("Humanoid")
	if h then
		h.WalkSpeed = State.speedEnabled and State.walkSpeed or DEFAULT_WALKSPEED
	end
end
trackConnection(LocalPlayer.CharacterAdded:Connect(function()
	task.wait(0.5)
	applyWalkSpeed()
	if State.flyEnabled then setFly(true) end
	if State.noclipEnabled then setNoclip(true) end
	if State.orbitEnabled then setOrbit(true) end
	if State.spinEnabled then setSpin(true) end
end))

-- 无限跳: 监听跳跃请求, 无论是否在地面都允许跳跃
local infJumpConn = nil
local function setupInfJump()
	if infJumpConn then infJumpConn:Disconnect(); infJumpConn = nil end
	local hum = LocalPlayer.Character and LocalPlayer.Character:FindFirstChildOfClass("Humanoid")
	if not hum then return end
	infJumpConn = UserInputService.JumpRequest:Connect(function()
		if State.infJumpEnabled then
			hum:ChangeState(Enum.HumanoidStateType.Jumping)
		end
	end)
	trackConnection(infJumpConn)
end

trackConnection(LocalPlayer.CharacterAdded:Connect(function()
	task.wait(0.5)
	setupInfJump()
end))

-- 初始化无限跳 (如果角色已存在)
task.spawn(function()
	task.wait(0.5)
	setupInfJump()
end)

-- 秒交互: 将所有 ProximityPrompt 的 HoldDuration 改为 0
local promptConn = nil
local originalPrompts = {}  -- 记录原始 HoldDuration
setInstantPrompt = function(on)
	State.promptInstantEnabled = on
	if on then
		-- 处理已存在的 ProximityPrompt
		for _, desc in ipairs(workspace:GetDescendants()) do
			if desc:IsA("ProximityPrompt") then
				if originalPrompts[desc] == nil then
					originalPrompts[desc] = desc.HoldDuration
				end
				desc.HoldDuration = 0
			end
		end
		-- 监听新添加的 ProximityPrompt
		promptConn = workspace.DescendantAdded:Connect(function(desc)
			if desc:IsA("ProximityPrompt") then
				if originalPrompts[desc] == nil then
					originalPrompts[desc] = desc.HoldDuration
				end
				desc.HoldDuration = 0
			end
		end)
		trackConnection(promptConn)
	else
		if promptConn then
			promptConn:Disconnect()
			promptConn = nil
		end
		-- 恢复原始 HoldDuration
		for prompt, orig in pairs(originalPrompts) do
			if prompt.Parent then
				prompt.HoldDuration = orig
			end
		end
		originalPrompts = {}
	end
end

--====================================================
-- 聊天翻译: 拦截聊天消息, 调用 Google 翻译 API 后显示译文
--====================================================
local HttpService     = game:GetService("HttpService")
local TextChatService = game:GetService("TextChatService")
local StarterGui      = game:GetService("StarterGui")

local chatTranslateConns = {}

-- 目标语言 → API 语言代码
local LangCode = {
	["中文"]         = "zh-CN",
	["English"]      = "en",
	["日本語"]       = "ja",
	["한국어"]       = "ko",
	["Français"]     = "fr",
	["Español"]      = "es",
	["Deutsch"]      = "de",
	["Português"]    = "pt",
	["Русский"]      = "ru",
	["Italiano"]     = "it",
	["العربية"]      = "ar",
	["हिन्दी"]         = "hi",
	["Tiếng Việt"]   = "vi",
	["ไทย"]          = "th",
	["Türkçe"]       = "tr",
	["Nederlands"]   = "nl",
	["Polski"]       = "pl",
	["Indonesia"]    = "id",
	["Українська"]   = "uk",
	["čeština"]      = "cs",
}

-- 显示浮动提示 (Toast)
local function showToast(text)
	local toast = Instance.new("Frame")
	toast.Name = "Toast"
	toast.Size = UDim2.fromOffset(320, 60)
	toast.Position = UDim2.new(0.5, -160, 0, -80)
	toast.AnchorPoint = Vector2.new(0, 0)
	toast.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	toast.BackgroundTransparency = 0.4
	toast.BorderSizePixel = 0
	local tc = Instance.new("UICorner")
	tc.CornerRadius = UDim.new(0, 8)
	tc.Parent = toast
	local ts = Instance.new("UIStroke")
	ts.Color = Color3.fromRGB(255, 255, 255)
	ts.Thickness = 1
	ts.Transparency = 0.3
	ts.Parent = toast
	-- 文字标签 (背景透明, 不影响框的描边)
	local label = Instance.new("TextLabel")
	label.Size = UDim2.new(1, -16, 1, -8)
	label.Position = UDim2.fromOffset(8, 4)
	label.BackgroundTransparency = 1
	label.Text = text
	label.TextColor3 = Color3.fromRGB(255, 255, 255)
	label.Font = Enum.Font.GothamBold
	label.TextSize = 14
	label.TextWrapped = true
	label.BorderSizePixel = 0
	label.Parent = toast
	toast.Parent = MainGui
	-- 动画: 从上滑入
	toast.Position = UDim2.new(0.5, -160, 0, -80)
	-- TweenService 平滑下滑 + 停留 + 上滑消失
	local TweenService = game:GetService("TweenService")
	local tweenDown = TweenService:Create(toast, TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Position = UDim2.new(0.5, -160, 0, 20),
	})
	tweenDown:Play()
	tweenDown.Completed:Connect(function()
		-- 停留 1.5 秒
		task.delay(1.5, function()
			if not toast.Parent then return end
			local tweenUp = TweenService:Create(toast, TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
				Position = UDim2.new(0.5, -160, 0, -80),
			})
			tweenUp:Play()
			tweenUp.Completed:Connect(function()
				toast:Destroy()
			end)
		end)
	end)
	-- 安全超时清理 (5 秒后强制删除)
	task.delay(5, function()
		if toast and toast.Parent then toast:Destroy() end
	end)
end

-- 二次确认弹窗
local function showConfirmDialog(message, onConfirm)
	local overlay = Instance.new("Frame")
	overlay.Name = "ConfirmOverlay"
	overlay.Size = UDim2.fromScale(1, 1)
	overlay.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	overlay.BackgroundTransparency = 0.5
	overlay.BorderSizePixel = 0
	overlay.ZIndex = 100
	overlay.Parent = MainGui

	local dialog = Instance.new("Frame")
	dialog.Name = "ConfirmDialog"
	dialog.Size = UDim2.fromOffset(340, 160)
	dialog.Position = UDim2.new(0.5, -170, 0.5, -80)
	dialog.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
	dialog.BorderSizePixel = 0
	dialog.ZIndex = 101
	dialog.Parent = overlay

	local dc = Instance.new("UICorner")
	dc.CornerRadius = UDim.new(0, 10)
	dc.Parent = dialog

	local ds = Instance.new("UIStroke")
	ds.Color = Color3.fromRGB(255, 255, 255)
	ds.Thickness = 1
	ds.Transparency = 0.5
	ds.Parent = dialog

	local msg = Instance.new("TextLabel")
	msg.Size = UDim2.new(1, -24, 1, -64)
	msg.Position = UDim2.fromOffset(12, 12)
	msg.BackgroundTransparency = 1
	msg.Text = message
	msg.TextColor3 = Color3.fromRGB(255, 255, 255)
	msg.Font = Enum.Font.GothamBold
	msg.TextSize = 15
	msg.TextWrapped = true
	msg.TextXAlignment = Enum.TextXAlignment.Center
	msg.TextYAlignment = Enum.TextYAlignment.Center
	msg.ZIndex = 102
	msg.Parent = dialog

	local btnNo = Instance.new("TextButton")
	btnNo.Size = UDim2.new(0.5, -16, 0, 36)
	btnNo.Position = UDim2.new(0, 8, 1, -44)
	btnNo.BackgroundColor3 = Color3.fromRGB(60, 60, 60)
	btnNo.Text = "取消"
	btnNo.TextColor3 = Color3.fromRGB(255, 255, 255)
	btnNo.Font = Enum.Font.GothamBold
	btnNo.TextSize = 14
	btnNo.BorderSizePixel = 0
	btnNo.ZIndex = 102
	btnNo.Parent = dialog

	local btnNoCorner = Instance.new("UICorner")
	btnNoCorner.CornerRadius = UDim.new(0, 6)
	btnNoCorner.Parent = btnNo

	local btnYes = Instance.new("TextButton")
	btnYes.Size = UDim2.new(0.5, -16, 0, 36)
	btnYes.Position = UDim2.new(0.5, 8, 1, -44)
	btnYes.BackgroundColor3 = Color3.fromRGB(200, 50, 50)
	btnYes.Text = "确认删除"
	btnYes.TextColor3 = Color3.fromRGB(255, 255, 255)
	btnYes.Font = Enum.Font.GothamBold
	btnYes.TextSize = 14
	btnYes.BorderSizePixel = 0
	btnYes.ZIndex = 102
	btnYes.Parent = dialog

	local btnYesCorner = Instance.new("UICorner")
	btnYesCorner.CornerRadius = UDim.new(0, 6)
	btnYesCorner.Parent = btnYes

	local function close()
		if overlay.Parent then overlay:Destroy() end
	end

	btnNo.MouseButton1Click:Connect(close)
	btnYes.MouseButton1Click:Connect(function()
		close()
		if onConfirm then onConfirm() end
	end)
end

-- 兼容多种执行器的 HTTP 请求
local function httpRequest(url)
	-- 优先使用执行器自带 HTTP
	local ok, result = pcall(function()
		if http_request then
			return http_request({ Url = url, Method = "GET" })
		elseif syn and syn.request then
			return syn.request({ Url = url, Method = "GET" })
		elseif request then
			return request({ Url = url, Method = "GET" })
		end
		error("no executor http")
	end)
	if ok and result then
		if type(result) == "string" then return result end
		if result.Body  then return result.Body end
		if result.body  then return result.body end
	end
	-- 回退到 HttpService (需游戏开启 HTTP 请求)
	local ok2, res2 = pcall(function() return HttpService:GetAsync(url) end)
	if ok2 then return res2 end
	return nil
end

-- 翻译单条文本
local function translateText(text, targetLang)
	local code = LangCode[targetLang] or "zh-CN"
	local q    = HttpService:UrlEncode(text)
	local url  = "https://translate.googleapis.com/translate_a/single?client=gtx&sl=auto&tl=" .. code .. "&dt=t&q=" .. q
	local body = httpRequest(url)
	if not body then return nil end
	local ok, data = pcall(function() return HttpService:JSONDecode(body) end)
	if not ok or not data or not data[1] then return nil end
	local parts = {}
	for _, seg in ipairs(data[1]) do
		if seg[1] then table.insert(parts, seg[1]) end
	end
	return #parts > 0 and table.concat(parts) or nil
end

-- 显示翻译结果到聊天框 (兼容新旧聊天系统)
local function showTranslation(speaker, translated)
	local text = "🌐 [" .. speaker .. "] " .. translated
	-- 尝试新版 TextChatService
	local done = pcall(function()
		local channels = TextChatService:FindFirstChild("TextChannels")
		if channels then
			local ch = channels:FindFirstChild("RBXGeneral") or channels:FindFirstChildOfClass("TextChannel")
			if ch then
				ch:DisplaySystemMessage(text)
				return
			end
		end
		error("no textchat channel")
	end)
	-- 回退到旧版系统消息
	if not done then
		pcall(function()
			StarterGui:SetCore("ChatMakeSystemMessage", {
				Text     = text,
				Color    = Color3.fromRGB(100, 200, 255),
				Font     = Enum.Font.SourceSansSemibold,
				TextSize = 18,
			})
		end)
	end
end

-- 发送文本到聊天框 (作为玩家消息发送, 兼容新旧聊天系统)
local function sendChatMessage(text)
	if not text or text == "" then return end
	-- 1) 新版 TextChatService: SendAsync
	local ok1 = pcall(function()
		local channels = TextChatService:FindFirstChild("TextChannels")
		if channels then
			local ch = channels:FindFirstChild("RBXGeneral") or channels:FindFirstChildOfClass("TextChannel")
			if ch then
				ch:SendAsync(text)
				return true
			end
		end
		error("no textchat channel")
	end)
	if ok1 then return end
	-- 2) 旧版聊天: StarterGui SetCore "ChatSend" (部分游戏支持)
	local ok2 = pcall(function()
		StarterGui:SetCore("ChatSend", text)
	end)
	if ok2 then return end
	-- 3) 旧版聊天: 触发 DefaultChatAlias (部分执行器支持)
	local ok3 = pcall(function()
		if TextChatService then
			TextChatService:SendAsync(text)
		end
	end)
	if ok3 then return end
	-- 4) 最终回退: 本地玩家 Humanoid.Chat (仅本地可见)
	pcall(function()
		local char = LocalPlayer.Character
		if char then
			local hum = char:FindFirstChildOfClass("Humanoid")
			if hum then
				hum:Chat(text)
			end
		end
	end)
end

-- 处理一条聊天消息
local function handleChatMessage(speakerName, message, userId)
	if not State.chatTranslateEnabled then return end
	if not message or message == "" then return end
	-- 跳过自己的消息
	if userId and userId == LocalPlayer.UserId then return end
	task.spawn(function()
		local translated = translateText(message, State.translateTargetLang or "中文")
		if translated and translated ~= message then
			showTranslation(speakerName, translated)
		end
	end)
end

setChatTranslation = function(on)
	State.chatTranslateEnabled = on
	if on then
		-- 1) 新版 TextChatService
		local ok1 = pcall(function()
			local conn = TextChatService.MessageReceived:Connect(function(msg)
				local ts = msg.TextSource
				if not ts then return end                 -- 系统消息跳过
				-- 优先用 DisplayName, 回退到用户名
				local displayName = ts.Name
				local p = Players:GetPlayerByUserId(ts.UserId)
				if p then displayName = p.DisplayName end
				handleChatMessage(displayName, msg.Text, ts.UserId)
			end)
			table.insert(chatTranslateConns, conn)
			trackConnection(conn)
		end)

		-- 2) 旧版聊天: 监听所有玩家 Humanoid.Chatted
		local function hookPlayer(player)
			if player == LocalPlayer then return end
			local function onChar(char)
				local hum = char:FindFirstChildOfClass("Humanoid")
				if not hum then return end
				local conn = hum.Chatted:Connect(function(msg)
					handleChatMessage(player.DisplayName, msg, player.UserId)
				end)
				table.insert(chatTranslateConns, conn)
				trackConnection(conn)
			end
			if player.Character then onChar(player.Character) end
			local c2 = player.CharacterAdded:Connect(onChar)
			table.insert(chatTranslateConns, c2)
			trackConnection(c2)
		end
		for _, p in ipairs(Players:GetPlayers()) do hookPlayer(p) end
		local cAdd = Players.PlayerAdded:Connect(hookPlayer)
		table.insert(chatTranslateConns, cAdd)
		trackConnection(cAdd)

		-- 3) 旧版 Chat Service: 监听 Chat 消息 (捕获 Global 等自定义频道)
		local ok3 = pcall(function()
			local ChatService = game:GetService("Chat")
			-- 监听 Chat.MessageReceived (旧版聊天事件)
			local conn = ChatService.ChildAdded:Connect(function(child)
				if child:IsA("Message") or child:IsA("TextLabel") then
					-- 尝试从消息对象提取发送者和内容
					local msgText = ""
					local speakerName = "Unknown"
					pcall(function()
						if child:GetAttribute("Message") then
							msgText = child:GetAttribute("Message")
						elseif child:GetAttribute("Text") then
							msgText = child:GetAttribute("Text")
						end
						if child:GetAttribute("Speaker") then
							speakerName = child:GetAttribute("Speaker")
						elseif child:GetAttribute("FromSpeaker") then
							speakerName = child:GetAttribute("FromSpeaker")
						end
					end)
					if msgText and msgText ~= "" then
						handleChatMessage(speakerName, msgText, nil)
					end
				end
			end)
			if conn then
				table.insert(chatTranslateConns, conn)
				trackConnection(conn)
			end
		end)

		-- 4) 监听 Player.Chatted (更底层的聊天事件, 捕获所有频道)
		local ok4 = pcall(function()
			for _, p in ipairs(Players:GetPlayers()) do
				if p ~= LocalPlayer then
					local conn = p.Chatted:Connect(function(msg)
						handleChatMessage(p.DisplayName, msg, p.UserId)
					end)
					if conn then
						table.insert(chatTranslateConns, conn)
						trackConnection(conn)
					end
				end
			end
			local cChatAdd = Players.PlayerAdded:Connect(function(p)
				if p == LocalPlayer then return end
				local conn = p.Chatted:Connect(function(msg)
					handleChatMessage(p.DisplayName, msg, p.UserId)
				end)
				if conn then
					table.insert(chatTranslateConns, conn)
					trackConnection(conn)
				end
			end)
			table.insert(chatTranslateConns, cChatAdd)
			trackConnection(cChatAdd)
		end)

		-- HTTP 不可用提示
		if not ok1 and not pcall(function() return http_request or (syn and syn.request) or request or HttpService end) then
			print("[GSEN辅助] 警告: 未检测到可用的 HTTP 函数, 聊天翻译可能无法工作")
		end
	else
		for _, conn in ipairs(chatTranslateConns) do
			if conn and conn.Connected then conn:Disconnect() end
		end
		chatTranslateConns = {}
	end
end

--====================================================
-- 隐身: 将角色所有部件透明度设为 1, 包括配件/面部/装饰
--====================================================
local originalTransparency = {}  -- [part] = 原始透明度
local invisibleConn = nil        -- 监听新添加部件

setInvisible = function(on)
	State.invisibleEnabled = on
	local function applyInvisible(char)
		if not char then return end
		for _, part in ipairs(char:GetDescendants()) do
			if part:IsA("BasePart") then
				-- 记录原始透明度 (仅首次)
				if originalTransparency[part] == nil then
					originalTransparency[part] = part.Transparency
				end
				if on then
					part.Transparency = 1
				else
					part.Transparency = originalTransparency[part] or 0
				end
			elseif part:IsA("Decal") then
				-- 面部贴花等
				if originalTransparency[part] == nil then
					originalTransparency[part] = part.Transparency
				end
				if on then
					part.Transparency = 1
				else
					part.Transparency = originalTransparency[part] or 0
				end
			end
		end
	end

	if on then
		-- 立即对当前角色生效
		applyInvisible(getLocalChar())
		-- 监听角色重生后重新应用
		invisibleConn = LocalPlayer.CharacterAdded:Connect(function(char)
			task.wait(0.3)
			originalTransparency = {}  -- 新角色, 清空旧缓存
			if State.invisibleEnabled then applyInvisible(char) end
		end)
		trackConnection(invisibleConn)
		-- 监听新添加的部件 (如换装)
		local descConn = workspace.DescendantAdded:Connect(function(desc)
			if State.invisibleEnabled and desc:IsA("BasePart") or desc:IsA("Decal") then
				local char = getLocalChar()
				if char and desc:IsDescendantOf(char) then
					if desc:IsA("BasePart") or desc:IsA("Decal") then
						if originalTransparency[desc] == nil then
							originalTransparency[desc] = desc.Transparency
						end
						desc.Transparency = 1
					end
				end
			end
		end)
		trackConnection(descConn)
	else
		-- 恢复所有部件原始透明度
		for part, orig in pairs(originalTransparency) do
			if part.Parent then
				part.Transparency = orig
			end
		end
		originalTransparency = {}
	end
end

--====================================================
-- 锁定血量: 持续将 Humanoid.Health 设为指定值
--====================================================
local godHealthConn = nil

setGodHealth = function(on)
	State.godHealthEnabled = on
	if on then
		local function applyHealth()
			local c = getLocalChar()
			local hum = c and c:FindFirstChildOfClass("Humanoid")
			if hum then
				hum.MaxHealth = State.customHealth
				hum.Health   = State.customHealth
			end
		end
		-- 立即应用一次
		applyHealth()
		-- 持续保持 (每 0.1 秒刷新, 防止受伤后回血)
		godHealthConn = RunService.Heartbeat:Connect(function()
			applyHealth()
		end)
		trackConnection(godHealthConn)
		-- 角色重生后自动重新应用
		local cAdd = LocalPlayer.CharacterAdded:Connect(function()
			task.wait(0.5)
			applyHealth()
		end)
		trackConnection(cAdd)
	else
		if godHealthConn then
			godHealthConn:Disconnect()
			godHealthConn = nil
		end
	end
end

-- 穿墙
setNoclip = function(on)
	State.noclipEnabled = on
	local c = getLocalChar()
	if not c then return end
	if on then
		for _, part in ipairs(c:GetDescendants()) do
			if part:IsA("BasePart") and part.CanCollide then
				Runtime.originalCollide[part] = true
				part.CanCollide = false
			end
		end
	else
		for part in pairs(Runtime.originalCollide) do
			if part.Parent then part.CanCollide = true end
		end
		Runtime.originalCollide = {}
	end
end

-- 飞行
local flyBV, flyBG
setFly = function(on)  -- 定义在此处, 移动标签页与 CharacterAdded 回调均可调用
	State.flyEnabled = on
	local c = getLocalChar()
	if not c then return end
	local hrp = c:FindFirstChild("HumanoidRootPart")
	local hum = c:FindFirstChildOfClass("Humanoid")
	if on and hrp then
		if flyBV then flyBV:Destroy(); flyBV = nil end
		if flyBG then flyBG:Destroy(); flyBG = nil end
		flyBV = trackInstance(Instance.new("BodyVelocity"))
		flyBV.MaxForce = Vector3.new(9e9, 9e9, 9e9)
		flyBV.Velocity = Vector3.zero
		flyBV.Parent = hrp
		flyBG = trackInstance(Instance.new("BodyGyro"))
		flyBG.MaxTorque = Vector3.new(9e9, 9e9, 9e9)
		flyBG.D = 150
		flyBG.P = 8000
		flyBG.CFrame = hrp.CFrame
		flyBG.Parent = hrp
		if hum then hum.PlatformStand = true end
	else
		if flyBV then flyBV:Destroy(); flyBV = nil end
		if flyBG then flyBG:Destroy(); flyBG = nil end
		if hum then hum.PlatformStand = false end
	end
end

-- 飞行输入更新 (兼容键盘 + 手机摇杆, 完全跟随相机方向含俯仰)
local function updateFly(dt)
	if not State.flyEnabled then return end
	local c = getLocalChar()
	if not c then return end
	local hrp = c:FindFirstChild("HumanoidRootPart")
	local hum = c:FindFirstChildOfClass("Humanoid")
	if not hrp or not flyBV then return end

	-- 相机完整朝向 (含俯仰角)
	local camLook = Camera.CFrame.LookVector
	local camRight = Camera.CFrame.RightVector

	local dir = Vector3.zero

	-- Humanoid.MoveDirection: 摇杆/键盘水平输入, 投影到相机完整朝向 (含上下)
	if hum and hum.MoveDirection.Magnitude > 0 then
		local moveDir = hum.MoveDirection
		-- 相机水平前/右方向, 用于解析摇杆的前后左右意图
		local flatLook = Vector3.new(camLook.X, 0, camLook.Z)
		local flatRight = Vector3.new(camRight.X, 0, camRight.Z)
		if flatLook.Magnitude > 0 then flatLook = flatLook.Unit end
		if flatRight.Magnitude > 0 then flatRight = flatRight.Unit end

		local forward = moveDir:Dot(flatLook)   -- 前进/后退意图
		local strafe  = moveDir:Dot(flatRight)  -- 左右意图

		-- 用相机完整朝向 (含俯仰) 计算实际飞行方向
		dir = camLook * forward + camRight * strafe
		if dir.Magnitude > 0 then dir = dir.Unit end
	end

	flyBV.Velocity = dir * State.flySpeed

	-- 角色完全跟随相机方向 (含俯仰), 可上下仰俯
	if camLook.Magnitude > 0 then
		flyBG.CFrame = CFrame.lookAt(hrp.Position, hrp.Position + camLook)
	end
end

-- 穿墙持续保持
local function updateNoclip()
	if not State.noclipEnabled then return end
	local c = getLocalChar()
	if not c then return end
	for _, part in ipairs(c:GetDescendants()) do
		if part:IsA("BasePart") and part.CanCollide then
			part.CanCollide = false
			Runtime.originalCollide[part] = true
		end
	end
end

-- 静默甩飞 (Walkfling) — 基于 Terukuma 开源方案
-- 原理: Stepped 保持 Humanoid 正常状态 + 关闭其他玩家碰撞
--       Heartbeat+RenderStepped 两步: 设极大角速度 + 放大线速度, 下一帧归零
--       角色全速移动, 碰撞时传递极大动量把别人甩飞
local flingStepConn = nil
local flingThread = nil

setFling = function(on)
	State.flingEnabled = on
	if on then
		if flingStepConn then flingStepConn:Disconnect() end
		if flingThread then task.cancel(flingThread) end

		-- Stepped: 保持 Humanoid 正常状态 + 关闭其他玩家碰撞
		flingStepConn = RunService.Stepped:Connect(function()
			if not State.flingEnabled then return end
			local c = getLocalChar()
			if not c then return end
			local hum = c:FindFirstChildOfClass("Humanoid")
			local hrp = c:FindFirstChild("HumanoidRootPart")
			if hum and hrp then
				-- 防僵硬: 保持正常站立状态
				hum.PlatformStand = false
				hum.Sit = false
				hum.AutoRotate = true
				local st = hum:GetState()
				if st == Enum.HumanoidStateType.Physics or
				   st == Enum.HumanoidStateType.FallingDown or
				   st == Enum.HumanoidStateType.Ragdoll then
					hum:ChangeState(Enum.HumanoidStateType.GettingUp)
				end
			end
			-- 关闭其他玩家所有零件的碰撞
			for _, other in ipairs(Players:GetPlayers()) do
				if other ~= LocalPlayer and other.Character then
					for _, part in ipairs(other.Character:GetDescendants()) do
						if part:IsA("BasePart") then
							part.CanCollide = false
						end
					end
				end
			end
		end)

		-- Heartbeat + RenderStepped 两步循环: 设角速度+放大线速度, 下一帧归零
		flingThread = task.spawn(function()
			while State.flingEnabled do
				RunService.Heartbeat:Wait()
				local c = getLocalChar()
				if not c then
					RunService.RenderStepped:Wait()
				elseif c:FindFirstChild("HumanoidRootPart") then
					local hrp = c:FindFirstChild("HumanoidRootPart")
					local hum = c:FindFirstChildOfClass("Humanoid")
					-- 保存当前速度
					local vel = hrp.AssemblyLinearVelocity
					-- 强制 Running 状态
					if hum then hum:ChangeState(Enum.HumanoidStateType.Running) end
					-- 限制 Y 轴速度 ±40 (防止飞起/坠落)
					local safeY = vel.Y
					if safeY > 40 then safeY = 40 end
					if safeY < -40 then safeY = -40 end
					-- 设极大角速度 (产生旋转甩飞力)
					hrp.AssemblyAngularVelocity = Vector3.new(50000, 50000, 50000)
					-- 放大当前线速度 1.1 倍 (保持移动方向, 轻微加速)
					hrp.AssemblyLinearVelocity = Vector3.new(vel.X * 1.1, safeY, vel.Z * 1.1)
					-- 等一帧让物理引擎处理碰撞
					RunService.RenderStepped:Wait()
					-- 归零角速度, 恢复原线速度
					if hrp and hrp.Parent then
						hrp.AssemblyAngularVelocity = Vector3.zero
						hrp.AssemblyLinearVelocity = Vector3.new(vel.X, safeY, vel.Z)
					end
				else
					RunService.RenderStepped:Wait()
				end
			end
		end)
	else
		-- 关闭: 停止所有循环, 归零速度
		if flingStepConn then
			flingStepConn:Disconnect()
			flingStepConn = nil
		end
		if flingThread then
			task.cancel(flingThread)
			flingThread = nil
		end
		local c = getLocalChar()
		if c then
			local hrp = c:FindFirstChild("HumanoidRootPart")
			if hrp then
				hrp.AssemblyAngularVelocity = Vector3.zero
				hrp.AssemblyLinearVelocity = Vector3.zero
			end
		end
	end
end

--========================================================
-- 3.5 环绕模块
--========================================================
setOrbit = function(on)
	State.orbitEnabled = on
	local cam = workspace.CurrentCamera
	local c = getLocalChar()
	local hum = c and c:FindFirstChildOfClass("Humanoid")
	if on then
		-- 开启: PlatformStand 防止重力/移动干扰环绕
		if hum then hum.PlatformStand = true end
		-- 切换摄像机为脚本控制, 避免跟随角色自转
		if cam then
			cam.CameraType = Enum.CameraType.Scriptable
		end
		savedCamOffset = nil  -- 等待 updateOrbit 首帧记录
	else
		-- 关闭: 恢复正常状态, 归零速度防止惯性滑动
		if hum then hum.PlatformStand = false end
		if c then
			local hrp = c:FindFirstChild("HumanoidRootPart")
			if hrp then
				hrp.AssemblyLinearVelocity = Vector3.zero
				hrp.AssemblyAngularVelocity = Vector3.zero
			end
		end
		-- 恢复摄像机为默认跟随模式
		if cam then
			cam.CameraType = Enum.CameraType.Custom
		end
		savedCamOffset = nil
	end
end

-- 环绕每帧更新: 绕目标玩家做水平圆周运动, 角色面向目标, 摄像机固定看向目标
local function updateOrbit(dt)
	if not State.orbitEnabled then return end
	local targetName = State.orbitTarget
	if not targetName or targetName == "(无其他玩家)" or targetName == "(选择玩家)" then return end
	local target = Players:FindFirstChild(targetName)
	if not target or not target.Character then return end
	local targetRoot = target.Character:FindFirstChild("HumanoidRootPart")
	if not targetRoot then return end

	local c = getLocalChar()
	if not c then return end
	local myRoot = c:FindFirstChild("HumanoidRootPart")
	local myHum = c:FindFirstChildOfClass("Humanoid")
	if not myRoot then return end

	-- 角度累加 (速度单位: 弧度/秒)
	orbitAngle = orbitAngle + State.orbitSpeed * dt
	if orbitAngle > math.pi * 2 then
		orbitAngle = orbitAngle - math.pi * 2
	end

	-- 计算环绕位置 (水平圆周, Y 轴与目标齐平)
	local radius = State.orbitRadius
	local targetPos = targetRoot.Position
	local offsetX = math.cos(orbitAngle) * radius
	local offsetZ = math.sin(orbitAngle) * radius
	local orbitPos = targetPos + Vector3.new(offsetX, 0, offsetZ)

	-- 角色位置在轨道上, 并面向目标
	myRoot.CFrame = CFrame.lookAt(orbitPos, targetPos)

	-- 摄像机固定: 首帧记录相对目标的位置偏移, 之后保持位置并始终看向目标
	local cam = workspace.CurrentCamera
	if cam then
		if not savedCamOffset then
			savedCamOffset = cam.CFrame.Position - targetPos
		end
		local camPos = targetPos + savedCamOffset
		cam.CFrame = CFrame.lookAt(camPos, targetPos)
	end

	-- 持续保持 PlatformStand
	if myHum then
		myHum.PlatformStand = true
	end
end

--========================================================
-- 3.6 自旋模块
--========================================================
-- 锚定/取消锚定角色所有部件
local function setCharacterAnchored(char, anchored)
	for _, part in ipairs(char:GetChildren()) do
		if part:IsA("BasePart") then
			part.Anchored = anchored
		end
	end
end

setSpin = function(on)
	State.spinEnabled = on
	local c = getLocalChar()
	local hum = c and c:FindFirstChildOfClass("Humanoid")
	if on then
		-- 开启: PlatformStand + 锚定全身, 防止物理引擎驱动四肢产生虚化
		if hum then hum.PlatformStand = true end
		if c then setCharacterAnchored(c, true) end
		spinYVelocity = 0
	else
		-- 关闭: 取消锚定, 恢复正常状态
		if c then setCharacterAnchored(c, false) end
		if hum then hum.PlatformStand = false end
		if c then
			local hrp = c:FindFirstChild("HumanoidRootPart")
			if hrp then
				hrp.AssemblyLinearVelocity = Vector3.zero
				hrp.AssemblyAngularVelocity = Vector3.zero
			end
		end
	end
end

-- 自旋每帧更新: 锚定状态下手动处理移动 + 跳跃 + 旋转, 摄像机正常跟随
local function updateSpin(dt)
	if not State.spinEnabled then return end
	local c = getLocalChar()
	if not c then return end
	local myRoot = c:FindFirstChild("HumanoidRootPart")
	local myHum = c:FindFirstChildOfClass("Humanoid")
	if not myRoot then return end

	-- 角度累加 (速度单位: 弧度/秒)
	spinAngle = spinAngle + State.spinSpeed * dt
	if spinAngle > math.pi * 2 then
		spinAngle = spinAngle - math.pi * 2
	end

	-- 计算当前位置
	local currentPos = myRoot.Position

	-- 用 Humanoid.MoveDirection 获取移动方向 (键盘 WASD 和手机摇杆都会自动更新此值)
	if myHum then
		local moveDir = myHum.MoveDirection
		if moveDir.Magnitude > 0 then
			local speed = State.speedEnabled and State.walkSpeed or DEFAULT_WALKSPEED
			-- 只在水平面移动
			currentPos = currentPos + Vector3.new(moveDir.X, 0, moveDir.Z) * speed * dt
		end
	end

	-- 射线检测参数 (排除自身角色)
	local rayParams = RaycastParams.new()
	rayParams.FilterDescendantsInstances = {c}
	rayParams.FilterType = Enum.RaycastFilterType.Exclude

	-- 检测是否在地面
	local groundRay = workspace:Raycast(currentPos, Vector3.new(0, -GROUND_OFFSET - 0.5, 0), rayParams)
	local onGround = groundRay ~= nil

	-- 跳跃检测: Humanoid.Jump (手机跳跃按钮) 或 空格键 (PC)
	local wantJump = (myHum and myHum.Jump) or UserInputService:IsKeyDown(Enum.KeyCode.Space)
	if wantJump and onGround and spinYVelocity <= 0 then
		spinYVelocity = JUMP_POWER
	end

	-- 重力
	spinYVelocity = spinYVelocity - workspace.Gravity * dt

	-- 应用垂直位移
	currentPos = currentPos + Vector3.new(0, spinYVelocity * dt, 0)

	-- 地面碰撞: 下落时如果穿过地面, 回到地面高度
	if spinYVelocity <= 0 then
		local landRay = workspace:Raycast(currentPos, Vector3.new(0, -GROUND_OFFSET - 1, 0), rayParams)
		if landRay then
			currentPos = Vector3.new(currentPos.X, landRay.Position.Y + GROUND_OFFSET, currentPos.Z)
			spinYVelocity = 0
		end
	end

	-- 用 PivotTo 刚性旋转 + 位移整个角色模型, 所有部件一起转, 不会虚化
	c:PivotTo(CFrame.new(currentPos) * CFrame.Angles(0, spinAngle, 0))

	-- 持续保持 PlatformStand
	if myHum then
		myHum.PlatformStand = true
	end
end

--========================================================
-- 3.7 循环传送模块
--========================================================
-- 传送自己到目标玩家身边
local function teleportToPlayer(targetName)
	local target = Players:FindFirstChild(targetName)
	if not target or not target.Character then return end
	local targetRoot = target.Character:FindFirstChild("HumanoidRootPart")
	if not targetRoot then return end
	local myChar = LocalPlayer.Character
	if not myChar then return end
	local myRoot = myChar:FindFirstChild("HumanoidRootPart")
	if not myRoot then return end
	myRoot.CFrame = targetRoot.CFrame + Vector3.new(0, 4, 0)
end

-- 循环传送: 指定玩家
local loopTpThread = nil
setLoopTp = function(on)
	State.loopTpEnabled = on
	if on then
		loopTpThread = task.spawn(function()
			while State.loopTpEnabled do
				local target = State.loopTpTarget
				if target and target ~= "(无其他玩家)" and target ~= "(选择玩家)" then
					teleportToPlayer(target)
				end
				task.wait(State.loopTpInterval)
			end
		end)
	else
		State.loopTpEnabled = false
	end
end

-- 循环传送: 敌对玩家 (持续传送到当前敌对玩家, 直到其消失再切换下一个)
local loopTpAllThread = nil
local loopTpAllIndex = 1
setLoopTpAll = function(on)
	State.loopTpAllEnabled = on
	if on then
		loopTpAllThread = task.spawn(function()
			while State.loopTpAllEnabled do
				-- 获取与自己不同队伍的玩家列表 (无队伍时视为所有人为敌对)
				local list = {}
				local myTeam = LocalPlayer.Team
				for _, p in ipairs(Players:GetPlayers()) do
					if p ~= LocalPlayer and (myTeam == nil or p.Team ~= myTeam) then
						table.insert(list, p.Name)
					end
				end
				if #list > 0 then
					if loopTpAllIndex > #list then loopTpAllIndex = 1 end
					local currentTarget = list[loopTpAllIndex]
					-- 持续循环传送到当前敌对玩家, 直到其消失 (离开/角色销毁/死亡/变同队)
					while State.loopTpAllEnabled do
						local p = Players:FindFirstChild(currentTarget)
						if not p then break end
						if myTeam ~= nil and p.Team == myTeam then break end  -- 变成同队, 跳过
						local char = p.Character
						if not char or not char:FindFirstChild("HumanoidRootPart") then break end
						local hum = char:FindFirstChildOfClass("Humanoid")
						if hum and hum.Health <= 0 then break end
						teleportToPlayer(currentTarget)
						task.wait(State.loopTpInterval)
					end
					loopTpAllIndex = loopTpAllIndex + 1
				else
					task.wait(0.5)
				end
			end
		end)
	else
		State.loopTpAllEnabled = false
	end
end

--========================================================
-- 4. 自瞄辅助模块
--========================================================
-- FOV 圈
local FovCircle
do
	FovCircle = trackInstance(Instance.new("Frame"))
	FovCircle.AnchorPoint = Vector2.new(0.5, 0.5)
	FovCircle.BackgroundColor3 = Color3.new(0,0,0)
	FovCircle.BackgroundTransparency = 1
	FovCircle.BorderSizePixel = 0
	FovCircle.Visible = false
	FovCircle.Parent = OverlayGui
	local s = trackInstance(Instance.new("UIStroke"))
	s.Color = Theme.Accent
	s.Thickness = 1.5
	s.Transparency = 0.2
	s.Parent = FovCircle
end

local function updateFovCircle()
	FovCircle.Position = UDim2.fromOffset(Camera.ViewportSize.X/2, Camera.ViewportSize.Y/2)
	-- aimFov 表示半径, 视觉圆直径 = aimFov * 2, 与检测范围一致
	FovCircle.Size = UDim2.fromOffset(State.aimFov * 2, State.aimFov * 2)
	-- 圆形
	local existing = FovCircle:FindFirstChildOfClass("UICorner")
	if not existing then
		local c = trackInstance(Instance.new("UICorner"))
		c.CornerRadius = UDim.new(1, 0)
		c.Parent = FovCircle
	end
	FovCircle.Visible = State.aimEnabled and State.aimMode == "FOV"
end

-- 墙体检测: 相机到目标之间是否被墙体遮挡
local function blockedByWall(targetPart)
	if not State.wallCheck then return false end
	local origin = Camera.CFrame.Position
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	-- 排除本地玩家和目标玩家自身的角色, 防止误判
	local filter = { LocalPlayer.Character, Camera }
	if targetPart and targetPart.Parent then
		table.insert(filter, targetPart.Parent)
	end
	params.FilterDescendantsInstances = filter
	local result = Workspace:Raycast(origin, targetPart.Position - origin, params)
	if result then
		return (result.Position - targetPart.Position).Magnitude > 5
	end
	return false
end

-- 选最佳目标
local function getAimTarget()
	local center = Vector2.new(Camera.ViewportSize.X/2, Camera.ViewportSize.Y/2)
	local camPos = Camera.CFrame.Position
	local camLook = Camera.CFrame.LookVector

	-- 根据模式决定搜索范围
	local mode = State.aimMode
	local best, bestDist = nil, math.huge

	for _, p in ipairs(Players:GetPlayers()) do
		if p ~= LocalPlayer and not sameTeam(p) and isAlive(p) then
			local part = getTargetPart(p, State.aimPart)
			if part then
				if (part.Position - camPos).Magnitude > State.aimDistance then
					-- 超出距离
				else
					local sp, onScreen = Camera:WorldToViewportPoint(part.Position)
					local screenPos = Vector2.new(sp.X, sp.Y)
					local dist = (screenPos - center).Magnitude

					local inRange = false
					if mode == "FOV" then
						-- FOV 圈内 + 屏幕内
						inRange = onScreen and sp.Z > 0 and dist < State.aimFov
					elseif mode == "180" then
						-- 前方 180° (与相机朝向夹角 < 90°)
						local toTarget = (part.Position - camPos).Unit
						local dot = toTarget:Dot(camLook)
						inRange = dot > 0 and onScreen and sp.Z > 0
					elseif mode == "360" then
						-- 全方位, 只要距离内即可 (不需要在屏幕上)
						inRange = true
					end

					if inRange then
						-- 选择离准星最近的 (360 模式下用距离排序)
						if not blockedByWall(part) then
							if mode == "360" then
								-- 360: 优先选最近的玩家 (3D 距离)
								local d3 = (part.Position - camPos).Magnitude
								if d3 < bestDist then
									best = part
									bestDist = d3
								end
							else
								-- FOV / 180: 选离准星屏幕距离最近的
								if dist < bestDist then
									best = part
									bestDist = dist
								end
							end
						end
					end
				end
			end
		end
	end
	return best
end

-- 自瞄每帧: 平滑转动相机看向目标
-- 概率锁头: 只在切换到新目标时掷一次骰子, 锁住同一目标期间保持稳定
local aimCurrentTarget = nil   -- 当前锁定的目标部件
local aimLockHead = true       -- 当前目标的锁头决定 (true=锁头, false=锁身体)

local function updateAim()
	if not State.aimEnabled then return end
	local target = getAimTarget()
	if not target then
		aimCurrentTarget = nil
		return
	end
	-- 目标切换时才重新掷骰
	if target ~= aimCurrentTarget then
		aimCurrentTarget = target
		if State.aimPart == "Head" and State.aimHeadLock < 100 then
			local roll = math.random(1, 100)
			aimLockHead = (roll <= State.aimHeadLock)
		else
			aimLockHead = true
		end
	end
	-- 根据 lockHead 决定实际瞄准部位
	local actualTarget = target
	if State.aimPart == "Head" and not aimLockHead then
		local char = target.Parent
		if char then
			local bodyPart = char:FindFirstChild("HumanoidRootPart") or char:FindFirstChild("Torso") or char:FindFirstChild("UpperTorso")
			if bodyPart then
				actualTarget = bodyPart
			end
		end
	end
	local camPos = Camera.CFrame.Position
	local aimCFrame = CFrame.new(camPos, actualTarget.Position)
	local smooth = math.clamp(State.aimSmooth, 0.01, 1)
	-- smooth 越大越快
	local newCFrame = Camera.CFrame:Lerp(aimCFrame, smooth)
	Camera.CFrame = newCFrame
end

--========================================================
-- 5. 主循环 / 渲染更新
-- 用 BindToRenderStep 设为相机优先级之后, 保证自瞄覆盖相机有"最后一帧"决定权
--========================================================
local RENDER_NAME = "GSEN_Update"
RunService:BindToRenderStep(RENDER_NAME, Enum.RenderPriority.Camera.Value + 1, function(dt)
	-- ESP 方框
	updateBoxes()
	-- 天线
	updateAntennas()
	-- 骨骼
	updateSkeletons()
	-- 飞行
	updateFly(dt)
	-- 穿墙保持
	updateNoclip()
	-- 环绕
	updateOrbit(dt)
	-- 自旋
	updateSpin(dt)
	-- 自瞄
	updateAim()
	-- FOV 圈
	updateFovCircle()
	-- 玩家数量
	local n = #Players:GetPlayers()
	CountLabel.Text = "Players: " .. tostring(n)
	-- 灵动岛时间 (UTC+8, 24小时制, 精确到秒)
	if IslandTimeLabel and IslandTimeLabel.Parent and ExpandButton and ExpandButton.Visible then
		local t = os.time() + 8 * 3600
		local dt = os.date("!*t", t)
		IslandTimeLabel.Text = string.format("%02d:%02d:%02d", dt.hour, dt.min, dt.sec)
	end
	-- 统一 ESP 清理 + 颜色更新 (一次遍历)
	updateEsp()
end)

--========================================================
-- 6. 构建标签页内容
--========================================================
-- 透视页
do
	local page = addTab("透视", "👁")
	makeSectionLabel(page, "玩家透视")
	makeToggle(page, "ESP 高亮透视", function(v) State.espEnabled = v; rebuildEsp() end, nil, "espEnabled")
	makeToggle(page, "骨骼透视", function(v) State.skeletonEnabled = v; rebuildEsp() end, nil, "skeletonEnabled")
	makeToggle(page, "玩家方框", function(v) State.boxEnabled = v; rebuildEsp() end, nil, "boxEnabled")
	makeToggle(page, "天线透视", function(v) State.antennaEnabled = v; rebuildEsp() end, nil, "antennaEnabled")
	makeToggle(page, "玩家用户名", function(v) State.nameEnabled = v; rebuildEsp() end, nil, "nameEnabled")
	makeToggle(page, "玩家昵称", function(v) State.nickEnabled = v; rebuildEsp() end, nil, "nickEnabled")
	makeSectionLabel(page, "信息")
	makeToggle(page, "显示玩家数量", function(v) CountLabel.Visible = v end)
end

-- 移动页
do
	local page = addTab("移动", "✈")
	makeSectionLabel(page, "角色移动")
	makeToggle(page, "移速开关", function(v)
		State.speedEnabled = v
		applyWalkSpeed()
	end, nil, "speedEnabled")
	makeSlider(page, "移速", 16, 10000, 16, "", function(v)
		State.walkSpeed = v
		if State.speedEnabled then applyWalkSpeed() end
	end, "walkSpeed")
	makeSectionLabel(page, "飞行模式")
	makeToggle(page, "飞行开关", function(v)
		if v then
			toggleFlyPanel(true)
			setFly(true)
			syncFlyPanelUI(true)
		else
			setFly(false)
			toggleFlyPanel(false)
		end
	end, nil, "flyEnabled")
	makeSectionLabel(page, "穿墙")
	makeToggle(page, "穿墙 (Noclip)", function(v) setNoclip(v) end, nil, "noclipEnabled")
	makeSectionLabel(page, "自旋")
	makeToggle(page, "自旋开关", function(v) setSpin(v) end, nil, "spinEnabled")
	makeSlider(page, "自旋速度", 0.5, 100, 5, "", function(v) State.spinSpeed = v end, "spinSpeed")
	makeSectionLabel(page, "无限跳")
	makeToggle(page, "无限跳", function(v) State.infJumpEnabled = v end, nil, "infJumpEnabled")
end

--========================================================
-- 战斗页
--========================================================
do
	local page = addTab("战斗", "🎯")
	makeSectionLabel(page, "自瞄辅助")
	makeToggle(page, "自瞄开关", function(v) State.aimEnabled = v end, nil, "aimEnabled")
	makeDropdown(page, "自瞄模式", {"FOV圈", "180°", "360°"}, "FOV圈", function(opt)
		local modeMap = {["FOV圈"] = "FOV", ["180°"] = "180", ["360°"] = "360"}
		State.aimMode = modeMap[opt] or "FOV"
	end, "aimMode")
	makeSlider(page, "FOV 圈大小", 30, 400, 120, "px", function(v) State.aimFov = v end, "aimFov")
	makeSlider(page, "自瞄平滑度", 0.05, 1, 0.30, "", function(v) State.aimSmooth = v end, "aimSmooth")
	makeSlider(page, "自瞄距离", 50, 10000, 500, "", function(v) State.aimDistance = v end, "aimDistance")
	makeDropdown(page, "自瞄部位", {"头部 Head", "身体 Body"}, "身体 Body", function(opt)
		local partMap = {["头部 Head"] = "Head", ["身体 Body"] = "Body"}
		State.aimPart = partMap[opt] or "Body"
	end, "aimPart")
	makeSlider(page, "概率锁头", 0, 100, 100, "%", function(v) State.aimHeadLock = math.floor(v) end, "aimHeadLock")
	makeToggle(page, "墙体检测", function(v) State.wallCheck = v end, nil, "wallCheck")
	makeToggle(page, "队伍检测", function(v) State.teamCheck = v end, nil, "teamCheck")
	makeToggle(page, "活体检测", function(v) State.aliveCheck = v end, nil, "aliveCheck")
end

--========================================================
-- 传送页
--========================================================
do
	local page = addTab("传送", "↗")
	makeSectionLabel(page, "传送 / 甩飞")
	local teleportTarget = nil
	local function getPlayerList()
		local list = {}
		for _, p in ipairs(Players:GetPlayers()) do
			if p ~= LocalPlayer then
				table.insert(list, p.Name)
			end
		end
		if #list == 0 then
			list = {"(无其他玩家)"}
		end
		return list
	end
	local tpDropdown = makeDropdown(page, "目标玩家", getPlayerList(), "(选择玩家)", function(opt)
		teleportTarget = opt
		State.flingTarget = opt
		State.orbitTarget = opt
		State.loopTpTarget = opt
	end)
	makeButton(page, "刷新玩家列表", function()
		local newList = getPlayerList()
		tpDropdown.refresh(newList)
		tpDropdown.valLbl.Text = "(选择玩家)"
		teleportTarget = nil
		State.flingTarget = nil
		State.orbitTarget = nil
		State.loopTpTarget = nil
	end)
	makeButton(page, "传送到该玩家", function()
		if not teleportTarget or teleportTarget == "(无其他玩家)" or teleportTarget == "(选择玩家)" then return end
		local target = Players:FindFirstChild(teleportTarget)
		if not target then return end
		local targetChar = target.Character
		if not targetChar then return end
		local targetRoot = targetChar:FindFirstChild("HumanoidRootPart")
		if not targetRoot then return end
		local myChar = LocalPlayer.Character
		if not myChar then return end
		local myRoot = myChar:FindFirstChild("HumanoidRootPart")
		if not myRoot then return end
		myRoot.CFrame = targetRoot.CFrame + Vector3.new(0, 3, 0)
	end)
	makeButton(page, "拉取该玩家到身边", function()
		if not teleportTarget or teleportTarget == "(无其他玩家)" or teleportTarget == "(选择玩家)" then return end
		local target = Players:FindFirstChild(teleportTarget)
		if not target then return end
		local targetChar = target.Character
		if not targetChar then return end
		local targetRoot = targetChar:FindFirstChild("HumanoidRootPart")
		if not targetRoot then return end
		local myChar = LocalPlayer.Character
		if not myChar then return end
		local myRoot = myChar:FindFirstChild("HumanoidRootPart")
		if not myRoot then return end
		targetRoot.CFrame = myRoot.CFrame + Vector3.new(0, 3, 0)
	end)
	makeButton(page, "甩飞玩家一次", function()
		if not teleportTarget or teleportTarget == "(无其他玩家)" or teleportTarget == "(选择玩家)" then return end
		local target = Players:FindFirstChild(teleportTarget)
		if not target then return end
		local targetChar = target.Character
		if not targetChar then return end
		local targetRoot = targetChar:FindFirstChild("HumanoidRootPart")
		if not targetRoot then return end
		local myChar = LocalPlayer.Character
		if not myChar then return end
		local myRoot = myChar:FindFirstChild("HumanoidRootPart")
		if not myRoot then return end

		-- 保存原位置
		local savedCF = myRoot.CFrame

		-- 创建 BodyVelocity 启动阶段
		local bv = Instance.new("BodyVelocity")
		bv.Name = "EpixVel"
		bv.Parent = myRoot
		bv.Velocity = Vector3.new(900000000, 900000000, 900000000)
		bv.MaxForce = Vector3.new(1 / 0, 1 / 0, 1 / 0)

		-- 执行甩飞动画: 连续改变位置/旋转, 极高速度+角速度
		task.spawn(function()
			local rotationAngle = 0
			local startTime = tick()
			local TIMEOUT = 5  -- 超时 5 秒

			while myRoot and myRoot.Parent and targetRoot and targetRoot.Parent do
				if tick() - startTime > TIMEOUT then break end

				local velMag = targetRoot.Velocity.Magnitude
				if velMag < 50 then
					rotationAngle = rotationAngle + 100

					-- 四个位置循环, 改变 CFrame + 极高 Velocity/RotVelocity
					local positions = {
						CFrame.new(0, 1.5, 0),
						CFrame.new(0, -1.5, 0),
						CFrame.new(2.25, 1.5, -2.25),
						CFrame.new(-2.25, -1.5, 2.25),
					}

					for _, offset in ipairs(positions) do
						if not myRoot or not myRoot.Parent then break end
						local cf = CFrame.new(targetRoot.Position) * offset * CFrame.Angles(math.rad(rotationAngle), 0, 0)
						myChar:SetPrimaryPartCFrame(cf)
						myRoot.Velocity = Vector3.new(90000000, 900000000, 90000000)
						myRoot.RotVelocity = Vector3.new(900000000, 900000000, 900000000)
						task.wait()
					end
				end

				if targetRoot.Velocity.Magnitude > 500 then
					break
				end
			end

			-- 清理: 移除 BodyVelocity, 恢复位置
			if bv and bv.Parent then bv:Destroy() end
			if myRoot and myRoot.Parent then
				myRoot.Velocity = Vector3.zero
				myRoot.RotVelocity = Vector3.zero
				myRoot.CFrame = savedCF
			end
		end)
	end)
	local flingToggle = makeToggle(page, "静默甩飞", function(v) setFling(v) end, nil, "flingEnabled")
	flingToggleSet = flingToggle.set

	makeSectionLabel(page, "环绕")
	local orbitToggle = makeToggle(page, "环绕目标玩家", function(v) setOrbit(v) end, nil, "orbitEnabled")
	orbitToggleSet = orbitToggle.set
	makeSlider(page, "环绕半径", 1, 50, 8, " studs", function(v) State.orbitRadius = v end, "orbitRadius")
	makeSlider(page, "环绕速度", 0.5, 100, 5, "", function(v) State.orbitSpeed = v end, "orbitSpeed")

	makeSectionLabel(page, "循环传送")
	local loopTpToggle = makeToggle(page, "循环传送指定玩家", function(v) setLoopTp(v) end, nil, "loopTpEnabled")
	local loopTpAllToggle = makeToggle(page, "循环传送敌对玩家", function(v) setLoopTpAll(v) end, nil, "loopTpAllEnabled")
end

--========================================================
-- 音乐页 (酷狗音乐 API)
--========================================================
local MusicState = {
	searchResults = {},   -- 搜索结果列表
	currentSound = nil,  -- 当前播放的 Sound 对象
	isPlaying   = false,
	isPaused    = false,
	pausedPosition = nil, -- 暂停时的播放位置
	loopMode    = false, -- false=单次, true=循环
	currentSong  = nil,   -- {name, singer, hash, album_id, duration}
	volume      = 1,
	-- UI 引用 (供外部更新)
	statusLabel  = nil,
	playBtn      = nil,  -- 暂停/播放按钮
	loopBtn      = nil,  -- 循环按钮
	progFill     = nil,  -- 进度条填充
	progLabel    = nil,  -- 进度时间标签
}

-- 酷狗搜索
local function kugouSearch(keyword, callback)
	local encoded = HttpService:UrlEncode(keyword)
	local url = "http://msearchcdn.kugou.com/api/v3/search/song?plat=0&keyword=" .. encoded .. "&version=9108&pagesize=30&page=1"
	task.spawn(function()
		local body = httpRequest(url)
		if not body then
			callback(nil, "网络请求失败")
			return
		end
		local ok, data = pcall(function() return HttpService:JSONDecode(body) end)
		if not ok or type(data) ~= "table" then
			callback(nil, "解析失败")
			return
		end
		local info = data.data and data.data.info
		if not info or #info == 0 then
			callback({}, "无搜索结果")
			return
		end
		local results = {}
		for _, song in ipairs(info) do
			table.insert(results, {
				name     = song.songname or song.filename or "未知",
				singer   = song.singername or "未知",
				hash     = song.hash or "",
				album_id = song.album_id or "",
				duration = song.duration or 0,
				filesize = song.filesize or 0,
				pay_type = song.pay_type or 0,  -- 0=免费, 3=VIP
			})
		end
		callback(results, nil)
	end)
end

-- 酷狗获取播放 URL
local function kugouGetPlayUrl(song, callback)
	-- 使用移动端 API (wwwapi 已失效)
	local url = "http://m.kugou.com/app/i/getSongInfo.php?cmd=playInfo&hash=" .. song.hash
	task.spawn(function()
		local body = httpRequest(url)
		if not body then
			callback(nil, "获取播放链接失败")
			return
		end
		local ok, data = pcall(function() return HttpService:JSONDecode(body) end)
		if not ok or type(data) ~= "table" then
			callback(nil, "解析播放数据失败")
			return
		end
		-- 检查是否付费歌曲
		local payType = data.pay_type or 0
		if payType ~= 0 then
			callback(nil, "该歌曲需要VIP, 无法播放")
			return
		end
		-- 获取播放 URL
		local playUrl = data.url or ""
		if playUrl == "" and data.backup_url then
			if type(data.backup_url) == "table" and #data.backup_url > 0 then
				playUrl = data.backup_url[1]
			elseif type(data.backup_url) == "string" and data.backup_url ~= "" then
				playUrl = data.backup_url
			end
		end
		if not playUrl or playUrl == "" then
			local errMsg = data.error or ""
			if errMsg ~= "" then
				callback(nil, errMsg)
			else
				callback(nil, "无法获取播放链接")
			end
			return
		end
		callback(playUrl, nil)
	end)
end

-- 停止当前播放
local function stopMusic()
	if MusicState.currentSound then
		pcall(function() MusicState.currentSound:Stop() end)
		pcall(function() MusicState.currentSound:Destroy() end)
		MusicState.currentSound = nil
	end
	MusicState.isPlaying = false
	MusicState.isPaused = false
	MusicState.pausedPosition = nil
	-- 更新播放按钮文字
	if MusicState.playBtn then
		pcall(function() MusicState.playBtn.Text = "▶ 播放" end)
	end
	-- 重置进度条
	if MusicState.progFill then
		pcall(function() MusicState.progFill.Size = UDim2.new(0, 0, 1, 0) end)
	end
	if MusicState.progLabel then
		pcall(function() MusicState.progLabel.Text = "0:00 / 0:00" end)
	end
end

-- 暂停/恢复
local function togglePause()
	if not MusicState.currentSound then return end
	if MusicState.isPaused then
		-- 恢复: 先记录暂停位置, Play() 可能重置位置, 需要手动恢复
		local savedPos = MusicState.pausedPosition or 0
		MusicState.currentSound:Play()
		-- 恢复到暂停前的位置
		if savedPos > 0 then
			pcall(function() MusicState.currentSound.TimePosition = savedPos end)
		end
		MusicState.isPaused = false
		MusicState.isPlaying = true
		MusicState.pausedPosition = nil
		if MusicState.playBtn then MusicState.playBtn.Text = "⏸ 暂停" end
		if MusicState.statusLabel then
			local s = MusicState.currentSong
			MusicState.statusLabel.Text = "▶ 播放中: " .. s.singer .. " - " .. s.name
		end
	else
		-- 暂停: 记录当前播放位置
		MusicState.pausedPosition = MusicState.currentSound.TimePosition or 0
		MusicState.currentSound:Pause()
		MusicState.isPaused = true
		MusicState.isPlaying = false
		if MusicState.playBtn then MusicState.playBtn.Text = "▶ 播放" end
		if MusicState.statusLabel then
			local s = MusicState.currentSong
			MusicState.statusLabel.Text = "⏸ 已暂停: " .. s.singer .. " - " .. s.name
		end
	end
end

-- 格式化时间
local function formatTime(sec)
	if not sec or sec < 0 then sec = 0 end
	local m = math.floor(sec / 60)
	local s = math.floor(sec % 60)
	return string.format("%d:%02d", m, s)
end

-- 设置 Sound 对象属性并开始播放
local function startPlayback(sound, song, statusLabel)
	pcall(function() sound.Looped = MusicState.loopMode end)
	pcall(function() sound.Volume = MusicState.volume or 1 end)
	sound.Parent = workspace
	MusicState.currentSound = sound
	MusicState.isPaused = false
	MusicState.isPlaying = true
	if MusicState.playBtn then MusicState.playBtn.Text = "⏸ 暂停" end
	statusLabel.Text = "▶ 播放中: " .. song.singer .. " - " .. song.name
	pcall(function() sound:Play() end)
	-- 播放结束
	trackConnection(sound.Ended:Connect(function()
		if MusicState.loopMode then
			-- 循环模式: 重新播放 (Looped=true 会自动循环, 这里是备用)
			pcall(function() sound:Play() end)
		else
			MusicState.isPlaying = false
			if MusicState.playBtn then MusicState.playBtn.Text = "▶ 播放" end
			statusLabel.Text = "播放结束: " .. song.singer .. " - " .. song.name
		end
	end))
end

-- 下载 MP3 到本地文件并播放
local MUSIC_DIR = "GSEN/music"
local function downloadAndPlay(playUrl, song, statusLabel)
	-- 确保目录存在
	if _makefolder then pcall(function() _makefolder(MUSIC_DIR) end) end

	-- 检查执行器是否支持 getcustomasset
	local _getcustomasset = getcustomasset or (syn and syn.getcustomasset) or getsynasset or getcustomassetfunc
	if not _getcustomasset then
		-- 不支持本地资源, 尝试直链播放
		statusLabel.Text = "尝试直链播放..."
		local sound = Instance.new("Sound")
		sound.SoundId = playUrl
		startPlayback(sound, song, statusLabel)
		return
	end

	-- 生成安全文件名
	local safeName = (song.singer .. "_" .. song.name):gsub("[^%w_]", "_")
	local filePath = MUSIC_DIR .. "/" .. safeName .. ".mp3"

	-- 如果文件已存在, 直接播放
	if _isfile and _isfile(filePath) then
		local sound = Instance.new("Sound")
		local assetUrl = _getcustomasset(filePath)
		sound.SoundId = assetUrl
		startPlayback(sound, song, statusLabel)
		return
	end

	-- 下载 MP3
	statusLabel.Text = "下载中: " .. song.singer .. " - " .. song.name
	task.spawn(function()
		local body = nil
		local okHttp, resHttp = pcall(function()
			if http_request then
				return http_request({ Url = playUrl, Method = "GET" })
			elseif syn and syn.request then
				return syn.request({ Url = playUrl, Method = "GET" })
			elseif request then
				return request({ Url = playUrl, Method = "GET" })
			end
		end)
		if okHttp and resHttp then
			if type(resHttp) == "string" then
				body = resHttp
			elseif resHttp.Body then
				body = resHttp.Body
			elseif resHttp.body then
				body = resHttp.body
			end
		end

		if not body or #body < 100 then
			statusLabel.Text = "✗ 下载失败, 可能是网络问题"
			return
		end

		-- 写入文件
		local okWrite = false
		if _writefile then
			okWrite = pcall(function() _writefile(filePath, body) end)
			if not okWrite then
				okWrite = pcall(function() _writefile(safeName .. ".mp3", body) end)
				if okWrite then filePath = safeName .. ".mp3" end
			end
		end

		if not okWrite then
			statusLabel.Text = "✗ 文件保存失败"
			return
		end

		-- 获取可播放资源 URL
		local assetUrl = nil
		local okAsset = pcall(function() assetUrl = _getcustomasset(filePath) end)
		if not okAsset or not assetUrl then
			statusLabel.Text = "✗ 无法创建音频资源"
			return
		end

		-- 播放
		local sound = Instance.new("Sound")
		sound.SoundId = assetUrl
		startPlayback(sound, song, statusLabel)
	end)
end

-- 播放指定歌曲
local function playSong(song, statusLabel)
	stopMusic()
	MusicState.statusLabel = statusLabel
	statusLabel.Text = "获取播放链接中..."
	kugouGetPlayUrl(song, function(playUrl, err)
		if not playUrl then
			statusLabel.Text = "✗ " .. (err or "播放失败")
			return
		end
		if playUrl:sub(1, 5) == "http:" then
			playUrl = "https" .. playUrl:sub(5)
		end
		MusicState.currentSong = song
		downloadAndPlay(playUrl, song, statusLabel)
	end)
end

-- 音乐页
do
	local page = addTab("酷狗", "🎵")
	makeSectionLabel(page, "酷狗音乐搜索")

	-- 搜索输入框 + 按钮
	local searchContainer = trackInstance(Instance.new("Frame"))
	searchContainer.Size = UDim2.new(1, -5, 0, 34)
	searchContainer.BackgroundTransparency = 1
	searchContainer.Parent = page

	local searchBox = trackInstance(Instance.new("TextBox"))
	searchBox.Size = UDim2.new(1, -90, 0, 34)
	searchBox.BackgroundColor3 = Theme.Element
	searchBox.BorderSizePixel = 0
	searchBox.Text = ""
	searchBox.PlaceholderText = "输入歌名或歌手名"
	searchBox.TextColor3 = Theme.Text
	searchBox.Font = FontMain
	searchBox.TextSize = 13
	searchBox.ClearTextOnFocus = false
	searchBox.TextXAlignment = Enum.TextXAlignment.Left
	local sbC = trackInstance(Instance.new("UICorner"))
	sbC.CornerRadius = UDim.new(0, 6)
	sbC.Parent = searchBox
	local sbP = trackInstance(Instance.new("UIPadding"))
	sbP.PaddingLeft = UDim.new(0, 10)
	sbP.Parent = searchBox
	searchBox.Parent = searchContainer

	local searchBtn = trackInstance(Instance.new("TextButton"))
	searchBtn.Size = UDim2.fromOffset(80, 34)
	searchBtn.Position = UDim2.new(1, -80, 0, 0)
	searchBtn.BackgroundColor3 = Theme.AccentDark
	searchBtn.Text = "搜索"
	searchBtn.TextColor3 = Theme.Text
	searchBtn.Font = FontBold
	searchBtn.TextSize = 13
	searchBtn.AutoButtonColor = false
	searchBtn.BorderSizePixel = 0
	local sbc2 = trackInstance(Instance.new("UICorner"))
	sbc2.CornerRadius = UDim.new(0, 6)
	sbc2.Parent = searchBtn
	searchBtn.Parent = searchContainer

	-- 状态标签
	local statusLabel = trackInstance(Instance.new("TextLabel"))
	statusLabel.Size = UDim2.new(1, -5, 0, 20)
	statusLabel.BackgroundTransparency = 1
	statusLabel.Text = "输入关键词后点击搜索"
	statusLabel.TextColor3 = Theme.SubText
	statusLabel.Font = FontMain
	statusLabel.TextSize = 12
	statusLabel.TextXAlignment = Enum.TextXAlignment.Left
	statusLabel.Parent = page

	-- 搜索结果列表容器 (可滚动)
	local resultsFrame = trackInstance(Instance.new("ScrollingFrame"))
	resultsFrame.Size = UDim2.new(1, -5, 0, 200)
	resultsFrame.BackgroundTransparency = 1
	resultsFrame.BorderSizePixel = 0
	resultsFrame.ScrollBarThickness = 4
	resultsFrame.ScrollBarImageColor3 = Theme.Stroke
	resultsFrame.CanvasSize = UDim2.new(0, 0, 0, 0)
	resultsFrame.Parent = page

	local resultsLayout = trackInstance(Instance.new("UIListLayout"))
	resultsLayout.FillDirection = Enum.FillDirection.Vertical
	resultsLayout.SortOrder = Enum.SortOrder.LayoutOrder
	resultsLayout.Padding = UDim.new(0, 4)
	resultsLayout.Parent = resultsFrame

	trackConnection(resultsLayout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
		resultsFrame.CanvasSize = UDim2.new(0, 0, 0, resultsLayout.AbsoluteContentSize.Y)
	end))

	-- 清空结果列表
	local function clearResults()
		for _, child in ipairs(resultsFrame:GetChildren()) do
			if child:IsA("GuiObject") then
				child:Destroy()
			end
		end
	end

	-- 格式化时长 (秒 -> mm:ss)
	local function formatDuration(sec)
		local m = math.floor(sec / 60)
		local s = math.floor(sec % 60)
		return string.format("%d:%02d", m, s)
	end

	-- 显示搜索结果
	local function displayResults(results)
		clearResults()
		for i, song in ipairs(results) do
			local item = trackInstance(Instance.new("TextButton"))
			item.Size = UDim2.new(1, 0, 0, 40)
			item.BackgroundColor3 = Theme.Element
			item.Text = ""
			item.AutoButtonColor = false
			item.BorderSizePixel = 0
			local iC = trackInstance(Instance.new("UICorner"))
			iC.CornerRadius = UDim.new(0, 4)
			iC.Parent = item

			-- 歌曲信息
			local songLabel = trackInstance(Instance.new("TextLabel"))
			songLabel.Size = UDim2.new(1, -70, 0, 40)
			songLabel.BackgroundTransparency = 1
			songLabel.Text = song.singer .. " - " .. song.name
			songLabel.TextColor3 = Theme.Text
			songLabel.Font = FontMain
			songLabel.TextSize = 12
			songLabel.TextXAlignment = Enum.TextXAlignment.Left
			songLabel.TextTruncate = Enum.TextTruncate.AtEnd
			local slP = trackInstance(Instance.new("UIPadding"))
			slP.PaddingLeft = UDim.new(0, 8)
			slP.Parent = songLabel
			songLabel.Parent = item

			-- 时长
			local durLabel = trackInstance(Instance.new("TextLabel"))
			durLabel.Size = UDim2.fromOffset(55, 40)
			durLabel.Position = UDim2.new(1, -60, 0, 0)
			durLabel.BackgroundTransparency = 1
			durLabel.Text = formatDuration(song.duration)
			durLabel.TextColor3 = Theme.SubText
			durLabel.Font = FontMain
			durLabel.TextSize = 11
			durLabel.TextXAlignment = Enum.TextXAlignment.Right
			durLabel.Parent = item

			-- 点击播放
			trackConnection(item.MouseButton1Click:Connect(function()
				playSong(song, statusLabel)
			end))
			trackConnection(item.MouseEnter:Connect(function()
				item.BackgroundColor3 = Theme.Hover
			end))
			trackConnection(item.MouseLeave:Connect(function()
				item.BackgroundColor3 = Theme.Element
			end))

			item.Parent = resultsFrame
		end
	end

	-- 执行搜索
	local function doSearch()
		local keyword = searchBox.Text
		if keyword == "" or keyword == nil then
			statusLabel.Text = "请输入搜索关键词"
			return
		end
		statusLabel.Text = "搜索中..."
		clearResults()
		kugouSearch(keyword, function(results, err)
			if err and #results == 0 then
				statusLabel.Text = "✗ " .. err
				return
			end
			MusicState.searchResults = results
			displayResults(results)
			statusLabel.Text = "共 " .. #results .. " 个结果, 点击歌曲播放"
		end)
	end

	trackConnection(searchBtn.MouseButton1Click:Connect(function() doSearch() end))
	trackConnection(searchBox.FocusLost:Connect(function(enter)
		if enter then doSearch() end
	end))

	-- 播放控制
	makeSectionLabel(page, "播放控制")
	local btnRow = trackInstance(Instance.new("Frame"))
	btnRow.Size = UDim2.new(1, -5, 0, 34)
	btnRow.BackgroundTransparency = 1
	btnRow.Parent = page

	local function makeCtrlButton(text, x, w, callback)
		local btn = trackInstance(Instance.new("TextButton"))
		btn.Size = UDim2.fromOffset(w or 60, 34)
		btn.Position = UDim2.fromOffset(x, 0)
		btn.BackgroundColor3 = Theme.AccentDark
		btn.Text = text
		btn.TextColor3 = Theme.Text
		btn.Font = FontBold
		btn.TextSize = 13
		btn.AutoButtonColor = false
		btn.BorderSizePixel = 0
		local bc = trackInstance(Instance.new("UICorner"))
		bc.CornerRadius = UDim.new(0, 6)
		bc.Parent = btn
		-- 用局部变量存储基础颜色, 闭包可访问, 避免依赖 SetAttribute
		local baseColor = Theme.AccentDark
		trackConnection(btn.MouseButton1Click:Connect(callback))
		trackConnection(btn.MouseEnter:Connect(function()
			btn.BackgroundColor3 = Theme.Accent
		end))
		trackConnection(btn.MouseLeave:Connect(function()
			btn.BackgroundColor3 = baseColor
		end))
		btn.Parent = btnRow
		-- 返回按钮 + 更新基础颜色的函数
		return btn, function(c) if c then baseColor = c end end
	end

	-- 暂停/播放按钮
	local playBtn = makeCtrlButton("▶ 播放", 0, 100, function()
		if MusicState.currentSound then
			togglePause()
		else
			statusLabel.Text = "请先选择一首歌曲播放"
		end
	end)
	MusicState.playBtn = playBtn

	-- 单次/循环按钮 (初始为单次)
	local loopBtn, setLoopBase = makeCtrlButton("➡ 单次", 110, 100, function()
		MusicState.loopMode = not MusicState.loopMode
		-- pcall 保护: Looped 赋值在某些执行器/Sound 状态下可能报错
		if MusicState.currentSound then
			pcall(function() MusicState.currentSound.Looped = MusicState.loopMode end)
		end
		-- 用 MusicState.loopBtn 而非闭包变量, 确保引用正确
		local btn = MusicState.loopBtn
		if not btn then return end
		if MusicState.loopMode then
			btn.Text = "🔁 循环"
			btn.BackgroundColor3 = Theme.Accent
			setLoopBase(Theme.Accent)
		else
			btn.Text = "➡ 单次"
			btn.BackgroundColor3 = Theme.AccentDark
			setLoopBase(Theme.AccentDark)
		end
	end)
	MusicState.loopBtn = loopBtn

	-- 进度条
	local progLabel = trackInstance(Instance.new("TextLabel"))
	progLabel.Size = UDim2.new(1, -5, 0, 18)
	progLabel.BackgroundTransparency = 1
	progLabel.Text = "0:00 / 0:00"
	progLabel.TextColor3 = Theme.SubText
	progLabel.Font = FontMain
	progLabel.TextSize = 11
	progLabel.TextXAlignment = Enum.TextXAlignment.Left
	progLabel.Parent = page
	MusicState.progLabel = progLabel

	local progBar = trackInstance(Instance.new("Frame"))
	progBar.Size = UDim2.new(1, -5, 0, 16)
	progBar.BackgroundColor3 = Theme.Element
	progBar.BorderSizePixel = 0
	local pbC = trackInstance(Instance.new("UICorner"))
	pbC.CornerRadius = UDim.new(0, 4)
	pbC.Parent = progBar
	progBar.Parent = page

	local progFill = trackInstance(Instance.new("Frame"))
	progFill.Size = UDim2.new(0, 0, 1, 0)
	progFill.BackgroundColor3 = Theme.Accent
	progFill.BorderSizePixel = 0
	local pfC = trackInstance(Instance.new("UICorner"))
	pfC.CornerRadius = UDim.new(0, 4)
	pfC.Parent = progFill
	progFill.Parent = progBar
	MusicState.progFill = progFill

	-- 进度条拖拽
	local progDragging = false
	trackConnection(progBar.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			if not MusicState.currentSound then return end
			progDragging = true
			local rel = (input.Position.X - progBar.AbsolutePosition.X) / progBar.AbsoluteSize.X
			rel = math.clamp(rel, 0, 1)
			progFill.Size = UDim2.new(rel, 0, 1, 0)
			local len = MusicState.currentSound.TimeLength
			if len and len > 0 then
				MusicState.currentSound.TimePosition = rel * len
				progLabel.Text = formatTime(rel * len) .. " / " .. formatTime(len)
			end
		end
	end))
	trackConnection(progBar.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			progDragging = false
		end
	end))
	trackConnection(UserInputService.InputChanged:Connect(function(input)
		if progDragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			if not MusicState.currentSound then return end
			local rel = (input.Position.X - progBar.AbsolutePosition.X) / progBar.AbsoluteSize.X
			rel = math.clamp(rel, 0, 1)
			progFill.Size = UDim2.new(rel, 0, 1, 0)
			local len = MusicState.currentSound.TimeLength
			if len and len > 0 then
				progLabel.Text = formatTime(rel * len) .. " / " .. formatTime(len)
			end
		end
	end))

	-- 进度条自动更新 (每 0.5 秒)
	task.spawn(function()
		while true do
			task.wait(0.5)
			if MusicState.currentSound and not progDragging then
				local pos = MusicState.currentSound.TimePosition or 0
				local len = MusicState.currentSound.TimeLength or 0
				if len > 0 then
					local rel = pos / len
					rel = math.clamp(rel, 0, 1)
					progFill.Size = UDim2.new(rel, 0, 1, 0)
					progLabel.Text = formatTime(pos) .. " / " .. formatTime(len)
				end
			end
		end
	end)

	-- 音量控制
	makeSectionLabel(page, "音量")
	local volLabel = trackInstance(Instance.new("TextLabel"))
	volLabel.Size = UDim2.new(1, -5, 0, 20)
	volLabel.BackgroundTransparency = 1
	volLabel.Text = "音量: 100%"
	volLabel.TextColor3 = Theme.SubText
	volLabel.Font = FontMain
	volLabel.TextSize = 12
	volLabel.TextXAlignment = Enum.TextXAlignment.Left
	volLabel.Parent = page

	local volSlider = trackInstance(Instance.new("Frame"))
	volSlider.Size = UDim2.new(1, -5, 0, 20)
	volSlider.BackgroundColor3 = Theme.Element
	volSlider.BorderSizePixel = 0
	local vC = trackInstance(Instance.new("UICorner"))
	vC.CornerRadius = UDim.new(0, 4)
	vC.Parent = volSlider
	volSlider.Parent = page

	local volFill = trackInstance(Instance.new("Frame"))
	volFill.Size = UDim2.new(1, 0, 1, 0)
	volFill.BackgroundColor3 = Theme.Accent
	volFill.BorderSizePixel = 0
	local vfC = trackInstance(Instance.new("UICorner"))
	vfC.CornerRadius = UDim.new(0, 4)
	vfC.Parent = volFill
	volFill.Parent = volSlider

	-- 音量拖拽
	local volDragging = false
	trackConnection(volSlider.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			volDragging = true
			local rel = (input.Position.X - volSlider.AbsolutePosition.X) / volSlider.AbsoluteSize.X
			rel = math.clamp(rel, 0, 1)
			volFill.Size = UDim2.new(rel, 0, 1, 0)
			local vol = math.floor(rel * 100)
			volLabel.Text = "音量: " .. vol .. "%"
			MusicState.volume = rel
			if MusicState.currentSound then
				MusicState.currentSound.Volume = rel
			end
		end
	end))
	trackConnection(volSlider.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			volDragging = false
		end
	end))
	trackConnection(UserInputService.InputChanged:Connect(function(input)
		if volDragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			local rel = (input.Position.X - volSlider.AbsolutePosition.X) / volSlider.AbsoluteSize.X
			rel = math.clamp(rel, 0, 1)
			volFill.Size = UDim2.new(rel, 0, 1, 0)
			local vol = math.floor(rel * 100)
			volLabel.Text = "音量: " .. vol .. "%"
			MusicState.volume = rel
			if MusicState.currentSound then
				MusicState.currentSound.Volume = rel
			end
		end
	end))
end

--========================================================
-- 网易云音乐页 (music.163.com API) — 独立状态, 不影响酷狗音乐
--========================================================
local NeteaseState = {
	searchResults = {},
	currentSound  = nil,
	isPlaying     = false,
	isPaused      = false,
	pausedPosition = nil,
	loopMode      = false,
	currentSong   = nil,  -- {name, singer, songId, duration}
	volume        = 1,
	statusLabel   = nil,
	playBtn       = nil,
	loopBtn       = nil,
	progFill      = nil,
	progLabel     = nil,
}

-- 网易云搜索
local function neteaseSearch(keyword, callback)
	local encoded = HttpService:UrlEncode(keyword)
	local url = "https://music.163.com/api/search/get/web?csrf_token=&s=" .. encoded .. "&type=1&offset=0&total=true&limit=100"
	task.spawn(function()
		local body = httpRequest(url)
		if not body then
			callback(nil, "网络请求失败")
			return
		end
		local ok, data = pcall(function() return HttpService:JSONDecode(body) end)
		if not ok or type(data) ~= "table" then
			callback(nil, "解析失败")
			return
		end
		local songs = data.result and data.result.songs
		if not songs or #songs == 0 then
			callback({}, "无搜索结果")
			return
		end
		local results = {}
		for _, song in ipairs(songs) do
			local singers = {}
			if song.artists then
				for _, art in ipairs(song.artists) do
					table.insert(singers, art.name or "")
				end
			end
			table.insert(results, {
				name     = song.name or "未知",
				singer   = table.concat(singers, "/"),
				songId   = tostring(song.id or ""),
				duration = (song.duration and math.floor(song.duration / 1000)) or 0,
				fee      = song.fee or 0,  -- 0=免费, 1=专辑, 4=VIP, 8=试听
			})
		end
		callback(results, nil)
	end)
end

-- 网易云获取播放 URL (直接用 outer url, 会 302 重定向到实际 MP3)
local function neteaseGetPlayUrl(song, callback)
	local playUrl = "https://music.163.com/song/media/outer/url?id=" .. song.songId .. ".mp3"
	callback(playUrl, nil)
end

-- 停止当前播放
local function stopNeteaseMusic()
	if NeteaseState.currentSound then
		pcall(function() NeteaseState.currentSound:Stop() end)
		pcall(function() NeteaseState.currentSound:Destroy() end)
		NeteaseState.currentSound = nil
	end
	NeteaseState.isPlaying = false
	NeteaseState.isPaused = false
	NeteaseState.pausedPosition = nil
	if NeteaseState.playBtn then
		pcall(function() NeteaseState.playBtn.Text = "▶ 播放" end)
	end
	if NeteaseState.progFill then
		pcall(function() NeteaseState.progFill.Size = UDim2.new(0, 0, 1, 0) end)
	end
	if NeteaseState.progLabel then
		pcall(function() NeteaseState.progLabel.Text = "0:00 / 0:00" end)
	end
end

-- 暂停/恢复
local function toggleNeteasePause()
	if not NeteaseState.currentSound then return end
	if NeteaseState.isPaused then
		local savedPos = NeteaseState.pausedPosition or 0
		NeteaseState.currentSound:Play()
		if savedPos > 0 then
			pcall(function() NeteaseState.currentSound.TimePosition = savedPos end)
		end
		NeteaseState.isPaused = false
		NeteaseState.isPlaying = true
		NeteaseState.pausedPosition = nil
		if NeteaseState.playBtn then NeteaseState.playBtn.Text = "⏸ 暂停" end
		if NeteaseState.statusLabel then
			local s = NeteaseState.currentSong
			NeteaseState.statusLabel.Text = "▶ 播放中: " .. s.singer .. " - " .. s.name
		end
	else
		NeteaseState.pausedPosition = NeteaseState.currentSound.TimePosition or 0
		NeteaseState.currentSound:Pause()
		NeteaseState.isPaused = true
		NeteaseState.isPlaying = false
		if NeteaseState.playBtn then NeteaseState.playBtn.Text = "▶ 播放" end
		if NeteaseState.statusLabel then
			local s = NeteaseState.currentSong
			NeteaseState.statusLabel.Text = "⏸ 已暂停: " .. s.singer .. " - " .. s.name
		end
	end
end

-- 设置 Sound 对象属性并开始播放
local function startNeteasePlayback(sound, song, statusLabel)
	pcall(function() sound.Looped = NeteaseState.loopMode end)
	pcall(function() sound.Volume = NeteaseState.volume or 1 end)
	sound.Parent = workspace
	NeteaseState.currentSound = sound
	NeteaseState.isPaused = false
	NeteaseState.isPlaying = true
	if NeteaseState.playBtn then NeteaseState.playBtn.Text = "⏸ 暂停" end
	statusLabel.Text = "▶ 播放中: " .. song.singer .. " - " .. song.name
	pcall(function() sound:Play() end)
	trackConnection(sound.Ended:Connect(function()
		if NeteaseState.loopMode then
			pcall(function() sound:Play() end)
		else
			NeteaseState.isPlaying = false
			if NeteaseState.playBtn then NeteaseState.playBtn.Text = "▶ 播放" end
			statusLabel.Text = "播放结束: " .. song.singer .. " - " .. song.name
		end
	end))
end

-- 下载 MP3 到本地文件并播放
local NETEASE_DIR = "GSEN/netease"
local function downloadAndPlayNetease(playUrl, song, statusLabel)
	if _makefolder then pcall(function() _makefolder(NETEASE_DIR) end) end

	local _getcustomasset = getcustomasset or (syn and syn.getcustomasset) or getsynasset or getcustomassetfunc
	if not _getcustomasset then
		statusLabel.Text = "尝试直链播放..."
		local sound = Instance.new("Sound")
		sound.SoundId = playUrl
		startNeteasePlayback(sound, song, statusLabel)
		return
	end

	local safeName = (song.singer .. "_" .. song.name):gsub("[^%w_]", "_")
	local filePath = NETEASE_DIR .. "/" .. safeName .. ".mp3"

	if _isfile and _isfile(filePath) then
		local sound = Instance.new("Sound")
		local assetUrl = _getcustomasset(filePath)
		sound.SoundId = assetUrl
		startNeteasePlayback(sound, song, statusLabel)
		return
	end

	statusLabel.Text = "下载中: " .. song.singer .. " - " .. song.name
	task.spawn(function()
		local body = nil
		local okHttp, resHttp = pcall(function()
			if http_request then
				return http_request({ Url = playUrl, Method = "GET" })
			elseif syn and syn.request then
				return syn.request({ Url = playUrl, Method = "GET" })
			elseif request then
				return request({ Url = playUrl, Method = "GET" })
			end
		end)
		if okHttp and resHttp then
			if type(resHttp) == "string" then
				body = resHttp
			elseif resHttp.Body then
				body = resHttp.Body
			elseif resHttp.body then
				body = resHttp.body
			end
		end

		if not body or #body < 100 then
			statusLabel.Text = "✗ 下载失败, 可能是网络问题或需要VIP"
			return
		end

		local okWrite = false
		if _writefile then
			okWrite = pcall(function() _writefile(filePath, body) end)
			if not okWrite then
				okWrite = pcall(function() _writefile(safeName .. ".mp3", body) end)
				if okWrite then filePath = safeName .. ".mp3" end
			end
		end

		if not okWrite then
			statusLabel.Text = "✗ 文件保存失败"
			return
		end

		local assetUrl = nil
		local okAsset = pcall(function() assetUrl = _getcustomasset(filePath) end)
		if not okAsset or not assetUrl then
			statusLabel.Text = "✗ 无法创建音频资源"
			return
		end

		local sound = Instance.new("Sound")
		sound.SoundId = assetUrl
		startNeteasePlayback(sound, song, statusLabel)
	end)
end

-- 播放指定歌曲
local function playNeteaseSong(song, statusLabel)
	stopNeteaseMusic()
	NeteaseState.statusLabel = statusLabel
	statusLabel.Text = "获取播放链接中..."
	neteaseGetPlayUrl(song, function(playUrl, err)
		if not playUrl then
			statusLabel.Text = "✗ " .. (err or "播放失败")
			return
		end
		NeteaseState.currentSong = song
		downloadAndPlayNetease(playUrl, song, statusLabel)
	end)
end

-- 网易云音乐页
do
	local page = addTab("网易云", "🎧")
	makeSectionLabel(page, "网易云音乐搜索")

	-- 搜索输入框 + 按钮
	local searchContainer = trackInstance(Instance.new("Frame"))
	searchContainer.Size = UDim2.new(1, -5, 0, 34)
	searchContainer.BackgroundTransparency = 1
	searchContainer.Parent = page

	local searchBox = trackInstance(Instance.new("TextBox"))
	searchBox.Size = UDim2.new(1, -90, 0, 34)
	searchBox.BackgroundColor3 = Theme.Element
	searchBox.BorderSizePixel = 0
	searchBox.Text = ""
	searchBox.PlaceholderText = "输入歌名或歌手名"
	searchBox.TextColor3 = Theme.Text
	searchBox.Font = FontMain
	searchBox.TextSize = 13
	searchBox.ClearTextOnFocus = false
	searchBox.TextXAlignment = Enum.TextXAlignment.Left
	local nsbC = trackInstance(Instance.new("UICorner"))
	nsbC.CornerRadius = UDim.new(0, 6)
	nsbC.Parent = searchBox
	local nsbP = trackInstance(Instance.new("UIPadding"))
	nsbP.PaddingLeft = UDim.new(0, 10)
	nsbP.Parent = searchBox
	searchBox.Parent = searchContainer

	local searchBtn = trackInstance(Instance.new("TextButton"))
	searchBtn.Size = UDim2.fromOffset(80, 34)
	searchBtn.Position = UDim2.new(1, -80, 0, 0)
	searchBtn.BackgroundColor3 = Theme.AccentDark
	searchBtn.Text = "搜索"
	searchBtn.TextColor3 = Theme.Text
	searchBtn.Font = FontBold
	searchBtn.TextSize = 13
	searchBtn.AutoButtonColor = false
	searchBtn.BorderSizePixel = 0
	local nsbc2 = trackInstance(Instance.new("UICorner"))
	nsbc2.CornerRadius = UDim.new(0, 6)
	nsbc2.Parent = searchBtn
	searchBtn.Parent = searchContainer

	-- 状态标签
	local statusLabel = trackInstance(Instance.new("TextLabel"))
	statusLabel.Size = UDim2.new(1, -5, 0, 20)
	statusLabel.BackgroundTransparency = 1
	statusLabel.Text = "输入关键词后点击搜索"
	statusLabel.TextColor3 = Theme.SubText
	statusLabel.Font = FontMain
	statusLabel.TextSize = 12
	statusLabel.TextXAlignment = Enum.TextXAlignment.Left
	statusLabel.Parent = page

	-- 搜索结果列表容器 (可滚动)
	local resultsFrame = trackInstance(Instance.new("ScrollingFrame"))
	resultsFrame.Size = UDim2.new(1, -5, 0, 200)
	resultsFrame.BackgroundTransparency = 1
	resultsFrame.BorderSizePixel = 0
	resultsFrame.ScrollBarThickness = 4
	resultsFrame.ScrollBarImageColor3 = Theme.Stroke
	resultsFrame.CanvasSize = UDim2.new(0, 0, 0, 0)
	resultsFrame.Parent = page

	local resultsLayout = trackInstance(Instance.new("UIListLayout"))
	resultsLayout.FillDirection = Enum.FillDirection.Vertical
	resultsLayout.SortOrder = Enum.SortOrder.LayoutOrder
	resultsLayout.Padding = UDim.new(0, 4)
	resultsLayout.Parent = resultsFrame

	trackConnection(resultsLayout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
		resultsFrame.CanvasSize = UDim2.new(0, 0, 0, resultsLayout.AbsoluteContentSize.Y)
	end))

	-- 清空结果列表
	local function clearResults()
		for _, child in ipairs(resultsFrame:GetChildren()) do
			if child:IsA("GuiObject") then
				child:Destroy()
			end
		end
	end

	-- 格式化时长 (秒 -> mm:ss)
	local function formatDuration(sec)
		local m = math.floor(sec / 60)
		local s = math.floor(sec % 60)
		return string.format("%d:%02d", m, s)
	end

	-- 显示搜索结果
	local function displayResults(results)
		clearResults()
		for i, song in ipairs(results) do
			local item = trackInstance(Instance.new("TextButton"))
			item.Size = UDim2.new(1, 0, 0, 40)
			item.BackgroundColor3 = Theme.Element
			item.Text = ""
			item.AutoButtonColor = false
			item.BorderSizePixel = 0
			local iC = trackInstance(Instance.new("UICorner"))
			iC.CornerRadius = UDim.new(0, 4)
			iC.Parent = item

			local songLabel = trackInstance(Instance.new("TextLabel"))
			songLabel.Size = UDim2.new(1, -95, 0, 40)
			songLabel.BackgroundTransparency = 1
			songLabel.Text = song.singer .. " - " .. song.name
			songLabel.TextColor3 = Theme.Text
			songLabel.Font = FontMain
			songLabel.TextSize = 12
			songLabel.TextXAlignment = Enum.TextXAlignment.Left
			songLabel.TextTruncate = Enum.TextTruncate.AtEnd
			local slP = trackInstance(Instance.new("UIPadding"))
			slP.PaddingLeft = UDim.new(0, 8)
			slP.Parent = songLabel
			songLabel.Parent = item

			-- VIP / 付费标记
			if song.fee and song.fee > 0 then
				local vipTag = trackInstance(Instance.new("TextLabel"))
				vipTag.Size = UDim2.fromOffset(28, 16)
				vipTag.Position = UDim2.new(1, -95, 0.5, -8)
				vipTag.BackgroundTransparency = 0
				if song.fee == 8 then
					-- 试听
					vipTag.Text = "试听"
					vipTag.BackgroundColor3 = Color3.fromRGB(100, 100, 120)
				else
					-- VIP (fee=1 或 4)
					vipTag.Text = "VIP"
					vipTag.BackgroundColor3 = Color3.fromRGB(200, 160, 40)
				end
				vipTag.TextColor3 = Color3.fromRGB(255, 255, 255)
				vipTag.Font = FontBold
				vipTag.TextSize = 10
				vipTag.TextScaled = false
				local vtC = trackInstance(Instance.new("UICorner"))
				vtC.CornerRadius = UDim.new(0, 3)
				vtC.Parent = vipTag
				vipTag.Parent = item
			end

			local durLabel = trackInstance(Instance.new("TextLabel"))
			durLabel.Size = UDim2.fromOffset(55, 40)
			durLabel.Position = UDim2.new(1, -60, 0, 0)
			durLabel.BackgroundTransparency = 1
			durLabel.Text = formatDuration(song.duration)
			durLabel.TextColor3 = Theme.SubText
			durLabel.Font = FontMain
			durLabel.TextSize = 11
			durLabel.TextXAlignment = Enum.TextXAlignment.Right
			durLabel.Parent = item

			trackConnection(item.MouseButton1Click:Connect(function()
				playNeteaseSong(song, statusLabel)
			end))
			trackConnection(item.MouseEnter:Connect(function()
				item.BackgroundColor3 = Theme.Hover
			end))
			trackConnection(item.MouseLeave:Connect(function()
				item.BackgroundColor3 = Theme.Element
			end))

			item.Parent = resultsFrame
		end
	end

	-- 执行搜索
	local function doSearch()
		local keyword = searchBox.Text
		if keyword == "" or keyword == nil then
			statusLabel.Text = "请输入搜索关键词"
			return
		end
		statusLabel.Text = "搜索中..."
		clearResults()
		neteaseSearch(keyword, function(results, err)
			if err and #results == 0 then
				statusLabel.Text = "✗ " .. err
				return
			end
			NeteaseState.searchResults = results
			displayResults(results)
			statusLabel.Text = "共 " .. #results .. " 个结果, 点击歌曲播放"
		end)
	end

	trackConnection(searchBtn.MouseButton1Click:Connect(function() doSearch() end))
	trackConnection(searchBox.FocusLost:Connect(function(enter)
		if enter then doSearch() end
	end))

	-- 播放控制
	makeSectionLabel(page, "播放控制")
	local btnRow = trackInstance(Instance.new("Frame"))
	btnRow.Size = UDim2.new(1, -5, 0, 34)
	btnRow.BackgroundTransparency = 1
	btnRow.Parent = page

	local function makeCtrlButton(text, x, w, callback)
		local btn = trackInstance(Instance.new("TextButton"))
		btn.Size = UDim2.fromOffset(w or 60, 34)
		btn.Position = UDim2.fromOffset(x, 0)
		btn.BackgroundColor3 = Theme.AccentDark
		btn.Text = text
		btn.TextColor3 = Theme.Text
		btn.Font = FontBold
		btn.TextSize = 13
		btn.AutoButtonColor = false
		btn.BorderSizePixel = 0
		local bc = trackInstance(Instance.new("UICorner"))
		bc.CornerRadius = UDim.new(0, 6)
		bc.Parent = btn
		local baseColor = Theme.AccentDark
		trackConnection(btn.MouseButton1Click:Connect(callback))
		trackConnection(btn.MouseEnter:Connect(function()
			btn.BackgroundColor3 = Theme.Accent
		end))
		trackConnection(btn.MouseLeave:Connect(function()
			btn.BackgroundColor3 = baseColor
		end))
		btn.Parent = btnRow
		return btn, function(c) if c then baseColor = c end end
	end

	-- 暂停/播放按钮
	local playBtn = makeCtrlButton("▶ 播放", 0, 100, function()
		if NeteaseState.currentSound then
			toggleNeteasePause()
		else
			statusLabel.Text = "请先选择一首歌曲播放"
		end
	end)
	NeteaseState.playBtn = playBtn

	-- 单次/循环按钮
	local loopBtn, setLoopBase = makeCtrlButton("➡ 单次", 110, 100, function()
		NeteaseState.loopMode = not NeteaseState.loopMode
		if NeteaseState.currentSound then
			pcall(function() NeteaseState.currentSound.Looped = NeteaseState.loopMode end)
		end
		local btn = NeteaseState.loopBtn
		if not btn then return end
		if NeteaseState.loopMode then
			btn.Text = "🔁 循环"
			btn.BackgroundColor3 = Theme.Accent
			setLoopBase(Theme.Accent)
		else
			btn.Text = "➡ 单次"
			btn.BackgroundColor3 = Theme.AccentDark
			setLoopBase(Theme.AccentDark)
		end
	end)
	NeteaseState.loopBtn = loopBtn

	-- 进度条
	local progLabel = trackInstance(Instance.new("TextLabel"))
	progLabel.Size = UDim2.new(1, -5, 0, 18)
	progLabel.BackgroundTransparency = 1
	progLabel.Text = "0:00 / 0:00"
	progLabel.TextColor3 = Theme.SubText
	progLabel.Font = FontMain
	progLabel.TextSize = 11
	progLabel.TextXAlignment = Enum.TextXAlignment.Left
	progLabel.Parent = page
	NeteaseState.progLabel = progLabel

	local progBar = trackInstance(Instance.new("Frame"))
	progBar.Size = UDim2.new(1, -5, 0, 16)
	progBar.BackgroundColor3 = Theme.Element
	progBar.BorderSizePixel = 0
	local npbC = trackInstance(Instance.new("UICorner"))
	npbC.CornerRadius = UDim.new(0, 4)
	npbC.Parent = progBar
	progBar.Parent = page

	local progFill = trackInstance(Instance.new("Frame"))
	progFill.Size = UDim2.new(0, 0, 1, 0)
	progFill.BackgroundColor3 = Theme.Accent
	progFill.BorderSizePixel = 0
	local npfC = trackInstance(Instance.new("UICorner"))
	npfC.CornerRadius = UDim.new(0, 4)
	npfC.Parent = progFill
	progFill.Parent = progBar
	NeteaseState.progFill = progFill

	-- 进度条拖拽
	local progDragging = false
	trackConnection(progBar.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			if not NeteaseState.currentSound then return end
			progDragging = true
			local rel = (input.Position.X - progBar.AbsolutePosition.X) / progBar.AbsoluteSize.X
			rel = math.clamp(rel, 0, 1)
			progFill.Size = UDim2.new(rel, 0, 1, 0)
			local len = NeteaseState.currentSound.TimeLength
			if len and len > 0 then
				NeteaseState.currentSound.TimePosition = rel * len
				progLabel.Text = formatTime(rel * len) .. " / " .. formatTime(len)
			end
		end
	end))
	trackConnection(progBar.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			progDragging = false
		end
	end))
	trackConnection(UserInputService.InputChanged:Connect(function(input)
		if progDragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			if not NeteaseState.currentSound then return end
			local rel = (input.Position.X - progBar.AbsolutePosition.X) / progBar.AbsoluteSize.X
			rel = math.clamp(rel, 0, 1)
			progFill.Size = UDim2.new(rel, 0, 1, 0)
			local len = NeteaseState.currentSound.TimeLength
			if len and len > 0 then
				progLabel.Text = formatTime(rel * len) .. " / " .. formatTime(len)
			end
		end
	end))

	-- 进度条自动更新 (每 0.5 秒)
	task.spawn(function()
		while true do
			task.wait(0.5)
			if NeteaseState.currentSound and not progDragging then
				local pos = NeteaseState.currentSound.TimePosition or 0
				local len = NeteaseState.currentSound.TimeLength or 0
				if len > 0 then
					local rel = pos / len
					rel = math.clamp(rel, 0, 1)
					progFill.Size = UDim2.new(rel, 0, 1, 0)
					progLabel.Text = formatTime(pos) .. " / " .. formatTime(len)
				end
			end
		end
	end)

	-- 音量控制
	makeSectionLabel(page, "音量")
	local volLabel = trackInstance(Instance.new("TextLabel"))
	volLabel.Size = UDim2.new(1, -5, 0, 20)
	volLabel.BackgroundTransparency = 1
	volLabel.Text = "音量: 100%"
	volLabel.TextColor3 = Theme.SubText
	volLabel.Font = FontMain
	volLabel.TextSize = 12
	volLabel.TextXAlignment = Enum.TextXAlignment.Left
	volLabel.Parent = page

	local volSlider = trackInstance(Instance.new("Frame"))
	volSlider.Size = UDim2.new(1, -5, 0, 20)
	volSlider.BackgroundColor3 = Theme.Element
	volSlider.BorderSizePixel = 0
	local nvC = trackInstance(Instance.new("UICorner"))
	nvC.CornerRadius = UDim.new(0, 4)
	nvC.Parent = volSlider
	volSlider.Parent = page

	local volFill = trackInstance(Instance.new("Frame"))
	volFill.Size = UDim2.new(1, 0, 1, 0)
	volFill.BackgroundColor3 = Theme.Accent
	volFill.BorderSizePixel = 0
	local nvfC = trackInstance(Instance.new("UICorner"))
	nvfC.CornerRadius = UDim.new(0, 4)
	nvfC.Parent = volFill
	volFill.Parent = volSlider

	-- 音量拖拽
	local volDragging = false
	trackConnection(volSlider.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			volDragging = true
			local rel = (input.Position.X - volSlider.AbsolutePosition.X) / volSlider.AbsoluteSize.X
			rel = math.clamp(rel, 0, 1)
			volFill.Size = UDim2.new(rel, 0, 1, 0)
			local vol = math.floor(rel * 100)
			volLabel.Text = "音量: " .. vol .. "%"
			NeteaseState.volume = rel
			if NeteaseState.currentSound then
				NeteaseState.currentSound.Volume = rel
			end
		end
	end))
	trackConnection(volSlider.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			volDragging = false
		end
	end))
	trackConnection(UserInputService.InputChanged:Connect(function(input)
		if volDragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			local rel = (input.Position.X - volSlider.AbsolutePosition.X) / volSlider.AbsoluteSize.X
			rel = math.clamp(rel, 0, 1)
			volFill.Size = UDim2.new(rel, 0, 1, 0)
			local vol = math.floor(rel * 100)
			volLabel.Text = "音量: " .. vol .. "%"
			NeteaseState.volume = rel
			if NeteaseState.currentSound then
				NeteaseState.currentSound.Volume = rel
			end
		end
	end))
end

-- 交互页
do
	local page = addTab("交互", "✋")
	makeSectionLabel(page, "ProximityPrompt")
	makeToggle(page, "秒交互 (ProximityPrompt)", function(v) setInstantPrompt(v) end, nil, "promptInstantEnabled")
	makeSectionLabel(page, "聊天翻译")
	makeToggle(page, "自动翻译聊天内容", function(v) setChatTranslation(v) end, nil, "chatTranslateEnabled")
	makeDropdown(page, "目标语言", {"中文", "English", "日本語", "한국어"}, "中文", function(opt)
		State.translateTargetLang = opt
	end, "translateTargetLang")
	makeSectionLabel(page, "文字翻译")
	-- 翻译目标语言 (文字翻译用)
	makeDropdown(page, "翻译目标语言", {"English", "中文", "日本語", "한국어", "Français", "Español", "Deutsch", "Português", "Русский", "Italiano", "العربية", "हिन्दी", "Tiếng Việt", "ไทย", "Türkçe", "Nederlands", "Polski", "Indonesia", "Українська", "čeština"}, "English", function(opt)
		State.textTranslateTargetLang = opt
	end, "textTranslateTargetLang")
	-- 输入框
	local inputBox = trackInstance(Instance.new("TextBox"))
	inputBox.Size = UDim2.new(1, -65, 0, 34)
	inputBox.BackgroundColor3 = Theme.Element
	inputBox.BorderSizePixel = 0
	inputBox.Text = ""
	inputBox.PlaceholderText = "输入要翻译的文字..."
	inputBox.TextColor3 = Theme.Text
	inputBox.Font = FontMain
	inputBox.TextSize = 13
	inputBox.ClearTextOnFocus = false
	inputBox.TextXAlignment = Enum.TextXAlignment.Left
	inputBox.Parent = page
	local ibc = trackInstance(Instance.new("UICorner"))
	ibc.CornerRadius = UDim.new(0, 6)
	ibc.Parent = inputBox
	-- 发送按钮
	local sendBtn = trackInstance(Instance.new("TextButton"))
	sendBtn.Size = UDim2.fromOffset(55, 34)
	sendBtn.Position = UDim2.new(1, -60, 0, 0)
	sendBtn.BackgroundColor3 = Theme.AccentDark
	sendBtn.Text = "发送"
	sendBtn.TextColor3 = Theme.Text
	sendBtn.Font = FontBold
	sendBtn.TextSize = 13
	sendBtn.BorderSizePixel = 0
	sendBtn.AutoButtonColor = false
	local sbc = trackInstance(Instance.new("UICorner"))
	sbc.CornerRadius = UDim.new(0, 6)
	sbc.Parent = sendBtn
	sendBtn.Parent = page
	-- 状态标签
	local trStatus = trackInstance(Instance.new("TextLabel"))
	trStatus.Size = UDim2.new(1, -5, 0, 20)
	trStatus.BackgroundTransparency = 1
	trStatus.Text = ""
	trStatus.TextColor3 = Theme.SubText
	trStatus.Font = FontMain
	trStatus.TextSize = 12
	trStatus.TextXAlignment = Enum.TextXAlignment.Left
	trStatus.Parent = page
	-- 执行翻译并发送
	local function doTranslate()
		local text = inputBox.Text
		if text == "" then
			trStatus.Text = "请输入文字"
			return
		end
		trStatus.Text = "翻译中..."
		task.spawn(function()
			local targetLang = State.textTranslateTargetLang or "中文"
			local translated = translateText(text, targetLang)
			if not translated then
				trStatus.Text = "翻译失败 (HTTP 不可用)"
				return
			end
			trStatus.Text = "译文: " .. translated
			sendChatMessage(translated)
			showToast("✓ 发送成功\n原文: " .. text .. "\n译文: " .. translated)
			inputBox.Text = ""
		end)
	end
	trackConnection(sendBtn.MouseButton1Click:Connect(function() doTranslate() end))
	trackConnection(inputBox.FocusLost:Connect(function(enter)
		if enter then doTranslate() end
	end))
	trackConnection(sendBtn.MouseEnter:Connect(function() sendBtn.BackgroundColor3 = Theme.Accent end))
	trackConnection(sendBtn.MouseLeave:Connect(function() sendBtn.BackgroundColor3 = Theme.AccentDark end))
end

-- 客户端页
do
	local page = addTab("客户端", "🧍")
	makeSectionLabel(page, "角色")
	makeToggle(page, "隐身 (客户端)", function(v) setInvisible(v) end, nil, "invisibleEnabled")
	makeSectionLabel(page, "血量")
	makeToggle(page, "锁定血量", function(v) setGodHealth(v) end, nil, "godHealthEnabled")
	makeSlider(page, "血量值", 1, 9999, 100, "", function(v)
		State.customHealth = v
		if State.godHealthEnabled then
			local c = getLocalChar()
			local hum = c and c:FindFirstChildOfClass("Humanoid")
			if hum then
				hum.MaxHealth = v
				hum.Health = v
			end
		end
	end, "customHealth")
end

--========================================================
-- 配置保存 / 加载 (支持命名)
--========================================================

-- 扫描 GSEN 目录下所有 *_config.json, 返回配置名列表
local function scanConfigs()
	local list = {}
	-- 策略1: 优先使用 listfiles 扫描目录
	if _listfiles and _isfolder and _isfolder(CONFIG_DIR) then
		local ok, result = pcall(_listfiles, CONFIG_DIR)
		if ok and type(result) == "table" then
			for _, fpath in ipairs(result) do
				local fname = fpath:match("([^/\\]+)$") or fpath
				local name = fname:match("^(.+)_config%.json$")
				if name then
					table.insert(list, name)
				end
			end
		end
	end
	-- 策略2: 如果目录扫描没结果, 尝试根目录扫描 (平铺模式)
	if #list == 0 and _listfiles then
		local ok, result = pcall(_listfiles, "")
		if ok and type(result) == "table" then
			for _, fpath in ipairs(result) do
				local fname = fpath:match("([^/\\]+)$") or fpath
				local name = fname:match("^(.+)_config%.json$")
				if name then
					table.insert(list, name)
				end
			end
		end
	end
	-- 策略3: 尝试列出当前工作目录下的文件
	if #list == 0 and _listfiles then
		local ok, result = pcall(_listfiles, ".")
		if ok and type(result) == "table" then
			for _, fpath in ipairs(result) do
				local fname = fpath:match("([^/\\]+)$") or fpath
				local name = fname:match("^(.+)_config%.json$")
				if name then
					table.insert(list, name)
				end
			end
		end
	end
	table.sort(list)
	return list
end

-- 保存配置 (name = 玩家自定义名称)
local function saveConfig(name)
	if not name or name == "" then
		return false, "请输入配置名称"
	end
	-- 过滤非法文件名字符
	name = name:gsub("[/\\:*?\"<>|%c]", "_")
	local filePath = CONFIG_DIR .. "/" .. name .. "_config.json"
	local config = {}
	for _, ctrl in ipairs(ConfigControls) do
		local ok, value = pcall(ctrl.get)
		if ok and value ~= nil then
			config[ctrl.key] = value
		end
	end
	local ok, json = pcall(function()
		return HttpService:JSONEncode(config)
	end)
	if not ok or not json then
		return false, "序列化失败"
	end
	local success, err, usedPath = safeWriteFile(filePath, json)
	if not success then
		return false, err or "写入文件失败"
	end
	return true, usedPath or filePath
end

-- 加载指定名称的配置
local function loadConfig(name)
	if not name or name == "" then
		return false, "请选择配置"
	end
	name = name:gsub("[/\\:*?\"<>|%c]", "_")
	local filePath = CONFIG_DIR .. "/" .. name .. "_config.json"
	local content, usedPath = safeReadFile(filePath)
	if not content then
		return false, "配置文件不存在或读取失败"
	end
	local ok2, config = pcall(function()
		return HttpService:JSONDecode(content)
	end)
	if not ok2 or type(config) ~= "table" then
		return false, "配置解析失败"
	end
	-- 先关闭所有已注册的开关 (避免叠加)
	for _, ctrl in ipairs(ConfigControls) do
		pcall(ctrl.apply, false)
	end
	-- 短暂等待让关闭逻辑完成
	task.wait(0.1)
	-- 逐个应用保存的值
	local applied = 0
	for _, ctrl in ipairs(ConfigControls) do
		local value = config[ctrl.key]
		if value ~= nil then
			local ok3 = pcall(ctrl.apply, value)
			if ok3 then applied = applied + 1 end
		end
	end
	return true, applied
end

-- 删除指定名称的配置
local function deleteConfig(name)
	if not name or name == "" then
		return false, "请选择配置"
	end
	name = name:gsub("[/\\:*?\"<>|%c]", "_")
	local filePath = CONFIG_DIR .. "/" .. name .. "_config.json"
	-- 尝试多种路径删除
	local paths = { filePath }
	local flatName = filePath:match("[^/\\]+$")
	if flatName and flatName ~= filePath then table.insert(paths, flatName) end
	local altPath = filePath:gsub("/", "\\")
	if altPath ~= filePath then table.insert(paths, altPath) end

	if not _delfile then
		return false, "执行器不支持删除文件"
	end

	local deleted = false
	for _, p in ipairs(paths) do
		if safeIsFile(p) then
			local ok = pcall(_delfile, p)
			if ok then
				deleted = true
				break
			end
		end
	end
	if not deleted then
		return false, "配置文件不存在或删除失败"
	end
	return true
end

-- 手动注册飞行速度 (飞行面板使用自定义输入框而非 makeSlider)
ConfigControls[#ConfigControls + 1] = {
	key = "flySpeed",
	get = function() return State.flySpeed end,
	apply = function(v)
		v = tonumber(v) or 60
		v = math.clamp(v, 10, 10000)
		State.flySpeed = v
		if FlySpeedInput and FlySpeedInput.Parent then
			FlySpeedInput.Text = tostring(v)
		end
	end,
}

-- 设置页
do
	-- 在构建 UI 前加载保存的动画模式, 确保 dropdown 初始值正确
	local savedMode = loadAnimMode()
	if savedMode and (savedMode == "碎片" or savedMode == "平滑") then
		State.animMode = savedMode
	end
	local page = addTab("设置", "⚙")
	makeButton(page, "关于", function()
		-- 如果已存在则先销毁
		if MainGui:FindFirstChild("AboutPanel") then
			MainGui.AboutPanel:Destroy()
		end

		local aboutPanel = trackInstance(Instance.new("Frame"))
		aboutPanel.Name = "AboutPanel"
		aboutPanel.Size = UDim2.fromOffset(200, 180)
		aboutPanel.Position = UDim2.new(0.5, -100, 0.5, -90)
		aboutPanel.BackgroundColor3 = Theme.Window
		aboutPanel.BorderSizePixel = 0
		aboutPanel.Active = true
		aboutPanel.ZIndex = 100
		local apC = trackInstance(Instance.new("UICorner"))
		apC.CornerRadius = UDim.new(0, 10)
		apC.Parent = aboutPanel
		local apS = trackInstance(Instance.new("UIStroke"))
		apS.Color = Theme.Accent
		apS.Thickness = 1
		apS.Parent = aboutPanel
		aboutPanel.Parent = MainGui

		-- 标题栏 (拖拽区域)
		local aboutTitle = trackInstance(Instance.new("Frame"))
		aboutTitle.Size = UDim2.new(1, 0, 0, 30)
		aboutTitle.BackgroundColor3 = Theme.TabBar
		aboutTitle.BorderSizePixel = 0
		aboutTitle.ZIndex = 101
		local atC = trackInstance(Instance.new("UICorner"))
		atC.CornerRadius = UDim.new(0, 10)
		atC.Parent = aboutTitle
		local atMask = trackInstance(Instance.new("Frame"))
		atMask.Size = UDim2.new(1, 0, 0, 15)
		atMask.Position = UDim2.fromOffset(0, 15)
		atMask.BackgroundColor3 = Theme.TabBar
		atMask.BorderSizePixel = 0
		atMask.ZIndex = 101
		atMask.Parent = aboutTitle
		local aboutTitleText = trackInstance(Instance.new("TextLabel"))
		aboutTitleText.Size = UDim2.new(1, -30, 1, 0)
		aboutTitleText.Position = UDim2.fromOffset(10, 0)
		aboutTitleText.BackgroundTransparency = 1
		aboutTitleText.Text = "关于"
		aboutTitleText.TextColor3 = Theme.Text
		aboutTitleText.Font = FontBold
		aboutTitleText.TextSize = 13
		aboutTitleText.TextXAlignment = Enum.TextXAlignment.Left
		aboutTitleText.ZIndex = 102
		aboutTitleText.Parent = aboutTitle
		aboutTitle.Parent = aboutPanel

		-- 关闭按钮
		local aboutCloseBtn = trackInstance(Instance.new("TextButton"))
		aboutCloseBtn.Size = UDim2.fromOffset(20, 20)
		aboutCloseBtn.Position = UDim2.new(1, -25, 0, 5)
		aboutCloseBtn.BackgroundColor3 = Theme.Element
		aboutCloseBtn.Text = "X"
		aboutCloseBtn.TextColor3 = Theme.Red
		aboutCloseBtn.Font = FontBold
		aboutCloseBtn.TextSize = 11
		aboutCloseBtn.BorderSizePixel = 0
		aboutCloseBtn.ZIndex = 102
		aboutCloseBtn.AutoButtonColor = false
		local acC = trackInstance(Instance.new("UICorner"))
		acC.CornerRadius = UDim.new(0, 5)
		acC.Parent = aboutCloseBtn
		trackConnection(aboutCloseBtn.MouseButton1Click:Connect(function()
			aboutPanel:Destroy()
		end))
		trackConnection(aboutCloseBtn.MouseEnter:Connect(function() aboutCloseBtn.BackgroundColor3 = Theme.Hover end))
		trackConnection(aboutCloseBtn.MouseLeave:Connect(function() aboutCloseBtn.BackgroundColor3 = Theme.Element end))
		aboutCloseBtn.Parent = aboutTitle

		-- 内容滚动区: 保持外层悬浮窗尺寸不变, 内容超出时在内部滚动
		local aboutScroll = trackInstance(Instance.new("ScrollingFrame"))
		aboutScroll.Name = "AboutScroll"
		aboutScroll.Size = UDim2.new(1, -12, 1, -38)
		aboutScroll.Position = UDim2.fromOffset(6, 32)
		aboutScroll.BackgroundTransparency = 1
		aboutScroll.BorderSizePixel = 0
		aboutScroll.ScrollBarThickness = 4
		aboutScroll.ScrollBarImageColor3 = Theme.Stroke
		aboutScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
		aboutScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
		aboutScroll.Parent = aboutPanel

		local aboutContent = trackInstance(Instance.new("Frame"))
		aboutContent.Name = "AboutContent"
		aboutContent.Size = UDim2.new(1, -6, 0, 250)
		aboutContent.BackgroundTransparency = 1
		aboutContent.BorderSizePixel = 0
		aboutContent.Parent = aboutScroll

		local aboutContentLayout = trackInstance(Instance.new("UIListLayout"))
		aboutContentLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
		aboutContentLayout.SortOrder = Enum.SortOrder.LayoutOrder
		aboutContentLayout.Padding = UDim.new(0, 8)
		aboutContentLayout.Parent = aboutContent

		trackConnection(aboutContentLayout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
			aboutContent.Size = UDim2.new(1, -6, 0, aboutContentLayout.AbsoluteContentSize.Y + 6)
			aboutScroll.CanvasSize = UDim2.new(0, 0, 0, aboutContentLayout.AbsoluteContentSize.Y + 6)
		end))

		-- 头像
		local avatarFrame = trackInstance(Instance.new("Frame"))
		avatarFrame.Size = UDim2.fromOffset(64, 64)
		avatarFrame.Position = UDim2.new(0.5, -32, 0, 0)
		avatarFrame.BackgroundColor3 = Theme.Element
		avatarFrame.BorderSizePixel = 0
		avatarFrame.ZIndex = 101
		avatarFrame.LayoutOrder = 1
		local avC = trackInstance(Instance.new("UICorner"))
		avC.CornerRadius = UDim.new(0, 32)
		avC.Parent = avatarFrame
		local avS = trackInstance(Instance.new("UIStroke"))
		avS.Color = Theme.Accent
		avS.Thickness = 2
		avS.Parent = avatarFrame
		avatarFrame.Parent = aboutContent

		-- 用 ImageLabel 加载头像
		local avatarImg = trackInstance(Instance.new("ImageLabel"))
		avatarImg.Size = UDim2.fromScale(1, 1)
		avatarImg.BackgroundTransparency = 1
		avatarImg.ZIndex = 102
		-- 获取用户头像 (headshot)
		local ok, thumb = pcall(function()
			return Players:GetUserThumbnailAsync(LocalPlayer.UserId, Enum.ThumbnailType.HeadShot, Enum.ThumbnailSize.Size420x420)
		end)
		if ok and thumb then
			avatarImg.Image = thumb
		end
		avatarImg.Parent = avatarFrame

		-- 用户名
		local usernameLabel = trackInstance(Instance.new("TextLabel"))
		usernameLabel.Size = UDim2.new(1, -20, 0, 20)
		usernameLabel.Position = UDim2.fromOffset(10, 0)
		usernameLabel.BackgroundTransparency = 1
		usernameLabel.Text = "@" .. LocalPlayer.Name
		usernameLabel.TextColor3 = Theme.Accent
		usernameLabel.Font = FontBold
		usernameLabel.TextSize = 13
		usernameLabel.ZIndex = 101
		usernameLabel.LayoutOrder = 2
		usernameLabel.Parent = aboutContent

		-- 昵称 (DisplayName)
		local nickLabel = trackInstance(Instance.new("TextLabel"))
		nickLabel.Size = UDim2.new(1, -20, 0, 20)
		nickLabel.Position = UDim2.fromOffset(10, 0)
		nickLabel.BackgroundTransparency = 1
		nickLabel.Text = LocalPlayer.DisplayName
		nickLabel.TextColor3 = Theme.Text
		nickLabel.Font = FontMain
		nickLabel.TextSize = 14
		nickLabel.ZIndex = 101
		nickLabel.LayoutOrder = 3
		nickLabel.Parent = aboutContent

		local authorLabel = trackInstance(Instance.new("TextLabel"))
		authorLabel.Size = UDim2.new(1, -20, 0, 20)
		authorLabel.Position = UDim2.fromOffset(10, 0)
		authorLabel.BackgroundTransparency = 1
		authorLabel.Text = "作者：円侁"
		authorLabel.TextColor3 = Theme.Text
		authorLabel.Font = FontBold
		authorLabel.TextSize = 13
		authorLabel.TextWrapped = true
		authorLabel.ZIndex = 101
		authorLabel.LayoutOrder = 4
		authorLabel.Parent = aboutContent

		local supportLabel = trackInstance(Instance.new("TextLabel"))
		supportLabel.Size = UDim2.new(1, -20, 0, 42)
		supportLabel.Position = UDim2.fromOffset(10, 0)
		supportLabel.BackgroundTransparency = 1
		supportLabel.Text = "技术支持：TRAE、Chat GPT、豆包"
		supportLabel.TextColor3 = Theme.SubText
		supportLabel.Font = FontMain
		supportLabel.TextSize = 13
		supportLabel.TextWrapped = true
		supportLabel.ZIndex = 101
		supportLabel.LayoutOrder = 5
		supportLabel.Parent = aboutContent

		-- 拖拽 (仅标题栏可拖动)
		local dragging2, dragStart2, startPos2
		trackConnection(aboutTitle.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
				dragging2 = true
				dragStart2 = input.Position
				startPos2 = aboutPanel.Position
			end
		end))
		trackConnection(aboutTitle.InputEnded:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
				dragging2 = false
			end
		end))
		trackConnection(UserInputService.InputChanged:Connect(function(input)
			if dragging2 and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
				local delta = input.Position - dragStart2
				aboutPanel.Position = UDim2.new(
					startPos2.X.Scale, startPos2.X.Offset + delta.X,
					startPos2.Y.Scale, startPos2.Y.Offset + delta.Y
				)
			end
		end))
	end)

	makeSectionLabel(page, "展开动画")
	local animDropdown = makeDropdown(page, "动画风格", {"碎片", "平滑"}, State.animMode, function(opt)
		State.animMode = opt
		local ok, err = saveAnimMode(opt)
		if ok then
			showToast("✓ 展开动画已切换为: " .. opt)
		else
			showToast("⚠ 展开动画已切换为: " .. opt .. "\n但配置未能自动保存\n" .. tostring(err))
		end
	end, "animMode")

	makeSectionLabel(page, "配置管理")
	-- 前向声明 (保存按钮回调需要引用)
	local configDropdown, selectedConfig

	-- 命名保存弹窗
	local function showSaveNamePanel()
		-- 防止重复弹出
		if MainGui:FindFirstChild("SaveNamePanel") then
			MainGui.SaveNamePanel:Destroy()
		end

		local panel = trackInstance(Instance.new("Frame"))
		panel.Name = "SaveNamePanel"
		panel.Size = UDim2.fromOffset(280, 160)
		panel.Position = UDim2.new(0.5, -140, 0.5, -80)
		panel.BackgroundColor3 = Theme.Window
		panel.BorderSizePixel = 0
		panel.Active = true
		panel.ZIndex = 120
		local pC = trackInstance(Instance.new("UICorner"))
		pC.CornerRadius = UDim.new(0, 10)
		pC.Parent = panel
		local pS = trackInstance(Instance.new("UIStroke"))
		pS.Color = Theme.Accent
		pS.Thickness = 1
		pS.Transparency = 0.15
		pS.Parent = panel
		panel.Parent = MainGui

		-- 标题
		local title = trackInstance(Instance.new("TextLabel"))
		title.Size = UDim2.new(1, -24, 0, 30)
		title.Position = UDim2.fromOffset(12, 10)
		title.BackgroundTransparency = 1
		title.Text = "保存配置"
		title.TextColor3 = Theme.Text
		title.Font = FontBold
		title.TextSize = 15
		title.TextXAlignment = Enum.TextXAlignment.Left
		title.ZIndex = 121
		title.Parent = panel

		-- 输入框
		local nameBox = trackInstance(Instance.new("TextBox"))
		nameBox.Size = UDim2.new(1, -24, 0, 34)
		nameBox.Position = UDim2.fromOffset(12, 48)
		nameBox.BackgroundColor3 = Theme.Element
		nameBox.BorderSizePixel = 0
		nameBox.Text = ""
		nameBox.PlaceholderText = "输入配置名称..."
		nameBox.TextColor3 = Theme.Text
		nameBox.Font = FontMain
		nameBox.TextSize = 13
		nameBox.ClearTextOnFocus = false
		nameBox.TextXAlignment = Enum.TextXAlignment.Left
		nameBox.ZIndex = 121
		nameBox.Parent = panel
		local nbC = trackInstance(Instance.new("UICorner"))
		nbC.CornerRadius = UDim.new(0, 6)
		nbC.Parent = nameBox

		-- 焦点
		task.delay(0.1, function()
			if nameBox.Parent then nameBox:CaptureFocus() end
		end)

		-- 按钮辅助函数
		local function makePanelButton(text, x, color, hoverColor, callback)
			local btn = trackInstance(Instance.new("TextButton"))
			btn.Size = UDim2.fromOffset(118, 30)
			btn.Position = UDim2.fromOffset(x, 98)
			btn.BackgroundColor3 = color
			btn.BorderSizePixel = 0
			btn.Text = text
			btn.TextColor3 = Theme.Text
			btn.Font = FontBold
			btn.TextSize = 13
			btn.AutoButtonColor = false
			btn.ZIndex = 121
			local bc = trackInstance(Instance.new("UICorner"))
			bc.CornerRadius = UDim.new(0, 6)
			bc.Parent = btn
			trackConnection(btn.MouseEnter:Connect(function() btn.BackgroundColor3 = hoverColor end))
			trackConnection(btn.MouseLeave:Connect(function() btn.BackgroundColor3 = color end))
			trackConnection(btn.MouseButton1Click:Connect(callback))
			btn.Parent = panel
			return btn
		end

		-- 取消按钮
		makePanelButton("取消", 12, Theme.Element, Theme.Hover, function()
			if panel and panel.Parent then panel:Destroy() end
		end)

		-- 确认保存
		local function doSave()
			local name = nameBox.Text
			if name == "" then
				showToast("✗ 请输入配置名称")
				return
			end
			local ok, info = saveConfig(name)
			if ok then
				showToast("✓ 配置已保存\n名称: " .. name)
				local newList = scanConfigs()
				configDropdown.refresh(newList)
				configDropdown.valLbl.Text = name
				selectedConfig = name
			else
				showToast("✗ 保存失败\n" .. tostring(info))
			end
			if panel and panel.Parent then panel:Destroy() end
		end

		makePanelButton("确认保存", 150, Theme.AccentDark, Theme.Accent, doSave)

		-- 回车提交
		trackConnection(nameBox.FocusLost:Connect(function(enter)
			if enter then doSave() end
		end))
	end

	-- 保存配置按钮 (点击后弹出命名窗口)
	makeButton(page, "保存配置", function()
		showSaveNamePanel()
	end)

	-- 已保存的配置列表
	makeSectionLabel(page, "已保存的配置")
	configDropdown = makeDropdown(page, "选择配置", scanConfigs(), "(无配置)", function(opt)
		selectedConfig = opt
	end)
	selectedConfig = nil

	-- 刷新列表按钮
	makeButton(page, "刷新配置列表", function()
		local newList = scanConfigs()
		configDropdown.refresh(newList)
		if #newList == 0 then
			configDropdown.valLbl.Text = "(无配置)"
			showToast("配置列表已刷新 (无配置)")
		else
			configDropdown.valLbl.Text = "(选择配置)"
			showToast("配置列表已刷新\n共 " .. #newList .. " 个配置")
		end
		selectedConfig = nil
	end)

	-- 加载配置按钮
	makeButton(page, "加载配置", function()
		if not selectedConfig or selectedConfig == "(无配置)" then
			showToast("✗ 请先选择一个配置")
			return
		end
		local ok, result = loadConfig(selectedConfig)
		if ok then
			showToast("✓ 配置已加载\n名称: " .. selectedConfig .. "\n已应用 " .. tostring(result) .. " 项设置")
		else
			showToast("✗ 加载失败\n" .. tostring(result))
		end
	end)

	-- 删除配置按钮
	makeButton(page, "删除配置", function()
		if not selectedConfig or selectedConfig == "(无配置)" then
			showToast("✗ 请先选择一个配置")
			return
		end
		local configName = selectedConfig
		showConfirmDialog("确认删除配置？\n名称: " .. configName, function()
			local ok, err = deleteConfig(configName)
			if ok then
				showToast("✓ 配置已删除\n名称: " .. configName)
				local newList = scanConfigs()
				configDropdown.refresh(newList)
				if #newList == 0 then
					configDropdown.valLbl.Text = "(无配置)"
				else
					configDropdown.valLbl.Text = "(选择配置)"
				end
				selectedConfig = nil
			else
				showToast("✗ 删除失败\n" .. tostring(err))
			end
		end)
	end)

	makeSectionLabel(page, "说明")
	local info = trackInstance(Instance.new("TextLabel"))
	info.Size = UDim2.new(1, 0, 0, 80)
	info.BackgroundTransparency = 1
	info.Text = "右 Ctrl 切换菜单显隐\n关闭 = 重置全部功能并销毁窗口\n最小化 = 隐藏窗口并显示展开按钮\n展开动画 = 切换碎片/平滑风格\n配置管理 = 输入名称保存配置, 从列表选择加载/删除"
	info.TextColor3 = Theme.SubText
	info.Font = FontMain
	info.TextSize = 12
	info.TextWrapped = true
	info.TextXAlignment = Enum.TextXAlignment.Left
	info.TextYAlignment = Enum.TextYAlignment.Top
	info.Parent = page

	-- 清理音乐缓存
	makeSectionLabel(page, "缓存清理")
	makeButton(page, "清理酷狗音乐缓存", function()
		local count = 0
		if _listfiles and _isfile then
			local ok, files = pcall(_listfiles, MUSIC_DIR)
			if ok and type(files) == "table" then
				for _, f in ipairs(files) do
					if _delfile then
						local delOk = pcall(_delfile, f)
						if delOk then count = count + 1 end
					end
				end
			end
		end
		showToast("✓ 酷狗缓存已清理\n删除 " .. count .. " 个文件")
	end)
	makeButton(page, "清理网易云音乐缓存", function()
		local count = 0
		if _listfiles and _isfile then
			local ok, files = pcall(_listfiles, NETEASE_DIR)
			if ok and type(files) == "table" then
				for _, f in ipairs(files) do
					if _delfile then
						local delOk = pcall(_delfile, f)
						if delOk then count = count + 1 end
					end
				end
			end
		end
		showToast("✓ 网易云缓存已清理\n删除 " .. count .. " 个文件")
	end)
end

--========================================================
-- 开山模块 (集成版) - 从原脚本提取核心逻辑, 使用 GSENAux UI 辅助函数
-- 移除 Obsidian UI 库, 改用 makeSectionLabel/makeToggle/makeSlider/makeButton/makeDropdown
-- Library:Notify -> showToast, Library.Toggles -> KS_Toggles, Library.Options -> 局部变量
--========================================================
-- 用 IIFE 包裹, 避免开山模块的局部变量挤占主脚本 200 个局部变量上限
-- 开山模块仅在「开采一座山」中加载 (UniverseId: 10187294555)
local KAISHAN_UNIVERSE_ID = 10187294555
local isKaishanGame = (game.GameId == KAISHAN_UNIVERSE_ID)
local function initKaishan()
  -- Config / Services / State / Storage / Connections (来自原脚本, 保持不变)
local Config={MinCrystalValue="2m",SpeedBoost=35,NormalSpeed=16,FlySpeed=100,AutoRejoinBoulders=false,AutoBuyBombs=false,RuneGrabRange=20,PickRange=13,PickBurst=8,AutoSellThreshold=0.5,MountainCenter=Vector3.new(42.67,1066.7,102.2),MountainRadius=862.7,RemotesFolder="Remotes",KeybindMenu="RightControl",KeybindAimTp="F"}
if getgenv().UniverseLoaded then if getgenv().UniverseUnload then pcall(getgenv().UniverseUnload)end end
getgenv().UniverseLoaded=true

local Services={Players=game:GetService("Players"),CoreGui=game:GetService("CoreGui"),RunService=game:GetService("RunService"),Workspace=game:GetService("Workspace"),ReplicatedStorage=game:GetService("ReplicatedStorage"),UserInputService=game:GetService("UserInputService"),HttpService=game:GetService("HttpService"),TeleportService=game:GetService("TeleportService"),GuiService=game:GetService("GuiService"),VirtualUser=game:GetService("VirtualUser")}
local LocalPlayer=Services.Players.LocalPlayer
local Mouse=LocalPlayer:GetMouse()
local State={afkRunning=true,espActive=false,playerEspActive=false,aimTpEnabled=false,speedActive=false,autoPickupActive=false,instantPromptActive=false,autoBuyBombs=false,minValue=2000000,valueFilter=true,minWeight=0,weightFilter=false,minLuck=0,luckFilter=false,espScale=0.7,playerScale=0.6,boulderScale=0.6,rootPart=nil,lastReport=0,tpState=nil,sweepAccumulator=math.huge,statsDirty=true,statsAccumulator=0,distanceAccumulator=math.huge,lastPickup=0,lastBagWarn=0,instantAccumulator=math.huge,registryCount=0,espCount=0,containerClock=0,streamMark=0,streamSpot=nil,speedHooked=nil,tierFilter={[1]=true,[2]=true,[3]=true,[4]=true,[5]=true,[6]=true}}
local Storage={afkConns={},registry={},candidates={},dirty={},espCache={},containerConns={},playerCache={},containerList={},sweepSeen={},lastDistanceOrigin=nil,pendingActions={},promptRestores={},claimed={},promptCache=setmetatable({},{__mode="k"}),instantPatched={},netConns={}}
local Connections={}
-- 替代 Library.Toggles[name].Value 的本地状态表
local KS_Toggles={Fly=false,Noclip=false,AutoRunePickup=false}
-- 替代 Library 控件的程序化句柄 (用于 setActive 时回写关闭)
local KS_ToggleHandles={}
-- 开山模块可持久化配置表 (由 ConfigControls 注册到外部配置系统)
local KS_Config={
espActive=false,espScale=0.7,playerEspActive=false,playerScale=0.6,boulderEspActive=false,boulderScale=0.6,
autoPickupActive=false,instantPromptActive=false,autoRunePickup=false,
tier1=true,tier2=true,tier3=true,tier4=true,tier5=true,tier6=true,
boulderMossite=false,boulderVoltite=false,boulderGildrite=false,boulderRimeveil=false,boulderNocturnite=false,
autoFarmBoulders=false,autoRejoinBoulders=false,
moneyFarmActive=false,focusLuck=false,minLuckPoints=10,autoPlantLuck=false,autoSell=false,
autoBuyBombs=false,
}

-- 反AFK (常驻, 无 UI)
do
 local function silenceIdle()local ok,list=pcall(function()return getconnections(LocalPlayer.Idled)end)if ok and type(list)=="table"then for _,c in ipairs(list)do pcall(function()c:Disable()end)end end end
 local function nudge()pcall(function()Services.VirtualUser:CaptureController()Services.VirtualUser:ClickButton2(Vector3.new())end)end
 silenceIdle()Storage.afkConns[#Storage.afkConns+1]=trackConnection(LocalPlayer.Idled:Connect(nudge))
 task.spawn(function()while State.afkRunning do task.wait(60)if not State.afkRunning or not LocalPlayer.Parent then break end;silenceIdle()nudge()end end)
end

-- 解析GUI根
local function resolveGuiRoot()local ok,hidden=pcall(function()return gethui()end)if ok and typeof(hidden)=="Instance"then return hidden end;local pg=LocalPlayer:FindFirstChildOfClass("PlayerGui")if pg then return pg end;return LocalPlayer:WaitForChild("PlayerGui",10)or Services.CoreGui end
local GuiRoot=resolveGuiRoot()
for _,container in ipairs({GuiRoot,Services.CoreGui})do for _,name in ipairs({"UniverseESPGui","UniverseCrystalEsp"})do pcall(function()local e=container:FindFirstChild(name)if e then e:Destroy()end end)end end

-- 查找远程 (缓存 Remotes 文件夹查找, 避免在其他游戏中重复 WaitForChild 阻塞)
local RemotesFolderCache
local function getRemotesFolder()
  if RemotesFolderCache ~= nil then return RemotesFolderCache end
  RemotesFolderCache = Services.ReplicatedStorage:FindFirstChild(Config.RemotesFolder)
  if not RemotesFolderCache then
    RemotesFolderCache = Services.ReplicatedStorage:WaitForChild(Config.RemotesFolder, 3)
  end
  return RemotesFolderCache
end
local function findRemote(name)local f=getRemotesFolder()if not f then return nil end;return f:FindFirstChild(name)or f:WaitForChild(name,2)end
local Remotes={SellRequest=findRemote("SellRequest"),GoHome=findRemote("GoHome"),HoldComplete=findRemote("CrystalHoldComplete"),ToggleFavorite=findRemote("ToggleFavorite"),DigRequest=findRemote("DigRequest"),BombShopQuery=findRemote("BombShopQuery"),BombBuyRequest=findRemote("BombBuyRequest"),BombShopRestocked=findRemote("BombShopRestocked"),PlotPlaceRequest=findRemote("PlotPlaceRequest")}

local ESP={font=Enum.Font.GothamBold,sweep=0.5,budget=0.005,offset=Vector3.new(0,3,0),width=250,height=66,text=16,ttl=5}
pcall(function()ESP.font=Enum.Font.LuckiestGuy end)
local PLAYER={offset=Vector3.new(0,-8,0),width=220,height=44,text=15}
local PACE={boost=Config.SpeedBoost,normal=Config.NormalSpeed,stats=0.25,distance=0.05}
local TP={offset=Vector3.new(0,4.5,0),hold=0.35,clear={Vector3.new(0,0,0),Vector3.new(0,3,0),Vector3.new(0,7,0),Vector3.new(5,3,0),Vector3.new(-5,3,0),Vector3.new(0,3,5),Vector3.new(0,3,-5),Vector3.new(0,12,0),Vector3.new(9,6,0),Vector3.new(-9,6,0),Vector3.new(0,6,9),Vector3.new(0,6,-9),Vector3.new(0,20,0)}}
local PICK={aimRange=5000,aimDot=0.995,range=Config.PickRange,cooldown=0.04,restore=0.2,burst=Config.PickBurst,retry=0.15,forget=5,pad=4,instantRadius=60,instantTick=0.25}
local COLORS={money=Color3.fromRGB(60,255,90),default=Color3.fromRGB(0,225,255),extra=Color3.fromRGB(255,255,255),player=Color3.fromRGB(255,40,140),stroke=Color3.fromRGB(0,0,0),hexDistance="00E5FF",hexLuck="FFC400"}
local TIER_NAMES={"普通","罕见","稀有","史诗","传说","神话","至高","Pulsar","Quasar"}
local LUCK={rarity={1,1.6,2.6,4.2,7,12,20,32,50},base=0.00045,exponent=0.5,cap=500,bomb=3,blood=4}
local MUTATION_LUCK={Verdant=15,Voltaic=20,Gilded=18,Onyx=28,Terminus=40,Frost=1.4,Fire=1.4,Thunder=1.5,Starfall=1.3,Aurora=2.2,Radioactive=2,Poison=1.5,Wet=1}
local WATCHED_ATTRIBUTES={"Value","Collected","WeightKg","Tier","TierName","CrystalName","Mutation","ExtraMutations"}
local SUFFIXES={"","k","M","B","T","Qa"}
local PARSE_MULTIPLIERS={k=1e3,m=1e6,b=1e9,t=1e12,qa=1e15,["%"]=1}
local CONTAINER_NAMES={"DroppedCrystals","Crystals"}

local EspHolder=trackInstance(Instance.new("Folder"))EspHolder.Name="UniverseCrystalEsp"EspHolder.Parent=GuiRoot

-- 工具函数
local function reportError(context,err)local now=os.clock()if now-State.lastReport<5 then return end;State.lastReport=now;warn(string.format("[开山] %s: %s",context,tostring(err)))end
local function formatShort(n,prefix)n=tonumber(n)or 0;prefix=prefix or"";local sign=n<0 and"-"or"";n=math.abs(n)if n<1000 then return string.format("%s%s%d",sign,prefix,math.floor(n+0.5))end;local index=0;while n>=1000 and index<#SUFFIXES-1 do n/=1000;index+=1 end;return string.format("%s%s%.2f%s",sign,prefix,n,SUFFIXES[index+1])end
local function formatWeight(kg)kg=tonumber(kg)or 0;if kg>=1000 then return formatShort(kg/1000).."t"end;return string.format("%.1fkg",kg)end
local function formatDistance(studs)studs=tonumber(studs)or 0;if studs>=1000 then return string.format("%.1fkm",studs/1000)end;return string.format("%dm",math.floor(studs+0.5))end
local function formatLuck(score)local pct=(tonumber(score)or 0)*100;if pct<=0 then return"+0%"end;if pct<1 then return string.format("+%.2f%%",pct)end;if pct<10 then return string.format("+%.1f%%",pct)end;return string.format("+%.0f%%",pct)end
local function parseValue(text)if type(text)~="string"then return nil end;local cleaned=text:lower():gsub("[%s,%$_%%]","")if cleaned==""then return 0 end;local number,suffix=cleaned:match("^(%d*%.?%d+)(%a*)$")if not number then return nil end;local base=tonumber(number)if not base then return nil end;if suffix==""then return base end;local mult=PARSE_MULTIPLIERS[suffix]if not mult then return nil end;return base*mult end
local function bindCharacter(character)if not character then State.rootPart=nil;return end;State.rootPart=character:FindFirstChild("HumanoidRootPart")end
bindCharacter(LocalPlayer.Character)
Connections.characterConn=trackConnection(LocalPlayer.CharacterAdded:Connect(function(character)State.rootPart=nil;State.tpState=nil;local waiter;waiter=character.ChildAdded:Connect(function(child)if child.Name=="HumanoidRootPart"then State.rootPart=child;waiter:Disconnect()end end)bindCharacter(character)if State.rootPart then waiter:Disconnect()end end))
local function getRoot()if State.rootPart and State.rootPart.Parent then return State.rootPart end;bindCharacter(LocalPlayer.Character)return State.rootPart end
local function getAttr(inst,name)if not inst then return nil end;local ok,value=pcall(inst.GetAttribute,inst,name)if ok then return value end;return nil end
local function crystalValue(inst)return tonumber(getAttr(inst,"Value"))or 0 end
local function crystalWeight(inst)return tonumber(getAttr(inst,"WeightKg"))or 0 end
local function crystalTier(inst)return tonumber(getAttr(inst,"Tier"))or 0 end
local function crystalRarity(inst)local name=getAttr(inst,"TierName")if type(name)=="string"and name~=""then return name end;return TIER_NAMES[crystalTier(inst)]or"未知"end
local function crystalName(inst)local name=getAttr(inst,"CrystalName")if type(name)=="string"and name~=""then return name end;return inst and inst.Name or"水晶"end
local function crystalColor(inst)local r=tonumber(getAttr(inst,"TierColorR"))local g=tonumber(getAttr(inst,"TierColorG"))local b=tonumber(getAttr(inst,"TierColorB"))if r and g and b then return Color3.fromRGB(r,g,b)end;return COLORS.default end
local function mutationLuck(name)if type(name)~="string"or name==""then return 1 end;return MUTATION_LUCK[name]or 1 end
local function combinedLuckMult(inst)local mutation=getAttr(inst,"Mutation")local roll=tonumber(getAttr(inst,"MutationLuckRoll"))local multiplier=(roll and roll>0)and roll or mutationLuck(mutation)local extra=getAttr(inst,"ExtraMutations")if type(extra)=="string"and extra~=""then for name in string.gmatch(extra,"[^,]+")do if name~=""then multiplier*=mutationLuck(name)end end end;if getAttr(inst,"IsBloodCrystal")==true then multiplier*=LUCK.blood end;if getAttr(inst,"AdminMutation")=="Radioactive"and mutation~="Radioactive"then local hasRadioactive=type(extra)=="string"and extra:find("Radioactive",1,true)~=nil;if not hasRadioactive then multiplier*=mutationLuck("Radioactive")end end;return multiplier end
local function computeLuck(inst)local tier=crystalTier(inst)if tier<=0 then return 0 end;local weight=math.max(0,crystalWeight(inst))local base=(LUCK.rarity[tier]or LUCK.rarity[1])*math.min(weight,LUCK.cap)^LUCK.exponent*LUCK.base;if getAttr(inst,"BombCrystal")==true then base*=LUCK.bomb end;return base*combinedLuckMult(inst)end
local function luckLabel(inst)local hover=inst:FindFirstChild("CrystalHover")if not hover then return nil end;local label=hover:FindFirstChild("LuckBoost")if not label or not label:IsA("TextLabel")then return nil end;return label end
local function luckLabelText(inst)local label=luckLabel(inst)if not label then return nil end;return label.Text end
local function tryParseLuckNumber(v)if v==nil then return nil end;local num=tonumber(v)if num and num>0 then return num>100 and num/100 or num end;if type(v)=="string"then local parsed=parseValue(v:match("([%d%.%,]+%a*)")or v)if parsed and parsed>0 then return parsed>100 and parsed/100 or parsed end end;return nil end
local luckDebugDone=false
local function crystalLuck(inst) -- 方法1(优先): 从标签文本读取, 乘以变异倍率 (标签显示基础幸运, 需乘变异倍率得到总幸运)
local mult=combinedLuckMult(inst)
local text=luckLabelText(inst)if type(text)=="string"and text~=""then local numPart=text:match("([%d%.%,]+%a*)%s*%%")if numPart then local pct=parseValue(numPart)if pct and pct>0 then return(pct/100)*mult end end;local xPart=text:match("[xX]%s*([%d%.]+)")or text:match("([%d%.]+)%s*[xX]")if xPart then local m=parseValue(xPart)if m and m>0 then return m*mult end end;local plainNum=text:match("([%d%.]+)")if plainNum then local val=tonumber(plainNum)or parseValue(plainNum)if val and val>0 then return(val>100 and val/100 or val)*mult end end end -- 方法1.5: 扫描水晶所有子对象中的 TextLabel (扩大搜索, 查找含%的幸运文本), 乘以变异倍率
for _,child in ipairs(inst:GetChildren())do if child:IsA("BillboardGui")or child.Name=="CrystalHover"then for _,desc in ipairs(child:GetDescendants())do if(desc:IsA("TextLabel")or desc:IsA("TextButton"))and type(desc.Text)=="string"then local t=desc.Text;if t:find("%%")or t:lower():find("luck")then local np=t:match("([%d%.%,]+%a*)%s*%%")if np then local pv=parseValue(np)if pv and pv>0 then return(pv/100)*mult end end end end end end end -- 方法2: 从水晶实例属性直接读取, 乘以变异倍率得到总幸运 (基础幸运×变异倍率=总幸运)
local attrVal=getAttr(inst,"LuckBoost")if attrVal~=nil then local r=tryParseLuckNumber(attrVal)if r then return r*combinedLuckMult(inst)end end -- 方法3: 从子对象读取 (IntValue/NumberValue), 乘以变异倍率
local luckObj=inst:FindFirstChild("LuckBoost")if luckObj and luckObj:IsA("ValueBase")then local r=tryParseLuckNumber(luckObj.Value)if r then return r*combinedLuckMult(inst)end end -- 方法4: 遍历水晶所有属性找幸运值, 乘以变异倍率
local ok,enum=pcall(inst.GetAttributes,inst)if ok and enum then for name,v in pairs(enum)do if name:lower():find("luck")then local r=tryParseLuckNumber(v)if r then return r*combinedLuckMult(inst)end end end end -- 方法5: 从 CrystalHover 属性读取, 乘以变异倍率
local hover=inst:FindFirstChild("CrystalHover")if hover then local ok2,enum2=pcall(hover.GetAttributes,hover)if ok2 and enum2 then for name,v in pairs(enum2)do if name:lower():find("luck")then local r=tryParseLuckNumber(v)if r then return r*combinedLuckMult(inst)end end end end end -- 调试: 首次打印水晶属性+子对象+PlayerGui 帮助诊断
if not luckDebugDone then luckDebugDone=true -- 打印水晶所有属性
local parts={}local ok3,enum3=pcall(inst.GetAttributes,inst)if ok3 and enum3 then for k,v in pairs(enum3)do parts[#parts+1]=tostring(k).."="..tostring(v)end end;print("[GSEN调试] 水晶属性: "..table.concat(parts,", ")) -- 打印水晶所有子对象 (递归)
local function dumpChildren(obj,depth)for _,child in ipairs(obj:GetChildren())do local prefix=string.rep("  ",depth)local childInfo=prefix..child.Name.." ("..child.ClassName..")"if child:IsA("TextLabel")or child:IsA("TextButton")then childInfo=childInfo.." Text=\""..tostring(child.Text).."\""end;if child:IsA("ValueBase")then childInfo=childInfo.." Value="..tostring(child.Value)end;local okAttr,childAttr=pcall(child.GetAttributes,child)if okAttr and childAttr then local attrStrs={}for k,v in pairs(childAttr)do attrStrs[#attrStrs+1]=tostring(k).."="..tostring(v)end;if #attrStrs>0 then childInfo=childInfo.." Attr:{"..table.concat(attrStrs,",").."}"end end;print("[GSEN调试] "..childInfo)dumpChildren(child,depth+1)end end;print("[GSEN调试] 水晶子对象树:")dumpChildren(inst,1) -- 扫描 PlayerGui 中与水晶/luck相关的GUI
local pGui=LocalPlayer:WaitForChild("PlayerGui")if pGui then print("[GSEN调试] 扫描PlayerGui中包含luck/运气的元素:")for _,screen in ipairs(pGui:GetChildren())do if screen:IsA("ScreenGui")or screen:IsA("BillboardGui")then local function scanGui(obj)for _,child in ipairs(obj:GetChildren())do if child:IsA("TextLabel")or child:IsA("TextButton")then local t=tostring(child.Text)if t:lower():find("luck")or t:find("运气")or t:find("幸运")then print("[GSEN调试] PlayerGui: "..child:GetFullName().." Text=\""..t.."\"")end end;scanGui(child)end end;scanGui(screen)end end end end -- 回退到公式估算
return computeLuck(inst)end
local function meetsFilter(inst,value)if not State.valueFilter then return true end;return(value or crystalValue(inst))>=State.minValue end
local function meetsWeightFilter(inst,weight)if not State.weightFilter then return true end;return(weight or crystalWeight(inst))>=State.minWeight end
local function meetsLuckFilter(inst,luck)if not State.luckFilter then return true end;local ok,actual=pcall(crystalLuck,inst)if not ok then return true end;return(luck or actual)>=State.minLuck end
local function tierFilterOk(inst)local tier=crystalTier(inst)if tier<=0 then return true end;return State.tierFilter[tier]~=false end
local function ownsGamepass(name)local folder=LocalPlayer:FindFirstChild("GamepassesOwned")if not folder then return false end;local flag=folder:FindFirstChild(name)return flag~=nil and flag:IsA("BoolValue")and flag.Value==true end
local function realStat(name)local data=LocalPlayer:FindFirstChild("PlayerData")local stats=data and data:FindFirstChild("RealStats")local entry=stats and stats:FindFirstChild(name)if not entry then return nil end;return tonumber(entry.Value)end
local function hasActiveRune(keyword)local data=LocalPlayer:FindFirstChild("PlayerData")local plot=data and data:FindFirstChild("PlotData")local runes=plot and plot:FindFirstChild("Runes")if not runes then return false end;for _,child in ipairs(runes:GetChildren())do local runeName=child:GetAttribute("RuneName")if type(runeName)=="string"and runeName:find(keyword,1,true)then if(tonumber(child:GetAttribute("Remaining"))or 0)>0 then return true end end end;return false end
local function backpackCapacity()if LocalPlayer:GetAttribute("InfBackpack")==true then return math.huge end;local base=realStat("CarryWeight")or 10;if ownsGamepass("CarryKgPlus4")then base*=4 end;local total=base+(realStat("CarryWeightBonus")or 0)if hasActiveRune("Weight")then return total*2 end;return total end
local function backpackWeight()local total=0;local function scan(container)if not container then return end;for _,child in ipairs(container:GetChildren())do if child:IsA("Tool")and getAttr(child,"Tier")~=nil then local kg=tonumber(getAttr(child,"WeightKg"))if kg then total+=kg end end end end;scan(LocalPlayer:FindFirstChildOfClass("Backpack"))scan(LocalPlayer.Character)return total end
local function backpackFree()local capacity=backpackCapacity()if capacity==math.huge then return math.huge end;return capacity-backpackWeight()end
local function looksLikeCrystal(inst)if not inst:IsA("BasePart")then return false end;return inst.Name:find("Crystal",1,true)~=nil end
local crystalFlags=setmetatable({},{__mode="k"})
local function isCrystal(inst)local cached=crystalFlags[inst]if cached~=nil then return cached end;local result=false;if inst:IsA("BasePart")and getAttr(inst,"Value")~=nil then result=getAttr(inst,"CrystalName")~=nil or inst.Name:find("Crystal",1,true)~=nil end;crystalFlags[inst]=result;return result end
local function rebuildContainers()table.clear(Storage.containerList)local seen={}local function push(container)if not container or seen[container]then return end;seen[container]=true;Storage.containerList[#Storage.containerList+1]=container end;push(Services.Workspace)for _,name in ipairs(CONTAINER_NAMES)do push(Services.Workspace:FindFirstChild(name))end;local things=Services.Workspace:FindFirstChild("Things")if things then for _,name in ipairs(CONTAINER_NAMES)do push(things:FindFirstChild(name))end end end
local function eachContainer(fn)local now=os.clock()local stale=#Storage.containerList==0 or now-State.containerClock>=1;if not stale then for _,container in ipairs(Storage.containerList)do if not container.Parent and container~=Services.Workspace then stale=true;break end end end;if stale then State.containerClock=now;rebuildContainers()end;for _,container in ipairs(Storage.containerList)do fn(container)end end
local function newLabel(name,parent,order,total,color,rich,maxText)local label=Instance.new("TextLabel")label.Name=name;label.BackgroundTransparency=1;label.BorderSizePixel=0;label.Size=UDim2.new(1,0,1/total,0)label.Position=UDim2.new(0,0,order/total,0)label.Font=ESP.font;label.TextScaled=true;label.TextTransparency=0;label.TextStrokeTransparency=0;label.TextStrokeColor3=COLORS.stroke;label.TextColor3=color;label.RichText=rich==true;label.Text=""label.Parent=parent;local constraint=Instance.new("UITextSizeConstraint")constraint.MaxTextSize=maxText;constraint.Parent=label;return label,constraint end
local function crystalGuiSize()return UDim2.fromOffset(ESP.width*State.espScale,ESP.height*State.espScale)end
local function crystalTextSize()return math.max(6,math.floor(ESP.text*State.espScale+0.5))end
local function playerGuiSize()return UDim2.fromOffset(PLAYER.width*State.playerScale,PLAYER.height*State.playerScale)end
local function playerTextSize()return math.max(6,math.floor(PLAYER.text*State.playerScale+0.5))end

-- ESP系统
local function createEntry(inst)local billboard=Instance.new("BillboardGui")billboard.Name="UniverseEsp";billboard.Adornee=inst;billboard.AlwaysOnTop=true;billboard.ResetOnSpawn=false;billboard.LightInfluence=0;billboard.Size=crystalGuiSize()billboard.StudsOffsetWorldSpace=ESP.offset;billboard.MaxDistance=math.huge;billboard.Parent=EspHolder;local textSize=crystalTextSize()local rarity,rarityConstraint=newLabel("稀有度",billboard,0,3,COLORS.default,false,textSize)local info,infoConstraint=newLabel("信息",billboard,1,3,COLORS.money,false,textSize)local extra,extraConstraint=newLabel("额外",billboard,2,3,COLORS.extra,true,textSize)return{gui=billboard,rarity=rarity,info=info,extra=extra,constraints={rarityConstraint,infoConstraint,extraConstraint},signature=false,luckText="+0%",distanceText=false}end
local function destroyEntry(inst,entry)entry=entry or Storage.espCache[inst]if not entry then return end;if entry.gui then entry.gui:Destroy()end;Storage.espCache[inst]=nil;State.espCount-=1;State.statsDirty=true end
local function applyEspScale()local size=crystalGuiSize()local textSize=crystalTextSize()for _,entry in pairs(Storage.espCache)do if entry.gui then entry.gui.Size=size end;for _,constraint in ipairs(entry.constraints)do constraint.MaxTextSize=textSize end end end
local function applyPlayerScale()local size=playerGuiSize()local textSize=playerTextSize()for _,entry in pairs(Storage.playerCache)do if entry.gui then entry.gui.Size=size end;for _,constraint in ipairs(entry.constraints)do constraint.MaxTextSize=textSize end end end
local function applyExtra(entry,distanceText)entry.distanceText=distanceText;entry.extra.Text=string.format('<font color="#%s">%s</font>  \u{2022}  <font color="#%s">%s</font>',COLORS.hexDistance,distanceText,COLORS.hexLuck,entry.luckText)end
local function buildTitle(inst)local rarity=crystalRarity(inst)local name=crystalName(inst)local mutation=getAttr(inst,"Mutation")if type(mutation)=="string"and mutation~=""then return string.format("[%s] %s (%s)",rarity,name,mutation)end;return string.format("[%s] %s",rarity,name)end
local function applyDetails(inst,entry,origin)local title=buildTitle(inst)local color=crystalColor(inst)local money=formatShort(crystalValue(inst),"$")local weight=formatWeight(crystalWeight(inst))local luckOk,luck=pcall(crystalLuck,inst)entry.luckText=formatLuck(luckOk and luck or 0)entry.rarity.Text=title;entry.rarity.TextColor3=color;entry.info.Text=string.format("%s  \u{2022}  %s",money,weight)local distanceText="--"if origin then distanceText=formatDistance((inst.Position-origin).Magnitude)end;applyExtra(entry,distanceText)end
local function crystalSignature(inst)return table.concat({tostring(getAttr(inst,"Tier")),tostring(getAttr(inst,"TierName")),tostring(getAttr(inst,"CrystalName")),tostring(getAttr(inst,"Value")),tostring(getAttr(inst,"WeightKg")),tostring(getAttr(inst,"Mutation")),tostring(getAttr(inst,"ExtraMutations")),tostring(luckLabelText(inst))},"|")end
local function markDirty(inst)Storage.dirty[inst]=true end
local function untrackCrystal(inst)local conns=Storage.registry[inst]if not conns then return end;for _,connection in ipairs(conns)do connection:Disconnect()end;Storage.registry[inst]=nil;State.registryCount-=1;Storage.dirty[inst]=nil;Storage.candidates[inst]=nil;State.statsDirty=true;destroyEntry(inst)end
local function trackCrystal(inst)if Storage.registry[inst]then return end;local conns={}Storage.registry[inst]=conns;State.registryCount+=1;State.statsDirty=true;local ok=pcall(function()conns[#conns+1]=inst.Destroying:Connect(function()untrackCrystal(inst)end)conns[#conns+1]=inst.AncestryChanged:Connect(function()if not inst:IsDescendantOf(Services.Workspace)then untrackCrystal(inst)end end)for _,name in ipairs(WATCHED_ATTRIBUTES)do conns[#conns+1]=inst:GetAttributeChangedSignal(name):Connect(function()markDirty(inst)end)end;local label=luckLabel(inst)if label then conns[#conns+1]=label:GetPropertyChangedSignal("Text"):Connect(function()markDirty(inst)end)end end)if not ok then untrackCrystal(inst)return end;markDirty(inst)end
local function syncCrystal(inst)Storage.dirty[inst]=nil;if not Storage.registry[inst]then return end;if not inst.Parent then untrackCrystal(inst)return end;local entry=Storage.espCache[inst]local hidden=not State.espActive or getAttr(inst,"Collected")==true;if not hidden then hidden=not meetsFilter(inst)end;if not hidden then hidden=not meetsWeightFilter(inst)end;if not hidden then hidden=not meetsLuckFilter(inst)end;if not hidden then hidden=not tierFilterOk(inst)end;if hidden then if entry then destroyEntry(inst,entry)end;return end;if not entry then local built,result=pcall(createEntry,inst)if not built then reportError("广告牌",result)return end;entry=result;Storage.espCache[inst]=entry;State.espCount+=1;State.statsDirty=true end;local signature=crystalSignature(inst)if signature==entry.signature then return end;local root=getRoot()local ok,err=pcall(applyDetails,inst,entry,root and root.Position or nil)if ok then entry.signature=signature else reportError("详情",err)end end
local function sweep()local seen=Storage.sweepSeen;table.clear(seen)eachContainer(function(container)for _,child in ipairs(container:GetChildren())do if not seen[child]and isCrystal(child)then seen[child]=true;if not Storage.registry[child]then trackCrystal(child)end end end end)local stale;for inst in pairs(Storage.registry)do if not seen[inst]then stale=stale or{}stale[#stale+1]=inst end end;if stale then for _,inst in ipairs(stale)do untrackCrystal(inst)end end end
local function updateDistances()local root=getRoot()if not root then return end;local origin=root.Position;if Storage.lastDistanceOrigin and(origin-Storage.lastDistanceOrigin).Magnitude<1 then return end;Storage.lastDistanceOrigin=origin;for inst,entry in pairs(Storage.espCache)do if inst.Parent then local text=formatDistance((inst.Position-origin).Magnitude)if text~=entry.distanceText then applyExtra(entry,text)end end end end
local function clearEsp()for inst,entry in pairs(Storage.espCache)do destroyEntry(inst,entry)end;Storage.espCache={}State.espCount=0;State.statsDirty=true end
local function clearRegistry()local all;for inst in pairs(Storage.registry)do all=all or{}all[#all+1]=inst end;if all then for _,inst in ipairs(all)do untrackCrystal(inst)end end;clearEsp()Storage.registry={}Storage.candidates={}Storage.dirty={}State.registryCount=0;State.statsDirty=true end
local function requestRefresh()for inst in pairs(Storage.registry)do Storage.dirty[inst]=true end;State.sweepAccumulator=math.huge end
local function trackingEnabled()return State.espActive end
local function onContainerChild(child)if looksLikeCrystal(child)then Storage.candidates[child]=os.clock()+ESP.ttl end end
local function watchContainers()for container,connection in pairs(Storage.containerConns)do if not container:IsDescendantOf(game)then connection:Disconnect()Storage.containerConns[container]=nil end end;eachContainer(function(container)if Storage.containerConns[container]then return end;Storage.containerConns[container]=container.ChildAdded:Connect(onContainerChild)end)end
local function unwatchContainers()for container,connection in pairs(Storage.containerConns)do connection:Disconnect()Storage.containerConns[container]=nil end end
local function updateTracking()if trackingEnabled()then State.sweepAccumulator=math.huge;watchContainers()requestRefresh()else unwatchContainers()clearRegistry()end end

local StatsLabel
Connections.espConn=trackConnection(Services.RunService.Heartbeat:Connect(function(deltaTime)if State.statsDirty and StatsLabel then State.statsDirty=false;StatsLabel.Text=string.format("追踪: %d  |  显示: %d",State.registryCount,State.espCount)end;if not trackingEnabled()then return end;local now=os.clock();for inst,expiry in pairs(Storage.candidates)do if not inst.Parent then Storage.candidates[inst]=nil elseif isCrystal(inst)then Storage.candidates[inst]=nil;trackCrystal(inst)elseif now>expiry then Storage.candidates[inst]=nil end end;local deadline=now+ESP.budget;if next(Storage.dirty)~=nil then for inst in pairs(Storage.dirty)do local ok,err=pcall(syncCrystal,inst)if not ok then Storage.dirty[inst]=nil;reportError("同步",err)end;if os.clock()>deadline then break end end end;State.sweepAccumulator+=deltaTime;if State.sweepAccumulator>=ESP.sweep then State.sweepAccumulator=0;local ok,err=pcall(function()watchContainers()sweep()end)if not ok then reportError("扫描",err)end end;State.distanceAccumulator+=deltaTime;if State.distanceAccumulator>=PACE.distance then State.distanceAccumulator=0;local ok,err=pcall(updateDistances)if not ok then reportError("距离",err)end end end))

-- 玩家ESP
local function destroyPlayerEntry(player)local entry=Storage.playerCache[player]if not entry then return end;if entry.gui then entry.gui:Destroy()end;Storage.playerCache[player]=nil end
local function createPlayerEntry(player)local billboard=Instance.new("BillboardGui")billboard.Name="UniversePlayerEsp";billboard.AlwaysOnTop=true;billboard.ResetOnSpawn=false;billboard.LightInfluence=0;billboard.Size=playerGuiSize()billboard.StudsOffsetWorldSpace=PLAYER.offset;billboard.MaxDistance=math.huge;billboard.Parent=EspHolder;local textSize=playerTextSize()local nameLabel,nameConstraint=newLabel("名称",billboard,0,2,COLORS.player,false,textSize)local distanceLabel,distanceConstraint=newLabel("距离",billboard,1,2,COLORS.extra,false,textSize)nameLabel.Text=player.DisplayName;return{gui=billboard,name=nameLabel,distance=distanceLabel,constraints={nameConstraint,distanceConstraint},nameText=player.DisplayName,distanceText=false}end
local function clearPlayerEsp()for player in pairs(Storage.playerCache)do destroyPlayerEntry(player)end;Storage.playerCache={}end
local function updatePlayerEsp()if not State.playerEspActive then return end;local root=getRoot()local origin=root and root.Position or nil;for _,player in ipairs(Services.Players:GetPlayers())do if player~=LocalPlayer then local character=player.Character;local target=character and character:FindFirstChild("HumanoidRootPart")if target then local entry=Storage.playerCache[player]if not entry then local built,result=pcall(createPlayerEntry,player)if built then entry=result;Storage.playerCache[player]=entry else reportError("玩家",result)end end;if entry then if entry.gui.Adornee~=target then entry.gui.Adornee=target end;if entry.nameText~=player.DisplayName then entry.nameText=player.DisplayName;entry.name.Text=player.DisplayName end;local text=origin and formatDistance((target.Position-origin).Magnitude)or"--"if text~=entry.distanceText then entry.distanceText=text;entry.distance.Text=text end end else destroyPlayerEntry(player)end end end;local gone;for player in pairs(Storage.playerCache)do if player==LocalPlayer or not player.Parent then gone=gone or{}gone[#gone+1]=player end end;if gone then for _,player in ipairs(gone)do destroyPlayerEntry(player)end end end

-- 传送系统
local function requestStream(position)if typeof(position)~="Vector3"then return end;local now=os.clock()if State.streamSpot and now-State.streamMark<0.3 and(State.streamSpot-position).Magnitude<32 then return end;State.streamMark=now;State.streamSpot=position;task.spawn(function()pcall(function()LocalPlayer:RequestStreamAroundAsync(position,1)end)end)end
local function applyPivot(cframe)local character=LocalPlayer.Character;if not character then return false end;requestStream(cframe.Position)local root=getRoot()if not root then return false end;local moved=pcall(function()character:PivotTo(cframe)end)if not moved then moved=pcall(function()root.CFrame=cframe end)end;if not moved then return false end;pcall(function()root.AssemblyLinearVelocity=Vector3.zero;root.AssemblyAngularVelocity=Vector3.zero end)return true end
local function findClearGoal(position,ignore)local params=OverlapParams.new()params.FilterType=Enum.RaycastFilterType.Exclude;params.FilterDescendantsInstances=ignore;params.MaxParts=1;for _,offset in ipairs(TP.clear)do local candidate=position+offset;local ok,hits=pcall(function()return Services.Workspace:GetPartBoundsInRadius(candidate,2.5,params)end)if ok and#hits==0 then return candidate end end;return position+TP.clear[#TP.clear]end
local function finishTeleport()if not State.tpState then return end;local root=getRoot()if root then pcall(function()root.AssemblyLinearVelocity=Vector3.zero;root.AssemblyAngularVelocity=Vector3.zero end)end;local character=LocalPlayer.Character;local humanoid=character and character:FindFirstChildOfClass("Humanoid")if humanoid then pcall(function()humanoid.PlatformStand=false;humanoid:SetStateEnabled(Enum.HumanoidStateType.Freefall,true)humanoid:SetStateEnabled(Enum.HumanoidStateType.FallingDown,true)humanoid:SetStateEnabled(Enum.HumanoidStateType.Ragdoll,true)humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)end)end;State.tpState=nil end
local function teleportTo(target)local position;if typeof(target)=="Vector3"then position=target elseif typeof(target)=="Instance"and target.Parent then position=target.Position end;if not position then return false end;local character=LocalPlayer.Character;if not character then return false end;local root=getRoot()if not root then return false end;finishTeleport()local humanoid=character:FindFirstChildOfClass("Humanoid")if humanoid then pcall(function()if humanoid.SeatPart or humanoid.Sit then humanoid.Sit=false end;humanoid:SetStateEnabled(Enum.HumanoidStateType.FallingDown,false)humanoid:SetStateEnabled(Enum.HumanoidStateType.Ragdoll,false)end)end;local ignore={character}if typeof(target)=="Instance"then ignore[#ignore+1]=target end;local goalFrame=CFrame.new(findClearGoal(position+TP.offset,ignore))if not applyPivot(goalFrame)then return false end;State.tpState={goal=goalFrame,holdUntil=os.clock()+TP.hold}return true end
local function schedule(delay,fn)Storage.pendingActions[#Storage.pendingActions+1]={at=os.clock()+delay,fn=fn}end

-- 拾取系统
local function crystalPrompt(inst)local cached=Storage.promptCache[inst]if cached and cached.Parent then return cached end;local ok,prompt=pcall(inst.FindFirstChildOfClass,inst,"ProximityPrompt")if not(ok and prompt)then ok,prompt=pcall(inst.FindFirstChildWhichIsA,inst,"ProximityPrompt",true)end;if ok and prompt then Storage.promptCache[inst]=prompt;return prompt end;Storage.promptCache[inst]=nil;return nil end
local function surfaceDistance(part,origin)local ok,distance=pcall(function()local point=part.CFrame:PointToObjectSpace(origin)local half=part.Size*0.5;local clamped=Vector3.new(math.clamp(point.X,-half.X,half.X),math.clamp(point.Y,-half.Y,half.Y),math.clamp(point.Z,-half.Z,half.Z))return(point-clamped).Magnitude end)if ok and distance then return distance end;return(part.Position-origin).Magnitude end
local function firePrompt(prompt)if not Storage.promptRestores[prompt]then Storage.promptRestores[prompt]={hold=prompt.HoldDuration,sight=prompt.RequiresLineOfSight,enabled=prompt.Enabled,range=prompt.MaxActivationDistance}end;pcall(function()prompt.HoldDuration=0;prompt.RequiresLineOfSight=false;prompt.Enabled=true;prompt.MaxActivationDistance=1000 end)local fired=false;if typeof(fireproximityprompt)=="function"then fired=pcall(fireproximityprompt,prompt,1)if not fired then fired=pcall(fireproximityprompt,prompt)end end;if not fired then fired=pcall(function()prompt:InputHoldBegin()prompt:InputHoldEnd()end)end;schedule(PICK.restore,function()local saved=Storage.promptRestores[prompt]if not saved then return end;Storage.promptRestores[prompt]=nil;if prompt.Parent then prompt.HoldDuration=saved.hold;prompt.RequiresLineOfSight=saved.sight;prompt.Enabled=saved.enabled;prompt.MaxActivationDistance=saved.range end end)return fired end
local pickupParams=OverlapParams.new()pickupParams.FilterType=Enum.RaycastFilterType.Exclude;pcall(function()pickupParams.MaxParts=300;pickupParams.RespectCanCollide=false end)
local pickupFound={}local pickupSeen={}
local function pickupCandidates(free,origin,filterFunc)local found=pickupFound;local seen=pickupSeen;table.clear(found)table.clear(seen)local now=os.clock()local function consider(child)if not child or seen[child]then return end;seen[child]=true;if not child.Parent or not isCrystal(child)or getAttr(child,"Collected")==true then return end;local claim=Storage.claimed[child]if claim and now-claim<PICK.retry then return end;if filterFunc and not filterFunc(child)then return end;if not tierFilterOk(child)then return end;local value=crystalValue(child)if not meetsFilter(child,value)then return end;local weight=crystalWeight(child)if not meetsWeightFilter(child,weight)then return end;if not meetsLuckFilter(child)then return end;if weight>free then return end;local distance=surfaceDistance(child,origin)if distance>PICK.range then return end;found[#found+1]={inst=child,prompt=crystalPrompt(child),value=value,weight=weight,distance=distance}end;pickupParams.FilterDescendantsInstances={LocalPlayer.Character or LocalPlayer}local ok,hits=pcall(function()return Services.Workspace:GetPartBoundsInRadius(origin,PICK.range+PICK.pad,pickupParams)end)if ok and hits then for _,part in ipairs(hits)do consider(part)end end;eachContainer(function(container)for _,child in ipairs(container:GetChildren())do if child:IsA("BasePart")then consider(child)elseif child:IsA("Model")then for _,inner in ipairs(child:GetChildren())do consider(inner)end end end end)for inst in pairs(Storage.registry)do consider(inst)end;table.sort(found,function(a,b)if a.value==b.value then return a.distance<b.distance end;return a.value>b.value end)return found end
local function grabCrystal(inst,prompt)local sent=false;if Remotes.HoldComplete then sent=pcall(function()if Remotes.HoldComplete:IsA("RemoteEvent")then Remotes.HoldComplete:FireServer(inst)end end)end;if not prompt then prompt=crystalPrompt(inst)end;if prompt and prompt.Parent and firePrompt(prompt)then sent=true end;if not sent and typeof(fireclickdetector)=="function"then local ok,detector=pcall(inst.FindFirstChildWhichIsA,inst,"ClickDetector",true)if ok and detector then sent=pcall(fireclickdetector,detector,0)end end;return sent end
local function instantPromptPatch(prompt)if Storage.instantPatched[prompt]or Storage.promptRestores[prompt]then return end;Storage.instantPatched[prompt]={hold=prompt.HoldDuration,sight=prompt.RequiresLineOfSight,enabled=prompt.Enabled}pcall(function()prompt.HoldDuration=0;prompt.RequiresLineOfSight=false;prompt.Enabled=true end)end
local function restoreInstantPrompts()for prompt,saved in pairs(Storage.instantPatched)do if prompt.Parent then pcall(function()prompt.HoldDuration=saved.hold;prompt.RequiresLineOfSight=saved.sight;prompt.Enabled=saved.enabled end)end end;table.clear(Storage.instantPatched)end
local function nearbyCrystalParts(origin,radius)pickupParams.FilterDescendantsInstances={LocalPlayer.Character or LocalPlayer}local ok,hits=pcall(function()return Services.Workspace:GetPartBoundsInRadius(origin,radius,pickupParams)end)if ok and hits then return hits end;return nil end
local function refreshInstantPrompts()local root=getRoot()if not root then return end;for prompt in pairs(Storage.instantPatched)do if not prompt.Parent then Storage.instantPatched[prompt]=nil end end;local hits=nearbyCrystalParts(root.Position,PICK.instantRadius)if not hits then return end;for _,part in ipairs(hits)do if isCrystal(part)and getAttr(part,"Collected")~=true then local prompt=crystalPrompt(part)if prompt then instantPromptPatch(prompt)end end end end
local function setInstantPrompt(value)State.instantPromptActive=value;State.instantAccumulator=math.huge;if not value then restoreInstantPrompts()end end
local function instantGrab()if not State.instantPromptActive then return end;local root=getRoot()if not root then return end;local hits=nearbyCrystalParts(root.Position,PICK.range+PICK.pad)if not hits then return end;local best,bestPrompt,bestDistance;for _,part in ipairs(hits)do if part.Parent and isCrystal(part)and getAttr(part,"Collected")~=true and tierFilterOk(part)and meetsFilter(part)and meetsWeightFilter(part)and meetsLuckFilter(part)then local distance=surfaceDistance(part,root.Position)if distance<=PICK.range and(not best or distance<bestDistance)then best=part;bestPrompt=crystalPrompt(part)bestDistance=distance end end end;if not best then return end;if bestPrompt then instantPromptPatch(bestPrompt)end;if grabCrystal(best,bestPrompt)then Storage.claimed[best]=os.clock()end end
local function pickupStep(filterFunc)local now=os.clock()if now-State.lastPickup<PICK.cooldown then return end;local root=getRoot()if not root then return end;local free=backpackFree()if free<=0 then if now-State.lastBagWarn>=8 then State.lastBagWarn=now;showToast("背包已满")end;return end;for inst,stamp in pairs(Storage.claimed)do if now-stamp>=PICK.forget or not inst.Parent then Storage.claimed[inst]=nil end end;local candidatesList=pickupCandidates(free,root.Position,filterFunc)if#candidatesList==0 then requestStream(root.Position)return end;local budget=free;local grabs=0;for _,entry in ipairs(candidatesList)do if grabs>=PICK.burst then break end;if entry.weight<=budget then Storage.claimed[entry.inst]=now;if grabCrystal(entry.inst,entry.prompt)then budget-=entry.weight;grabs+=1 end end end;if grabs>0 then State.lastPickup=now end end
local BackpackLabel
local function updateBackpackLabel()if not BackpackLabel then return end;local capacity=backpackCapacity()local used=backpackWeight()if capacity==math.huge then BackpackLabel.Text=string.format("背包 %.1f / \u{221E} kg",used)return end;local free=math.max(0,capacity-used)BackpackLabel.Text=string.format("背包 %.1f / %.1f kg\n剩余 %.1f kg",used,capacity,free)end
local function enforceSpeed(humanoid)if not humanoid or humanoid.WalkSpeed==PACE.boost then return end;pcall(function()humanoid.WalkSpeed=PACE.boost end)end
local function watchSpeed(humanoid)if State.speedHooked==humanoid then return end;if Connections.speedConn then Connections.speedConn:Disconnect()Connections.speedConn=nil end;State.speedHooked=humanoid;if not humanoid then return end;local ok,connection=pcall(function()return humanoid:GetPropertyChangedSignal("WalkSpeed"):Connect(function()if State.speedActive then enforceSpeed(humanoid)end end)end)if ok then Connections.speedConn=connection end end
local function setSpeedBoost(value)State.speedActive=value;local character=LocalPlayer.Character;local humanoid=character and character:FindFirstChildOfClass("Humanoid")if value then watchSpeed(humanoid)enforceSpeed(humanoid)return end;watchSpeed(nil)if humanoid then pcall(function()humanoid.WalkSpeed=PACE.normal end)end end

-- 调度器
Connections.schedulerConn=trackConnection(Services.RunService.Heartbeat:Connect(function(deltaTime)if State.tpState then local ok,err=pcall(function()if not applyPivot(State.tpState.goal)then finishTeleport()return end;if os.clock()>=State.tpState.holdUntil then finishTeleport()end end)if not ok then finishTeleport()reportError("传送",err)end end;if State.autoPickupActive then local ok,err=pcall(pickupStep)if not ok then reportError("拾取",err)end end;if State.instantPromptActive then State.instantAccumulator+=deltaTime;if State.instantAccumulator>=PICK.instantTick then State.instantAccumulator=0;local ok,err=pcall(refreshInstantPrompts)if not ok then reportError("即时",err)end end end;if State.speedActive then local body=LocalPlayer.Character;local mover=body and body:FindFirstChildOfClass("Humanoid")if mover then watchSpeed(mover)enforceSpeed(mover)end end;if State.playerEspActive then local ok,err=pcall(updatePlayerEsp)if not ok then reportError("玩家ESP",err)end end;State.statsAccumulator+=deltaTime;if State.statsAccumulator>=PACE.stats then State.statsAccumulator=0;local ok,err=pcall(updateBackpackLabel)if not ok then reportError("背包",err)end end;if#Storage.pendingActions==0 then return end;local now=os.clock()for index=#Storage.pendingActions,1,-1 do local job=Storage.pendingActions[index]if now>=job.at then table.remove(Storage.pendingActions,index)local ok,err=pcall(job.fn)if not ok then reportError("操作",err)end end end end))

-- 排序和瞄准
local function sortedByScore(scoreFn)local scored={}local seen={}local function consider(inst)if seen[inst]or not inst.Parent then return end;if getAttr(inst,"Collected")==true then return end;seen[inst]=true;local ok,score=pcall(scoreFn,inst)scored[#scored+1]={inst=inst,score=ok and score or 0}end;for inst in pairs(Storage.registry)do consider(inst)end;eachContainer(function(container)for _,child in ipairs(container:GetChildren())do if isCrystal(child)then consider(child)end end end)table.sort(scored,function(a,b)return a.score>b.score end)return scored end
local Mountain={}local aimParams=RaycastParams.new()aimParams.FilterType=Enum.RaycastFilterType.Exclude;aimParams.IgnoreWater=true
local function getAimedCrystal()local unitRay=Mouse.UnitRay;local origin=unitRay.Origin;local direction=unitRay.Direction.Unit;local character=LocalPlayer.Character;aimParams.FilterDescendantsInstances=character and{character}or{}local hit=Services.Workspace:Raycast(origin,direction*PICK.aimRange,aimParams)if hit and hit.Instance and(Storage.registry[hit.Instance]or isCrystal(hit.Instance))then return hit.Instance end;local best,bestDot;local seen={}local function consider(inst)if seen[inst]or not inst.Parent then return end;seen[inst]=true;local offset=(inst.Position+ESP.offset)-origin;local magnitude=offset.Magnitude;if magnitude>0 then local dot=direction:Dot(offset/magnitude)if not bestDot or dot>bestDot then bestDot=dot;best=inst end end end;for inst in pairs(Storage.espCache)do consider(inst)end;eachContainer(function(container)for _,child in ipairs(container:GetChildren())do if isCrystal(child)then consider(child)end end end)if best and bestDot and bestDot>=PICK.aimDot then return best end;return nil end
local function aimTeleport()if not State.espActive then showToast("请先启用水晶ESP")return end;local inst=getAimedCrystal()if not inst then showToast("未瞄准到水晶")return end;if teleportTo(inst)then showToast(string.format("传送 -> %s",crystalName(inst)))else showToast("传送失败")end end
local function tpToRank(scoreFn,rank,formatter)local entry=sortedByScore(scoreFn)[rank]if not entry or entry.score<=0 then showToast(string.format("没有找到第%d名的水晶",rank))return end;if teleportTo(entry.inst)then showToast(string.format("传送 #%d %s (%s)",rank,crystalName(entry.inst),formatter(entry.inst,entry.score)))else showToast("传送失败")end end
local function fireRemote(remote,...)if not remote or typeof(remote)~="Instance"then return false end;local args=table.pack(...)local ok=pcall(function()if remote:IsA("RemoteEvent")then remote:FireServer(table.unpack(args,1,args.n))elseif remote:IsA("BindableEvent")then remote:Fire(table.unpack(args,1,args.n))elseif remote:IsA("RemoteFunction")then remote:InvokeServer(table.unpack(args,1,args.n))end end)return ok end
local function unfavoriteAll()local cleared=0;local function scan(container)if not container then return end;for _,child in ipairs(container:GetChildren())do if child:IsA("Tool")and child:GetAttribute("Favorited")==true then pcall(function()child:SetAttribute("Favorited",false)end)fireRemote(Remotes.ToggleFavorite,child,false)cleared+=1 end end end;scan(LocalPlayer:FindFirstChildOfClass("Backpack"))scan(LocalPlayer.Character)return cleared end
local function mountainSpot()local centerX=Services.Workspace:GetAttribute("MountainCenterX")or Config.MountainCenter.X;local centerZ=Services.Workspace:GetAttribute("MountainCenterZ")or Config.MountainCenter.Z;if typeof(centerX)=="number"and typeof(centerZ)=="number"then local base=Services.Workspace:GetAttribute("MountainBaseY")or 22;local peak=Services.Workspace:GetAttribute("MountainPeakY")or 1675;local height=700;if typeof(base)=="number"and typeof(peak)=="number"then height=base+(peak-base)*0.55 end;return Vector3.new(centerX,height,centerZ)end;local things=Services.Workspace:FindFirstChild("Things")local zones=things and things:FindFirstChild("MountainZones")if zones then for _,child in ipairs(zones:GetChildren())do if child:IsA("BasePart")and child.Name=="MountainZone"then return child.Position end end end;return Config.MountainCenter end
local function mountainSpan()local radius=Services.Workspace:GetAttribute("MountainRadius")if typeof(radius)=="number"and radius>20 then return radius end;return Config.MountainRadius end
local function getSellCFrame()local things=Services.Workspace:FindFirstChild("Things")local prox=things and things:FindFirstChild("SellProx")if prox and prox:IsA("BasePart")then return CFrame.new(prox.Position+Vector3.new(0,3,0),prox.Position)end;local model=things and things:FindFirstChild("SellModel")local part=model and model:FindFirstChild("SellPart")if part and part:IsA("BasePart")then return CFrame.new(part.Position+Vector3.new(0,3,0),part.Position)end;return CFrame.new(-45.85,32,1066.58)end
local sellClock=0
local function doRemoteSell()local now=os.clock()if now-sellClock<1.5 then return false end;sellClock=now;unfavoriteAll()fireRemote(Remotes.SellRequest,"all")return true end
local function doSell()local now=os.clock()if now-sellClock<1.5 then return false end;sellClock=now;unfavoriteAll()fireRemote(Remotes.GoHome,"sell")schedule(0.6,function()unfavoriteAll()fireRemote(Remotes.SellRequest,"all")end)return true end

-- 巨石模块
do
 local function install()local BOULDER_INFO={Mossite={rarity="普通",pickaxe="钛金尖刺",crystals="8-11",runes="幸运 / 急速",color=Color3.fromRGB(150,220,120)},Voltite={rarity="罕见",pickaxe="天界顶点",crystals="10-14",runes="风暴 / 重量",color=Color3.fromRGB(110,190,240)},Gildrite={rarity="稀有",pickaxe="日蚀之牙",crystals="11-15",runes="财富 / 爆破",color=Color3.fromRGB(255,200,60)},Rimeveil={rarity="史诗",pickaxe="虚空统治",crystals="13-18",runes="保存 / 温暖",color=Color3.fromRGB(170,100,255)},Nocturnite={rarity="传说",pickaxe="终焉",crystals="16-22",runes="挖掘者 / 巨人",color=Color3.fromRGB(255,80,180)}}
 local BOULDER_OFFSET=Vector3.new(0,7,0)local BOULDER_WIDTH=300;local BOULDER_HEIGHT=78;local BOULDER_STEP=0.4;local GRAB_RANGE=Config.RuneGrabRange;local GRAB_STEP=0.15;local GRAB_LIMIT=4;local GRAB_RETRY=0.2;local boulderEsp=false;local autoGrab=false;local boulderCache={}local grabbed={}local boulderClock=0;local grabClock=0;local scanParams=OverlapParams.new()scanParams.FilterType=Enum.RaycastFilterType.Exclude
 local function textSize()return math.max(6,math.floor(ESP.text*State.boulderScale+0.5))end
 local function anchorPart(inst)if not inst then return nil end;if inst:IsA("BasePart")then return inst end;if inst:IsA("Model")then return inst.PrimaryPart or inst:FindFirstChildWhichIsA("BasePart")end;return nil end
 local function createCard(anchor,offset,colors,width,height)local billboard=Instance.new("BillboardGui")billboard.Name="UniverseMountainEsp";billboard.Adornee=anchor;billboard.AlwaysOnTop=true;billboard.ResetOnSpawn=false;billboard.LightInfluence=0;billboard.Size=UDim2.fromOffset(width*State.boulderScale,height*State.boulderScale)billboard.StudsOffsetWorldSpace=offset;billboard.MaxDistance=math.huge;billboard.Parent=EspHolder;local total=#colors;local size=textSize()local labels={}local constraints={}for index,color in ipairs(colors)do local label,constraint=newLabel("行"..index,billboard,index-1,total,color,false,size)labels[index]=label;constraints[index]=constraint end;return{gui=billboard,labels=labels,constraints=constraints,width=width,height=height,text={}}end
 local function scaleCard(entry)entry.gui.Size=UDim2.fromOffset(entry.width*State.boulderScale,entry.height*State.boulderScale)local size=textSize()for _,constraint in ipairs(entry.constraints)do constraint.MaxTextSize=size end end
 local function setLine(entry,index,text)if entry.text[index]==text then return end;entry.text[index]=text;entry.labels[index].Text=text end
 local function dropCard(cache,key)local entry=cache[key]if not entry then return end;if entry.gui then entry.gui:Destroy()end;cache[key]=nil end
 local function clearCache(cache)for key in pairs(cache)do dropCard(cache,key)end end
 local function boulderKind(inst)if not inst then return nil end;for kind in pairs(BOULDER_INFO)do if inst.Name:find(kind,1,true)then return kind end end;return nil end
 local function boulderRoots()local roots={}local decorations=Services.Workspace:FindFirstChild("MountainDecorations")local folder=decorations and decorations:FindFirstChild("Boulders")if folder then roots[#roots+1]=folder end;local test=Services.Workspace:FindFirstChild("BoulderTest")if test then roots[#roots+1]=test end;return roots end
 local function eachBoulder(fn)for _,container in ipairs(boulderRoots())do for _,child in ipairs(container:GetChildren())do local kind=boulderKind(child)if kind then fn(child,kind)end end end end
 local function isRune(inst)if not inst then return false end;if getAttr(inst,"RuneId")~=nil or getAttr(inst,"IsRune")==true or getAttr(inst,"RuneName")~=nil then return true end;return inst.Name:find(" Rune",1,true)~=nil end
 local function runeTitle(inst)local id=getAttr(inst,"RuneId")or getAttr(inst,"RuneName")if type(id)=="string"and id~=""then if id:find("Rune",1,true)then return id end;return id.." 符文"end;return inst and inst.Name or"符文"end
 local function eachRune(origin,radius,fn)local seen={}local function offer(owner,part)if not owner or seen[owner]then return end;local anchor=part or anchorPart(owner)if not anchor or not anchor.Parent then return end;if(anchor.Position-origin).Magnitude>radius then return end;seen[owner]=true;fn(owner,anchor)end;local function scanFolder(container)if not container then return end;for _,child in ipairs(container:GetChildren())do if isRune(child)then offer(child,anchorPart(child))end end end;scanFolder(Services.Workspace)scanFolder(Services.Workspace:FindFirstChild("Things"))scanFolder(Services.Workspace:FindFirstChild("DroppedCrystals"))local character=LocalPlayer.Character;scanParams.FilterDescendantsInstances=character and{character}or{}local ok,parts=pcall(function()return Services.Workspace:GetPartBoundsInRadius(origin,radius,scanParams)end)if not ok or not parts then return end;for _,part in ipairs(parts)do if isRune(part)then offer(part,part)else local parent=part.Parent;if parent and parent~=Services.Workspace and isRune(parent)then offer(parent,anchorPart(parent)or part)end end end end
 local function syncBoulders()local root=getRoot()local origin=root and root.Position or nil;local seen={}eachBoulder(function(model,kind)local anchor=anchorPart(model)if not anchor then return end;seen[model]=true;local info=BOULDER_INFO[kind]local entry=boulderCache[model]if entry and not entry.gui.Parent then dropCard(boulderCache,model)entry=nil end;if not entry then entry=createCard(anchor,BOULDER_OFFSET,{info.color,COLORS.extra,COLORS.money},BOULDER_WIDTH,BOULDER_HEIGHT)boulderCache[model]=entry end;if entry.gui.Adornee~=anchor then entry.gui.Adornee=anchor end;scaleCard(entry)setLine(entry,1,string.format("[%s] %s",info.rarity,kind))setLine(entry,2,string.format("%s  \u{2022}  %s 水晶",info.pickaxe,info.crystals))local distance=origin and formatDistance((anchor.Position-origin).Magnitude)or"--"setLine(entry,3,string.format("%s  \u{2022}  %s",info.runes,distance))end)local stale;for model in pairs(boulderCache)do if not seen[model]then stale=stale or{}stale[#stale+1]=model end end;if stale then for _,model in ipairs(stale)do dropCard(boulderCache,model)end end end
 local function grabRunes(radius)local root=getRoot()if not root then return 0 end;local now=os.clock()local fired=0;for prompt,stamp in pairs(grabbed)do if now-stamp>5 or not prompt.Parent then grabbed[prompt]=nil end end;eachRune(root.Position,radius or GRAB_RANGE,function(owner,part)if fired>=GRAB_LIMIT then return end;local prompt=owner:FindFirstChildOfClass("ProximityPrompt")if not prompt then prompt=crystalPrompt(owner)end;if not prompt and part~=owner then prompt=crystalPrompt(part)end;if not prompt or not prompt.Parent then return end;local last=grabbed[prompt]if last and now-last<GRAB_RETRY then return end;grabbed[prompt]=now;if firePrompt(prompt)then fired+=1;showToast(string.format("符文: %s",runeTitle(owner)))end end)return fired end
 function Mountain.applyScale()for _,entry in pairs(boulderCache)do scaleCard(entry)end end
 function Mountain.boulderList()local list={}for _,kind in ipairs({"Mossite","Voltite","Gildrite","Rimeveil","Nocturnite"})do local info=BOULDER_INFO[kind]list[#list+1]=string.format("%s  \u{2022}  %s",kind,info.pickaxe)end;return list end
 function Mountain.setBoulderEsp(value)boulderEsp=value;if value then boulderClock=math.huge else clearCache(boulderCache)end end
 function Mountain.setAutoGrab(value)autoGrab=value;if value then grabClock=math.huge else table.clear(grabbed)end end
 function Mountain.grabRange()return GRAB_RANGE end
 function Mountain.grabNear(radius)local ok,fired=pcall(grabRunes,radius)if not ok then reportError("符文抓取",fired)return 0 end;return fired or 0 end
 function Mountain.runesNear(radius)local root=getRoot()if not root then return 0 end;local count=0;eachRune(root.Position,radius or GRAB_RANGE,function()count+=1 end)return count end
 function Mountain.shutdown()boulderEsp=false;autoGrab=false;clearCache(boulderCache)table.clear(grabbed)end
 Connections.mountainConn=trackConnection(Services.RunService.Heartbeat:Connect(function(deltaTime)if boulderEsp then boulderClock+=deltaTime;if boulderClock>=BOULDER_STEP then boulderClock=0;local ok,err=pcall(syncBoulders)if not ok then reportError("巨石",err)end end end;if autoGrab then grabClock+=deltaTime;if grabClock>=GRAB_STEP then grabClock=0;local ok,err=pcall(grabRunes)if not ok then reportError("符文抓取",err)end end end end))end
 install()
end

-- 移动模块
local Move={}
do
 local function install()local FLY_KEYS={{key=Enum.KeyCode.W,axis="look",sign=1},{key=Enum.KeyCode.S,axis="look",sign=-1},{key=Enum.KeyCode.D,axis="right",sign=1},{key=Enum.KeyCode.A,axis="right",sign=-1},{key=Enum.KeyCode.Space,axis="up",sign=1},{key=Enum.KeyCode.LeftControl,axis="up",sign=-1}}local flyActive=false;local noclipActive=false;local jumpActive=false;local flySpeed=Config.FlySpeed;local velocity;local gyro;local flyConn;local noclipConn;local jumpConn;local collisions={}
 local function humanoidOf()local character=LocalPlayer.Character;return character and character:FindFirstChildOfClass("Humanoid")end
 local function dropMovers()if velocity then pcall(function()velocity:Destroy()end)velocity=nil end;if gyro then pcall(function()gyro:Destroy()end)gyro=nil end end
 local function attach(root)dropMovers()local ok=pcall(function()local body=Instance.new("BodyVelocity")body.Name="UniverseFlyVelocity";body.MaxForce=Vector3.new(9e9,9e9,9e9)body.P=9e4;body.Velocity=Vector3.zero;body.Parent=root;velocity=body;local spin=Instance.new("BodyGyro")spin.Name="UniverseFlyGyro";spin.MaxTorque=Vector3.new(9e9,9e9,9e9)spin.P=9e4;spin.D=500;spin.CFrame=root.CFrame;spin.Parent=root;gyro=spin end)if not ok then dropMovers()end;return ok end
 local function flyStep()if State.tpState then return end;local root=getRoot()if not root then return end;if not velocity or velocity.Parent~=root then if not attach(root)then return end end;local camera=Services.Workspace.CurrentCamera;if not camera then return end;local humanoid=humanoidOf()if humanoid and not humanoid.PlatformStand then humanoid.PlatformStand=true end;local frame=camera.CFrame;local direction=Vector3.zero;if not Services.UserInputService:GetFocusedTextBox()then for _,entry in ipairs(FLY_KEYS)do if Services.UserInputService:IsKeyDown(entry.key)then if entry.axis=="look"then direction+=frame.LookVector*entry.sign elseif entry.axis=="right"then direction+=frame.RightVector*entry.sign else direction+=Vector3.yAxis*entry.sign end end end end;if direction.Magnitude>0.1 then velocity.Velocity=direction.Unit*flySpeed else velocity.Velocity=Vector3.zero end;local flat=Vector3.new(frame.LookVector.X,0,frame.LookVector.Z)if flat.Magnitude>0.05 then gyro.CFrame=CFrame.new(root.Position,root.Position+flat)end end
 local function noclipStep()local character=LocalPlayer.Character;if not character then return end;for _,part in ipairs(character:GetDescendants())do if part:IsA("BasePart")and part.CanCollide then if collisions[part]==nil then collisions[part]=true end;part.CanCollide=false end end end
 function Move.setFly(value)flyActive=value;if value then local root=getRoot()if root then attach(root)end;if not flyConn then flyConn=Services.RunService.Heartbeat:Connect(function()if not flyActive then return end;local ok,err=pcall(flyStep)if not ok then reportError("飞行",err)end end)end;return end;if flyConn then flyConn:Disconnect()flyConn=nil end;dropMovers()local humanoid=humanoidOf()if humanoid then pcall(function()humanoid.PlatformStand=false;humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)end)end end
 function Move.setFlySpeed(value)flySpeed=math.clamp(value,10,500)end
 function Move.setNoclip(value)noclipActive=value;if value then if not noclipConn then noclipConn=Services.RunService.Heartbeat:Connect(function()if not noclipActive then return end;local ok,err=pcall(noclipStep)if not ok then reportError("穿墙",err)end end)end;return end;if noclipConn then noclipConn:Disconnect()noclipConn=nil end;for part,state in pairs(collisions)do if part.Parent then pcall(function()part.CanCollide=state end)end end;table.clear(collisions)end
 function Move.setInfJump(value)jumpActive=value;if value then if not jumpConn then jumpConn=Services.UserInputService.JumpRequest:Connect(function()if not jumpActive then return end;local humanoid=humanoidOf()if humanoid then pcall(function()humanoid:ChangeState(Enum.HumanoidStateType.Jumping)end)end end)end;return end;if jumpConn then jumpConn:Disconnect()jumpConn=nil end end
 function Move.shutdown()Move.setFly(false)Move.setNoclip(false)Move.setInfJump(false)Move.glideStop()end end
 install()
end

-- 滑翔模块
do
 local function install()local GLIDE_SPEED=350;local AIM_RATE=9;local SNAP_GAP=0.35;local RESPONSE=200;local STREAM_GAP=0.5;local HOLD_FORCE=1e7;local HOLD_TORQUE=1e7;local attachment;local mover;local aligner;local cursor;local facing;local goalFrame;local aimSpot;local streamClock=0;local glideConn;local running=false
 local function humanoidOf()local character=LocalPlayer.Character;return character and character:FindFirstChildOfClass("Humanoid")end
 local function detach()if mover then pcall(function()mover:Destroy()end)mover=nil end;if aligner then pcall(function()aligner:Destroy()end)aligner=nil end;if attachment then pcall(function()attachment:Destroy()end)attachment=nil end end
 local function attach(root)detach()local ok=pcall(function()local point=Instance.new("Attachment")point.Name="UniverseGlidePoint";point.Parent=root;local position=Instance.new("AlignPosition")position.Name="UniverseGlidePosition";position.Mode=Enum.PositionAlignmentMode.OneAttachment;position.Attachment0=point;position.RigidityEnabled=false;position.ApplyAtCenterOfMass=true;position.ReactionForceEnabled=false;position.MaxForce=HOLD_FORCE;position.MaxVelocity=math.huge;position.Responsiveness=RESPONSE;position.Position=root.Position;position.Parent=root;local orientation=Instance.new("AlignOrientation")orientation.Name="UniverseGlideOrientation";orientation.Mode=Enum.OrientationAlignmentMode.OneAttachment;orientation.Attachment0=point;orientation.RigidityEnabled=false;orientation.ReactionTorqueEnabled=false;orientation.MaxTorque=HOLD_TORQUE;orientation.MaxAngularVelocity=math.huge;orientation.Responsiveness=RESPONSE;orientation.CFrame=root.CFrame.Rotation;orientation.Parent=root;attachment=point;mover=position;aligner=orientation end)if not ok then detach()end;return ok end
 local function step(deltaTime)if not goalFrame then return end;local root=getRoot()if not root then return end;if not mover or mover.Parent~=root or not aligner or aligner.Parent~=root then if not attach(root)then return end;cursor=root.Position;facing=root.CFrame.Rotation end;local humanoid=humanoidOf()if humanoid and not humanoid.PlatformStand then pcall(function()humanoid.PlatformStand=true end)end;cursor=cursor or root.Position;facing=facing or root.CFrame.Rotation;local delta=goalFrame.Position-cursor;local span=GLIDE_SPEED*deltaTime;if delta.Magnitude<=math.max(span,SNAP_GAP)then cursor=goalFrame.Position else cursor+=delta.Unit*span end;streamClock+=deltaTime;if streamClock>=STREAM_GAP then streamClock=0;requestStream(goalFrame.Position)end;local look=goalFrame.Rotation;if aimSpot then local gap=aimSpot-cursor;if gap.Magnitude>0.1 then look=CFrame.lookAt(cursor,aimSpot).Rotation end end;facing=facing:Lerp(look,1-math.exp(-AIM_RATE*deltaTime))mover.Position=cursor;aligner.CFrame=facing end
 function Move.glide(goal,aim)if typeof(goal)~="CFrame"then return false end;goalFrame=goal;aimSpot=typeof(aim)=="Vector3"and aim or nil;if not running then running=true;local root=getRoot()if root then cursor=root.Position;facing=root.CFrame.Rotation;attach(root)end end;if not glideConn then glideConn=Services.RunService.Heartbeat:Connect(function(deltaTime)if not running then return end;local ok,err=pcall(step,deltaTime)if not ok then reportError("滑翔",err)end end)end;return true end
 function Move.glideStop()running=false;goalFrame=nil;aimSpot=nil;cursor=nil;facing=nil;streamClock=0;if glideConn then glideConn:Disconnect()glideConn=nil end;detach()local root=getRoot()if root then pcall(function()root.AssemblyLinearVelocity=Vector3.zero;root.AssemblyAngularVelocity=Vector3.zero end)end;local humanoid=humanoidOf()if humanoid then pcall(function()humanoid.PlatformStand=false;humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)end)end end end
 install()
end

--========================================================
-- UI 构建 (使用 GSENAux 辅助函数, 全部放入 开山 单页面)
--========================================================
-- 仅在「开采一座山」中创建开山标签页 (UniverseId: 10187294555)
local page = isKaishanGame and addTab("开山", "⛰️") or nil

-- 简易文本输入 (最小价值用; GSENAux 无现成文本输入辅助)
local function makeTextInput(parent, text, default, placeholder, callback)
	local container = trackInstance(Instance.new("Frame"))
	container.Size = UDim2.new(1, -5, 0, 36)
	container.BackgroundColor3 = Theme.Element
	container.BorderSizePixel = 0
	local cc = trackInstance(Instance.new("UICorner"))
	cc.CornerRadius = UDim.new(0, 6); cc.Parent = container
	local label = trackInstance(Instance.new("TextLabel"))
	label.Size = UDim2.new(1, -120, 1, 0)
	label.Position = UDim2.fromOffset(12, 0)
	label.BackgroundTransparency = 1
	label.Text = text; label.TextColor3 = Theme.Text
	label.Font = FontMain; label.TextSize = 13
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Parent = container
	local box = trackInstance(Instance.new("TextBox"))
	box.Size = UDim2.new(0, 100, 0, 22)
	box.Position = UDim2.new(1, -112, 0.5, -11)
	box.BackgroundColor3 = Theme.Background
	box.TextColor3 = Theme.Accent
	box.Font = FontBold; box.TextSize = 13
	box.PlaceholderText = placeholder or ""
	box.Text = default or ""
	box.ClearTextOnFocus = false
	box.TextXAlignment = Enum.TextXAlignment.Center
	local bc = trackInstance(Instance.new("UICorner"))
	bc.CornerRadius = UDim.new(0, 4); bc.Parent = box
	box.Parent = container
	trackConnection(box.FocusLost:Connect(function(enter)
		task.spawn(callback, box.Text, enter)
	end))
	container.Parent = parent
	return {container = container, box = box}
end

-- 注册开山模块开关到配置系统
local function ksReg(key, default, getter, applier)
	KS_Config[key]=default
	ConfigControls[#ConfigControls + 1] = {
		key = "ks_" .. key,
		get = function() return getter() end,
		apply = function(v) applier(v) end,
	}
end
-- 通用: 注册一个 makeToggle 返回的开关
local function ksRegToggle(key, toggleHandle, default, onApply)
	KS_Config[key]=default
	ConfigControls[#ConfigControls + 1] = {
		key = "ks_" .. key,
		get = function() return KS_Config[key] end,
		apply = function(v) KS_Config[key]=v; if toggleHandle then toggleHandle.set(v) end; if onApply then onApply(v) end end,
	}
end
-- 通用: 注册一个 makeSlider 返回的滑条
local function ksRegSlider(key, sliderHandle, default, onApply)
	KS_Config[key]=default
	ConfigControls[#ConfigControls + 1] = {
		key = "ks_" .. key,
		get = function() return KS_Config[key] end,
		apply = function(v) KS_Config[key]=v; if sliderHandle then sliderHandle.setValue(v) end; if onApply then onApply(v) end end,
	}
end

-- 水晶ESP
if isKaishanGame then
makeSectionLabel(page, "水晶ESP")
local espToggle=makeToggle(page, "水晶ESP", function(value) KS_Config.espActive=value; State.espActive=value; if not value then clearEsp() end; updateTracking() end)
ksRegToggle("espActive", espToggle, false, function(v) State.espActive=v; if not v then clearEsp() end; updateTracking() end)
local espScaleSlider=makeSlider(page, "水晶大小", 40, 250, 70, "%", function(value) KS_Config.espScale=value/100; State.espScale=value/100; applyEspScale() end)
ksRegSlider("espScale", espScaleSlider, 0.7, function(v) State.espScale=v; applyEspScale() end)
makeSectionLabel(page, "品质过滤 (只显示勾选的品质)")
local tierKeys={"tier1","tier2","tier3","tier4","tier5","tier6","tier7","tier8","tier9"}
for i=1,#TIER_NAMES do local tier=i;local t=makeToggle(page, TIER_NAMES[tier], function(value) KS_Config[tierKeys[tier]]=value; State.tierFilter[tier]=value;requestRefresh()end)t.set(true)ksRegToggle(tierKeys[tier],t,true,function(v) State.tierFilter[tier]=v;requestRefresh()end)end
makeSectionLabel(page, "最小价值会隐藏并跳过低于此价值的水晶。支持单位: k/m/b/t (如 500k, 2m, 1.5b)。留空显示全部")
local function setMinValue(text)local parsed=parseValue(text)if not parsed then return end;State.minValue=math.max(parsed,0)State.valueFilter=State.minValue>0;requestRefresh()end
makeTextInput(page, "最小价值", Config.MinCrystalValue, "2m", setMinValue)
makeSectionLabel(page, "最小重量会隐藏并跳过低于此重量的水晶。支持单位: k/m/b/t (如 5k=5000, 1.5m=1500000)。留空显示全部")
local minWeightInput
local function setMinWeight(text)local parsed=parseValue(text)if not parsed then State.minWeight=0;State.weightFilter=false;if minWeightInput then minWeightInput.box.Text="" end;requestRefresh()return end;State.minWeight=math.max(parsed,0)State.weightFilter=State.minWeight>0;requestRefresh()end
minWeightInput=makeTextInput(page, "最小重量", "", "", setMinWeight)
ConfigControls[#ConfigControls + 1] = {
	key = "ks_minWeight",
	get = function() return minWeightInput.box.Text end,
	apply = function(v) minWeightInput.box.Text = tostring(v or "") setMinWeight(tostring(v or "")) end,
}
makeSectionLabel(page, "最小幸运会隐藏并跳过低于此幸运值的水晶。支持单位: k/m/b (如 5=5%, 10.5=10.5%)。留空显示全部")
local minLuckInput
local function setMinLuck(text)local parsed=parseValue(text)if not parsed then State.minLuck=0;State.luckFilter=false;if minLuckInput then minLuckInput.box.Text="" end;requestRefresh()return end;State.minLuck=math.max(parsed,0)State.luckFilter=State.minLuck>0;requestRefresh()end
minLuckInput=makeTextInput(page, "最小幸运", "", "", setMinLuck)
ConfigControls[#ConfigControls + 1] = {
	key = "ks_minLuck",
	get = function() return minLuckInput.box.Text end,
	apply = function(v) minLuckInput.box.Text = tostring(v or "") setMinLuck(tostring(v or "")) end,
}
StatsLabel=makeSectionLabel(page, "追踪: 0  |  显示: 0")

-- 巨石ESP
makeSectionLabel(page, "巨石ESP")
local bEspToggle=makeToggle(page, "巨石ESP", function(value) KS_Config.boulderEspActive=value; Mountain.setBoulderEsp(value) end)
ksRegToggle("boulderEspActive", bEspToggle, false, function(v) Mountain.setBoulderEsp(v) end)
local bScaleSlider=makeSlider(page, "巨石大小", 40, 250, 60, "%", function(value) KS_Config.boulderScale=value/100; State.boulderScale=value/100; Mountain.applyScale() end)
ksRegSlider("boulderScale", bScaleSlider, 0.6, function(v) State.boulderScale=v; Mountain.applyScale() end)
makeSectionLabel(page, "巨石类型: Mossite / Voltite / Gildrite / Rimeveil / Nocturnite")

-- 拾取
makeSectionLabel(page, "拾取")
local apToggle=makeToggle(page, "自动拾取", function(value) KS_Config.autoPickupActive=value; State.autoPickupActive=value end)
ksRegToggle("autoPickupActive", apToggle, false, function(v) State.autoPickupActive=v end)
local ipToggle=makeToggle(page, "即时提示", function(value) KS_Config.instantPromptActive=value; setInstantPrompt(value) end)
ksRegToggle("instantPromptActive", ipToggle, false, function(v) setInstantPrompt(v) end)
local arToggle=makeToggle(page, "自动符文拾取", function(value) KS_Config.autoRunePickup=value; KS_Toggles.AutoRunePickup=value; Mountain.setAutoGrab(value) end)
ksRegToggle("autoRunePickup", arToggle, false, function(v) KS_Toggles.AutoRunePickup=v; Mountain.setAutoGrab(v) end)
BackpackLabel=makeSectionLabel(page, "背包 0.0 / 0.0 kg")

-- 输入处理 (即时拾取 E)
do
 local MOUSE_KEYS={[Enum.UserInputType.MouseButton1]="MB1",[Enum.UserInputType.MouseButton2]="MB2",[Enum.UserInputType.MouseButton3]="MB3"}
 local function pressedKeyName(input)local pressed=MOUSE_KEYS[input.UserInputType]if not pressed and input.UserInputType==Enum.UserInputType.Keyboard then pressed=input.KeyCode.Name end;return pressed end
 Connections.aimInputConn=trackConnection(Services.UserInputService.InputBegan:Connect(function(input,processed)if processed or Services.UserInputService:GetFocusedTextBox()then return end;local pressed=pressedKeyName(input)if not pressed then return end;if State.instantPromptActive and pressed=="E"then local ok,err=pcall(instantGrab)if not ok then reportError("即时",err)end end end))
end

-- 网络模块
local Net={}
do
 local function install()local PLACE=game.PlaceId;local PAGES=1;local POOL_TARGET=20;local RETRY_STEP=1.5;local RETRY_LIMIT=10;local BACK_DELAY=3;local REFILL_MARK=8;local WARM_STEP=30;local visited={}local pool={}local hopping=false;local reviving=false;local lastCode=0;local alive=true
 local function note(text)showToast("跳服  "..text)end
 local function grab(link)local sender=(syn and syn.request)or(http and http.request)or http_request or request;if type(sender)=="function"then local ok,response=pcall(function()return sender({Url=link,Method="GET"})end)if ok and type(response)=="table"then local code=tonumber(response.StatusCode)or 0;if code>=200 and code<300 and type(response.Body)=="string"then return response.Body,code end;return nil,code end end;local ok,body=pcall(function()return game:HttpGet(link)end)if ok and type(body)=="string"then return body,200 end;return nil,0 end
 local function fetch(cursor)local link=string.format("https://games.roblox.com/v1/games/%d/servers/Public?sortOrder=Desc&excludeFullGames=true&limit=100",PLACE)if type(cursor)=="string"and cursor~=""then link..="&cursor="..cursor end;local body,code=grab(link)if type(body)~="string"then lastCode=code or 0;return nil,nil end;lastCode=200;local parsed,data=pcall(function()return Services.HttpService:JSONDecode(body)end)if not parsed or type(data)~="table"then lastCode=-1;return nil,nil end;return data.data,data.nextPageCursor end
 local function refill()table.clear(pool)local cursor;for _=1,PAGES do local entries,nextCursor=fetch(cursor)if type(entries)=="table"then for _,entry in ipairs(entries)do local id=type(entry)=="table"and entry.id or nil;if type(id)=="string"and id~=game.JobId and not visited[id]then local playing=tonumber(entry.playing)or 0;local room=tonumber(entry.maxPlayers)or 0;if room==0 or playing<room then pool[#pool+1]=id end end end end;cursor=nextCursor;if type(cursor)~="string"or cursor==""or#pool>=POOL_TARGET then break end end;for index=#pool,2,-1 do local swap=math.random(1,index)pool[index],pool[swap]=pool[swap],pool[index]end;return#pool end
 function Net.rejoin()if reviving then return end;reviving=true;local jobId=game.JobId;task.spawn(function()for _=1,RETRY_LIMIT do local sent=pcall(function()Services.TeleportService:TeleportToPlaceInstance(PLACE,jobId,LocalPlayer)end)if not sent then pcall(function()Services.TeleportService:Teleport(PLACE,LocalPlayer)end)end;task.wait(RETRY_STEP)end;reviving=false end)end
 function Net.hop()if hopping then return false end;hopping=true;visited[game.JobId]=true;task.spawn(function()for round=1,RETRY_LIMIT do if#pool==0 and refill()==0 then table.clear(visited)visited[game.JobId]=true;refill()end;local choice=table.remove(pool)if choice then visited[choice]=true;note(string.format("尝试 %d  %s",round,string.sub(choice,1,8)))local sent,err=pcall(function()Services.TeleportService:TeleportToPlaceInstance(PLACE,choice,LocalPlayer)end)if not sent then note("被阻止  "..tostring(err))end;if#pool<=REFILL_MARK then task.spawn(refill)end else note(string.format("无服务器  http %d",lastCode))end;task.wait(RETRY_STEP)end;hopping=false end)return true end
 function Net.forget()table.clear(visited)table.clear(pool)visited[game.JobId]=true end
 function Net.busy()return hopping end
 function Net.ready()return#pool end
 function Net.stop()alive=false end
 task.spawn(function()while alive do if#pool<POOL_TARGET and not hopping then refill()end;task.wait(WARM_STEP)end end)
 Storage.netConns[#Storage.netConns+1]=trackConnection(Services.TeleportService.TeleportInitFailed:Connect(function()hopping=false end))
 Storage.netConns[#Storage.netConns+1]=trackConnection(Services.GuiService.ErrorMessageChanged:Connect(function()local ok,message=pcall(function()return Services.GuiService:GetErrorMessage()end)if ok and type(message)=="string"and message~=""then task.delay(BACK_DELAY,Net.rejoin)end end))
 local prompts=Services.CoreGui:FindFirstChild("RobloxPromptGui")local overlay=prompts and prompts:FindFirstChild("promptOverlay")if overlay then Storage.netConns[#Storage.netConns+1]=trackConnection(overlay.ChildAdded:Connect(function(child)if child.Name:find("ErrorPrompt")then task.delay(BACK_DELAY,Net.rejoin)end end))end end
 install()
end

-- 巨石农场模块
local Farm={}
do
 local function install()local FARM_KINDS={"Mossite","Voltite","Gildrite","Rimeveil","Nocturnite"}
 local SCAN_SPOTS={CFrame.new(-12.7105675,459.090942,818.847412,0.993408799,-0.00500036497,-0.11451605,0.000644713698,0.999275982,-0.0380407833,0.114623353,0.0377162211,0.992692769),CFrame.new(13.0506754,318.450409,-488.078888,-0.99998939,0.000884758658,-0.00452193478,-0.000498382491,0.954864502,0.297041386,0.00458064489,0.297040492,-0.954853892),CFrame.new(74.3923645,610.789368,210.838226,-0.94896102,-0.27110818,0.161162555,2.26557495e-06,0.51098305,0.859590769,-0.315393418,0.815718472,-0.484902382)}
 local PLACE_ID=game.PlaceId;local HOLD_DIST=8;local SCAN_HOLD=1.4;local SWING_GAP=0.04;local SWING_BURST=6;local SWING_FLOOR=0.02;local COOLDOWN_KEYS={"SwingCooldown","DigCooldown","Cooldown","SwingSpeed","DigSpeed"}local AIM_ANGLES={0,35,-35,70,-70,110,-110,145,-145,180}local AIM_LIFT={0,5,-4,12}local SIGHT_GRACE=1.5;local SIGHT_STEPS=8;local LOST_GRACE=1.8;local DRY_ROUNDS=3;local DRY_TIME=1.0;local PROBE_DIST={0,-3,4,-5,8}local CENTER_STEP=0.75;local CENTER_SHIFT=7;local SPOT_HOLD=5.0;local SPOT_SLACK=12;local ARRIVE_DIST=3.5;local STUCK_TIME=4.0;local DRY_SWAP=4.0;local SKIP_TIME=9.0;local SWEEP_PARTS=3;local RUNE_SWEEP=90;local LOOT_TIME=2.5;local EQUIP_STEP=0.5;local RESET_WAIT=1.5
 local PICK_NAMES={["生锈的废铁"]=true,["风化的木头"]=true,["碎裂的石头"]=true,["硬化铁"]=true,["铜镐"]=true,["强化钢"]=true,["钛金尖刺"]=true,["冰霜镐"]=true,["翡翠雕刻者"]=true,["火山玄武岩"]=true,["黑曜石之刃"]=true,["风暴镐"]=true,["天界顶点"]=true,["星界撕裂"]=true,["日蚀之牙"]=true,["星云王座"]=true,["虚空统治"]=true,["奇点"]=true,["终焉"]=true,["管理员镐"]=true,["鲨鱼镐"]=true,["钻石镐"]=true}
 local active=false;local autoRejoin=Config.AutoRejoinBoulders;local targets={}local phase="idle";local target,anchor;local swingClock=0;local equipClock=0;local waitUntil=0;local lastSpot;local hpMark;local dryRounds=0;local scanned=false;local scanIndex=0;local heldPick;local spotFrame;local aimTurn=0;local blindClock=0;local lostClock=0;local dryClock=0;local probeIndex=0;local partCursor=0;local pendingFinish=false;local lootUntil=0;local statusText="空闲";local scanRetries=0;local lastPos;local stuckClock=0;local lockedCenter;local spotCenter;local centerClock=0;local spotClock=0
 local function toggleValue(name)return KS_Toggles[name]==true end
 local function isPickaxe(tool)if not tool or not tool:IsA("Tool")then return false end;if getAttr(tool,"IsPickaxe")==true then return true end;if PICK_NAMES[tool.Name]then return true end;return getAttr(tool,"DigPower")~=nil and getAttr(tool,"Tier")==nil end
 local function pickScore(tool)if not isPickaxe(tool)then return 0 end;local score=1;local power=tonumber(getAttr(tool,"DigPower"))if power then score+=power end;return score end
 local function equipPick()local character=LocalPlayer.Character;local humanoid=character and character:FindFirstChildOfClass("Humanoid")if not character or not humanoid then return nil end;local held=character:FindFirstChildOfClass("Tool")if held and isPickaxe(held)then return held end;local choice;local best=0;local function consider(tool)local score=pickScore(tool)if score>best then best=score;choice=tool end end;consider(held)local backpack=LocalPlayer:FindFirstChildOfClass("Backpack")if backpack then for _,tool in ipairs(backpack:GetChildren())do consider(tool)end end;if not choice then if backpack then for _,tool in ipairs(backpack:GetChildren())do if tool:IsA("Tool")then choice=tool;break end end end end;if not choice then return nil end;if choice==held then return held end;pcall(function()humanoid:EquipTool(choice)end)local now=character:FindFirstChildOfClass("Tool")if now then return now end;return choice end
 local rayParams=RaycastParams.new()rayParams.FilterType=Enum.RaycastFilterType.Exclude;rayParams.IgnoreWater=true;rayParams.RespectCanCollide=false
 local JUNK_WORDS={"vfx","effect","fx","debris","particle","shard","chunk","dust","smoke"}
 local function junkName(instance)local name=string.lower(instance.Name)for _,word in ipairs(JUNK_WORDS)do if string.find(name,word,1,true)then return true end end;return false end
 local function ignorable(instance,model)if not instance then return true end;if model and instance:IsDescendantOf(model)then return true end;if instance:IsA("Terrain")then return true end;if not instance:IsA("BasePart")then return true end;if instance.Transparency>=0.5 or not instance.CanCollide or not instance.CanQuery then return true end;if not instance.Anchored or instance.Massless then return true end;if junkName(instance)then return true end;local owner=instance:FindFirstAncestorOfClass("Model")if owner and Services.Players:GetPlayerFromCharacter(owner)then return true end;return false end
 local function sightClear(origin,part,model)if not part or not part.Parent then return true end;local delta=part.Position-origin;local distance=delta.Magnitude;if distance<1 then return true end;local skip={LocalPlayer.Character,Services.Workspace.Terrain}for _=1,SIGHT_STEPS do rayParams.FilterDescendantsInstances=skip;local hit=Services.Workspace:Raycast(origin,delta.Unit*(distance+2),rayParams)if not hit then return true end;local instance=hit.Instance;if instance==part or(model and instance:IsDescendantOf(model))then return true end;if not ignorable(instance,model)then return false end;skip[#skip+1]=instance end;return true end
 local function usablePart(item)if not item:IsA("BasePart")then return false end;if not item.Anchored or item.Transparency>=0.9 or item.Massless then return false end;return not junkName(item)end
 local function partList(model)local list={}if not model then return list end;if model:IsA("BasePart")then list[1]=model;return list end;local spare={}for _,item in ipairs(model:GetDescendants())do if item:IsA("BasePart")then if usablePart(item)then list[#list+1]=item else spare[#spare+1]=item end end end;if#list>0 then return list end;return spare end
 local function anchorSpot(model,part)if part and part.Parent then return part.Position end;if not model or not model.Parent then return nil end;local ok,pivot=pcall(model.GetPivot,model)if ok and pivot then return pivot.Position end;return nil end
 local function coreSpot(model)if not model or not model.Parent then return nil end;if model:IsA("BasePart")then return model.Position end;local boxed,box=pcall(model.GetBoundingBox,model)if boxed and box then return box.Position end;local ok,pivot=pcall(model.GetPivot,model)if ok and pivot then return pivot.Position end;return nil end
 local function coreFrame(core,part)local look=part and part.Parent and part.Position or nil;if not look or(look-core).Magnitude<1 then look=core+Vector3.new(0,-2,0)end;return CFrame.new(core,look)end
 local function visibleAnchor(model)if not model then return nil end;local root=getRoot()local origin=root and root.Position;local pick,pickDistance,fallback,fallbackDistance;for _,part in ipairs(partList(model))do local distance=origin and(part.Position-origin).Magnitude or 0;if not fallback or distance<fallbackDistance then fallback=part;fallbackDistance=distance end;if origin and sightClear(origin,part,model)then if not pick or distance<pickDistance then pick=part;pickDistance=distance end end end;return pick or fallback end
 local function freshAnchor(model)local list=partList(model)local count=#list;if count==0 then return nil end;for _=1,count do partCursor=partCursor%count+1;local item=list[partCursor]if item and item.Parent then return item end end;return nil end
 local function hitSpot(part,model)local root=getRoot()if not root then return part.Position end;local origin=root.Position;local delta=part.Position-origin;local distance=delta.Magnitude;if distance<1 then return part.Position end;local skip={LocalPlayer.Character,Services.Workspace.Terrain}for _=1,SIGHT_STEPS do rayParams.FilterDescendantsInstances=skip;local hit=Services.Workspace:Raycast(origin,delta.Unit*(distance+2),rayParams)if not hit then break end;if hit.Instance==part or hit.Instance:IsDescendantOf(model)then return hit.Position end;skip[#skip+1]=hit.Instance end;return part.Position end
 local function swingGap(tool)local pick=tool or heldPick;if pick then for _,key in ipairs(COOLDOWN_KEYS)do local value=tonumber(getAttr(pick,key))if value and value>0 then return math.clamp(value,SWING_FLOOR,0.5)end end end;return SWING_GAP end
 local function swing(part,model,center)local event=Remotes.DigRequest;if not event or not heldPick then return false end;local name=heldPick.Name;local core=center or(part and part.Parent and part.Position)local spot=core;if part and part.Parent then spot=hitSpot(part,model)or core end;if not spot and not core then return false end;spot=spot or core;core=core or spot;local sweepList={}if model and model.Parent then local list=partList(model)local count=#list;if count>0 then for _=1,math.min(SWEEP_PARTS,count)do partCursor=partCursor%count+1;local item=list[partCursor]if item and item.Parent then sweepList[#sweepList+1]=item.Position end end end end;return pcall(function()for index=1,SWING_BURST do if index%2==0 then fireRemote(event,name,core)else fireRemote(event,name,spot)end end;for _,point in ipairs(sweepList)do fireRemote(event,name,point)end end)end
 local function hold(goal,aim)return Move.glide(goal,aim)end
 local function restart()task.spawn(function()pcall(function()LocalPlayer:Kick("开山: 正在重启服务器")end)for _=1,20 do task.wait(1.5)local sent=pcall(function()Services.TeleportService:Teleport(PLACE_ID,LocalPlayer)end)if not sent then pcall(function()Services.TeleportService:TeleportToPlaceInstance(PLACE_ID,game.JobId,LocalPlayer)end)end end end)end
 local function boulderRoots()local roots={}local decorations=Services.Workspace:FindFirstChild("MountainDecorations")local folder=decorations and decorations:FindFirstChild("Boulders")if folder then roots[#roots+1]=folder end;local test=Services.Workspace:FindFirstChild("BoulderTest")if test then roots[#roots+1]=test end;return roots end
 local function boulderKind(inst)if not inst then return nil end;local attrName=getAttr(inst,"BoulderName")local str=tostring(attrName or inst.Name)for _,kind in ipairs(FARM_KINDS)do if str:find(kind,1,true)then return kind end end;return nil end
 local function anchorOf(model)if not model then return nil end;if model:IsA("BasePart")then return model end;local list=partList(model)if list[1]then return list[1]end;local ok,part=pcall(model.FindFirstChildWhichIsA,model,"BasePart",true)if ok and part then return part end;return nil end
 local function boulderHealth(model)if not model then return nil end;local hp=getAttr(model,"HP")if hp==nil then hp=getAttr(model,"Health")end;if hp==nil then hp=getAttr(model,"Hp")end;if hp==nil then hp=getAttr(model,"CurrentHealth")end;return tonumber(hp)end
 local blacklistedBoulders={}local lastDamageClock=0
 local function pickTarget()local root=getRoot()if not root then return nil end;local now=os.clock()for b,expire in pairs(blacklistedBoulders)do if now>expire or not b.Parent then blacklistedBoulders[b]=nil end end;local best,bestAnchor,bestScore;for _,container in ipairs(boulderRoots())do for _,child in ipairs(container:GetChildren())do if not blacklistedBoulders[child]then local kind=boulderKind(child)if kind and targets[kind]then local part=anchorOf(child)if part then local distance=(part.Position-root.Position).Magnitude;local hp=boulderHealth(child)or 0;if hp>=0 then local priority=10;for idx,k in ipairs(FARM_KINDS)do if k==kind then priority=idx;break end end;local score=priority*1000+distance;if not best or score<bestScore then best=child;bestAnchor=part;bestScore=score end end end end end end end;return best,bestAnchor end
 local function approach(part,model,turn,spot,pad)local root=getRoot()if not root then return nil end;local center=spot or(part and part.Parent and part.Position)if not center then return nil end;local away=root.Position-center;away=Vector3.new(away.X,0,away.Z)if away.Magnitude<0.5 then away=Vector3.new(0,0,1)end;away=away.Unit;local modelSize;if model and model:IsA("Model")then local ok,ext=pcall(model.GetExtentsSize,model)if ok and ext then modelSize=ext end end;if not modelSize and part and part.Parent then modelSize=part.Size end;modelSize=modelSize or Vector3.new(12,12,12)local outerRadius=math.max(modelSize.X,modelSize.Z)*0.5;local reach=math.max(outerRadius+6.5+(pad or 0),8.5)local skip=turn or 0;for _,lift in ipairs(AIM_LIFT)do for _,angle in ipairs(AIM_ANGLES)do local dir=(CFrame.fromAxisAngle(Vector3.yAxis,math.rad(angle))*away).Unit;local candidate=center+dir*reach+Vector3.new(0,lift,0)if sightClear(candidate,part,model)then if skip<=0 then return CFrame.new(candidate,center)end;skip-=1 end end end;return CFrame.new(center+away*reach+Vector3.new(0,AIM_LIFT[2],0),center)end
 local function beginLoot(finish)pendingFinish=finish==true;lootUntil=os.clock()+LOOT_TIME;phase="loot";statusText="正在拾取符文"end
 local function stop()active=false;phase="idle";target=nil;anchor=nil;waitUntil=0;Move.glideStop()hpMark=nil;dryRounds=0;pendingFinish=false;lootUntil=0;spotFrame=nil;aimTurn=0;blindClock=0;lostClock=0;dryClock=0;probeIndex=0;scanRetries=0;stuckClock=0;lastPos=nil;lastDamageClock=0;lockedCenter=nil;spotCenter=nil;centerClock=0;spotClock=0;table.clear(blacklistedBoulders)statusText="空闲";Move.setFly(toggleValue("Fly"))Move.setNoclip(toggleValue("Noclip"))Mountain.setAutoGrab(toggleValue("AutoRunePickup"))end
 local function step(deltaTime)local root=getRoot()if not root then statusText="等待角色...";return end;local now=os.clock()local travelling=spotFrame~=nil and(root.Position-spotFrame.Position).Magnitude>ARRIVE_DIST;if travelling and lastPos and(root.Position-lastPos).Magnitude<0.5 then stuckClock+=deltaTime;if stuckClock>=STUCK_TIME then stuckClock=0;spotFrame=nil;aimTurn=(aimTurn+1)%#AIM_ANGLES;probeIndex+=1 end else stuckClock=0;lastPos=root.Position end;if phase=="scan"then if not scanned then if scanIndex==0 then scanIndex=1;waitUntil=now+SCAN_HOLD end;if scanIndex<=#SCAN_SPOTS then hold(SCAN_SPOTS[scanIndex])statusText=string.format("扫描中 %d/%d",scanIndex,#SCAN_SPOTS)if now>=waitUntil then scanIndex+=1;waitUntil=now+SCAN_HOLD end;return end;scanned=true end;local model=pickTarget()if not model then scanRetries+=1;if scanRetries<=3 then statusText="等待巨石...";waitUntil=now+1.5;return end;scanRetries=0;beginLoot(true)statusText="最终符文扫描";return end;scanRetries=0;target=model;anchor=visibleAnchor(model)or anchorOf(model)spotFrame=nil;spotCenter=nil;lockedCenter=nil;centerClock=0;spotClock=0;aimTurn=0;blindClock=0;lostClock=0;dryClock=0;probeIndex=0;hpMark=nil;dryRounds=0;lastDamageClock=now;phase="mine";return end;if phase=="mine"then if not target or not target.Parent then lastSpot=root.CFrame;beginLoot(false)return end;local kind=boulderKind(target)or"巨石";local hp=boulderHealth(target)if hp and hp<=0 then lastSpot=root.CFrame;beginLoot(false)return end;if not anchor or not anchor.Parent or not anchor:IsDescendantOf(target)then anchor=visibleAnchor(target)or anchorOf(target)end;centerClock+=deltaTime;local center=lockedCenter;if not center or centerClock>=CENTER_STEP then centerClock=0;local fresh=coreSpot(target)or anchorSpot(target,anchor)if fresh and(not center or(fresh-center).Magnitude>=CENTER_SHIFT)then center=fresh;lockedCenter=fresh end end;if not center then lostClock+=deltaTime;if lostClock>=LOST_GRACE then lastSpot=root.CFrame;beginLoot(false)return end;statusText=string.format("保持 %s",kind)return end;lostClock=0;spotClock+=deltaTime;if spotFrame and spotCenter and(spotCenter-center).Magnitude>SPOT_SLACK then spotFrame=nil end;if not spotFrame then spotFrame=approach(anchor,target,aimTurn,center,PROBE_DIST[probeIndex%#PROBE_DIST+1])spotCenter=center;spotClock=0 end;if spotFrame then Move.setNoclip(true)hold(spotFrame,center)end;if heldPick==nil or heldPick.Parent~=LocalPlayer.Character then equipClock=0;heldPick=equipPick()else equipClock+=deltaTime;if equipClock>=EQUIP_STEP then equipClock=0;heldPick=equipPick()or heldPick end end;if not heldPick then statusText="装备镐子中...";return end;swingClock+=deltaTime;local gap=swingGap()local swung=0;if swingClock>=gap then swung=math.min(math.floor(swingClock/gap),4)swingClock-=swung*gap;for _=1,swung do swing(anchor,target,center)end end;if hp then if hpMark==nil or hp<(hpMark-0.001)then hpMark=hp;dryRounds=0;dryClock=0;blindClock=0;lastDamageClock=now else dryClock+=deltaTime;dryRounds+=swung;if dryClock>=DRY_SWAP then dryClock=0;dryRounds=0;anchor=freshAnchor(target)or visibleAnchor(target)or anchor;if spotClock>=SPOT_HOLD then aimTurn=(aimTurn+1)%#AIM_ANGLES;probeIndex+=1;spotFrame=nil end end end;if now-lastDamageClock>=SKIP_TIME then blacklistedBoulders[target]=now+15;target=nil;anchor=nil;spotFrame=nil;phase="scan";statusText="跳过无法击中的巨石";return end;statusText=string.format("挖掘 %s  %.0f 血量",kind,hp)return end;if sightClear(root.Position,anchor,target)then blindClock=0 else blindClock+=deltaTime;if blindClock>=SIGHT_GRACE then blindClock=0;anchor=visibleAnchor(target)or anchor;if spotClock>=SPOT_HOLD then aimTurn=(aimTurn+1)%#AIM_ANGLES;spotFrame=nil end end end;statusText=string.format("挖掘 %s",kind)return end;if phase=="loot"then if lastSpot then hold(lastSpot)end;Mountain.grabNear(RUNE_SWEEP)if now<lootUntil then statusText=string.format("拾取符文中  %.1fs",lootUntil-now)return end;if pendingFinish then phase="reset";waitUntil=now+RESET_WAIT;statusText="符文已收集"else target=nil;anchor=nil;phase="scan";statusText="下一个巨石"end;return end;if phase=="reset"then if now<waitUntil then return end;if autoRejoin then statusText="正在重启服务器";showToast("没有更多巨石 - 重新加入中")stop()restart()else statusText="重新扫描山脉...";showToast("没有更多巨石 - 4秒后重新扫描")target=nil;anchor=nil;scanned=false;scanIndex=0;phase="scan";waitUntil=now+4.0 end end end
 local function setActive(value)if not value then stop()return end;if not next(targets)then showToast("请选择至少一个巨石")if KS_ToggleHandles.AutoFarmBoulders then KS_ToggleHandles.AutoFarmBoulders.set(false)end;return end;active=true;phase="scan";waitUntil=0;target=nil;anchor=nil;lastSpot=nil;swingClock=0;equipClock=0;hpMark=nil;dryRounds=0;spotFrame=nil;aimTurn=0;blindClock=0;lostClock=0;dryClock=0;probeIndex=0;scanned=false;scanIndex=0;heldPick=nil;pendingFinish=false;lootUntil=0;scanRetries=0;stuckClock=0;lastPos=nil;lockedCenter=nil;spotCenter=nil;centerClock=0;spotClock=0;statusText="启动中";Move.setFly(false)Move.setNoclip(true)Mountain.setAutoGrab(true)end
 -- 巨石农场 UI (使用 GSENAux 辅助函数)
 makeSectionLabel(page, "巨石农场 - 目标 (选择要挖的巨石类型)")
 local boulderKeys={"boulderMossite","boulderVoltite","boulderGildrite","boulderRimeveil","boulderNocturnite"}
 for idx,kind in ipairs(FARM_KINDS) do local t=makeToggle(page, kind, function(value) KS_Config[boulderKeys[idx]]=value; if value then targets[kind]=true else targets[kind]=nil end end) ksRegToggle(boulderKeys[idx],t,false,function(v) if v then targets[kind]=true else targets[kind]=nil end end) end
 local farmToggle=makeToggle(page, "巨石自动农场", setActive)
 KS_ToggleHandles.AutoFarmBoulders=farmToggle
 ksRegToggle("autoFarmBoulders",farmToggle,false,function(v) setActive(v) end)
 local rejoinToggle=makeToggle(page, "完成后自动重进", function(value) KS_Config.autoRejoinBoulders=value; autoRejoin=value end)
 ksRegToggle("autoRejoinBoulders",rejoinToggle,false,function(v) autoRejoin=v end)
 local StatusLabel=makeSectionLabel(page, "巨石农场状态: 空闲")
 local labelClock=0
 Connections.farmConn=trackConnection(Services.RunService.Heartbeat:Connect(function(deltaTime)if active then local ok,err=pcall(step,deltaTime)if not ok then reportError("巨石农场",err)end end;labelClock+=deltaTime;if labelClock>=0.25 then labelClock=0;StatusLabel.Text="巨石农场状态: "..statusText end end))
 Farm.stop=stop;Farm.equipPick=equipPick;Farm.swingGap=swingGap end
 install()
end

-- 金钱农场模块
local Money={}
do
 local function install()local SCAN_SPOTS={CFrame.new(-12.7105675,459.090942,818.847412,0.993408799,-0.00500036497,-0.11451605,0.000644713698,0.999275982,-0.0380407833,0.114623353,0.0377162211,0.992692769),CFrame.new(13.0506754,318.450409,-488.078888,-0.99998939,0.000884758658,-0.00452193478,-0.000498382491,0.954864502,0.297041386,0.00458064489,0.297040492,-0.954853892),CFrame.new(74.3923645,610.789368,210.838226,-0.94896102,-0.27110818,0.161162555,2.26557495e-06,0.51098305,0.859590769,-0.315393418,0.815718472,-0.484902382)}
 local SCAN_HOLD=1.4;local PEAK_GAP=8;local PEAK_STEP=48;local PEAK_RINGS=12;local COLUMN_STEP=8;local RING_MAX=6;local RAY_TOP=120;local RAY_DROP=60;local ZONE_PAD=12;local SURFACE_GAP=0.15;local COLUMN_DRY=25;local DIG_BURST=7;local DIG_SINK=1.2;local DIG_LIFT=6;local EQUIP_STEP=0.5;local SELL_MARK=Config.AutoSellThreshold;local SELL_WAIT=7;local DIG_REACH=12;local DIG_REFRESH=5;local COLLECT_RANGE=32000;local COLLECT_LIFT=5;local COLLECT_GAP=0.15;local GRAB_GAP=0.05;local MAX_LOOT_TIME=4.0
 local OFFSETS={Vector2.new(0,0)}local PEAK_OFFSETS={Vector2.new(0,0)}for ring=1,RING_MAX do local slices=ring*6;for slice=0,slices-1 do local angle=slice/slices*math.pi*2;local reach=ring*COLUMN_STEP;OFFSETS[#OFFSETS+1]=Vector2.new(math.cos(angle)*reach,math.sin(angle)*reach)end end;for ring=1,PEAK_RINGS do local slices=ring*3;for slice=0,slices-1 do local angle=slice/slices*math.pi*2;local reach=ring*PEAK_STEP;PEAK_OFFSETS[#PEAK_OFFSETS+1]=Vector2.new(math.cos(angle)*reach,math.sin(angle)*reach)end end
 local surfaceParams=RaycastParams.new()surfaceParams.FilterType=Enum.RaycastFilterType.Include;surfaceParams.FilterDescendantsInstances={Services.Workspace.Terrain}surfaceParams.IgnoreWater=true
 local digParams=RaycastParams.new()digParams.FilterType=Enum.RaycastFilterType.Include;digParams.IgnoreWater=true
 local digClock=0
 local function digFilter(now)if digClock>0 and now-digClock<DIG_REFRESH then return end;digClock=now;local list={Services.Workspace.Terrain}local decorations=Services.Workspace:FindFirstChild("MountainDecorations")local boulders=decorations and decorations:FindFirstChild("Boulders")if boulders then list[#list+1]=boulders end;local test=Services.Workspace:FindFirstChild("BoulderTest")if test then list[#list+1]=test end;digParams.FilterDescendantsInstances=list end
 local function pickReach(tool)local override=tool and tonumber(getAttr(tool,"OverrideMaxReach"))return(override or DIG_REACH)+3 end
 local function aimPoint(origin,spot,reach,now)digFilter(now)local goals={spot,spot-Vector3.new(0,2,0),origin-Vector3.new(0,reach,0)}for _,goal in ipairs(goals)do local delta=goal-origin;local distance=delta.Magnitude;if distance>0.05 then local span=math.min(distance+4,reach)local hit=Services.Workspace:Raycast(origin,delta.Unit*span,digParams)if hit then return hit.Position end end end;local delta=spot-origin;if delta.Magnitude<=reach then return spot end;return origin+delta.Unit*reach end
 local active=false;local autoSell=false;local focusLuck=false;local minLuckPoints=4;local autoPlantLuck=false;local plantClock=0;local heldPick;local loot;local lootClock=0;local grabClock=0;local lootHp;local lootMax;local lootStartTime=0;local lootLastHpChange=0;local lootHpMark;local blacklistedLoot={}local blacklistedColumns={}local target;local columnY;local columnDry=0;local columnSwings=0;local surfaceClock=0;local peakClock=0;local scanIndex=0;local scanUntil=0;local loaded=false;local swingClock=0;local equipClock=0;local sellPhase="idle";local sellReturnCFrame;local sellPhaseClock=0;local plantPhase="idle";local plantPhaseClock=0;local plantReturnCFrame;local plantTools={}local plantIndex=1;local plantPlotPos;local plantGroundPos;local lootBlocked=false;local statusText="空闲"
 local function toggleValue(name)return KS_Toggles[name]==true end
 local function getSellCFrame()local things=Services.Workspace:FindFirstChild("Things")local prox=things and things:FindFirstChild("SellProx")if prox and prox:IsA("BasePart")then return CFrame.new(prox.Position+Vector3.new(0,3,0),prox.Position)end;local model=things and things:FindFirstChild("SellModel")local part=model and model:FindFirstChild("SellPart")if part and part:IsA("BasePart")then return CFrame.new(part.Position+Vector3.new(0,3,0),part.Position)end;return CFrame.new(-45.85,32,1066.58)end
 local function zoneBase()local base=Services.Workspace:GetAttribute("MountainBaseY")if typeof(base)=="number"then return base end;return Config.MountainCenter.Y-500 end
 local function zonePeak()local peak=Services.Workspace:GetAttribute("MountainPeakY")if typeof(peak)=="number"then return peak end;return Config.MountainCenter.Y+600 end
 local function zoneCenter()local spot=mountainSpot()if spot then return Vector2.new(spot.X,spot.Z)end;return Vector2.new(Config.MountainCenter.X,Config.MountainCenter.Z)end
 local function insideZone(x,z)local center=zoneCenter()if not center then return false end;return(Vector2.new(x,z)-center).Magnitude<=mountainSpan()+ZONE_PAD end
 local function surfaceAt(x,z)if not insideZone(x,z)then return nil end;local base=zoneBase()local top=zonePeak()+RAY_TOP;local hit=Services.Workspace:Raycast(Vector3.new(x,top,z),Vector3.new(0,-(top-base+RAY_DROP),0),surfaceParams)if not hit or hit.Position.Y<=base+1 then return nil end;return hit.Position end
 local function farmOrigin(root)if insideZone(root.Position.X,root.Position.Z)then return root.Position end;return mountainSpot()or root.Position end
 local function gridKey(x,z)return string.format("%d_%d",math.floor(x/4),math.floor(z/4))end
 local function highestColumn(origin,offsets)local now=os.clock()local best;for _,offset in ipairs(offsets)do local posX=origin.X+offset.X;local posZ=origin.Z+offset.Y;local key=gridKey(posX,posZ)local expire=blacklistedColumns[key]if not expire or now>expire then blacklistedColumns[key]=nil;local spot=surfaceAt(posX,posZ)if spot and(not best or spot.Y>best.Y)then best=spot end end end;return best end
 local function pickTarget(origin,now)local center=mountainSpot()if center and now-peakClock>=PEAK_GAP then peakClock=now;local high=highestColumn(center,PEAK_OFFSETS)if high then return high end end;local spot=highestColumn(origin,OFFSETS)if spot then return spot end;if center then peakClock=now;return highestColumn(center,PEAK_OFFSETS)end;return nil end
 local function holdAt(goal,aim)return Move.glide(goal,aim)end
 local function swing(spot)local event=Remotes.DigRequest;if not event or not heldPick then return false end;local name=heldPick.Name;local root=getRoot()local aim=spot;if root then aim=aimPoint(root.Position,spot,pickReach(heldPick),os.clock())or spot end;return pcall(function()for step=0,DIG_BURST-1 do fireRemote(event,name,aim-Vector3.new(0,step*DIG_SINK,0))end end)end
 local function bagRatio()local capacity=backpackCapacity()if capacity==math.huge or capacity<=0 then return 0 end;return backpackWeight()/capacity end
 local function getPlayerPlot()local lpName=LocalPlayer.Name;local slots=Services.Workspace:FindFirstChild("Things")and Services.Workspace.Things:FindFirstChild("Plots")and Services.Workspace.Things.Plots:FindFirstChild("Slots")if slots then local plot=slots:FindFirstChild(lpName)if plot then return plot end end;return nil end
 local function getPlotPlantPosition()local plot=getPlayerPlot()if not plot then return nil end;local spawn=plot:FindFirstChild("Spawn")local region=plot:FindFirstChild("Region")if region and region:IsA("BasePart")and spawn and spawn:IsA("BasePart")then local corner=region.CFrame*CFrame.new(-region.Size.X/2+15,0,-region.Size.Z/2+15)return Vector3.new(corner.Position.X,spawn.Position.Y-1.5,corner.Position.Z)end;if spawn and spawn:IsA("BasePart")then return spawn.Position-Vector3.new(30,1.5,30)end;local ok,pivot=pcall(plot.GetPivot,plot)if ok and pivot then return pivot.Position end;return nil end
 local function getLuckToolsInBackpack()local list={}local function scan(container)if not container then return end;for _,child in ipairs(container:GetChildren())do if child:IsA("Tool")then local isCryst=getAttr(child,"Tier")~=nil or child:GetAttribute("MeshTemplate")~=nil;if isCryst then local luckPts=math.floor(crystalLuck(child)*100+0.5)if luckPts>=minLuckPoints then list[#list+1]=child end end end end end;scan(LocalPlayer:FindFirstChildOfClass("Backpack"))scan(LocalPlayer.Character)return list end
 local function findLoot(free,origin)local now=os.clock()local best,bestScore,bestDistance;local blocked=false;local seen={}for inst,expire in pairs(blacklistedLoot)do if now>expire or not inst.Parent then blacklistedLoot[inst]=nil end end;local function consider(inst)if not inst or seen[inst]or blacklistedLoot[inst]then return end;seen[inst]=true;if not inst.Parent or not isCrystal(inst)or getAttr(inst,"Collected")==true then return end;if not tierFilterOk(inst)then return end;if not meetsWeightFilter(inst)then return end;if not meetsLuckFilter(inst)then return end;local score=0;if focusLuck then local luckPts=math.floor(crystalLuck(inst)*100+0.5)if luckPts<minLuckPoints then return end;score=luckPts else local value=crystalValue(inst)if not meetsFilter(inst,value)then return end;score=value end;local distance=(inst.Position-origin).Magnitude;if distance>COLLECT_RANGE then return end;if crystalWeight(inst)>free then blocked=true;return end;local better=false;if not best then better=true elseif score>bestScore then better=true elseif score==bestScore and distance<bestDistance then better=true end;if better then best=inst;bestScore=score;bestDistance=distance end end;eachContainer(function(container)for _,child in ipairs(container:GetChildren())do if child:IsA("BasePart")then consider(child)elseif child:IsA("Model")then for _,inner in ipairs(child:GetChildren())do if inner:IsA("BasePart")then consider(inner)end end end end end)for inst in pairs(Storage.registry)do consider(inst)end;return best,blocked end
 local function stop()active=false;target=nil;columnY=nil;loaded=false;Move.glideStop()scanIndex=0;loot=nil;lootHp=nil;lootMax=nil;lootBlocked=false;lootStartTime=0;lootLastHpChange=0;lootHpMark=nil;table.clear(blacklistedLoot)table.clear(blacklistedColumns)sellPhase="idle";sellReturnCFrame=nil;sellPhaseClock=0;plantPhase="idle";plantPhaseClock=0;plantReturnCFrame=nil;heldPick=nil;statusText="空闲";Move.setFly(toggleValue("Fly"))Move.setNoclip(toggleValue("Noclip"))Mountain.setAutoGrab(toggleValue("AutoRunePickup"))end
 local function crystalHealth(inst)if not inst then return nil end;local hp=getAttr(inst,"MinedHP")or getAttr(inst,"Health")or getAttr(inst,"Hp")or getAttr(inst,"CurrentHealth")return tonumber(hp)end
 local function step(deltaTime)local root=getRoot()if not root then statusText="等待角色...";return end;local now=os.clock()if plantPhase~="idle"then if plantPhase=="travel"then statusText="前往地块...";holdAt(plantPlotPos)if(root.Position-plantPlotPos.Position).Magnitude<10 or(now-plantPhaseClock>12)then plantPhase="do_plant";plantPhaseClock=now end;return end;if plantPhase=="do_plant"then statusText="种植幸运水晶...";holdAt(plantPlotPos)if now-plantPhaseClock>=0.15 then plantPhaseClock=now;if plantIndex<=#plantTools then local tool=plantTools[plantIndex]local col=(plantIndex-1)%6;local row=math.floor((plantIndex-1)/6)local plantSpot=plantGroundPos+Vector3.new(col*4-10,0,row*4-10)pcall(function()Remotes.PlotPlaceRequest:FireServer(tool.Name,plantSpot,0,tool)end)plantIndex+=1 else plantPhase="return";plantPhaseClock=now end end;return end;if plantPhase=="return"then statusText="返回山脉...";local destination=plantReturnCFrame or mountainSpot()holdAt(destination)if(root.Position-destination.Position).Magnitude<12 or(now-plantPhaseClock>12)then plantPhase="idle";plantReturnCFrame=nil;target=nil;columnY=nil;surfaceClock=0 end;return end end;if autoPlantLuck and plantPhase=="idle"and now-plantClock>=2.0 then plantClock=now;local tools=getLuckToolsInBackpack()if#tools>=5 then local pos=getPlotPlantPosition()if pos then plantGroundPos=pos;plantPlotPos=CFrame.new(pos+Vector3.new(0,8,0),pos)plantReturnCFrame=root.CFrame;plantTools=tools;plantIndex=1;plantPhase="travel";plantPhaseClock=now;statusText="前往地块...";return end end end;if not loaded then if scanIndex==0 then scanIndex=1;scanUntil=now+SCAN_HOLD end;if scanIndex<=#SCAN_SPOTS then holdAt(SCAN_SPOTS[scanIndex])statusText=string.format("加载地形 %d/%d",scanIndex,#SCAN_SPOTS)if now>=scanUntil then scanIndex+=1;scanUntil=now+SCAN_HOLD end;return end;loaded=true;peakClock=0 end;if sellPhase~="idle"then local sellCFrame=getSellCFrame()if sellPhase=="travel"then statusText="前往出售站...";holdAt(sellCFrame)if(root.Position-sellCFrame.Position).Magnitude<10 or(now-sellPhaseClock>12)then sellPhase="do_sell";sellPhaseClock=now end;return end;if sellPhase=="do_sell"then statusText="出售水晶...";holdAt(sellCFrame)if now-sellPhaseClock>=0.3 and now-sellPhaseClock<0.6 then unfavoriteAll()fireRemote(Remotes.SellRequest,"all")local things=Services.Workspace:FindFirstChild("Things")local prox=things and things:FindFirstChild("SellProx")local prompt=prox and prox:FindFirstChildOfClass("ProximityPrompt")if prompt then firePrompt(prompt)end end;if(now-sellPhaseClock>=1.5)or(backpackWeight()<=0)then lootBlocked=false;sellPhase="return";sellPhaseClock=now end;return end;if sellPhase=="return"then statusText="返回山脉...";local destination=sellReturnCFrame or mountainSpot()holdAt(destination)if(root.Position-destination.Position).Magnitude<12 or(now-sellPhaseClock>12)then sellPhase="idle";sellReturnCFrame=nil;target=nil;columnY=nil;surfaceClock=0 end;return end end;if autoSell and sellPhase=="idle"and(bagRatio()>=SELL_MARK or lootBlocked)then sellReturnCFrame=root.CFrame;sellPhase="travel";sellPhaseClock=now;statusText="前往出售站...";return end;if focusLuck then pickupStep(function(inst)local luckPts=math.floor(crystalLuck(inst)*100+0.5)return luckPts>=minLuckPoints end)else pickupStep()end;if heldPick==nil or heldPick.Parent~=LocalPlayer.Character then equipClock=0;heldPick=Farm.equipPick()else equipClock+=deltaTime;if equipClock>=EQUIP_STEP then equipClock=0;heldPick=Farm.equipPick()or heldPick end end;if not heldPick then statusText="装备镐子中...";return end;swingClock+=deltaTime;local swingNeed=math.max(0.02,Farm.swingGap(heldPick)*0.4)local canSwing=swingClock>=swingNeed;local free=backpackFree()if loot then local parented=loot.Parent~=nil;local collected=(getAttr(loot,"Collected")==true)local currentHp=crystalHealth(loot)if currentHp and currentHp>0 then if lootHpMark==nil or currentHp<(lootHpMark-0.001)then lootHpMark=currentHp;lootLastHpChange=now end end;local hpStuck=(now-lootLastHpChange>12.0)and(now-lootStartTime>12.0)local maxTimeout=(now-lootStartTime>40.0)local cantFit=(crystalWeight(loot)>free)if not parented or collected or hpStuck or maxTimeout or cantFit then if(hpStuck or maxTimeout)and loot and parented then blacklistedLoot[loot]=now+20 end;loot=nil;lootHp=nil;lootMax=nil;lootHpMark=nil end end;if loot then local hp=crystalHealth(loot)if hp and(lootMax==nil or hp>lootMax)then lootMax=hp end;lootHp=hp end;if not loot and now-lootClock>=COLLECT_GAP then lootClock=now;loot,lootBlocked=findLoot(free,root.Position)if loot then lootStartTime=now;lootLastHpChange=now;lootHp=crystalHealth(loot)lootMax=lootHp;lootHpMark=lootHp end end;if loot and loot.Parent then local spot=loot.Position;holdAt(CFrame.new(spot+Vector3.new(0,COLLECT_LIFT,0),spot),spot)requestStream(spot)if canSwing then swingClock-=swingNeed;swing(spot)end;if now-grabClock>=GRAB_GAP then grabClock=now;grabCrystal(loot,crystalPrompt(loot))end;if lootHp and lootHp>0 then local ratio=0;if lootMax and lootMax>0 then ratio=math.clamp(1-lootHp/lootMax,0,1)end;statusText=string.format("挖掘 %s (%s) %d%%",crystalName(loot),formatShort(crystalValue(loot),"$"),math.floor(ratio*100))else statusText=string.format("收集 %s (%s)...",crystalName(loot),formatShort(crystalValue(loot),"$"))end;return end;local origin=farmOrigin(root)if target and now-surfaceClock>=SURFACE_GAP then surfaceClock=now;local spot=surfaceAt(target.X,target.Z)if not spot then target=nil;columnY=nil;columnDry=0;columnSwings=0 else if not columnY or spot.Y<columnY-0.05 then columnDry=0 else columnDry+=columnSwings end;columnSwings=0;columnY=spot.Y;target=spot;if columnDry>=COLUMN_DRY then blacklistedColumns[gridKey(target.X,target.Z)]=now+20;target=nil;columnY=nil;columnDry=0 end end end;if not target then local spot=pickTarget(origin,now)if not spot then spot=surfaceAt(origin.X,origin.Z)end;if not spot then requestStream(origin)if canSwing then swingClock-=swingNeed;swing(root.Position-Vector3.new(0,DIG_REACH*0.5,0))end;statusText="加载地形";return end;target=spot;columnY=spot.Y;columnDry=0;columnSwings=0;surfaceClock=now end;holdAt(CFrame.new(target+Vector3.new(0,DIG_LIFT,0),target),target)if canSwing then swingClock-=swingNeed;columnSwings+=1;swing(target)end;statusText=string.format("挖掘表面 %dm",math.floor(target.Y))end
 local function setActive(value)if not value then stop()return end;active=true;target=nil;columnY=nil;columnDry=0;columnSwings=0;surfaceClock=0;peakClock=0;scanIndex=0;scanUntil=0;loaded=false;loot=nil;lootClock=0;lootHp=nil;lootMax=nil;lootBlocked=false;lootStartTime=0;table.clear(blacklistedLoot)table.clear(blacklistedColumns)swingClock=0;equipClock=0;sellSpot=nil;sellUntil=0;heldPick=nil;statusText="启动中";Move.setFly(false)Move.setNoclip(true)Mountain.setAutoGrab(true)end
 -- 金钱农场 UI
 makeSectionLabel(page, "金钱农场 - 水晶自动农场 (加载山脉并按价值或幸运点挖掘水晶)")
 local mfToggle=makeToggle(page, "自动农场", setActive)
 ksRegToggle("moneyFarmActive",mfToggle,false,function(v) setActive(v) end)
 local flToggle=makeToggle(page, "专注幸运水晶", function(value) KS_Config.focusLuck=value; focusLuck=value; loot=nil end)
 ksRegToggle("focusLuck",flToggle,false,function(v) focusLuck=v; loot=nil end)
 local mlSlider=makeSlider(page, "最低幸运点", 1, 1000, 10, "", function(val) KS_Config.minLuckPoints=val; minLuckPoints=val; Config.MinLuckBoost=val; loot=nil end)
 ksRegSlider("minLuckPoints",mlSlider,10,function(v) minLuckPoints=v; Config.MinLuckBoost=v; loot=nil end)
 local plToggle=makeToggle(page, "自动在地块种植幸运水晶", function(value) KS_Config.autoPlantLuck=value; autoPlantLuck=value end)
 ksRegToggle("autoPlantLuck",plToggle,false,function(v) autoPlantLuck=v end)
 local asToggle=makeToggle(page, "50%时自动出售", function(value) KS_Config.autoSell=value; autoSell=value end)
 ksRegToggle("autoSell",asToggle,false,function(v) autoSell=v end)
 local StatusLabel=makeSectionLabel(page, "金钱农场状态: 空闲")
 local labelClock=0
 Connections.moneyConn=trackConnection(Services.RunService.Heartbeat:Connect(function(deltaTime)if active then local ok,err=pcall(step,deltaTime)if not ok then reportError("金钱农场",err)end end;labelClock+=deltaTime;if labelClock>=0.25 then labelClock=0;StatusLabel.Text="金钱农场状态: "..statusText end end))
 local function buyAllAvailableBombs()local query=Remotes.BombShopQuery;local buyReq=Remotes.BombBuyRequest;if not query or not buyReq then return 0 end;local ok,data=pcall(function()return query:InvokeServer()end)if not ok or not data or not data.stock then return 0 end;local boughtTotal=0;for bombId,amount in pairs(data.stock)do local count=tonumber(amount)or 0;if count>0 then for _=1,count do local success,res=pcall(function()return buyReq:InvokeServer(bombId)end)if success and res and res.ok then boughtTotal+=1 else break end end end end;return boughtTotal end
 if Remotes.BombShopRestocked then Connections.bombRestockConn=trackConnection(Remotes.BombShopRestocked.OnClientEvent:Connect(function()if State.autoBuyBombs then task.spawn(buyAllAvailableBombs)end end))end
 local bombCheckClock=0;Connections.bombLoopConn=trackConnection(Services.RunService.Heartbeat:Connect(function(deltaTime)if State.autoBuyBombs then bombCheckClock+=deltaTime;if bombCheckClock>=10.0 then bombCheckClock=0;task.spawn(buyAllAvailableBombs)end end end))
 -- 炸弹购买 UI
 makeSectionLabel(page, "炸弹购买 (商店有货时自动购买所有炸弹)")
 local abToggle=makeToggle(page, "补货时自动购买", function(value) KS_Config.autoBuyBombs=value; State.autoBuyBombs=value; if value then task.spawn(buyAllAvailableBombs) end end)
 ksRegToggle("autoBuyBombs",abToggle,false,function(v) State.autoBuyBombs=v; if v then task.spawn(buyAllAvailableBombs) end end)
 makeButton(page, "立即购买所有库存", function() task.spawn(function() local count=buyAllAvailableBombs(); showToast(string.format("从商店购买了 %d 个炸弹！",count)) end) end)
 Money.stop=stop end
 install()
end


-- 跳服 UI (移至开山页最后)
makeSectionLabel(page, "跳服")
makeButton(page, "跳服 (随机切换服务器)", function() if not Net.busy() then if not Net.hop() then showToast("跳服启动失败") end else showToast("跳服进行中...") end end)
makeButton(page, "重进当前服", function() Net.rejoin() end)
end -- if isKaishanGame

-- 清理函数 (保留原脚本自管理卸载逻辑)
local function cleanupAll()State.espActive=false;State.playerEspActive=false;State.aimTpEnabled=false;setSpeedBoost(false)finishTeleport()unwatchContainers()if Mountain.shutdown then Mountain.shutdown()end;if Move.shutdown then Move.shutdown()end;restoreInstantPrompts()table.clear(Storage.pendingActions)table.clear(Storage.promptRestores)table.clear(Storage.claimed)if Net.stop then Net.stop()end;for _,connection in ipairs(Storage.netConns)do if connection then connection:Disconnect()end end;table.clear(Storage.netConns)State.afkRunning=false;for _,connection in ipairs(Storage.afkConns)do if connection then connection:Disconnect()end end;table.clear(Storage.afkConns)if Farm and Farm.stop then Farm.stop()end;if Money and Money.stop then Money.stop()end;for key,connection in pairs(Connections)do if connection then connection:Disconnect()end end;table.clear(Connections)State.speedHooked=nil;clearRegistry()clearPlayerEsp()if EspHolder then EspHolder:Destroy()EspHolder=nil end;State.rootPart=nil;getgenv().UniverseLoaded=false;getgenv().UniverseUnload=nil end
getgenv().UniverseUnload=cleanupAll
end
-- 仅在「开采一座山」中初始化开山模块 (UniverseId: 10187294555)
local ksOk, ksErr = pcall(function()
  if not isKaishanGame then
    warn("[GSEN辅助] 当前游戏非开采一座山 (GameId="..tostring(game.GameId).."), 跳过开山模块")
    return
  end
  initKaishan()
end)
if not ksOk then
	warn("[GSEN辅助] 开山模块初始化失败: " .. tostring(ksErr))
end
--========================================================
-- 开山模块 (集成版) 结束
--========================================================

-- 将开山标签移动到设置标签前面 (交换两者的 LayoutOrder)
do
	local ksTab = Tabs["开山"]
	local setTab = Tabs["设置"]
	if ksTab and setTab then
		local ksOrder, setOrder = ksTab.order, setTab.order
		ksTab.button.LayoutOrder = setOrder
		setTab.button.LayoutOrder = ksOrder
		ksTab.order, setTab.order = setOrder, ksOrder
	end
end

-- 默认选中第一个标签 (透视)
for n, t in pairs(Tabs) do
	t.page.Visible = (n == "透视")
	t.button.BackgroundColor3 = (n == "透视") and Theme.Element or Theme.TabBtn
	t.button.TextColor3 = (n == "透视") and Theme.Text or Theme.SubText
end
-- 高亮框定位到第一个标签 (用实际位置)
local firstTab = Tabs["透视"]
if firstTab then
	local clipPos = TabClip.AbsolutePosition
	local btnPos = firstTab.button.AbsolutePosition
	local btnSize = firstTab.button.AbsoluteSize
	TabHighlight.Size = UDim2.fromOffset(btnSize.X, 32)
	TabHighlight.Position = UDim2.fromOffset(btnPos.X - clipPos.X, btnPos.Y - clipPos.Y)
	TabHighlight.Visible = true
	currentTabBtn = firstTab.button
end
currentPage = "透视"

--========================================================
-- 7. 最小化 / 关闭 逻辑
--========================================================
-- 最小化时弹出的展开按钮 (灵动岛风格, 固定屏幕顶部居中)
do
	ExpandButton = trackInstance(Instance.new("TextButton"))
	ExpandButton.Name = "DynamicIsland"
	-- 胶囊形状, 固定在屏幕顶部居中
	ExpandButton.Size = UDim2.fromOffset(220, 32)
	ExpandButton.AnchorPoint = Vector2.new(0.5, 0)
	ExpandButton.Position = UDim2.new(0.5, 0, 0, 8)
	ExpandButton.BackgroundColor3 = Color3.fromRGB(20, 20, 30)
	ExpandButton.Text = "GSEN"
	ExpandButton.TextColor3 = Theme.Text
	ExpandButton.Font = FontBold
	ExpandButton.TextSize = 13
	ExpandButton.TextXAlignment = Enum.TextXAlignment.Center
	ExpandButton.Visible = false
	ExpandButton.AutoButtonColor = false
	ExpandButton.BorderSizePixel = 0
	local c = trackInstance(Instance.new("UICorner"))
	c.CornerRadius = UDim.new(1, 0)
	c.Parent = ExpandButton
	local est = trackInstance(Instance.new("UIStroke"))
	est.Color = Theme.Accent
	est.Thickness = 1.5
	est.Transparency = 0.2
	est.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	est.Parent = ExpandButton
	ExpandButton.Parent = MainGui

	-- 灵动岛右侧时间显示 (UTC+8, 24小时制, 精确到秒)
	local TimeLabel = trackInstance(Instance.new("TextLabel"))
	TimeLabel.Name = "TimeLabel"
	TimeLabel.Size = UDim2.fromOffset(72, 18)
	TimeLabel.Position = UDim2.new(1, -80, 0.5, -9)
	TimeLabel.BackgroundTransparency = 1
	TimeLabel.Text = "--:--:--"
	TimeLabel.TextColor3 = Theme.SubText
	TimeLabel.Font = FontMain
	TimeLabel.TextSize = 12
	TimeLabel.TextXAlignment = Enum.TextXAlignment.Right
	TimeLabel.ZIndex = 2
	TimeLabel.Parent = ExpandButton
	IslandTimeLabel = TimeLabel

	-- 悬停: 变宽 + 颜色变亮
	trackConnection(ExpandButton.MouseEnter:Connect(function()
		TweenService:Create(ExpandButton, TweenInfo.new(0.2, Enum.EasingStyle.Quad), {
			Size = UDim2.fromOffset(240, 32),
			BackgroundColor3 = Color3.fromRGB(35, 35, 50),
		}):Play()
	end))
	trackConnection(ExpandButton.MouseLeave:Connect(function()
		TweenService:Create(ExpandButton, TweenInfo.new(0.2, Enum.EasingStyle.Quad), {
			Size = UDim2.fromOffset(220, 32),
			BackgroundColor3 = Color3.fromRGB(20, 20, 30),
		}):Play()
	end))
end

local minimized = false
-- 窗口正常状态的尺寸
local WIN_SIZE = UDim2.fromOffset(460, 330)
-- 灵动岛位置 (缩放中心)
local ISLAND_POS = UDim2.new(0.5, 0, 0, 8)
local ISLAND_ANCHOR = Vector2.new(0.5, 0)
-- 保存最小化前的窗口位置 (UDim2 用于拖拽, 绝对位置/大小 用于碎片动画)
local savedWindowPos = UDim2.new(0.5, -230, 0.5, -165)
local savedWindowAbsPos = Vector2.new(0, 0)
local savedWindowAbsSize = Vector2.new(460, 330)

-- 碎片容器 (挂在 OverlayGui 下, 始终在最上层)
local FragmentContainer = trackInstance(Instance.new("Frame"))
FragmentContainer.Name = "Fragments"
FragmentContainer.Size = UDim2.new(1, 0, 1, 0)
FragmentContainer.BackgroundTransparency = 1
FragmentContainer.BorderSizePixel = 0
FragmentContainer.Visible = false
FragmentContainer.ZIndex = 100
FragmentContainer.Parent = OverlayGui

-- 获取灵动岛在屏幕上的绝对中心位置
local function getIslandCenter()
	local vp = Camera.ViewportSize
	return Vector2.new(vp.X / 2, 8 + 16) -- 灵动岛 Y=8, 高度 32, 中心 Y=24
end

-- 碎片动画: 最小化 — 窗口碎裂飞向灵动岛
local function fragmentMinimize(winAbsPos, winAbsSize, onComplete)
	FragmentContainer.Visible = true
	local islandCenter = getIslandCenter()

	-- 碎片网格: 每块 20x20
	local fragSize = 20
	local cols = math.ceil(winAbsSize.X / fragSize)
	local rows = math.ceil(winAbsSize.Y / fragSize)
	local total = cols * rows
	local finished = 0

	for row = 0, rows - 1 do
		for col = 0, cols - 1 do
			local frag = Instance.new("Frame")
			frag.Size = UDim2.fromOffset(fragSize, fragSize)
			-- 起始位置: 窗口对应位置
			local startX = winAbsPos.X + col * fragSize
			local startY = winAbsPos.Y + row * fragSize
			frag.Position = UDim2.fromOffset(startX, startY)
			frag.BackgroundColor3 = Theme.Window
			frag.BorderSizePixel = 0
			local c = Instance.new("UICorner")
			c.CornerRadius = UDim.new(0, 3)
			c.Parent = frag
			frag.ZIndex = 100
			frag.Parent = FragmentContainer

			-- 随机延迟 + 飞向灵动岛
			local delay = math.random() * 0.15
			local duration = 0.3 + math.random() * 0.2
			local offsetX = (math.random() - 0.5) * 60
			local offsetY = (math.random() - 0.5) * 40

			task.delay(delay, function()
				TweenService:Create(frag, TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
					Position = UDim2.fromOffset(islandCenter.X + offsetX, islandCenter.Y + offsetY),
					Size = UDim2.fromOffset(2, 2),
					BackgroundTransparency = 1,
					Rotation = math.random(-180, 180),
				}):Play()
				task.delay(duration, function()
					frag:Destroy()
					finished = finished + 1
					if finished >= total and onComplete then
						onComplete()
					end
				end)
			end)
		end
	end
end

-- 碎片动画: 展开 — 碎片从灵动岛涌出拼成窗口
local function fragmentExpand(winAbsPos, winAbsSize, onComplete)
	FragmentContainer.Visible = true
	local islandCenter = getIslandCenter()

	local fragSize = 20
	local cols = math.ceil(winAbsSize.X / fragSize)
	local rows = math.ceil(winAbsSize.Y / fragSize)
	local total = cols * rows
	local finished = 0

	for row = 0, rows - 1 do
		for col = 0, cols - 1 do
			local frag = Instance.new("Frame")
			frag.Size = UDim2.fromOffset(2, 2)
			-- 起始位置: 灵动岛中心 + 随机偏移
			local offsetX = (math.random() - 0.5) * 60
			local offsetY = (math.random() - 0.5) * 40
			frag.Position = UDim2.fromOffset(islandCenter.X + offsetX, islandCenter.Y + offsetY)
			frag.BackgroundColor3 = Theme.Window
			frag.BorderSizePixel = 0
			local c = Instance.new("UICorner")
			c.CornerRadius = UDim.new(0, 3)
			c.Parent = frag
			frag.ZIndex = 100
			frag.Parent = FragmentContainer

			-- 目标位置: 窗口对应位置
			local targetX = winAbsPos.X + col * fragSize
			local targetY = winAbsPos.Y + row * fragSize
			local delay = math.random() * 0.2
			local duration = 0.3 + math.random() * 0.2

			task.delay(delay, function()
				frag.BackgroundTransparency = 0
				TweenService:Create(frag, TweenInfo.new(duration, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
					Position = UDim2.fromOffset(targetX, targetY),
					Size = UDim2.fromOffset(fragSize, fragSize),
					Rotation = 0,
				}):Play()
				task.delay(duration, function()
					finished = finished + 1
					if finished >= total then
						-- 碎片到位后: 窗口淡入 + 碎片淡出, 平滑过渡
						Window.Visible = true
						-- 收集窗口及其子元素 (标题栏、侧边栏、内容区等)
						local fadeGroup = { Window }
						for _, child in ipairs(Window:GetChildren()) do
							if child:IsA("GuiObject") then
								table.insert(fadeGroup, child)
							end
						end
						-- 记录原始透明度, 设为全透明
						local origTransparency = {}
						for i, obj in ipairs(fadeGroup) do
							origTransparency[i] = obj.BackgroundTransparency
							obj.BackgroundTransparency = 1
						end
						-- 同时启动窗口淡入和碎片淡出
						for i, obj in ipairs(fadeGroup) do
							TweenService:Create(obj, TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
								BackgroundTransparency = origTransparency[i],
							}):Play()
						end
						for _, child in ipairs(FragmentContainer:GetChildren()) do
							if child:IsA("Frame") then
								TweenService:Create(child, TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
									BackgroundTransparency = 1,
								}):Play()
							end
						end
						-- 过渡完成后清理碎片
						task.delay(0.25, function()
							FragmentContainer.Visible = false
							for _, child in ipairs(FragmentContainer:GetChildren()) do
								child:Destroy()
							end
							if onComplete then onComplete() end
						end)
					end
				end)
			end)
		end
	end
end

-- 递归收集 Window 下所有 GuiObject 后代
local function collectAllDescendants(root)
	local list = {}
	local function recurse(parent)
		for _, child in ipairs(parent:GetChildren()) do
			if child:IsA("GuiObject") then
				table.insert(list, child)
			end
			recurse(child)
		end
	end
	recurse(root)
	return list
end

-- 保存所有后代的原始透明度 (最小化前调用, 展开时恢复)
local savedTransparency = {}

-- 平滑动画: 最小化 — 窗口上移 + 缩小 + 淡出
local function smoothMinimize(onComplete)
	-- 保存当前位置 (setMinimized 已保存 savedWindowPos)
	-- 窗口向上滑出并淡出
	Window.Visible = true
	local origPos = Window.Position

	-- 递归收集所有后代并保存原始透明度
	savedTransparency = {}
	local fadeGroup = collectAllDescendants(Window)
	for _, obj in ipairs(fadeGroup) do
		savedTransparency[obj] = obj.BackgroundTransparency
	end

	local tween = TweenService:Create(Window, TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
		Position = UDim2.new(origPos.X.Scale, origPos.X.Offset, 0, -Window.AbsoluteSize.Y - 20),
	})
	tween:Play()
	-- 同时淡出所有后代元素
	for _, obj in ipairs(fadeGroup) do
		TweenService:Create(obj, TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
			BackgroundTransparency = 1,
		}):Play()
	end
	tween.Completed:Connect(function()
		Window.Visible = false
		Window.Position = origPos -- 恢复位置, 供下次展开
		if onComplete then onComplete() end
	end)
end

-- 平滑动画: 展开 — 窗口从下方滑入 + 淡入
local function smoothExpand(onComplete)
	-- 从屏幕底部下方滑入
	local origPos = Window.Position
	Window.Position = UDim2.new(origPos.X.Scale, origPos.X.Offset, 1, 40)
	Window.Visible = true

	-- 递归收集所有后代, 恢复保存的原始透明度
	local fadeGroup = collectAllDescendants(Window)
	for _, obj in ipairs(fadeGroup) do
		local origT = savedTransparency[obj]
		if origT == nil then origT = 0 end
		obj.BackgroundTransparency = 1
		TweenService:Create(obj, TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			BackgroundTransparency = origT,
		}):Play()
	end

	local tween = TweenService:Create(Window, TweenInfo.new(0.4, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
		Position = origPos,
	})
	tween:Play()
	tween.Completed:Connect(function()
		savedTransparency = {}
		if onComplete then onComplete() end
	end)
end

local function setMinimized(on)
	minimized = on
	if on then
		-- 保存当前窗口绝对位置和大小 (碎片动画用绝对坐标, 避免平台差异)
		savedWindowPos = Window.Position
		savedWindowAbsPos = Window.AbsolutePosition
		savedWindowAbsSize = Window.AbsoluteSize

		if State.animMode == "平滑" then
			-- 平滑模式: 窗口上移淡出
			smoothMinimize(function()
				-- 灵动岛弹出
				ExpandButton.Visible = true
				ExpandButton.Size = UDim2.fromOffset(40, 8)
				ExpandButton.BackgroundTransparency = 1
				TweenService:Create(ExpandButton, TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
					Size = UDim2.fromOffset(220, 32),
					BackgroundTransparency = 0,
				}):Play()
			end)
		else
			-- 碎片模式: 立即隐藏窗口, 开始碎片飞散
			Window.Visible = false

			-- 碎片从窗口位置飞向灵动岛
			fragmentMinimize(savedWindowAbsPos, savedWindowAbsSize, function()
				FragmentContainer.Visible = false
			end)

			-- 灵动岛: 从小到大弹出 (延迟一点等碎片开始汇集)
			task.delay(0.2, function()
				ExpandButton.Visible = true
				ExpandButton.Size = UDim2.fromOffset(40, 8)
				ExpandButton.BackgroundTransparency = 1
				TweenService:Create(ExpandButton, TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
					Size = UDim2.fromOffset(220, 32),
					BackgroundTransparency = 0,
				}):Play()
			end)
		end

	else
		-- 灵动岛: 缩小 + 淡出
		local islandTween = TweenService:Create(ExpandButton, TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
			Size = UDim2.fromOffset(40, 8),
			BackgroundTransparency = 1,
		})
		islandTween:Play()
		islandTween.Completed:Connect(function()
			ExpandButton.Visible = false
			ExpandButton.Size = UDim2.fromOffset(220, 32)
			ExpandButton.BackgroundTransparency = 0

			if State.animMode == "平滑" then
				-- 平滑模式: 窗口从下方滑入
				smoothExpand()
			else
				-- 碎片模式: 使用保存的绝对位置作为碎片目标, Y 向下偏移 55px 补偿偏差
				local winAbsPos = Vector2.new(savedWindowAbsPos.X, savedWindowAbsPos.Y + 55)
				local winAbsSize = savedWindowAbsSize

				-- 碎片从灵动岛涌出, 直接飞往缩小前的位置拼成窗口
				fragmentExpand(winAbsPos, winAbsSize, function()
					-- Window.Position 从未修改, 直接显示即可, 避免位置漂移
					Window.Visible = true
				end)
			end
		end)
	end
end

trackConnection(MinimizeBtn.MouseButton1Click:Connect(function() setMinimized(true) end))
trackConnection(ExpandButton.MouseButton1Click:Connect(function() setMinimized(false) end))

-- 关闭确认窗口: 点击右上角 X 后先确认, 确定后再执行原来的关闭清理流程
local function showCloseConfirm()
	-- 防止重复弹出多个确认窗口
	local oldConfirm = MainGui:FindFirstChild("CloseConfirmPanel")
	if oldConfirm then
		oldConfirm:Destroy()
	end

	local confirmPanel = trackInstance(Instance.new("Frame"))
	confirmPanel.Name = "CloseConfirmPanel"
	confirmPanel.Size = UDim2.fromOffset(260, 140)
	confirmPanel.Position = UDim2.new(0.5, -130, 0.5, -70)
	confirmPanel.BackgroundColor3 = Theme.Window
	confirmPanel.BorderSizePixel = 0
	confirmPanel.Active = true
	confirmPanel.ZIndex = 120
	local cpCorner = trackInstance(Instance.new("UICorner"))
	cpCorner.CornerRadius = UDim.new(0, 10)
	cpCorner.Parent = confirmPanel
	local cpStroke = trackInstance(Instance.new("UIStroke"))
	cpStroke.Color = Theme.Accent
	cpStroke.Thickness = 1
	cpStroke.Transparency = 0.15
	cpStroke.Parent = confirmPanel
	confirmPanel.Parent = MainGui

	local title = trackInstance(Instance.new("TextLabel"))
	title.Size = UDim2.new(1, -24, 0, 34)
	title.Position = UDim2.fromOffset(12, 8)
	title.BackgroundTransparency = 1
	title.Text = "确认关闭"
	title.TextColor3 = Theme.Text
	title.Font = FontBold
	title.TextSize = 15
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.ZIndex = 121
	title.Parent = confirmPanel

	local message = trackInstance(Instance.new("TextLabel"))
	message.Size = UDim2.new(1, -24, 0, 44)
	message.Position = UDim2.fromOffset(12, 42)
	message.BackgroundTransparency = 1
	message.Text = "确定要关闭 GSEN 辅助吗？\n确定后会重置全部功能并销毁窗口。"
	message.TextColor3 = Theme.SubText
	message.Font = FontMain
	message.TextSize = 12
	message.TextWrapped = true
	message.TextXAlignment = Enum.TextXAlignment.Left
	message.TextYAlignment = Enum.TextYAlignment.Top
	message.ZIndex = 121
	message.Parent = confirmPanel

	local function makeConfirmButton(text, x, color, hoverColor, callback)
		local btn = trackInstance(Instance.new("TextButton"))
		btn.Size = UDim2.fromOffset(108, 30)
		btn.Position = UDim2.fromOffset(x, 98)
		btn.BackgroundColor3 = color
		btn.BorderSizePixel = 0
		btn.Text = text
		btn.TextColor3 = Theme.Text
		btn.Font = FontBold
		btn.TextSize = 13
		btn.AutoButtonColor = false
		btn.ZIndex = 121
		local bc = trackInstance(Instance.new("UICorner"))
		bc.CornerRadius = UDim.new(0, 6)
		bc.Parent = btn
		trackConnection(btn.MouseEnter:Connect(function() btn.BackgroundColor3 = hoverColor end))
		trackConnection(btn.MouseLeave:Connect(function() btn.BackgroundColor3 = color end))
		trackConnection(btn.MouseButton1Click:Connect(callback))
		btn.Parent = confirmPanel
		return btn
	end

	makeConfirmButton("取消", 12, Theme.Element, Theme.Hover, function()
		if confirmPanel and confirmPanel.Parent then
			confirmPanel:Destroy()
		end
	end)

	makeConfirmButton("确定关闭", 140, Theme.AccentDark, Theme.Accent, function()
		if confirmPanel and confirmPanel.Parent then
			confirmPanel:Destroy()
		end
		ResetAndDestroy()
	end)
end

-- 关闭 = 重置全部功能并销毁
ResetAndDestroy = function()
	-- 关闭所有开关
	State.espEnabled = false
	State.boxEnabled = false
	State.antennaEnabled = false
	State.nameEnabled = false
	State.nickEnabled = false
	State.aimEnabled = false

	-- 关闭飞行
	if State.flyEnabled then setFly(false) end
	-- 关闭穿墙
	if State.noclipEnabled then setNoclip(false) end
	-- 关闭甩飞
	if State.flingEnabled then setFling(false) end
	-- 关闭环绕
	if State.orbitEnabled then setOrbit(false) end
	-- 关闭自旋
	if State.spinEnabled then setSpin(false) end
	-- 关闭循环传送
	if State.loopTpEnabled then setLoopTp(false) end
	if State.loopTpAllEnabled then setLoopTpAll(false) end
	-- 关闭秒交互
	if State.promptInstantEnabled then setInstantPrompt(false) end
	-- 关闭聊天翻译
	if State.chatTranslateEnabled then setChatTranslation(false) end
	-- 关闭隐身
	if State.invisibleEnabled then setInvisible(false) end
	-- 关闭锁定血量
	if State.godHealthEnabled then setGodHealth(false) end
	-- 关闭音乐
	pcall(function()
		if MusicState and MusicState.currentSound then
			MusicState.currentSound:Stop()
			MusicState.currentSound:Destroy()
			MusicState.currentSound = nil
		end
	end)
	-- 关闭移速开关 (恢复默认移速, 但保留已调节的参数值)
	State.speedEnabled = false
	applyWalkSpeed()

	-- 解除渲染绑定 (它不在 connections 里, 需单独解绑)
	pcall(function() RunService:UnbindFromRenderStep("GSEN_Update") end)

	-- 清理所有 ESP
	for p in pairs(Runtime.espObjects) do clearEspFor(p) end

	-- 断开所有连接
	for _, conn in ipairs(Runtime.connections) do
		if conn and conn.Connected then conn:Disconnect() end
	end
	Runtime.connections = {}

	-- 销毁 GUI 实例
	for _, inst in ipairs(Runtime.instances) do
		if inst and inst.Parent then inst:Destroy() end
	end
	Runtime.instances = {}
end
trackConnection(CloseBtn.MouseButton1Click:Connect(function() showCloseConfirm() end))

--========================================================
-- 8. 菜单显隐切换键 (右 Ctrl)
--========================================================
trackConnection(UserInputService.InputBegan:Connect(function(input, gpe)
	if gpe then return end
	if input.KeyCode == Enum.KeyCode.RightControl then
		if minimized then
			setMinimized(false)
		else
			setMinimized(true)
		end
	end
end))

-- 初始化
CountLabel.Visible = false
applyWalkSpeed()
print("[GSEN辅助 V150] 已加载 — 右 Ctrl 切换菜单 | 概率锁头 | 酷狗 + 网易云(VIP) | 音乐缓存清理 | 开山模块集成(⛰️ESP/农场/拾取/跳服) | 水晶品质+重量+幸运过滤(ESP+拾取) | 重量单位改为t | 开山配置持久化 | IIFE隔离局部变量 | 高亮框跟随滚动裁切 | Sidebar圆角去描边 | 开山标签移至设置上方 | 幸运值多源解析 | 全品质过滤(9档) | 深度调试日志 | 删除配置二次确认弹窗 | 跳服移至开山页末尾 | initKaishan异常保护 | 聊天翻译支持Global频道 | Remotes文件夹查找缓存(其他游戏快速初始化) | UniverseId条件加载(非开采一座山跳过开山模块) | 幸运值=基础幸运×变异倍率(方法1-5全部乘变异倍率) | 修复金钱农场/巨石农场人物无法移动(滑翔AlignOrientation属性错误ReactionForceEnabled→ReactionTorqueEnabled) | 重复执行脚本时清理旧GUI(防旧实例残留导致修改不生效) | 删除重复拖拽缩放代码 | 右下角缩放把手:纯空心圆角正方形(UIStroke白色半透明1.2px描边,圆角6px,32×32) | 缩放把手正方形改为溢出窗口显示(handle挂到MainGui,不受Window.ClipsDescendants裁切,监听Window的Size/Position变化实时跟随窗口右下角) | 缩放把手可见性跟随悬浮窗(handle挂到MainGui后不受Window.Visible传播,监听GetPropertyChangedSignal事件隐藏菜单时正方形同步隐藏) | 修复V149版本号print字符串内嵌英文双引号导致的编译期语法错误(无报错但脚本全部不执行)")
