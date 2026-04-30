-- Fallback — loads alphabetically last, only defines CaptureScreenshot if no
-- managed bridge claimed it. Warns the user that a screenshot resource is missing.
if CaptureScreenshot then return end

function CaptureScreenshot(cb)
    print('[pickle_dealerships] No screenshot resource detected. Install screenshot-basic or a compatible alternative (fivemanage, fivemerr).')
    cb(nil)
end
