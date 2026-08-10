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
	-- 自瞄
	aimEnabled  = false,
	aimMode     = "FOV",   -- FOV / 180 / 360
	aimFov      = 120,
	aimSmooth   = 0.30,
	aimPart     = "Body",
	aimDistance = 500,
	wallCheck   = true,
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
local setFly, setNoclip, ResetAndDestroy

--========================================================
-- 1. WindUI 风格 GUI 框架
--========================================================
local Theme = {
	Background = Color3.fromRGB(24, 24, 37),
	Window     = Color3.fromRGB(30, 30, 46),
	TabBar     = Color3.fromRGB(17, 17, 27),
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
end

--========================================================
-- 5.5 飞行控制悬浮窗
--========================================================
local FlyPanel       -- 面板根
local FlyPanelToggle -- 面板内的飞行开关引用
local FlySpeedInput  -- 飞行速度输入框
local toggleFlyPanel

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
Sidebar.Size = UDim2.fromOffset(120, 1)
Sidebar.Position = UDim2.fromOffset(0, 38)
Sidebar.BackgroundColor3 = Theme.TabBar
Sidebar.BorderSizePixel = 0
Sidebar.Parent = Window

local sideStroke = trackInstance(Instance.new("UIStroke"))
sideStroke.Color = Theme.Stroke
sideStroke.Thickness = 1
sideStroke.Transparency = 0.5
sideStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
sideStroke.Parent = Sidebar

local TabList = trackInstance(Instance.new("Frame"))
TabList.Size = UDim2.new(1, -16, 1, -55)
TabList.Position = UDim2.fromOffset(8, 60)
TabList.BackgroundTransparency = 1
TabList.Parent = Sidebar

local tabLayout = trackInstance(Instance.new("UIListLayout"))
tabLayout.FillDirection = Enum.FillDirection.Vertical
tabLayout.SortOrder = Enum.SortOrder.LayoutOrder
tabLayout.Padding = UDim.new(0, 6)
tabLayout.Parent = TabList

-- 共享高亮选中框 (挂在 Sidebar 下, 避开 TabList 的 UIListLayout 自动排列)
local TabHighlight = trackInstance(Instance.new("Frame"))
TabHighlight.Name = "TabHighlight"
TabHighlight.Size = UDim2.new(1, -16, 0, 32)
TabHighlight.Position = UDim2.fromOffset(8, 60)
TabHighlight.BackgroundColor3 = Theme.Element
TabHighlight.BackgroundTransparency = 1
TabHighlight.BorderSizePixel = 0
TabHighlight.Visible = false
TabHighlight.ZIndex = 10
local thc = trackInstance(Instance.new("UICorner"))
thc.CornerRadius = UDim.new(0, 6)
thc.Parent = TabHighlight
local ths = trackInstance(Instance.new("UIStroke"))
ths.Color = Theme.Accent
ths.Thickness = 1.5
ths.Transparency = 0.3
ths.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
ths.Parent = TabHighlight
TabHighlight.Parent = Sidebar

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
	btn.Size = UDim2.new(1, 0, 0, 32)
	btn.BackgroundColor3 = Theme.TabBar
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
			TweenService:Create(btn, TweenInfo.new(0.15), { BackgroundColor3 = Theme.TabBar }):Play()
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
				BackgroundColor3 = Theme.TabBar,
				TextColor3 = Theme.SubText,
			}):Play()
		end

		-- 新标签背景变亮
		TweenService:Create(newTab.button, TweenInfo.new(0.2, Enum.EasingStyle.Quad), {
			BackgroundColor3 = Theme.Element,
			TextColor3 = Theme.Text,
		}):Play()

		-- 高亮框: 从旧位置放大 → 移动到新位置 → 缩小回原尺寸
		-- 从标签按钮的实际绝对位置计算, 避免硬编码偏差
		local sidePos = Sidebar.AbsolutePosition
		local newBtnPos = newTab.button.AbsolutePosition
		local newY = newBtnPos.Y - sidePos.Y
		local oldY = newY
		if oldTab then
			local oldBtnPos = oldTab.button.AbsolutePosition
			oldY = oldBtnPos.Y - sidePos.Y
		end
		local newX = newBtnPos.X - sidePos.X
		local newW = newTab.button.AbsoluteSize.X
		local oldX = newX
		local oldW = newW
		if oldTab then
			oldX = oldTab.button.AbsolutePosition.X - sidePos.X
			oldW = oldTab.button.AbsoluteSize.X
		end

		if not TabHighlight.Visible then
			-- 首次显示
			TabHighlight.Size = UDim2.fromOffset(newW, 32)
			TabHighlight.Position = UDim2.fromOffset(newX, newY)
			TabHighlight.Visible = true
		else
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

			-- 0.27秒后缩小回正常尺寸 (和标签一样大)
			task.delay(0.27, function()
				TweenService:Create(TabHighlight, TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
					Size = UDim2.fromOffset(newW, 32),
					Position = UDim2.fromOffset(newX, newY),
				}):Play()
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
local function makeToggle(parent, text, callback, height)
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
	return {container = container, set = set}
end

-- 滑条
local function makeSlider(parent, text, min, max, default, suffix, callback)
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
	trackConnection(UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then dragging = false end
	end))
	trackConnection(UserInputService.InputChanged:Connect(function(input)
		if dragging and input.UserInputType == Enum.UserInputType.MouseMovement then
			update(input.Position.X)
		end
	end))

	container.Parent = parent
	setValue(default)
	return {container = container, setValue = setValue}
end

-- 下拉框 (列表挂载到 Content 层, 不受 page.ClipsDescendants 裁切)
local function makeDropdown(parent, text, options, default, callback)
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

	-- 列表挂到 Content 层, 绕过 page 的 ClipsDescendants
	local MAX_LIST_HEIGHT = 140
	local listHeight = math.min(#options * 28, MAX_LIST_HEIGHT)
	local list = trackInstance(Instance.new("ScrollingFrame"))
	list.Size = UDim2.new(0, 0, 0, listHeight)
	list.BackgroundColor3 = Theme.Element
	list.BorderSizePixel = 0
	list.Visible = false
	list.ZIndex = 20
	list.ScrollBarThickness = 4
	list.ScrollBarImageColor3 = Theme.Stroke
	list.CanvasSize = UDim2.new(0, 0, 0, #options * 28)
	list.AutomaticCanvasSize = Enum.AutomaticSize.Y
	list.ClipsDescendants = true
	list.Parent = Content

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

	-- 创建选项按钮的通用函数
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
		b.ZIndex = 21
		trackConnection(b.MouseEnter:Connect(function() b.BackgroundColor3 = Theme.Hover end))
		trackConnection(b.MouseLeave:Connect(function() b.BackgroundColor3 = Theme.Element end))
		trackConnection(b.MouseButton1Click:Connect(function()
			valLbl.Text = opt
			closeList()
			task.spawn(callback, opt)
		end))
		b.Parent = list
	end

	-- ---- 开关列表 ----
	local renderConn = nil

	local function closeList()
		list.Visible = false
		container.ZIndex = 1
		if renderConn then
			renderConn:Disconnect()
			renderConn = nil
		end
	end

	local function openList()
		list.Visible = true
		container.ZIndex = 10
		if renderConn then renderConn:Disconnect() end
		renderConn = RunService.RenderStepped:Connect(function()
			-- pcall 防止实例被销毁后报错
			local ok = pcall(function()
				if not list.Visible then return end
				local cPos  = container.AbsolutePosition
				local cSize = container.AbsoluteSize
				local dPos  = Content.AbsolutePosition
				list.Position = UDim2.fromOffset(
					cPos.X - dPos.X + 6,
					cPos.Y - dPos.Y + 38
				)
				list.Size = UDim2.new(0, cSize.X - 12, 0, listHeight)
			end)
			if not ok and renderConn then
				renderConn:Disconnect()
				renderConn = nil
			end
		end)
		trackConnection(renderConn)
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

	-- 点击列表外部关闭
	trackConnection(UserInputService.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 and list.Visible then
			local mp   = input.Position
			local cPos = container.AbsolutePosition
			local cSz  = container.AbsoluteSize
			local lPos = list.AbsolutePosition
			local lSz  = list.AbsoluteSize
			local inContainer = mp.X >= cPos.X and mp.X <= cPos.X + cSz.X
				and mp.Y >= cPos.Y and mp.Y <= cPos.Y + cSz.Y
			local inList = mp.X >= lPos.X and mp.X <= lPos.X + lSz.X
				and mp.Y >= lPos.Y and mp.Y <= lPos.Y + lSz.Y
			if not inContainer and not inList then
				closeList()
			end
		end
	end))

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
	return {container = container, refresh = refresh, valLbl = valLbl}
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
	CountLabel.Size = UDim2.fromOffset(180, 28)
	CountLabel.Position = UDim2.fromOffset(16, 16)
	CountLabel.BackgroundColor3 = Theme.Window
	CountLabel.BackgroundTransparency = 0.2
	CountLabel.TextColor3 = Theme.Text
	CountLabel.Font = FontBold
	CountLabel.TextSize = 13
	CountLabel.Text = "Players: 0"
	CountLabel.Parent = OverlayGui
	local cc = trackInstance(Instance.new("UICorner"))
	cc.CornerRadius = UDim.new(0, 6)
	cc.Parent = CountLabel
	local s = trackInstance(Instance.new("UIStroke"))
	s.Color = Theme.Stroke
	s.Parent = CountLabel
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
end))

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
local function updateAim()
	if not State.aimEnabled then return end
	local target = getAimTarget()
	if not target then return end
	local camPos = Camera.CFrame.Position
	local aimCFrame = CFrame.new(camPos, target.Position)
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
	makeToggle(page, "ESP 高亮透视", function(v) State.espEnabled = v; rebuildEsp() end)
	makeToggle(page, "骨骼透视", function(v) State.skeletonEnabled = v; rebuildEsp() end)
	makeToggle(page, "玩家方框", function(v) State.boxEnabled = v; rebuildEsp() end)
	makeToggle(page, "天线透视", function(v) State.antennaEnabled = v; rebuildEsp() end)
	makeToggle(page, "玩家用户名", function(v) State.nameEnabled = v; rebuildEsp() end)
	makeToggle(page, "玩家昵称", function(v) State.nickEnabled = v; rebuildEsp() end)
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
	end)
	makeSlider(page, "移速", 16, 10000, 16, "", function(v)
		State.walkSpeed = v
		if State.speedEnabled then applyWalkSpeed() end
	end)
	makeSectionLabel(page, "飞行模式")
	makeToggle(page, "飞行开关", function(v)
		if v then
			toggleFlyPanel(true)
		else
			toggleFlyPanel(false)
		end
	end)
	makeSectionLabel(page, "穿墙")
	makeToggle(page, "穿墙 (Noclip)", function(v) setNoclip(v) end)
	makeSectionLabel(page, "传送")
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
	local tpDropdown = makeDropdown(page, "传送目标", getPlayerList(), "(选择玩家)", function(opt)
		teleportTarget = opt
	end)
	makeButton(page, "刷新玩家列表", function()
		local newList = getPlayerList()
		tpDropdown.refresh(newList)
		tpDropdown.valLbl.Text = "(选择玩家)"
		teleportTarget = nil
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
end

-- 战斗页
do
	local page = addTab("战斗", "🎯")
	makeSectionLabel(page, "自瞄辅助")
	makeToggle(page, "自瞄开关", function(v) State.aimEnabled = v end)
	makeDropdown(page, "自瞄模式", {"FOV圈", "180°", "360°"}, "FOV圈", function(opt)
		local modeMap = {["FOV圈"] = "FOV", ["180°"] = "180", ["360°"] = "360"}
		State.aimMode = modeMap[opt] or "FOV"
	end)
	makeSlider(page, "FOV 圈大小", 30, 400, 120, "px", function(v) State.aimFov = v end)
	makeSlider(page, "自瞄平滑度", 0.05, 1, 0.30, "", function(v) State.aimSmooth = v end)
	makeSlider(page, "自瞄距离", 50, 10000, 500, "", function(v) State.aimDistance = v end)
	makeDropdown(page, "自瞄部位", {"头部 Head", "身体 Body"}, "身体 Body", function(opt)
		local partMap = {["头部 Head"] = "Head", ["身体 Body"] = "Body"}
		State.aimPart = partMap[opt] or "Body"
	end)
	makeToggle(page, "墙体检测", function(v) State.wallCheck = v end)
	makeToggle(page, "队伍检测", function(v) State.teamCheck = v end)
	makeToggle(page, "活体检测", function(v) State.aliveCheck = v end)
end

-- 设置页
do
	local page = addTab("设置", "⚙")
	makeSectionLabel(page, "菜单")
	makeButton(page, "全部重置并关闭", function()
		ResetAndDestroy()
	end)
	makeSectionLabel(page, "说明")
	local info = trackInstance(Instance.new("TextLabel"))
	info.Size = UDim2.new(1, 0, 0, 80)
	info.BackgroundTransparency = 1
	info.Text = "右 Ctrl 切换菜单显隐\n关闭 = 重置全部功能并销毁窗口\n最小化 = 隐藏窗口并显示展开按钮"
	info.TextColor3 = Theme.SubText
	info.Font = FontMain
	info.TextSize = 12
	info.TextWrapped = true
	info.TextXAlignment = Enum.TextXAlignment.Left
	info.TextYAlignment = Enum.TextYAlignment.Top
	info.Parent = page
end

-- 默认选中第一个标签 (透视)
for n, t in pairs(Tabs) do
	t.page.Visible = (n == "透视")
	t.button.BackgroundColor3 = (n == "透视") and Theme.Element or Theme.TabBar
	t.button.TextColor3 = (n == "透视") and Theme.Text or Theme.SubText
end
-- 高亮框定位到第一个标签 (用实际位置)
local firstTab = Tabs["透视"]
if firstTab then
	local sidePos = Sidebar.AbsolutePosition
	local btnPos = firstTab.button.AbsolutePosition
	local btnSize = firstTab.button.AbsoluteSize
	TabHighlight.Size = UDim2.fromOffset(btnSize.X, 32)
	TabHighlight.Position = UDim2.fromOffset(btnPos.X - sidePos.X, btnPos.Y - sidePos.Y)
	TabHighlight.Visible = true
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

local function setMinimized(on)
	minimized = on
	if on then
		-- 保存当前窗口绝对位置和大小 (碎片动画用绝对坐标, 避免平台差异)
		savedWindowPos = Window.Position
		savedWindowAbsPos = Window.AbsolutePosition
		savedWindowAbsSize = Window.AbsoluteSize

		-- 立即隐藏窗口, 开始碎片飞散
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

			-- 使用保存的绝对位置作为碎片目标, Y 向下偏移 55px 补偿偏差
			local winAbsPos = Vector2.new(savedWindowAbsPos.X, savedWindowAbsPos.Y + 55)
			local winAbsSize = savedWindowAbsSize

			-- 碎片从灵动岛涌出, 直接飞往缩小前的位置拼成窗口
			fragmentExpand(winAbsPos, winAbsSize, function()
				-- Window.Position 从未修改, 直接显示即可, 避免位置漂移
				Window.Visible = true
			end)
		end)
	end
end

trackConnection(MinimizeBtn.MouseButton1Click:Connect(function() setMinimized(true) end))
trackConnection(ExpandButton.MouseButton1Click:Connect(function() setMinimized(false) end))

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
trackConnection(CloseBtn.MouseButton1Click:Connect(function() ResetAndDestroy() end))

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
print("[GSEN辅助] 已加载 — 右 Ctrl 切换菜单")
