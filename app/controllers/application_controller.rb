# app/controllers/application_controller.rb
class ApplicationController < ActionController::API
  # Only include this if you added modules like Devise::Controllers::Helpers
  include ActionController::RequestForgeryProtection

  protect_from_forgery with: :null_session
end