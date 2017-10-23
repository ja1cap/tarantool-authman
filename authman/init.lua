local auth = {}
local response = require('authman.response')
local error = require('authman.error')
local validator = require('authman.validator')
local db = require('authman.db')
local utils = require('authman.utils.utils')
local geo_utils = require('authman.utils.geo')
local fun = require('fun')

function auth.api(config)
    local api = {}

    config = validator.config(config)
    local user = require('authman.model.user').model(config)
    local password = require('authman.model.password').model(config)
    local password_token = require('authman.model.password_token').model(config)
    local social = require('authman.model.social').model(config)
    local session = require('authman.model.session').model(config)
    local socket = require('authman.model.socket').model(config)

    db.configurate(config).create_database()
    require('authman.migrations.migrations')(config)

    -----------------
    -- API methods --
    -----------------
    function api.registration(external_identity, user_id)
        external_identity = utils.lower(external_identity)

        local email = ''
        local phone = 0

        local user_tuple
        if validator.email(external_identity) then
            email = external_identity
            user_tuple = user.get_by_email(email, user.COMMON_TYPE)
        elseif validator.phone(external_identity) then
            phone = external_identity
            user_tuple = user.get_by_phone(phone, user.COMMON_TYPE)
        else
            return response.error(error.INVALID_PARAMS)
        end

        if user_tuple ~= nil then
            if user_tuple[user.IS_ACTIVE] and user_tuple[user.TYPE] == user.COMMON_TYPE then
                return response.error(error.USER_ALREADY_EXISTS)
            else
                local code = user.generate_activation_code(user_tuple[user.ID])
                return response.ok(user.serialize(user_tuple, {code=code}))
            end
        end

        user_tuple = {
            [user.EMAIL] = email,
            [user.PHONE] = phone,
            [user.TYPE] = user.COMMON_TYPE,
            [user.IS_ACTIVE] = false,
        }
        if validator.not_empty_string(user_id) then
            user_tuple[user.ID] = user_id
        end

        user_tuple = user.create(user_tuple)

        local code = user.generate_activation_code(user_tuple[user.ID])
        return response.ok(user.serialize(user_tuple, {code=code}))
    end

    function api.complete_registration(external_identity, code, raw_password)
        external_identity = utils.lower(external_identity)

        local is_email = validator.email(external_identity)
        local is_phone = validator.phone(external_identity)
        if not ((is_email or is_phone) and validator.not_empty_string(code)) then
            return response.error(error.INVALID_PARAMS)
        end

        if not password.strong_enough(raw_password) then
            return response.error(error.WEAK_PASSWORD)
        end

        local user_tuple
        if is_email then
            user_tuple = user.get_by_email(external_identity, user.COMMON_TYPE)
        elseif is_phone then
            user_tuple = user.get_by_phone(external_identity, user.COMMON_TYPE)
        else
            return response.error(error.INVALID_PARAMS)
        end

        if user_tuple == nil then
            return response.error(error.USER_NOT_FOUND)
        end

        if user_tuple[user.IS_ACTIVE] then
            return response.error(error.USER_ALREADY_ACTIVE)
        end

        local user_id = user_tuple[user.ID]
        local correct_code = user.generate_activation_code(user_id)
        if code ~= correct_code then
            return response.error(error.WRONG_ACTIVATION_CODE)
        end

        password.create_or_update({
            [password.USER_ID] = user_id,
            [password.HASH] = password.hash(raw_password, user_id)
        })

        user_tuple = user.update({
            [user.ID] = user_id,
            [user.IS_ACTIVE] = true,
            [user.REGISTRATION_TS] = utils.now(),
        })

        return response.ok(user.serialize(user_tuple))
    end

    function api.set_profile(user_id, user_profile)
        if not validator.not_empty_string(user_id) then
            return response.error(error.INVALID_PARAMS)
        end

        local user_tuple = user.get_by_id(user_id)
        if user_tuple == nil then
            return response.error(error.USER_NOT_FOUND)
        end

        if not user_tuple[user.IS_ACTIVE] then
            return response.error(error.USER_NOT_ACTIVE)
        end

        user_tuple = user.update({
          [user.ID] = user_id,
          [user.GENDER] = user_profile.gender or user_tuple[user.GENDER],
          [user.BIRTH_YEAR] = user_profile.birth_year or user_tuple[user.BIRTH_YEAR],
          [user.BIRTH_MONTH] = user_profile.birth_month or user_tuple[user.BIRTH_MONTH],
          [user.BIRTH_DAY] = user_profile.birth_day or user_tuple[user.BIRTH_DAY],
          [user.PROFILE] = {
            [user.PROFILE_FIRST_NAME] = user_profile.first_name or user_tuple[user.PROFILE_FIRST_NAME],
            [user.PROFILE_LAST_NAME] = user_profile.last_name or user_tuple[user.PROFILE_LAST_NAME],
          },
        })

        return response.ok(user.serialize(user_tuple))
    end

    function api.get_profile(user_id)
        if not validator.not_empty_string(user_id) then
            return response.error(error.INVALID_PARAMS)
        end

        local user_tuple = user.get_by_id(user_id)
        if user_tuple == nil then
            return response.error(error.USER_NOT_FOUND)
        end

        return response.ok(user.serialize(user_tuple))
    end

    function api.delete_user(user_id)
        if not validator.not_empty_string(user_id) then
            return response.error(error.INVALID_PARAMS)
        end

        local user_tuple = user.get_by_id(user_id)
        if user_tuple == nil then
            return response.error(error.USER_NOT_FOUND)
        end

        user.delete(user_id)
        password.delete_by_user_id(user_id)
        social.delete_by_user_id(user_id)
        password_token.delete(user_id)

        return response.ok(user.serialize(user_tuple))
    end

    function api.set_registration_geo(user_id, coords, coords_cube, country_name, country_iso_code, city_name, city_geoname_id)
      if not validator.not_empty_string(user_id) then
          return response.error(error.INVALID_PARAMS)
      end

      local user_tuple = user.get_by_id(user_id)
      if user_tuple == nil then
          return response.error(error.USER_NOT_FOUND)
      end

      if not user_tuple[user.IS_ACTIVE] then
          return response.error(error.USER_NOT_ACTIVE)
      end

      user_tuple = user.update({
          [user.ID] = user_id,
          [user.REGISTRATION_COORDS] = coords or {},
          [user.REGISTRATION_COORDS_CUBE] = coords_cube or { 0, 0, 0 },
          [user.REGISTRATION_COUNTRY_NAME] = country_name or '',
          [user.REGISTRATION_COUNTRY_ISO_CODE] = country_iso_code or '',
          [user.REGISTRATION_CITY_NAME] = city_name or '',
          [user.REGISTRATION_CITY_GEONAME_ID] = city_geoname_id or 0,
      })

      return response.ok(user.serialize(user_tuple))
    end

    function api.set_current_geo(user_id, coords, coords_cube, country_name, country_iso_code, city_name, city_geoname_id)
      if not validator.not_empty_string(user_id) then
          return response.error(error.INVALID_PARAMS)
      end

      local user_tuple = user.get_by_id(user_id)
      if user_tuple == nil then
          return response.error(error.USER_NOT_FOUND)
      end

      if not user_tuple[user.IS_ACTIVE] then
          return response.error(error.USER_NOT_ACTIVE)
      end

      user_tuple = user.update({
          [user.ID] = user_id,
          [user.CURRENT_COORDS] = coords or {},
          [user.CURRENT_COORDS_CUBE] = coords_cube or { 0, 0, 0 },
          [user.CURRENT_COORDS_TS] = utils.now(),
          [user.CURRENT_COUNTRY_NAME] = country_name or '',
          [user.CURRENT_COUNTRY_ISO_CODE] = country_iso_code or '',
          [user.CURRENT_CITY_NAME] = city_name or '',
          [user.CURRENT_CITY_GEONAME_ID] = city_geoname_id or 0,
      })

      return response.ok(user.serialize(user_tuple))
    end

    function api.nearby(lat, lng, gender, age, limit, offset)

      local point = geo_utils.coords_to_cude({ lng, lat })

      limit = limit or 10
      offset = offset or 0
      if gender ~= nil then
        gender = tonumber(gender)
      end
      if age ~= nil then
        if type(age) == 'table' then
          age[1] = tonumber(age[1])
          age[2] = tonumber(age[2])
        else
          age = tonumber(age)
        end
      end

      local results = {}
      local skip_count = 0

      for _, user_tuple in user.get_space().index[user.SPATIAL_INDEX]:pairs(point:totable(), { iterator = 'neighbor' }) do
        if user.filter_tuple(user_tuple) then
          if offset == 0 or skip_count > offset then
            local user_data = user.serialize(user_tuple)
            user_data.distance = math.ceil(point:distance(geo_utils.coords_to_cude(user_tuple[user.CURRENT_COORDS])))
            results[#results + 1] = user_data
          else
            skip_count = skip_count + 1
          end
        end
      end

      return true, results
    end

    function api.auth(external_identity, raw_password)
        external_identity = utils.lower(external_identity)

        local user_tuple
        if validator.email(external_identity) then
            user_tuple = user.get_by_email(external_identity, user.COMMON_TYPE)
        elseif validator.phone(external_identity) then
            user_tuple = user.get_by_phone(external_identity, user.COMMON_TYPE)
        else
            return response.error(error.INVALID_PARAMS)
        end

        if user_tuple == nil then
            return response.error(error.USER_NOT_FOUND)
        end

        if not user_tuple[user.IS_ACTIVE] then
            return response.error(error.USER_NOT_ACTIVE)
        end

        if not password.is_valid(raw_password, user_tuple[user.ID]) then
            return response.error(error.WRONG_PASSWORD)
        end

        local signed_session = session.create(user_tuple[user.ID], session.COMMON_SESSION_TYPE)
        user.update_session_ts(user_tuple)

        return response.ok(user.serialize(user_tuple, {session = signed_session}))
    end

    function api.check_auth(signed_session)
        if not validator.not_empty_string(signed_session) then
            return response.error(error.INVALID_PARAMS)
        end

        local encoded_session_data = session.validate_session(signed_session)

        if encoded_session_data == nil then
            return response.error(error.WRONG_SESSION_SIGN)
        end

        local session_tuple = session.get_by_session(encoded_session_data)
        if session_tuple == nil then
            return response.error(error.NOT_AUTHENTICATED)
        end

        local user_tuple = user.get_by_id(session_tuple[session.USER_ID])
        if user_tuple == nil then
            return response.error(error.USER_NOT_FOUND)
        end

        if not user_tuple[user.IS_ACTIVE] then
            return response.error(error.USER_NOT_ACTIVE)
        end


        local session_data = session.decode(encoded_session_data)
        local new_session
        if session_data.type == session.SOCIAL_SESSION_TYPE then

            local social_tuple = social.get_by_id(session_tuple[session.CREDENTIAL_ID])
            if social_tuple == nil then
                return response.error(error.USER_NOT_FOUND)
            end

            if session.is_expired(session_data) then
                return response.error(error.NOT_AUTHENTICATED)

            elseif session.need_social_update(session_data) then

                local updated_user_tuple = {user_tuple[user.ID]}
                local social_id = social.get_profile_info(
                    social_tuple[social.PROVIDER], social_tuple[social.TOKEN], updated_user_tuple
                )

                if social_id == nil then
                    return response.error(error.NOT_AUTHENTICATED)
                end

                user_tuple = user.update(updated_user_tuple)
                new_session = session.create(
                    user_tuple[user.ID], session.SOCIAL_SESSION_TYPE, social_tuple[social.ID]
                )

                user.update_session_ts(user_tuple)

            else
                new_session = signed_session
            end

            social_tuple = social.get_by_user_id(user_tuple[user.ID])

            return response.ok(
                user.serialize(user_tuple, {
                    session = new_session,
                    social = social.serialize(social_tuple),
                })
            )

        else

            if session.is_expired(session_data) then
                return response.error(error.NOT_AUTHENTICATED)

            elseif session.need_common_update(session_data) then
                new_session = session.create(session_data.user_id, session.COMMON_SESSION_TYPE)
                user.update_session_ts(user_tuple)
            else
                new_session = signed_session
            end

            return response.ok(user.serialize(user_tuple, {session = new_session}))

        end
    end

    function api.drop_session(signed_session)
        if not validator.not_empty_string(signed_session) then
            return response.error(error.INVALID_PARAMS)
        end

        local encoded_session_data = session.validate_session(signed_session)

        if encoded_session_data == nil then
            return response.error(error.WRONG_SESSION_SIGN)
        end

        local deleted = session.delete(encoded_session_data)
        return response.ok(deleted)
    end

    function api.restore_password(external_identity)
        external_identity = utils.lower(external_identity)

        local user_tuple
        if validator.email(external_identity) then
            user_tuple = user.get_by_email(external_identity, user.COMMON_TYPE)
        elseif validator.phone(external_identity) then
            user_tuple = user.get_by_phone(external_identity, user.COMMON_TYPE)
        else
            return response.error(error.INVALID_PARAMS)
        end

        if user_tuple == nil then
            return response.error(error.USER_NOT_FOUND)
        end

        if not user_tuple[user.IS_ACTIVE] then
            return response.error(error.USER_NOT_ACTIVE)
        end
        return response.ok(password_token.generate(user_tuple[user.ID]))
    end

    function api.complete_restore_password(external_identity, token, raw_password)
        external_identity = utils.lower(external_identity)

        if not validator.not_empty_string(token) then
            return response.error(error.INVALID_PARAMS)
        end

        local user_tuple
        if validator.email(external_identity) then
            user_tuple = user.get_by_email(external_identity, user.COMMON_TYPE)
        elseif validator.phone(external_identity) then
            user_tuple = user.get_by_phone(external_identity, user.COMMON_TYPE)
        else
            return response.error(error.INVALID_PARAMS)
        end

        if user_tuple == nil then
            return response.error(error.USER_NOT_FOUND)
        end

        if not user_tuple[user.IS_ACTIVE] then
            return response.error(error.USER_NOT_ACTIVE)
        end

        if not password.strong_enough(raw_password) then
            return response.error(error.WEAK_PASSWORD)
        end

        local user_id = user_tuple[user.ID]
        if password_token.is_valid(token, user_id) then

            password.create_or_update({
                [password.USER_ID] = user_id,
                [password.HASH] = password.hash(raw_password, user_id)
            })


            user_tuple = user.update({
                [user.ID] = user_id,
                [user.TYPE] = user.COMMON_TYPE,
            })

            password_token.delete(user_id)

            return response.ok(user.serialize(user_tuple))
        else
            return response.error(error.WRONG_RESTORE_TOKEN)
        end
    end

    function api.social_auth_url(provider, state)
        if not validator.provider(provider) then
            return response.error(error.WRONG_PROVIDER)
        end

        return response.ok(social.get_social_auth_url(provider, state))
    end

    function api.social_auth(provider, code)
        local token, social_id, social_tuple
        local user_tuple = {}

        if not (validator.provider(provider) and validator.not_empty_string(code)) then
            return response.error(error.WRONG_PROVIDER)
        end

        token = social.get_token(provider, code, user_tuple)
        if not validator.not_empty_string(token) then
            return response.error(error.WRONG_AUTH_CODE)
        end

        social_id = social.get_profile_info(provider, token, user_tuple)
        if not validator.not_empty_string(social_id) then
            return response.error(error.SOCIAL_AUTH_ERROR)
        end

        local now = utils.now()
        user_tuple[user.EMAIL] = utils.lower(user_tuple[user.EMAIL])
        user_tuple[user.IS_ACTIVE] = true
        user_tuple[user.TYPE] = user.SOCIAL_TYPE
        user_tuple[user.SESSION_UPDATE_TS] = now

        social_tuple = social.get_by_social_id(social_id, provider)
        if social_tuple == nil then
            user_tuple = user.create(user_tuple)
            social_tuple = social.create({
                [social.USER_ID] = user_tuple[user.ID],
                [social.PROVIDER] = provider,
                [social.SOCIAL_ID] = social_id,
                [social.TOKEN] = token,
            })
        else
            user_tuple[user.ID] = social_tuple[social.USER_ID]
            user_tuple = user.create_or_update(user_tuple)
            social_tuple = social.update({
                [social.ID] = social_tuple[social.ID],
                [social.USER_ID] = user_tuple[user.ID],
                [social.TOKEN] = token,
            })
        end

        local new_session = session.create(
            user_tuple[user.ID], session.SOCIAL_SESSION_TYPE, social_tuple[social.ID]
        )

        return response.ok(user.serialize(user_tuple, {
            session = new_session,
            social = social.serialize(social_tuple),
        }))
    end

    function api.socket_connect(socket_id, user_id, creation_ts)
      if not validator.not_empty_string(socket_id) or not validator.not_empty_string(user_id) then
          return response.error(error.INVALID_PARAMS)
      end

      local user_tuple = user.get_by_id(user_id)
      if user_tuple == nil then
          return response.error(error.USER_NOT_FOUND)
      end

      local socket_tuple = socket.create(socket_id, user_id, creation_ts)
      return response.ok(socket.serialize(socket_tuple))
    end

    function api.socket_disconnect(socket_id)
      if not validator.not_empty_string(socket_id) then
          return response.error(error.INVALID_PARAMS)
      end

      local socket_tuple = socket.get_by_id(socket_id)
      if socket_tuple == nil then
          return response.error(error.SOCKET_NOT_FOUND)
      end
      socket.delete(socket_id)

      return response.ok(socket.serialize(socket_tuple))
    end

    function api.sockets(user_id)
      if not validator.not_empty_string(user_id) then
          return response.error(error.INVALID_PARAMS)
      end

      local socket_tuples = socket.get_by_user_id(user_id)
      return response.ok(fun.map(socket.serialize, fun.iter(socket_tuples)):totable())
    end

    return api
end

return auth
