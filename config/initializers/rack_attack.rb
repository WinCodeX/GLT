Rack::Attack.throttle('api', limit: 100, period: 1.hour) do |req|
  req.ip if req.path.start_with?('/api/')
end