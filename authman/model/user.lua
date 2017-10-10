local user = {}

local digest = require('digest')
local uuid = require('uuid')
local validator =  require('authman.validator')
local utils = require('authman.utils.utils')

-----
-- user (uuid, email, type, is_active, profile)
-----
function user.model(config)
    local model = {}
    model.SPACE_NAME = config.spaces.user.name

    model.PRIMARY_INDEX = 'primary'
    model.EMAIL_INDEX = 'email_index'
    model.PHONE_INDEX = 'phone_index'
    model.GEO_INDEX = 'geo_index'

    model.ID = 1
    model.EMAIL = 2
    model.PHONE = 3
    model.TYPE = 4
    model.IS_ACTIVE = 5
    model.PROFILE = 6
    model.REGISTRATION_TS = 7    -- date of auth.registration or auth.complete_registration
    model.SESSION_UPDATE_TS = 8  -- date of auth.auth, auth.social_auth or auth.check_auth if session was updated
    model.GENDER = 9
    model.BIRTH_YEAR = 10
    model.BIRTH_MONTH = 11
    model.BIRTH_DAY = 12
    model.GEO_COUNTRY_NAME = 13
    model.GEO_COUNTRY_ISO_CODE = 14
    model.GEO_CITY_NAME = 15
    model.GEO_CITY_GEONAME_ID = 16
    model.GEO_COORDS = 17
    model.GEO_COORDS_CUBE = 18

    model.PROFILE_FIRST_NAME = 'first_name'
    model.PROFILE_LAST_NAME = 'last_name'

    model.COMMON_TYPE = 1
    model.SOCIAL_TYPE = 2

    model.UNDEFINED_GENDER = 0
    model.MALE_GENDER = 1
    model.FEMALE_GENDER = 1

    function model.get_space()
        return box.space[model.SPACE_NAME]
    end

    function model.serialize(user_tuple, data)

        local user_data = {
            id = user_tuple[model.ID],
            email = user_tuple[model.EMAIL],
            phone = user_tuple[model.PHONE],
            is_active = user_tuple[model.IS_ACTIVE],
            profile = user_tuple[model.PROFILE],
            gender = user_tuple[model.GENDER],
            birth_year = user_tuple[model.BIRTH_YEAR],
            birth_month = user_tuple[model.BIRTH_MONTH],
            birth_day = user_tuple[model.BIRTH_DAY],
            geo = {
                country_name = user_tuple[model.GEO_COUNTRY_NAME],
                country_iso_code = user_tuple[model.GEO_COUNTRY_ISO_CODE],
                city_name = user_tuple[model.GEO_CITY_NAME],
                city_geoname_id = user_tuple[model.GEO_CITY_GEONAME_ID],
                coords = user_tuple[model.GEO_COORDS],
                coords_cube = user_tuple[model.GEO_COORDS_CUBE],
            },
        }
        if data ~= nil then
            for k,v in pairs(data) do
                user_data[k] = v
            end
        end

        return user_data
    end

    function model.get_by_id(user_id)
        return model.get_space():get(user_id)
    end

    function model.get_by_email(email, type)
        if validator.not_empty_string(email) then
            return model.get_space().index[model.EMAIL_INDEX]:select({email, type})[1]
        end
    end

    function model.get_id_by_email(email, type)
        local user_tuple = model.get_by_email(email, type)
        if user_tuple ~= nil then
            return user_tuple[model.ID]
        end
    end

    function model.get_by_phone(phone, type)
        if validator.phone(phone) then
            return model.get_space().index[model.PHONE_INDEX]:select({phone, type})[1]
        end
    end

    function model.get_id_by_phone(phone, type)
        local user_tuple = model.get_by_email(phone, type)
        if user_tuple ~= nil then
            return user_tuple[model.ID]
        end
    end

    function model.delete(user_id)
        if validator.not_empty_string(user_id) then
            return model.get_space():delete({user_id})
        end
    end

    function model.create(user_tuple)
        -- create is registration
        user_tuple[model.REGISTRATION_TS] = utils.now()

        local user_id
        if user_tuple[model.ID] then
            user_id = user_tuple[model.ID]
        else
            user_id = uuid.str()
        end
        local email = validator.string(user_tuple[model.EMAIL]) and user_tuple[model.EMAIL] or ''
        local phone = validator.positive_number(user_tuple[model.PHONE]) and user_tuple[model.PHONE] or 0
        return model.get_space():insert{
            user_id,
            email,
            phone,
            user_tuple[model.TYPE],
            user_tuple[model.IS_ACTIVE],
            user_tuple[model.PROFILE],
            user_tuple[model.REGISTRATION_TS],
            user_tuple[model.SESSION_UPDATE_TS],
            user_tuple[model.GENDER] or model.UNDEFINED_GENDER,
            user_tuple[model.BIRTH_YEAR] or 0,
            user_tuple[model.BIRTH_MONTH] or 0,
            user_tuple[model.BIRTH_DAY] or 0,
            user_tuple[model.GEO_COUNTRY_NAME] or '',
            user_tuple[model.GEO_COUNTRY_ISO_CODE] or '',
            user_tuple[model.GEO_CITY_NAME] or '',
            user_tuple[model.GEO_CITY_GEONAME_ID] or 0,
            user_tuple[model.GEO_COORDS] or {},
            user_tuple[model.GEO_COORDS_CUBE] or { 0, 0, 0 },
        }
    end

    function model.update(user_tuple)
        local user_id, fields
        user_id = user_tuple[model.ID]
        fields = utils.format_update(user_tuple)
        return model.get_space():update(user_id, fields)
    end

    function model.create_or_update(user_tuple)
        local user_id = user_tuple[model.ID]

        if user_id and model.get_by_id(user_id) then
            user_tuple = model.update(user_tuple)
        else
            user_tuple = model.create(user_tuple)
        end
        return user_tuple
    end

    function model.set_new_id(user_id, new_user_id)
        local user_tuple = model.get_by_id(user_id)
        model.delete(user_id)

        model.create_or_update()
        return model.get_space():update(user_id, {{'=', model.ID, new_user_id}})
    end

    function model.generate_activation_code(user_id)
        return digest.md5_hex(string.format('%s%s', config.activation_secret, user_id))
    end

    function model.update_session_ts(user_tuple)
        if not validator.table(user_tuple) then
            user_tuple = user_tuple:totable()
        end
        user_tuple[model.SESSION_UPDATE_TS] = utils.now()
        model.update(user_tuple)
    end

    return model
end

return user