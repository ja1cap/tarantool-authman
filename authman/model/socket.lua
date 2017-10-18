local socket = {}

function socket.model(config)

  local model = {}

  model.SPACE_NAME = config.spaces.socket.name

  local shard
  if config.shard ~= nil then
    shard = require('shard')
  end

  model.PRIMARY_INDEX = 'primary'
  model.USER_ID_INDEX = 'user'

  model.ID = 1
  model.USER_ID = 2
  model.CREATION_TS = 3

  function model.get_space()
    return shard and shard[model.SPACE_NAME] or box.space[model.SPACE_NAME]
  end

  function model.serialize(socket_tuple)
      return {
          id = socket_tuple[model.ID],
          user_id = socket_tuple[model.USER_ID],
          creation_ts = socket_tuple[model.CREATION_TS],
      }
  end

  function model.create(socket_id, user_id, creation_ts)
    return model.get_space():insert{
      socket_id,
      user_id,
      creation_ts or os.time(),
    }
  end

  function model.get_by_id(socket_id)
      return model.get_space():get(socket_id)
  end

  function model.get_by_user_id(user_id)
      return model.get_space().index[model.USER_ID_INDEX]:select{user_id}
  end

  function model.delete(socket_id)
      local socket_tuple = model.get_space():delete(socket_id)
      return socket_tuple ~= nil
  end

end

return socket
