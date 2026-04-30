-- FiveManage screenshot bridge — uploads to fivemanage.com and returns base64
-- (screenshot-basic compatible API).
-- https://fivemanage.com
if GetResourceState('fivemanage') ~= 'started' then return end

function CaptureScreenshot(cb)
    exports.fivemanage:requestScreenshot(function(data)
        cb(data)
    end)
end
