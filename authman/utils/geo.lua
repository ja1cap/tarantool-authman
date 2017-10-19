local geo = {}

local _, gis = pcall(require, 'gis')

function geo.coords_to_cude(coords)
    if type(gis) ~= 'table' then
        error('gis module not found')
    end
    return gis.Point(coords, 4326):transform(4328) -- lonlat to geocentric (3D)
end

return geo
