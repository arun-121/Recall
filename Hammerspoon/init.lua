-- Recall — optional Hammerspoon integration
--
-- Hammerspoon is OPTIONAL. Recall works fully as a normal macOS app without it.
-- This snippet registers a global hotkey that launches Recall if it isn't
-- running, or focuses it if it is — giving you a Spotlight-style summon.
--
-- Setup:
--   1. Install Hammerspoon:  https://www.hammerspoon.org  (or `brew install --cask hammerspoon`)
--   2. Copy the block below into ~/.hammerspoon/init.lua
--      (or `require` this file from your init.lua)
--   3. Adjust APP_PATH if you installed Recall somewhere other than /Applications.
--   4. Reload Hammerspoon's config (menu bar icon > Reload Config).
--
-- Default hotkey: Cmd + Alt + Space.

local APP_NAME = "Recall"
-- If you ran Scripts/build_app.sh, point this at the built bundle, e.g.
-- local APP_PATH = os.getenv("HOME") .. "/Desktop/Recall/dist/Recall.app"
local APP_PATH = "/Applications/Recall.app"

local function toggleRecall()
    local app = hs.application.get(APP_NAME)
    if app and app:isFrontmost() then
        -- Already focused: hide it so the hotkey acts as a toggle.
        app:hide()
    elseif app then
        -- Running but not focused: bring it forward.
        app:activate(true)
        app:unhide()
    else
        -- Not running: launch it. Prefer the explicit path, fall back to name.
        if not hs.application.launchOrFocus(APP_PATH) then
            hs.application.launchOrFocus(APP_NAME)
        end
    end
end

-- Cmd + Alt + Space
hs.hotkey.bind({ "cmd", "alt" }, "space", toggleRecall)

hs.alert.show("Recall hotkey ready: Cmd+Alt+Space")
