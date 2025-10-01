# config/initializers/redis.rb
require 'connection_pool'

REDIS_POOL = ConnectionPool.new(size: 5, timeout: 5) do
  Redis.new(url: ENV['REDIS_URL'] || 'redis://localhost:6379/1')
end