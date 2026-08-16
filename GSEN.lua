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
		local ok, err = deleteConfig(selectedConfig)
		if ok then
			showToast("✓ 配置已删除\n名称: " .. selectedConfig)
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
print("[GSEN辅助 V103] 已加载 — 右 Ctrl 切换菜单 | 概率锁头(目标切换时检测) | 酷狗(30首) + 网易云(100首,VIP标记) | 音乐缓存清理 | 高亮框跟随滚动裁切 | Sidebar圆角去描边")
