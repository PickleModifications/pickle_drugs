-- screenshot-basic bridge (pichotm/Koil) — the de-facto standard.
-- https://github.com/citizenfx/screenshot-basic
if GetResourceState('screenshot-basic') ~= 'started' then return end

function CaptureScreenshot(cb)
    exports['screenshot-basic']:requestScreenshot(function(data)
        cb(data)
    end)
end
