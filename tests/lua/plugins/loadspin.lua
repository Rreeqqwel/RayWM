-- Runs away while loading, also catching the budget error with pcall.
while true do pcall(function() while true do end end) end
